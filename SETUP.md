# Setup Guide

How to stand up a TimescaleDB HA stack from a fresh Linux/macOS host. Every
step has a "verify" command and a "if it fails" pointer. Allow ~20 minutes
end-to-end on a reasonable network.

## 1. Prerequisites

| What | Why | How to check |
|---|---|---|
| **Docker Engine 24+** with the Compose v2 plugin | runs every service | `docker --version && docker compose version` — both must succeed |
| **Bash + make + curl + python3** | the Makefile + drill scripts use them | `which bash make curl python3` |
| **psql client (libpq)** — optional | only needed if you'll run the verification drills (step 7) or use `make psql*` from the host. Skip if your app brings its own driver and you'll `docker exec` for ad-hoc SQL | `psql --version` |
| **~5 GB free disk** | image + PGDATA + WAL + backups | `df -h .` |
| **No process bound to the published ports** | conflict prevents bring-up | see ports table below |

Published host ports (defaults from `.env.example`; all configurable):

| Port | Service | Purpose |
|---|---|---|
| `16432` | pgBouncer → HAProxy → primary | application writes |
| `15001` | HAProxy → replica (fallback: primary) | application reads |
| `17000` | HAProxy stats UI | ops only — bind to `127.0.0.1` |
| `19187` / `19188` | postgres_exporter on primary / replica | Prometheus scrape |

Check for conflicts:

```bash
for p in 16432 15001 17000 19187 19188; do
  (lsof -nP -iTCP:$p -sTCP:LISTEN 2>/dev/null || ss -tlnp 2>/dev/null | grep ":$p ") && echo "PORT $p IS IN USE"
done
```

If any port is in use, edit the corresponding `*_HOST_PORT` in `.env`
(step 3).

## 2. Get the code

```bash
git clone https://github.com/wanasyraf96/tsdb-ha.git
cd tsdb-ha
```

**Verify:** `ls Makefile docker/ primary/ replica/ proxy/ etcd/` shows all
directories exist.

## 3. Configure `.env`

```bash
cp .env.example .env
$EDITOR .env
```

What you **must** change before any non-dev use:

| Group | Variables | Notes |
|---|---|---|
| **Passwords** | `POSTGRES_PASSWORD`, `REPLICATOR_PASSWORD`, `REWIND_PASSWORD`, `APP_PASSWORD`, `MONITORING_PASSWORD`, `PGBOUNCER_AUTH_PASSWORD`, `ETCD_ROOT_PASSWORD` | each different, ≥20 chars. Generate with `openssl rand -hex 24` |
| **App identity** | `APP_DB`, `APP_USER` | the database + role your application uses |
| **Storage paths** | `DATA_ROOT` | for production set to an absolute path on a dedicated disk, e.g. `DATA_ROOT=/var/lib/tsdb`. Leave as `./data` for dev |

What you **may** change:

| Variable | Default | When to change |
|---|---|---|
| `PGBOUNCER_HOST_PORT`, `HAPROXY_READ_HOST_PORT`, `HAPROXY_STATS_HOST_PORT`, `PRIMARY_EXPORTER_HOST_PORT`, `REPLICA_EXPORTER_HOST_PORT` | offsets of `+10000` from canonical | if a port is already taken on the host (step 1) |
| `TSDB_BASE_IMAGE` | `timescale/timescaledb:2.27.1-pg18` | upgrading PostgreSQL/TimescaleDB versions |
| `PATRONI_VERSION` | `4.0.4` | upgrading Patroni |

**Verify the file loads cleanly:**

```bash
bash -c 'set -a; . ./.env; set +a; echo "DB=$APP_DB USER=$APP_USER DATA_ROOT=$DATA_ROOT"'
```

**If it fails** with a parsing error, you have a stray space or unquoted
special character around an `=`. Values with spaces need quotes:
`APP_PASSWORD='my password'`.

## 4. Get the tsdb-ha image

You have two options here. Pick one.

### Option A (recommended) — pull the published image

The fastest path. The published image is multi-arch (`linux/amd64` +
`linux/arm64`) so you don't need to install build dependencies on the host.

In `.env`, replace `TSDB_HA_IMAGE_TAG` with a published tag, e.g.:

```bash
TSDB_HA_IMAGE_TAG=wana96/tsdb-ha:v0.1.0       # or :latest for the rolling tag
```

Then:

```bash
make pull
```

### Option B — build locally

Use this if you need to customize `TSDB_BASE_IMAGE` or `PATRONI_VERSION`,
or if you can't reach Docker Hub from the target host.

```bash
make build
```

