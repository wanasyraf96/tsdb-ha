# TimescaleDB HA Stack — Design Spec

**Date:** 2026-05-28
**Owner:** nazeem@vectolabs.com
**Status:** Approved (pending user review of this document)
**Location:** `/Users/vectolabs/apps/infra/timescaledb/`

## 1. Goal

Run an optimized TimescaleDB cluster in Docker Compose with a streaming read replica and automated failover, sized for a single 1 vCPU / 4 GB ARM host (m7g.medium). The app must connect through stable endpoints that survive node loss without configuration changes.

## 2. Workload

- **IoT/time-series ingest** plus **analytics/reporting**.
- Analytics granularity: hourly, daily, weekly, monthly, yearly (continuous aggregates on hypertables).
- Data retention: **7 years**, enforced via TimescaleDB compression + retention policies on hypertables — not via backups.

## 3. Non-goals

- True host-failure HA (single-host setup; both nodes share the same machine).
- Prometheus/Grafana shipped in this stack — metrics endpoints are exposed for an external Prometheus to scrape.
- Alert rules — listed conceptually; live wherever the user's monitoring stack does.
- Off-host backup target (S3, GCS) — documented as a one-line `.env` follow-up; not configured by default.
- TLS between containers — everything is on an internal docker network for now.
- Multi-host deployment — out of scope, but the design has a documented upgrade path.

## 4. Architecture

Single host, four small compose units on a shared external docker network. Apps connect to stable endpoints that don't change when a node is promoted, demoted, restarted, or wiped and re-bootstrapped.

```
                                  Host bind-mounts
                                  /var/lib/tsdb/{primary,replica,etcd,backups}
                                              │
   ┌──────────────────── tsdb-net (external docker network) ────────────────────┐
   │                                                                            │
   │   ┌─ proxy/ compose ─────────────────────────────────┐                     │
   │   │  pgbouncer:6432  ──►  haproxy:5000 (writes →leader)                    │
   │   │  haproxy:5001 (reads → replica, falls back to leader)                  │
   │   │  haproxy:7000 (stats UI, host loopback only)                           │
   │   │  pgbackrest-cron  (scheduled full/diff via haproxy:5000)               │
   │   └──────────────────────────────────────────────────┘                     │
   │                          ▲             ▲                                   │
   │                          │             │   Patroni REST API on :8008       │
   │                          │             │   (HAProxy health checks)         │
   │   ┌─ etcd/ compose ──────┴───────────┐ │                                   │
   │   │  etcd:2379  (DCS — leader election, cluster state)                     │
   │   └──────────────────────────────────┘                                     │
   │                          ▲             ▲                                   │
   │   ┌─ primary/ compose ───┴──┐  ┌───────┴── replica/ compose ──┐            │
   │   │  patroni → postgres:5432│  │ patroni → postgres:5432      │            │
   │   │  pgbackrest (archive)   │  │ pgbackrest (archive)         │            │
   │   │  pg_exporter:9187       │  │ pg_exporter:9188             │            │
   │   └─────────────────────────┘  └──────────────────────────────┘            │
   │                                                                            │
   └────────────────────────────────────────────────────────────────────────────┘
```

### 4.1 Stable endpoints

| Endpoint | Purpose | Behind |
|---|---|---|
| `localhost:6432` | App writes | pgBouncer → HAProxy → current leader |
| `localhost:5001` | App reads | HAProxy → current replica (falls back to leader if replica unhealthy or lagging >10 MB) |
| `127.0.0.1:7000` | HAProxy stats UI | HAProxy |
| `127.0.0.1:9187` | Primary node metrics | postgres_exporter |
| `127.0.0.1:9188` | Replica node metrics | postgres_exporter |

Internal-only (never published to host): postgres `:5432` on either node, Patroni REST `:8008`, etcd `:2379`.

### 4.2 Compose units

| Compose | Role | Lifecycle |
|---|---|---|
| `etcd/` | DCS for Patroni. Single-node (SPOF for now; replaceable later by 3-node etcd cluster). | Up before any Patroni. |
| `proxy/` | Stable endpoint layer: HAProxy + pgBouncer + pgbackrest-cron. | Survives node swaps; only restart on its own config changes. |
| `primary/` | First Patroni-managed postgres node. | Independent up/down without affecting replica. |
| `replica/` | Second Patroni-managed postgres node. | Independent up/down; re-bootstraps from etcd state if PGDATA empty. |

