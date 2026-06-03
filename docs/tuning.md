# Tuning Notes

Sized for a 1 vCPU / 4 GB ARM host running both pg nodes. All values are
cluster-wide unless noted.

## Memory

- `shared_buffers = 768 MB` (primary), `512 MB` (replica override) — keeps
  the pair under ~1.3 GB so OS cache + haproxy + pgbouncer + etcd + exporters
  fit on the host.
- `effective_cache_size = 2 GB` — planner hint that ~half the host is
  available for OS cache.
- `work_mem = 16 MB` (primary), `32 MB` (replica override) — replica favors
  analytics queries.
- `maintenance_work_mem = 128 MB` — enough for VACUUM + CREATE INDEX without
  starving foreground.

## Write path

- `synchronous_commit = off` — biggest single ingest win. Durability bound
  to ~200 ms (the interval between WAL flushes). Acceptable because
  (a) WAL is archived continuously by pgBackRest and (b) a hot standby is
  streaming.
- `wal_compression = on` — saves disk + network for IoT-style high-throughput
  inserts.
- `max_wal_size = 2 GB` — large enough to avoid forced checkpoints during
  bursts.
- `checkpoint_completion_target = 0.9` — spread checkpoint I/O.

## Replication

- `wal_keep_size = 256 MB` — safety margin alongside slots; lets a briefly
  disconnected replica catch up without slot fallback.
- `hot_standby_feedback = on` — replica reports its oldest xmin to primary,
  preventing snapshot-conflict cancellations on long analytical queries.
  Cost is some bloat back-pressure on primary; fine for IoT workloads that
  mostly hit fresh chunks.

## Parallelism

- `max_parallel_workers = 2` — single vCPU; more adds scheduling overhead.
- `timescaledb.max_background_workers = 8` — enough for concurrent
  compression + continuous aggregate refreshes.

## How to retune

Cluster-wide values are managed by Patroni and stored in etcd. Edit live:

```bash
docker exec tsdb-primary patronictl -c /tmp/patroni.yml edit-config
```

or via the REST API:

```bash
docker exec tsdb-primary curl -s -X PATCH \
  -d '{"postgresql":{"parameters":{"work_mem":"32MB"}}}' \
  http://localhost:8008/config
```

Some parameters require a restart (`pending_restart` will show in
`patronictl list`). Trigger via `patronictl restart tsdb <member-name>`.

Node-local overrides live in each node's `patroni.yml` under
`postgresql.parameters`. Static file edits require a `patronictl reload`
(or full container restart if Patroni doesn't pick up the change — see
the "DCS-managed pg_hba doesn't refresh from file" note in `ha.md`).