This builds `tsdb-ha:<version>-patroni<version>-pgbackrest` from
`docker/Dockerfile.tsdb-ha`. Takes 2–5 minutes on first build (downloads
TimescaleDB base + installs Patroni + pgBackRest). Subsequent rebuilds
are cached and fast.

### Verify (either option)

```bash
docker images | grep tsdb-ha
```

You should see one entry matching `TSDB_HA_IMAGE_TAG` from `.env`.

**If it fails:**
- `failed to authorize` / `connection reset` — pull-through registry issue.
  Try `docker pull timescale/timescaledb:2.27.1-pg18` (build path) or
  `docker pull wana96/tsdb-ha:latest` (pull path) directly first.
- `apk add: not found` (build only) — base image isn't Alpine. Check
  `TSDB_BASE_IMAGE` matches an Alpine variant of TimescaleDB.
- Out of disk — Docker keeps layers in `/var/lib/docker`. `docker system df`
  shows usage; `docker system prune` frees space.

## 5. Bring the stack up

```bash
make up
```

This composes `build → net → up-etcd → up-primary → up-proxy → up-replica`
in order, then runs `make status` to print the final state. Each step
waits for its predecessor to report healthy before continuing. The first
bring-up takes ~60–90 seconds because the replica clones from the
primary via `pg_basebackup`.

**Expected `make status` output (the last block):**

```
── Patroni cluster ──
+ Cluster: tsdb ... ----+
| Member       | Role    | State     | TL | Lag in MB |
+--------------+---------+-----------+----+-----------+
| tsdb-primary | Leader  | running   |  1 |           |
| tsdb-replica | Replica | streaming |  1 |         0 |
+--------------+---------+-----------+----+-----------+

── HAProxy backends ──
  postgres_write     tsdb-primary    UP
  postgres_write     tsdb-replica    DOWN     ← expected: only primary serves writes
  postgres_read      tsdb-replica    UP
  postgres_read      tsdb-primary    UP

── pgBackRest ──
stanza: tsdb
    status: error (missing stanza path)        ← expected at this stage; step 6 fixes
```

**If a node fails to become healthy:**

```bash
docker ps -a                            # see which container is unhealthy
docker logs tsdb-primary --tail 80      # or tsdb-replica / haproxy / pgbouncer / etcd
make logs SERVICE=tsdb-primary          # tail -f equivalent
```

Common causes by container:

| Container | Symptom | Likely cause |
|---|---|---|
| `etcd` | not healthy within 30s | port 2379 taken inside docker network — usually a leftover container. `docker network inspect tsdb-net` |
| `tsdb-primary` | not healthy within 120s | etcd auth failure (mismatched `ETCD_ROOT_PASSWORD`), or PGDATA permission issue. Check logs for `failed to authenticate on etcd` |
| `tsdb-replica` | not healthy within 180s | replica can't reach primary on port 5432 inside the network, or `replicator` password mismatch. `docker exec tsdb-replica patronictl -c /tmp/patroni.yml list` |
| `haproxy` | not healthy within 30s | Patroni REST on 8008 not reachable for backend health checks. Confirm primary is healthy first |
| `pgbouncer` | crashes immediately | `userlist.txt` rendering failed — `MONITORING_PASSWORD` or `PGBOUNCER_AUTH_PASSWORD` is empty in `.env` |

To start over from scratch:

```bash
make down
rm -rf ${DATA_ROOT:-./data}
make up
```

## 6. First backup (initializes the pgBackRest stanza)

```bash
make backup
```

`make backup` is idempotent about the stanza — the first run creates it,
subsequent runs reuse it. The first backup defaults to `TYPE=diff` but
pgBackRest auto-promotes it to a full because no prior backup exists.

**Verify:**

```bash
make backup-info
```

You should see at least one backup listed with `status: ok`. Re-run
`make status` and the `pgBackRest` block will now show the backup
instead of "missing stanza path".

**If it fails:**
- `stanza-create command end: aborted with exception` — the leader can't
  write to `/var/lib/pgbackrest`. Check that `$BACKUP_REPO` on the host
  is writable by uid 70 (alpine postgres). `ls -ld $(pwd)/data/backups`.
- `WAL archive check failed` — `archive_command` isn't able to push. Check
  `docker exec tsdb-primary su-exec postgres pgbackrest --stanza=tsdb check`
  for the underlying error.

## 7. Run the verification drills

These are the gates for "is HA actually working?". Run all three on a
fresh stack before declaring success.

```bash
make drill-failover                    # ~40s
make drill-replica-kill                # ~30s
make drill-restore                     # ~2 min (does a full PITR cycle)
```

Each prints `PASS` on success. What each checks:

- **drill-failover** — kills the leader, asserts writes recover within
  the failover window and the old primary rejoins as replica.
- **drill-replica-kill** — pauses the replica, asserts writes keep flowing
  and reads fall back to the leader via HAProxy.
- **drill-restore** — inserts sentinel A, backs up, sleeps past target,
  inserts sentinel B, runs `make restore` to a timestamp between A and B,
  asserts only A is present in the restored cluster.

**If a drill fails:** see `docs/backup-restore.md` (PITR specifics),
`docs/ha.md` (failover specifics), and the logs of the relevant container.
A failed drill is a real problem — don't ship until they all pass.

## 8. Connect your application

Get the connection strings the app should use:

```bash
echo "Writes: postgresql://${APP_USER}:<APP_PASSWORD>@<host>:${PGBOUNCER_HOST_PORT:-16432}/${APP_DB}"
echo "Reads:  postgresql://${APP_USER}:<APP_PASSWORD>@<host>:${HAPROXY_READ_HOST_PORT:-15001}/${APP_DB}"
```

(Source `.env` first if running standalone:
`set -a; . ./.env; set +a`.)

**Verify from the host:**

```bash
make psql-app                          # writes path (pgBouncer)
make psql-replica                      # reads path (HAProxy → replica)
```

Both should drop you into a `psql` prompt. Run `\dt` — same tables on
both. Run `INSERT` on the writes path; run `SELECT` on the reads path a
moment later; row should appear.

**If the reads path returns the wrong rows or hangs:**

```bash
curl -s "http://127.0.0.1:${HAPROXY_STATS_HOST_PORT:-17000}/;csv" | \
  awk -F, 'NR>1 && $2!="FRONTEND" {print $1, $2, $18}'
```

You want `postgres_read` showing both members `UP`. If the replica is
DOWN, reads fall back to primary — that's safe but means replication is
broken. See `docs/operations.md` "Replica lag investigation".

## 9. Schedule recurring backups

The stack does **not** ship a backup scheduler container — backups run
from the host's crontab to keep the image small and the schedule
inspectable. Add to the host crontab (`crontab -e`):

```cron
0 2 * * 0    cd /path/to/tsdb-ha && make backup TYPE=full >>/var/log/tsdb-backup.log 2>&1
0 2 * * 1-6  cd /path/to/tsdb-ha && make backup TYPE=diff >>/var/log/tsdb-backup.log 2>&1
```

**Verify** by tailing the log after the first scheduled run, or trigger
manually now:

```bash
make backup TYPE=full
tail /var/log/tsdb-backup.log
```

Retention is enforced inside pgBackRest itself (`repo1-retention-full=2`,
`repo1-retention-diff=6` → ~2 weeks rolling). No separate cleanup job
needed.

## 10. Day-2 quick reference

| Need | Command |
|---|---|
| One-screen health check | `make status` |
| Planned role swap | `make switchover` |
| Force-promote replica (emergency) | `make failover` |
| Re-bootstrap replica from leader | `make reinit-replica` |
| Take an on-demand backup | `make backup` (or `make backup TYPE=full`) |
| Restore to a point in time | `make restore POINT_IN_TIME='2026-06-01 14:30:00'` |
| Tail one container | `make logs SERVICE=tsdb-primary` |
| psql writes / reads | `make psql` / `make psql-replica` |
| Stop everything (data preserved) | `make down` |

For deeper context:
- `docs/architecture.md` — what each compose unit does + boot order
- `docs/operations.md` — runbook for common scenarios
- `docs/ha.md` — what happens on primary failure
- `docs/tuning.md` — memory / WAL / parallelism knobs
- `docs/backup-restore.md` — backup schedule + PITR mechanics

## 11. General debugging cheat-sheet

When something is wrong and you don't yet know what:

```bash
# 1. What's actually running?
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# 2. Patroni's view of the world
docker exec tsdb-primary patronictl -c /tmp/patroni.yml list

# 3. HAProxy's view of the world
curl -s "http://127.0.0.1:${HAPROXY_STATS_HOST_PORT:-17000}/;csv" | head

# 4. etcd reachable + cluster keys present
docker exec etcd etcdctl --user root:$ETCD_ROOT_PASSWORD endpoint health
docker exec etcd etcdctl --user root:$ETCD_ROOT_PASSWORD get --prefix /service/tsdb/ --keys-only

# 5. Backup repo state
make backup-info

# 6. Recent logs of any container
docker logs <container> --tail 100 --timestamps
```

If you're really stuck, `make down && rm -rf ${DATA_ROOT:-./data} && make up`
is always safe for dev. Production: tear-down loses data — capture
`docker logs` for every container first.