## 5. Folder layout

```
infra/timescaledb/
├── README.md
├── .env.example                    # image tags, memory knobs, paths, passwords, cluster name
├── Makefile                        # build, up, down, status, switchover, failover, psql, backup, restore, drills
├── docker/
│   └── Dockerfile.tsdb-ha          # timescaledb + patroni + pgbackrest
├── etcd/
│   └── docker-compose.yml
├── proxy/
│   ├── docker-compose.yml
│   ├── haproxy/
│   │   └── haproxy.cfg
│   ├── pgbouncer/
│   │   ├── pgbouncer.ini
│   │   └── entrypoint.sh           # SCRAM userlist shim (edoburu pattern)
│   └── pgbackrest/
│       ├── pgbackrest.conf
│       └── crontab
├── primary/
│   ├── docker-compose.yml
│   ├── patroni.yml                 # node-local; cluster defaults live in DCS after bootstrap
│   └── post-init.sh                # one-shot: app role, monitoring role, extensions
├── replica/
│   ├── docker-compose.yml
│   └── patroni.yml                 # same shape, differs only in `name`, `connect_address`
├── scripts/
│   └── drills/
│       ├── failover.sh
│       ├── replica-kill.sh
│       └── restore.sh
└── docs/
    ├── architecture.md
    ├── operations.md
    ├── tuning.md
    ├── ha.md
    ├── backup-restore.md
    └── specs/
        └── 2026-05-28-timescaledb-stack-design.md   # this document
```

## 6. Container specs

### 6.1 Custom image (`docker/Dockerfile.tsdb-ha`)

```dockerfile
FROM timescale/timescaledb:2.27.1-pg18
USER root
RUN apk add --no-cache python3 py3-pip py3-psycopg2 pgbackrest tini su-exec \
 && pip install --break-system-packages 'patroni[etcd3]==4.0.*'
COPY entrypoint.sh /usr/local/bin/
ENTRYPOINT ["/sbin/tini","--","entrypoint.sh"]
```

- Image tag and Patroni version pinned in `.env` (`TSDB_HA_IMAGE_TAG`, `PATRONI_VERSION`).
- `entrypoint.sh` drops privileges to `postgres` and execs `patroni /etc/patroni.yml`.
- Built locally via `make build`. No registry required.

### 6.2 etcd

- Image: `bitnami/etcd:3.5` (multi-arch, ARM-compatible).
- Auth: `ETCD_ROOT_PASSWORD` from `.env`.
- Bind-mount: `/var/lib/tsdb/etcd` → `/bitnami/etcd`.
- Single-node now; cluster mode is the documented upgrade path.

### 6.3 Patroni configuration

`patroni.yml` (primary; replica differs only in `name` and `connect_address`):

```yaml
scope: tsdb
namespace: /service/
name: tsdb-primary

restapi:
  listen: 0.0.0.0:8008
  connect_address: tsdb-primary:8008

etcd3:
  hosts: etcd:2379
  username: root
  password: ${ETCD_ROOT_PASSWORD}

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        shared_preload_libraries: 'timescaledb,pg_stat_statements'
        # Memory (1 vCPU / 4 GB host shared by both PGs)
        shared_buffers: 768MB
        effective_cache_size: 2GB
        work_mem: 16MB
        maintenance_work_mem: 128MB
        wal_buffers: 16MB
        # Write path (IoT ingest)
        wal_level: replica
        max_wal_size: 2GB
        min_wal_size: 512MB
        checkpoint_completion_target: 0.9
        synchronous_commit: 'off'
        wal_compression: 'on'
        archive_mode: 'on'
        archive_command: 'pgbackrest --stanza=tsdb archive-push %p'
        # Replication
        max_wal_senders: 5
        max_replication_slots: 5
        hot_standby: 'on'
        hot_standby_feedback: 'on'
        wal_keep_size: 256MB
        # Parallelism
        max_worker_processes: 8
        max_parallel_workers: 2
        max_parallel_workers_per_gather: 1
        timescaledb.max_background_workers: 8
        # Logging
        log_min_duration_statement: 500ms
        log_checkpoints: 'on'
        log_lock_waits: 'on'

  post_init: /etc/patroni/post-init.sh

  initdb:
    - encoding: UTF8
    - data-checksums

postgresql:
  listen: 0.0.0.0:5432
  connect_address: tsdb-primary:5432
  data_dir: /var/lib/postgresql/data/pgdata
  bin_dir: /usr/local/bin
  authentication:
    replication:
      username: replicator
      password: ${REPLICATOR_PASSWORD}
    superuser:
      username: postgres
      password: ${POSTGRES_PASSWORD}
    rewind:
      username: rewind_user
      password: ${REWIND_PASSWORD}
  parameters: {}
  pg_hba:
    - host replication replicator 0.0.0.0/0 scram-sha-256
    - host all          all        0.0.0.0/0 scram-sha-256
    - host all          all        ::/0      scram-sha-256

tags:
  noloadbalance: false
  clonefrom: false
  nosync: false
```

