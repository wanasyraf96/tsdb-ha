# TimescaleDB HA Stack

Dockerized TimescaleDB primary + read replica with automated failover via
Patroni + etcd + HAProxy. Sized for a single 1 vCPU / 4 GB ARM host.

See `docs/specs/2026-05-28-timescaledb-stack-design.md` for the full design.

## Quickstart

```bash
cp .env.example .env
$EDITOR .env                # set passwords + paths
make build                  # build the custom tsdb-ha image
make up                     # net → etcd → primary → proxy → replica
make status                 # one-screen cluster overview
```

Writes: `localhost:16432` (pgBouncer → HAProxy → current leader)
Reads:  `localhost:15001` (HAProxy → current replica, falls back to leader)
Stats:  `127.0.0.1:17000` (HAProxy stats UI)

(Ports are configurable in `.env`. Defaults are offset by `+10000` from the
canonical 6432/5001/7000/9187/9188 so this stack can run alongside another
Postgres dev stack on the same host.)

First-time install: see [`SETUP.md`](./SETUP.md) for a step-by-step walk-through
with verification + debugging at each stage.

Day-2: `docs/operations.md` runbook, `docs/ha.md` for HA behavior,
`docs/backup-restore.md` for backup/restore drills.
