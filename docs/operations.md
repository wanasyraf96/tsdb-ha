# Operations Runbook

Commands assume you're in `infra/timescaledb/` with `.env` in place.

## First-time setup

```bash
cp .env.example .env
$EDITOR .env                       # set passwords + paths
make build
make up
make backup TYPE=full              # also initializes the pgBackRest stanza
make status
```

For a guided walk-through with verification + debugging at each step, see
`SETUP.md` at the repo root.

## Planned reboot

```bash
make down
# reboot the host
make up
```

## Status check

```bash
make status
```

Shows: Patroni cluster, replication lag, etcd health, HAProxy backends,
last backup.

## Replica lag investigation

```bash
docker exec tsdb-primary patronictl -c /tmp/patroni.yml list
docker exec tsdb-primary su-exec postgres psql -h /var/run/postgresql \
  -U postgres -c "SELECT * FROM pg_stat_replication"
```

Persistent lag > 30s or `wal_status != reserved`: `make reinit-replica`.

## Primary crash / OOM

No action required. Patroni promotes the standby within ~15 s; HAProxy starts
routing writes to the new leader; pgBouncer's stale server-connections get
reset by HAProxy's `on-marked-down shutdown-sessions`. End-to-end recovery
~30–40 s (the long tail is pgBouncer's `server_login_retry`).

Once the host recovers:

```bash
make up-primary
```

Patroni's `pg_rewind` runs automatically. If timelines diverged too far,
Patroni wipes PGDATA and runs fresh `pg_basebackup`. Both paths automatic.

## Planned primary maintenance

```bash
make switchover                    # graceful, no data loss
make down-replica                  # the old primary is now the replica
# do maintenance
make up-replica
```

## After any cluster identity change (fresh up, restore drill)

pgBouncer caches the SCRAM hash for `pgbouncer_auth` in its in-memory userlist.
After etcd is wiped (e.g., the restore drill), a new `pgbouncer_auth` user
exists with a different hash. Restart pgBouncer to re-fetch:

```bash
docker restart pgbouncer
```

## Backup not running

```bash
make backup-info                   # last backup age
docker exec tsdb-primary su-exec postgres pgbackrest --stanza=tsdb check
```

Continuous WAL push is via `archive_command` on whichever node is leader.
Scheduled full/diff backups: see "Scheduled backups" below.

## Scheduled backups (host crontab)

The stack does not ship a backup scheduler container. Add to the docker
host's crontab:

```cron
# Full backup Sundays 02:00
0 2 * * 0  cd /path/to/infra/timescaledb && make backup TYPE=full >>/var/log/tsdb-backup.log 2>&1
# Differential Mon–Sat 02:00
0 2 * * 1-6  cd /path/to/infra/timescaledb && make backup TYPE=diff >>/var/log/tsdb-backup.log 2>&1
```

(Retention is enforced inside `pgbackrest backup` per the stanza config:
2 full + 6 diff backups ≈ two weeks rolling.)

## Restore to a point in time

`make restore POINT_IN_TIME='YYYY-MM-DD HH:MM:SS'` is destructive but
end-to-end automated via Patroni's `pgbackrest_pitr` custom bootstrap
method. See `docs/backup-restore.md` for the full procedure and what it
touches.

## Verification drills

Run after any meaningful change (image bump, Patroni config change, tuning):

```bash
make drill-failover                # ~40s recovery on dev machine
make drill-replica-kill            # read fallback + replica catch-up
make drill-restore                 # full PITR cycle, asserts A survives / B doesn't
```
