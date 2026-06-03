# Architecture

Single-host topology, four docker-compose units on a shared external network.
The canonical diagram + rationale live in
`docs/specs/2026-05-28-timescaledb-stack-design.md` §4.

## Compose units

| Unit | What's in it | Lifecycle |
|---|---|---|
| `etcd/` | etcd (single-node, `bitnamilegacy/etcd:3.6.4`) | Up first, down last. Holds Patroni DCS state. |
| `primary/` | tsdb-ha (postgres + patroni + pgbackrest), postgres_exporter | First pg node. |
| `proxy/` | haproxy, pgbouncer | Stable endpoint layer. Survives node swaps. |
| `replica/` | tsdb-ha, postgres_exporter | Second pg node. Bootstraps from current leader. |

(Original spec included a `pgbackrest-cron` container in `proxy/`. It was
dropped during implementation — pgbackrest's `pg1-host` remote mode requires
SSH or TLS server setup that we don't ship. Backups now run via `docker exec`
into the current leader; the cron schedule lives in host crontab.)

## Stable endpoints

| Endpoint | Behind |
|---|---|
| `localhost:16432` (writes) | pgBouncer → HAProxy `:5000` → current leader |
| `localhost:15001` (reads) | HAProxy `:5001` → current replica (falls back to leader) |
| `127.0.0.1:17000` (HAProxy stats) | HAProxy |
| `127.0.0.1:19187/19188` (metrics) | postgres_exporter |

Ports are offset `+10000` from canonical to avoid clashing with another
Postgres stack on the same dev host. Change in `.env`.

## Boot order

1. `make net` — creates `tsdb-net` docker network.
2. `make up-etcd` — DCS first.
3. `make up-primary` — first Patroni claims leadership, runs `post-init.sh`.
4. `make up-proxy` — HAProxy + pgBouncer.
5. `make up-replica` — second Patroni bootstraps via `pg_basebackup` from
   current leader.

`make up` does all of the above with health gates. `make down` reverses it
(data preserved in host bind-mounts).
