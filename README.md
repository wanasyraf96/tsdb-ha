# tsdb-ha — TimescaleDB HA Stack

A self-contained, single-host **High-Availability TimescaleDB** stack built
from Docker Compose units. Patroni + etcd orchestrate leader election and
automated failover; HAProxy + pgBouncer present stable read/write endpoints
that survive node swaps; pgBackRest handles backups and point-in-time
recovery.

Sized to run on a modest 1 vCPU / 4 GB ARM host, but scales up cleanly.

---

## Features

- **Automated failover** via Patroni — write path recovers in ~30–40 s after
  a leader kill (measured on the dev host).
- **Stable endpoints** that never change as roles flip:
  - Writes → `localhost:16432` (pgBouncer → HAProxy → current leader)
  - Reads  → `localhost:15001` (HAProxy → current replica, falls back to leader)
- **TimescaleDB 2.27 / PostgreSQL 18** base image, Patroni 4.0.4.
- **pgBackRest** with on-demand and scheduled backups, and a tested PITR
  flow (`make restore POINT_IN_TIME=...`).
- **Drill scripts** for failover, replica-kill, and restore — verifiable HA
  rather than aspirational HA.
- **Prometheus metrics** exposed via `postgres_exporter` on both nodes and
  the HAProxy stats page.
- **Configurable port offsets** (`+10000` by default) so this stack can run
  alongside another Postgres dev stack on the same host without clashing.
- **Idempotent `make` targets** with health gates — `make up` builds, brings
  everything up in order, and waits for each unit to become healthy.

---

## Architecture

Four Docker Compose units share an external network (`tsdb-net`):

```
                 ┌────────────────────────────────────────────────────┐
                 │                     Clients                        │
                 │     writes :16432            reads :15001          │
                 └──────────────┬──────────────────────┬──────────────┘
                                │                      │
                          ┌─────▼─────┐                │
                          │ pgBouncer │                │
                          └─────┬─────┘                │
                                │                      │
                          ┌─────▼──────────────────────▼─────┐
                          │             HAProxy              │
                          │   :5000 leader   :5001 replica   │
                          │       :7000 stats / health       │
                          └───┬─────────────────────────┬────┘
                              │                         │
                ┌─────────────▼────────┐  ┌─────────────▼────────┐
                │      tsdb-primary    │  │      tsdb-replica    │
                │  ┌────────────────┐  │  │  ┌────────────────┐  │
                │  │ Patroni + PG18 │  │  │  │ Patroni + PG18 │  │
                │  │  TimescaleDB   │◄─┼──┼──┤  TimescaleDB   │  │
                │  │  pgBackRest    │  │  │  │  (streaming    │  │
                │  └────────┬───────┘  │  │  │   replica)     │  │
                │           │          │  │  └────────────────┘  │
                │  postgres_exporter   │  │  postgres_exporter   │
                └───────────┼──────────┘  └──────────────────────┘
                            │                       │
                            │   Patroni DCS state   │
                            └───────────┬───────────┘
                                        │
                                  ┌─────▼──────┐
                                  │    etcd    │
                                  └────────────┘
```

| Compose unit | Contents                                | Role                                                              |
| ------------ | --------------------------------------- | ----------------------------------------------------------------- |
| `etcd/`      | etcd (single-node)                      | Patroni DCS. Up first, down last.                                 |
| `primary/`   | tsdb-ha image, postgres_exporter        | First PG node. Claims leadership on first boot, runs `post-init`. |
| `proxy/`     | HAProxy, pgBouncer                      | Stable client-facing endpoints. Survives node swaps.              |
| `replica/`   | tsdb-ha image, postgres_exporter        | Second PG node. Bootstraps from current leader.                   |

See [`docs/architecture.md`](./docs/architecture.md) for the deeper rationale
and the full design spec at
[`docs/specs/2026-05-28-timescaledb-stack-design.md`](./docs/specs/).

---

## Requirements

- **Docker** (with Buildx) and **Docker Compose v2**.
- **Make**, **bash**, **python3** (used by some Makefile helpers).
- **`psql` client** on the host (only needed for `make psql*` targets).
- ~4 GB RAM, ~2 vCPU on the host. The stack runs comfortably on a 1 vCPU
  / 4 GB ARM box; tuning lives in [`docs/tuning.md`](./docs/tuning.md).
- Linux or macOS. (Tested on macOS / Darwin ARM.)

---

## Quickstart

```bash
cp .env.example .env
$EDITOR .env                # set passwords + paths
make build                  # build the custom tsdb-ha image
make up                     # net → etcd → primary → proxy → replica
make status                 # one-screen cluster overview
```

That's it. `make up` is idempotent and waits for each layer to become
healthy before starting the next.

First-time install: [`SETUP.md`](./SETUP.md) has a step-by-step walkthrough
with verification + debugging at each stage.

### Skip the build — use the published image

If you don't need to customize the PostgreSQL/Patroni versions, point at the
prebuilt multi-arch image on Docker Hub instead of building locally:

```bash
cp .env.example .env
# In .env, replace TSDB_HA_IMAGE_TAG with:
#   TSDB_HA_IMAGE_TAG=wanasyraf96/tsdb-ha:latest
$EDITOR .env
make pull                   # docker pull the published image
make up
```

Published tags follow the git tags on this repo (`vMAJOR.MINOR.PATCH`), plus
a rolling `:latest`. Images are built for `linux/amd64` and `linux/arm64`.