Replica `patroni.yml` overrides:

```yaml
name: tsdb-replica
restapi:
  connect_address: tsdb-replica:8008
postgresql:
  connect_address: tsdb-replica:5432
  parameters:
    shared_buffers: 512MB
    work_mem: 32MB
    default_statistics_target: 200
```

> Note: cluster-wide `parameters` under `bootstrap.dcs.postgresql.parameters` apply to both nodes. Per-node `postgresql.parameters` in each node's `patroni.yml` override the cluster defaults. The replica trades 256 MB of buffer cache for larger `work_mem` to favor analytical query plans.

### 6.4 `post-init.sh` (runs once on first leader bootstrap)

- Creates `app` role + `tsdb` database.
- Creates read-only `monitoring` role (used by postgres_exporter).
- `CREATE EXTENSION timescaledb; CREATE EXTENSION pg_stat_statements;`
- Logs hypertable + continuous-aggregate templates (1h/1d/1w/1mo/1y) as commented examples for the operator to apply per schema.

### 6.5 HAProxy (`proxy/haproxy/haproxy.cfg`)

```
listen postgres_write
    bind *:5000
    option httpchk GET /leader
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server tsdb-primary tsdb-primary:5432 check port 8008
    server tsdb-replica tsdb-replica:5432 check port 8008

listen postgres_read
    bind *:5001
    balance roundrobin
    option httpchk
    http-check send meth GET uri /replica?lag=10MB
    http-check expect status 200
    server tsdb-replica tsdb-replica:5432 check port 8008
    server tsdb-primary tsdb-primary:5432 check port 8008 backup

listen stats
    bind *:7000
    stats enable
    stats uri /
```

- `/leader` returns 200 only on the current leader.
- `/replica?lag=10MB` returns 200 only on a replica with replay lag < 10 MB.
- `on-marked-down shutdown-sessions` resets stale client connections on failover so apps don't hang on TCP keepalive.

### 6.6 pgBouncer

- Image: `edoburu/pgbouncer:latest` (Alpine; ships psql + nc for the SCRAM userlist shim).
- `pool_mode = transaction`
- `max_client_conn = 500`, `default_pool_size = 25`, `min_pool_size = 5`
- `server_reset_query = DISCARD ALL`
- `auth_type = scram-sha-256`; userlist generated at boot by an entrypoint shim that queries postgres via `haproxy:5000` for the SCRAM hash.
- Upstream is `haproxy:5000` so failover requires no pgBouncer reconfig.
- Published to host on `:6432`.

### 6.7 pgBackRest

- Binary baked into the custom postgres image for `archive_command` (only the current leader actually pushes WAL).
- Standalone `pgbackrest-cron` container in `proxy/`:
  - Shares `/var/lib/tsdb/backups` bind-mount with both pg nodes.
  - `pgbackrest.conf` sets `pg1-host=haproxy`, `pg1-port=5000` so backups always target the current leader.
  - Cron:
    - Sun 02:00 → `--type=full backup`
    - Mon–Sat 02:00 → `--type=diff backup`
    - Daily 02:30 → `expire`
  - Retention: `repo1-retention-full=2`, `repo1-retention-diff=6` (~2 weeks rolling PITR).
  - Runs `stanza-create` idempotently and `pgbackrest check` at startup.

### 6.8 postgres_exporter

- One sidecar per pg node, in its node's compose unit.
- Connects via docker network using the read-only `monitoring` role.
- Published to host loopback only: `127.0.0.1:9187` (primary), `127.0.0.1:9188` (replica).

## 7. Data flow

### 7.1 Write path

