# HA Behavior

## Why Patroni + etcd + HAProxy

Apps never name a specific postgres. Writes go to `localhost:16432`, reads
to `localhost:15001`. When the leader dies, Patroni promotes the standby
within ~15 s and HAProxy starts routing the same endpoints to the new
leader. No `.env` edits, no app restarts.

## Failover timeline

```
t+0    leader becomes unreachable
t+5    standby Patroni notices missed heartbeat
t+10   etcd leader-key TTL (30 s, configurable) expires
t+10   standby's Patroni acquires the leader key
t+11   pg_promote() runs on standby
t+12   HAProxy /leader probe flips to new leader
t+12   on-marked-down shutdown-sessions resets stale pgBouncer ↔ leader conns
t+13   pgBouncer reconnects via HAProxy to new leader
t+30   pgBouncer's `server_login_retry` cooldown clears stale auth caches
```

Real-world drill results on the dev host: write path back online in 30–40 s.

## Timing knobs

In `primary/patroni.yml` under `bootstrap.dcs`:

- `ttl: 30` — how long the leader's etcd key lives without a heartbeat.
- `loop_wait: 10` — how often Patroni checks state.
- `retry_timeout: 10` — how long Patroni retries DCS operations.

Lower values = faster failover, more sensitive to transient blips. The
defaults above are conservative.

## Old primary rejoining

Patroni runs `pg_rewind` against the new leader (uses the `rewind_user` role).
If timelines diverged too much, Patroni wipes PGDATA and runs fresh
`pg_basebackup`. Both paths automatic.

## Manual switchover

```bash
make switchover                    # ~5s, graceful, no data loss
```

## DCS-managed pg_hba doesn't refresh from file

`postgresql.pg_hba` in `patroni.yml` is stored in etcd on first bootstrap.
After that, changes to the file are ignored by `patronictl reload`. To
change pg_hba after bootstrap:

```bash
# Read current DCS config:
docker exec tsdb-primary curl -s http://localhost:8008/config

# PATCH new pg_hba (need to PATCH the whole list):
docker exec tsdb-primary curl -s -X PATCH \
  -d '{"postgresql":{"pg_hba":["local all all peer",...]}}' \
  http://localhost:8008/config

# Reload + restart container to render the new pg_hba.conf:
docker exec tsdb-primary curl -s -X POST http://localhost:8008/reload
docker compose -f primary/docker-compose.yml --env-file .env restart
```

## When etcd is down

Patroni stops promoting. The current leader keeps serving (subject to
`master_start_timeout`); replicas stay replicas. Restore etcd, cluster
resumes.

## Single-host caveat

This is not host-failure HA. The whole stack lives on one host. The point of
the design is operational automation (no `.env` flips) and an upgrade path
to multi-host (spec §12).
