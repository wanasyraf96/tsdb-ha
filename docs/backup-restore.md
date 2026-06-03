# Backup & Restore

pgBackRest with continuous WAL archiving + scheduled full/diff backups.

## Schedule (host crontab)

```cron
0 2 * * 0    cd /path/to/infra/timescaledb && make backup TYPE=full >>/var/log/tsdb-backup.log 2>&1
0 2 * * 1-6  cd /path/to/infra/timescaledb && make backup TYPE=diff >>/var/log/tsdb-backup.log 2>&1
```

Retention: `repo1-retention-full=2`, `repo1-retention-diff=6` → ~2 weeks PITR.

## How `make backup` works

`make backup` looks up the current leader via `patronictl list --format json`
and runs `pgbackrest backup` inside that container as the `postgres` user
(unix socket + peer auth — see `primary/pgbackrest.conf`). The backup repo
is bind-mounted into both pg containers at `/var/lib/pgbackrest`, sharing
the same on-disk repo.

WAL archiving uses `archive_command` on whichever node is currently leader:
`pgbackrest --stanza=tsdb archive-push %p`. Async archiving (`archive-async=y`)
means WAL is batched into the repo in the background.

## On-demand backup

```bash
make backup              # diff
make backup TYPE=full    # full
make backup-info         # repository state
```

## Restore to a point in time

```bash
make restore POINT_IN_TIME='YYYY-MM-DD HH:MM:SS'
```

End-to-end PITR via Patroni's custom bootstrap method `pgbackrest_pitr`:

1. `down-replica` + `down-primary`
2. Wipe `/service/$CLUSTER_SCOPE/` from etcd so the restored primary
   bootstraps as a fresh leader
3. Wipe `$PRIMARY_PGDATA/pgdata` so Patroni's bootstrap path fires
4. Start primary with `POINT_IN_TIME` exported. `entrypoint.sh` flips
   `bootstrap.method` to `pgbackrest_pitr`. Patroni invokes
   `/etc/patroni/pitr-bootstrap.sh`, which runs `pgbackrest restore`
   targeting that time. Patroni then writes the `recovery_conf` block
   (`restore_command`, `recovery_target_time`, `recovery_target_action:
   promote`) into postgresql.auto.conf, starts postgres, replays WAL up to
   the target via `archive-get`, and promotes.
5. Restart `pgbouncer` so it picks up the restored cluster.
6. Wipe `$REPLICA_PGDATA/pgdata` + `up-replica` to re-bootstrap the replica
   from the new leader via streaming.

`scripts/drills/restore.sh` exercises this end-to-end (inserts sentinel A,
backs up, sleeps past target, inserts sentinel B, restores to a time
between A and B) and asserts only A survives. It is wired into
`make drill-restore`.

The bootstrap method is dormant in normal operation: `entrypoint.sh` only
sets `method: pgbackrest_pitr` when `POINT_IN_TIME` is in the environment,
so `make up` falls through to the default `initdb` bootstrap.

### Manual PITR (without Patroni's bootstrap method)

If you need to restore outside of `make restore` — e.g., for debugging — the
old manual procedure still works:

1. **Stop everything writing**
   ```bash
   make down-replica
   make down-primary
   ```

2. **Capture or confirm the target time** in UTC (e.g., `2026-05-28 14:30:00`).

3. **Wipe etcd state for the cluster** so the restored node becomes a fresh
   leader:
   ```bash
   docker exec etcd etcdctl --user root:$ETCD_ROOT_PASSWORD \
     del --prefix /service/tsdb/
   ```

4. **Wipe primary PGDATA and run pgbackrest restore**:
   ```bash
   rm -rf data/primary/pgdata
   docker run --rm \
     --network tsdb-net \
     -v $(pwd)/data/primary:/var/lib/postgresql/data \
     -v $(pwd)/data/backups:/var/lib/pgbackrest \
     -v $(pwd)/primary/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro \
     --entrypoint pgbackrest --user postgres \
     tsdb-ha:2.27.1-pg18-patroni4.0.4-pgbackrest \
     --stanza=tsdb --type=time --target='2026-05-28 14:30:00' \
     --target-action=promote --pg1-path=/var/lib/postgresql/data/pgdata restore
   ```

5. **Add `restore_command` to Patroni's DCS** so Patroni includes it when it
   starts postgres (only needed during recovery — Patroni will leave it set
   after promotion, but it'll be inert):
   ```bash
   make up-etcd        # if not running
   make up-proxy       # if not running
   # Pre-seed DCS config with restore_command. (Needs etcd already up.)
   docker exec etcd etcdctl --user root:$ETCD_ROOT_PASSWORD put /service/tsdb/config \
     '{"postgresql":{"parameters":{"restore_command":"pgbackrest --stanza=tsdb archive-get %f %p"}}}'
   ```

6. **Bring primary up**. Patroni replays WAL to the target via `restore_command`,
   reaches the target, promotes, becomes leader.
   ```bash
   make up-primary
   ```

7. **Re-bootstrap replica from the new (restored) leader**:
   ```bash
   rm -rf data/replica/pgdata
   make up-replica
   ```

8. **Restart pgBouncer** to refresh its userlist for the new cluster:
   ```bash
   docker restart pgbouncer
   ```

9. **Verify** with `make status`. Inspect `drill_restore` or your data to
   confirm the PITR landed where expected.

## Verifying archive_command is healthy

```bash
docker exec tsdb-primary su-exec postgres pgbackrest --stanza=tsdb check
```

Should print "WAL archive check successful" lines.

## Off-host backups (S3)

`repo1-type=posix` writes to the local bind-mount. To move to S3, edit
`primary/pgbackrest.conf` and `replica/pgbackrest.conf`:

```ini
repo1-type=s3
repo1-s3-bucket=...
repo1-s3-region=...
repo1-s3-endpoint=s3.amazonaws.com
repo1-s3-key=...
repo1-s3-key-secret=...
```

Restart the pg containers and run `make backup TYPE=full` to seed.