```
app  ──►  localhost:6432 (pgbouncer)  ──►  haproxy:5000  ──►  current leader:5432
                                                                    │
                                                                    ├──► hypertables (raw)
                                                                    ├──► continuous aggregates 1h/1d/1w/1mo/1y
                                                                    ├──► compression policy (chunks > 7d)
                                                                    └──► retention policy (drop chunks > 7y)
                                                                          │
                                                                          ▼
                                                                       WAL stream
                                                                          │
                                                          ┌───────────────┴─────────────┐
                                                          ▼                             ▼
                                                  current standby                 archive_command
                                                                                  → pgbackrest archive-push
```

### 7.2 Read path

```
analytics  ──►  localhost:5001 (haproxy)  ──►  current healthy replica (lag < 10 MB)
                                                       │
                                                       └──► leader (fallback when replica unhealthy)
```

`hot_standby_feedback = on` on the replica avoids snapshot-conflict cancellations during long analytics queries.

### 7.3 Failover sequence (~10–20 s end-to-end)

1. t+0  — leader becomes unreachable (crash, kill, OOM, network drop).
2. t+5  — Patroni on the standby notices missed leader heartbeat.
3. t+10 — etcd leader-key TTL expires.
4. t+10 — Standby's Patroni acquires the leader key.
5. t+11 — Patroni runs `pg_promote()` on the standby.
6. t+12 — HAProxy's `/leader` probe on the new leader returns 200; routes `:5000` to it.
7. t+12 — `on-marked-down shutdown-sessions` resets stale connections to old leader.
8. t+13 — pgBouncer reconnects through HAProxy to new leader; app's next query succeeds.

DCS timing knobs (`ttl=30`, `loop_wait=10`, `retry_timeout=10`) are conservative — they tolerate transient blips at the cost of ~15 s failover. Documented in `docs/ha.md`.

### 7.4 Old primary rejoining

1. Patroni starts on the recovered node.
2. Sees current leader in etcd; does not race for promotion.
3. Runs `pg_rewind` against the new leader if timelines diverged.
4. If `pg_rewind` fails, nukes PGDATA and runs a fresh `pg_basebackup`.
5. Starts streaming as standby.

No operator action required for the standard recovery path.

### 7.5 Backup flow

- WAL archive: every WAL segment, pushed by `archive_command` running on the current leader, into the shared `/var/lib/tsdb/backups` bind-mount.
- Scheduled: pgbackrest-cron connects through `haproxy:5000` so it always backs up the current leader.
- Restore: destructive, all-uppercase-confirmation Makefile target documented in `docs/backup-restore.md`.

## 8. Operations

### 8.1 Makefile targets

| Target | Description |
|---|---|
| `make build` | Build custom `tsdb-ha` image. |
| `make net` | Create external `tsdb-net` docker network (idempotent). |
| `make up` | Full stack with ordered health gates: net → etcd → primary → proxy → replica. |
| `make up-etcd` / `up-primary` / `up-proxy` / `up-replica` | One unit at a time. |
| `make down` / `down-<unit>` | Stop. Bind-mounts retained. |
| `make nuke-replica` | Stop replica and wipe its PGDATA (confirmation required). |
| `make status` | One-screen overview: `patronictl list`, HAProxy backends, etcd health, replication lag, last backup. |
| `make psql` / `psql-replica` | psql to leader via pgbouncer; psql to replica via haproxy:5001. |
| `make logs SERVICE=<svc>` | Tail logs across compose units. |
| `make switchover` | Planned, graceful role swap. |
| `make failover` | Emergency promotion (confirmation required). |
| `make reinit-replica` | Tell Patroni to wipe and re-bootstrap the replica. |
| `make backup TYPE=full\|diff` | On-demand backup. |
| `make backup-info` | List backups + WAL coverage window. |
| `make restore POINT_IN_TIME='YYYY-MM-DD HH:MM:SS'` | PITR (requires typing `RESTORE`). |
| `make exporter-curl` | Smoke-test exporter + HAProxy stats endpoints. |
| `make drill-failover` / `drill-replica-kill` / `drill-restore` | Verification drills (see §9). |

### 8.2 Standard runbook scenarios

Documented in `docs/operations.md`:

1. First-time setup.
2. Planned host reboot.
3. Replica lagging.
4. Primary OOM or crash (auto-handled by Patroni).
5. Planned primary maintenance via `switchover`.
6. Backup not running.
7. Restore to a point in time.

### 8.3 Safety rules baked into the Makefile

- All `up-*` targets are idempotent.
- All destructive targets require typing a confirmation string.
- `make down` never passes `-v`. Bind-mounts are wiped only via `make nuke-*`.
- Every target verifies `.env` exists and points to `.env.example` if missing.