---

## Endpoints

| Endpoint              | Purpose                                                | Behind                                |
| --------------------- | ------------------------------------------------------ | ------------------------------------- |
| `localhost:16432`     | **Writes** (apps connect here)                         | pgBouncer → HAProxy `:5000` → leader  |
| `localhost:15001`     | **Reads** (falls back to leader if no replica)         | HAProxy `:5001` → replica             |
| `127.0.0.1:17000`     | HAProxy stats UI                                       | HAProxy                               |
| `127.0.0.1:19187`     | Primary `postgres_exporter` (Prometheus metrics)       | postgres_exporter                     |
| `127.0.0.1:19188`     | Replica `postgres_exporter` (Prometheus metrics)       | postgres_exporter                     |

Ports are configurable in `.env`. Defaults are offset by `+10000` from the
canonical 6432/5001/7000/9187/9188.

---

## Make targets

Run `make help` for the full list. The ones you'll use most:

| Target                  | What it does                                                          |
| ----------------------- | --------------------------------------------------------------------- |
| `make up`               | Build + bring up everything in dependency order (with health gates).  |
| `make down`             | Stop everything. Data is preserved (host bind-mounts).                |
| `make status`           | One-screen overview: Patroni list, replication lag, etcd, HAProxy backends, pgBackRest info. |
| `make psql`             | Connect to the current leader via pgBouncer (writes path).            |
| `make psql-replica`     | Connect to the current replica via HAProxy (reads path).              |
| `make psql-app`         | Connect as the app user to the app DB.                                |
| `make logs SERVICE=…`   | Tail logs for one service (e.g. `SERVICE=tsdb-primary`).              |
| `make switchover`       | Graceful role swap (primary ↔ replica), no data loss.                 |
| `make failover`         | **DANGER**: emergency manual promotion of replica.                    |
| `make reinit-replica`   | Wipe + re-bootstrap the replica from the current leader.              |
| `make backup TYPE=…`    | On-demand pgBackRest backup. `TYPE=full\|diff` (default `diff`).      |
| `make backup-info`      | Show backup repo info.                                                |
| `make restore POINT_IN_TIME='YYYY-MM-DD HH:MM:SS'` | **DANGER**: PITR restore to a target time.       |
| `make drill-failover`   | Drill: kill leader, measure recovery time.                            |
| `make drill-replica-kill` | Drill: verify read fallback when replica dies.                      |
| `make drill-restore`    | Drill: insert sentinels, PITR, verify.                                |

---

## Documentation

- [`SETUP.md`](./SETUP.md) — first-time install, step-by-step.
- [`docs/architecture.md`](./docs/architecture.md) — compose units, boot order, endpoints.
- [`docs/ha.md`](./docs/ha.md) — HA behavior, failover timeline, timing knobs.
- [`docs/operations.md`](./docs/operations.md) — day-2 runbook.
- [`docs/backup-restore.md`](./docs/backup-restore.md) — backup strategy and PITR drills.
- [`docs/tuning.md`](./docs/tuning.md) — resource tuning for the 1 vCPU / 4 GB profile.
- [`docs/specs/`](./docs/specs/) — full design specs.

---

## Troubleshooting

### `make up` fails waiting for primary to become healthy

`make up-primary` waits up to 120 s, then dumps the last 50 lines of the
primary's logs. Common causes:

- **Bad `.env`** — missing or invalid `POSTGRES_PASSWORD` / `REPLICATOR_PASSWORD`.
- **etcd not reachable** — re-run `make up-etcd` and check `docker logs etcd`.
- **Stale PGDATA** — if you've torn the cluster down dirty, `data/primary/pgdata`
  may have inconsistent state. Investigate before deleting.

### Replica won't bootstrap

`make up-replica` waits up to 180 s. If it times out, the replica is usually
stuck on `pg_basebackup` against the leader. Re-bootstrap from scratch:

```bash
make nuke-replica          # asks for 'NUKE' confirmation
make up-replica
```

### After failover, writes still error out for ~30 s

Expected. The pgBouncer ↔ leader connection pool needs to drain stale
sessions, and `server_login_retry` has a 30 s cooldown after auth misses.
See the failover timeline in [`docs/ha.md`](./docs/ha.md).

### `pg_hba.conf` changes don't take effect

Patroni stores `pg_hba` in etcd on first bootstrap, so edits to
`patroni.yml` after that are ignored. To change pg_hba after bootstrap, you
must PATCH the DCS config — see [`docs/ha.md`](./docs/ha.md) for the curl
recipe.

### Backups fail with "no stanza"

The pgBackRest stanza is created on the leader the first time `make backup`
runs, but you can force it explicitly:

```bash
make stanza-create
make backup TYPE=full
```

### Restore (PITR) issues

`make restore` is destructive — it wipes Patroni state in etcd, wipes the
primary PGDATA, restores from pgBackRest, replays WAL to your target time,
then re-bootstraps the replica. Always test it via `make drill-restore`
first, which exercises the same path with sentinel rows.

### Where do the logs live?

- Inside containers: standard docker logs (`docker logs tsdb-primary`,
  `make logs SERVICE=…`).
- pgBackRest backup logs: in the backup repo at `data/backups/log/`.

---

## License

MIT — see [`LICENSE`](./LICENSE).