## 9. Verification — failure drills

Scripts under `scripts/drills/`, invoked via Makefile, run against the bind-mounted dev data only.

| Drill | What it does | Pass criterion |
|---|---|---|
| `make drill-failover` | `docker kill -s SIGKILL` the leader; run write loop on `:6432` and read loop on `:5001` from a busybox sidecar on `tsdb-net`; measure downtime. | Write downtime < 30 s; read downtime < 5 s; killed node rejoins automatically. |
| `make drill-replica-kill` | Kill standby; verify writes flow, reads route to leader via HAProxy fallback, WAL slot retains; restart replica and verify catch-up. | Zero write failures; zero read failures; replica catches up < 60 s. |
| `make drill-restore` | Insert sentinel A, sleep 30 s, insert sentinel B, restore to a point between A and B, verify A exists and B does not. | PITR boundary correct; cluster reaches consistent state. |

Drills should be run after every meaningful change (image bump, Patroni config change, tuning change).

## 10. Key metrics worth alerting on

| Metric | Source | Alert condition |
|---|---|---|
| `pg_replication_slots.active` | postgres_exporter | 0 — slot exists but not streaming |
| `pg_stat_replication.replay_lag` | postgres_exporter | > 30 s |
| `pg_replication.is_in_recovery` on primary node | postgres_exporter | true — unexpected demotion |
| `pgbackrest info --output=json` last full | pgbackrest-cron sidecar | > 8 d |
| HAProxy backend `tsdb-primary` on `:5000` | HAProxy stats | down > 1 min |
| etcd health | etcd | unhealthy — DCS unavailable, no promotions possible |

Alert wiring lives in the user's existing monitoring stack; no rules shipped here.

## 11. Tuning rationale

- **`synchronous_commit = off`** — biggest single ingest win. With WAL archiving + a replica, the durability tradeoff is bounded to the time between two WAL flushes (~200 ms).
- **`shared_buffers = 768 MB` (primary), `512 MB` (replica)** — sum stays under ~1.3 GB so the host has headroom for OS cache, pgbouncer, etcd, haproxy, and exporters.
- **`hot_standby_feedback = on`** — accept the bloat back-pressure cost in exchange for long analytics queries that don't get cancelled. Fine for IoT writes which mostly hit fresh chunks.
- **`max_parallel_workers = 2`** — single vCPU means parallelism above 2 doesn't help and increases scheduling overhead.
- **`timescaledb.max_background_workers = 8`** — enough for compression + multiple continuous aggregate refreshes without starving foreground queries.

## 12. Upgrade path to multi-host HA

When a second machine arrives:

1. Provision a 3-node etcd cluster (two on the new host, one on the existing).
2. Update `etcd3.hosts` in both `patroni.yml` files to list all etcd members.
3. Move `replica/` compose to the new host with the same bind-mount layout.
4. Update HAProxy `server` lines to point at the new host's IP for `tsdb-replica`.
5. Run `make drill-failover` to confirm cross-host promotion works.

No schema changes. No app-side changes. The `localhost:6432` and `localhost:5001` endpoints continue to be the only thing apps know about (deploy HAProxy on each app host, or front the cluster with a network LB).

## 13. Out of scope (explicit)

- Prometheus / Grafana / Alertmanager containers.
- Alert rule files.
- S3 / GCS backup target configuration (defaults are local-only).
- TLS on Patroni REST, HAProxy frontends, etcd client port.
- Multi-host etcd / Patroni topology.
- Application-side schema (hypertable definitions, continuous-aggregate views, retention policy SQL) — templates printed in `post-init.sh` for the operator to apply per dataset.

## 14. Open items resolved during brainstorming

| Question | Decision |
|---|---|
| Folder location | `infra/timescaledb/` under `apps/infra/` |
| Workload profile | IoT ingest + analytics, hourly→yearly aggregation, 7 y retention |
| Host size | m7g.medium (1 vCPU / 4 GB ARM); tuning sized accordingly |
| Replica topology | Two compose files on the same host for independent up/down |
| Optional services | pgBouncer in front of primary, postgres_exporter on each node, pgBackRest |
| PG / TimescaleDB version | `timescale/timescaledb:2.27.1-pg18` (pinned via `.env`) |
| Failover automation | Patroni + etcd + HAProxy (chosen over repmgr and custom shell) |
| Read fallback | Reads fall back to primary when replica unhealthy or lagging > 10 MB |
