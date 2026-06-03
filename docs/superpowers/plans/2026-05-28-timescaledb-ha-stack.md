# TimescaleDB HA Stack — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Dockerized TimescaleDB HA cluster (primary + read replica) with automated failover via Patroni/etcd/HAProxy, sized for a 1 vCPU / 4 GB ARM host, with stable connection endpoints that survive node loss.

**Architecture:** Four small docker-compose units on a shared external docker network: `etcd/` (DCS), `primary/` and `replica/` (Patroni-wrapped TimescaleDB nodes built from a custom image with pgBackRest baked in), and `proxy/` (HAProxy + pgBouncer + pgbackrest-cron). Apps connect to stable host endpoints — `localhost:6432` for writes (pgBouncer → HAProxy → current leader) and `localhost:5001` for reads (HAProxy → current replica, falling back to leader). All state lives in host bind-mounts.

**Tech Stack:** Docker Compose v2 · `timescale/timescaledb:2.27.1-pg18` (Alpine) · Patroni 4.0.x · etcd 3.5 · HAProxy · `edoburu/pgbouncer` · pgBackRest · `prometheuscommunity/postgres-exporter`.

**Spec:** `/Users/vectolabs/apps/infra/timescaledb/docs/specs/2026-05-28-timescaledb-stack-design.md`

**Working directory for all paths in this plan:** `/Users/vectolabs/apps/infra/timescaledb/` (referred to as `<root>` below).

---

## Task 1: Project scaffold

Lay down the directory skeleton, `.env.example`, `.gitignore`, top-level `README.md`, and a `Makefile` that prints help. Nothing functional yet — this gives the rest of the plan stable file locations and gives operators a working `make help` from the start.

**Files:**
- Create: `<root>/.env.example`
- Create: `<root>/.gitignore`
- Create: `<root>/README.md`
- Create: `<root>/Makefile`
- Create (empty placeholder dirs): `<root>/{docker,etcd,proxy/haproxy,proxy/pgbouncer,proxy/pgbackrest,primary,replica,scripts/drills,docs}/.gitkeep`

- [ ] **Step 1: Create `<root>/.env.example`**

```bash
# ─────────────────────────────────────────────────────────────────────────────
# TimescaleDB HA stack — environment template.
# Copy to .env and edit before running `make build && make up`.
# ─────────────────────────────────────────────────────────────────────────────

# Image pins
TSDB_BASE_IMAGE=timescale/timescaledb:2.27.1-pg18
PATRONI_VERSION=4.0.4
TSDB_HA_IMAGE_TAG=tsdb-ha:2.27.1-pg18-patroni4.0.4-pgbackrest
ETCD_IMAGE_TAG=bitnami/etcd:3.5
HAPROXY_IMAGE_TAG=haproxy:2.9-alpine
PGBOUNCER_IMAGE_TAG=edoburu/pgbouncer:latest
PG_EXPORTER_IMAGE_TAG=prometheuscommunity/postgres-exporter:v0.15.0

# Cluster identity
CLUSTER_SCOPE=tsdb
PRIMARY_NAME=tsdb-primary
REPLICA_NAME=tsdb-replica

# Host paths (bind-mounts). Override for prod, e.g. /var/lib/tsdb/...
DATA_ROOT=./data
PRIMARY_PGDATA=${DATA_ROOT}/primary
REPLICA_PGDATA=${DATA_ROOT}/replica
ETCD_DATA=${DATA_ROOT}/etcd
BACKUP_REPO=${DATA_ROOT}/backups

# Credentials — change before any non-dev use
POSTGRES_PASSWORD=changeme-superuser
REPLICATOR_PASSWORD=changeme-replicator
REWIND_PASSWORD=changeme-rewind
APP_PASSWORD=changeme-app
MONITORING_PASSWORD=changeme-monitoring
PGBOUNCER_AUTH_PASSWORD=changeme-pgbouncer-auth
ETCD_ROOT_PASSWORD=changeme-etcd-root

# Application database + role
APP_DB=tsdb
APP_USER=app

# Published host ports
PGBOUNCER_HOST_PORT=6432
HAPROXY_READ_HOST_PORT=5001
HAPROXY_STATS_HOST_PORT=7000
PRIMARY_EXPORTER_HOST_PORT=9187
REPLICA_EXPORTER_HOST_PORT=9188

# Docker network name (shared, external)
DOCKER_NETWORK=tsdb-net
```

- [ ] **Step 2: Create `<root>/.gitignore`**

```
.env
data/
*.log
.DS_Store
```

- [ ] **Step 3: Create `<root>/README.md`**

```markdown
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

Writes: `localhost:6432` (pgBouncer → HAProxy → current leader)
Reads:  `localhost:5001` (HAProxy → current replica, falls back to leader)
Stats:  `127.0.0.1:7000`  (HAProxy stats UI)

See `docs/operations.md` for runbook, `docs/ha.md` for HA behavior,
`docs/backup-restore.md` for backup/restore drills.
```

- [ ] **Step 4: Create `<root>/Makefile` (skeleton with help target)**

```makefile
SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

# Load .env if present
ifneq (,$(wildcard ./.env))
include .env
export
endif

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@echo "TimescaleDB HA stack — Makefile targets"
	@echo
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: check-env
check-env:
	@test -f .env || (echo "ERROR: .env not found. Copy .env.example to .env and edit." && exit 1)
```

- [ ] **Step 5: Create placeholder `.gitkeep` files for the directory tree**

```bash
cd <root>
mkdir -p docker etcd proxy/haproxy proxy/pgbouncer proxy/pgbackrest primary replica scripts/drills docs
touch docker/.gitkeep etcd/.gitkeep proxy/.gitkeep proxy/haproxy/.gitkeep proxy/pgbouncer/.gitkeep proxy/pgbackrest/.gitkeep primary/.gitkeep replica/.gitkeep scripts/drills/.gitkeep docs/.gitkeep
```

- [ ] **Step 6: Verify scaffold**

Run from `<root>`:
```bash
make help
```
Expected output: a header followed by the `help` target line. No errors.

```bash
cp .env.example .env
make check-env
```
Expected: returns silently (exit 0).

- [ ] **Step 7: Commit**

```bash
cd /Users/vectolabs/apps/infra
git add timescaledb/.env.example timescaledb/.gitignore timescaledb/README.md timescaledb/Makefile timescaledb/**/.gitkeep
git commit -m "feat(timescaledb): scaffold project structure + makefile skeleton"
```

---

## Task 2: Custom postgres image with Patroni + pgBackRest

Build the `tsdb-ha` image — TimescaleDB + Patroni + pgBackRest in one container — and add a `make build` target. This image is reused by both `primary/` and `replica/` compose units.

**Files:**
- Create: `<root>/docker/Dockerfile.tsdb-ha`
- Create: `<root>/docker/entrypoint.sh`
- Modify: `<root>/Makefile` (add `build` target)

- [ ] **Step 1: Write the Dockerfile**

`<root>/docker/Dockerfile.tsdb-ha`:
```dockerfile
ARG TSDB_BASE_IMAGE=timescale/timescaledb:2.27.1-pg18
FROM ${TSDB_BASE_IMAGE}

ARG PATRONI_VERSION=4.0.4

USER root

RUN apk add --no-cache \
      python3 py3-pip py3-psycopg2 \
      pgbackrest \
      tini su-exec gettext bash curl \
 && pip install --break-system-packages --no-cache-dir \
      "patroni[etcd3]==${PATRONI_VERSION}"

# pgBackRest needs a writable log dir owned by postgres
RUN install -d -o postgres -g postgres /var/log/pgbackrest /var/lib/pgbackrest /etc/pgbackrest

COPY entrypoint.sh /usr/local/bin/tsdb-entrypoint.sh
RUN chmod +x /usr/local/bin/tsdb-entrypoint.sh

# Patroni REST API
EXPOSE 5432 8008

ENTRYPOINT ["/sbin/tini","--","/usr/local/bin/tsdb-entrypoint.sh"]
```

- [ ] **Step 2: Write the entrypoint**

`<root>/docker/entrypoint.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

# Render patroni.yml from template if a template is mounted; otherwise use the
# patroni.yml mounted directly. Either way, the resulting file must live at
# /tmp/patroni.yml (writable by postgres user).
if [[ -f /etc/patroni/patroni.yml.tpl ]]; then
  envsubst < /etc/patroni/patroni.yml.tpl > /tmp/patroni.yml
elif [[ -f /etc/patroni/patroni.yml ]]; then
  envsubst < /etc/patroni/patroni.yml > /tmp/patroni.yml
else
  echo "ERROR: no /etc/patroni/patroni.yml(.tpl) mounted" >&2
  exit 1
fi
chown postgres:postgres /tmp/patroni.yml

# Ensure PGDATA parent is owned by postgres
PGDATA_PARENT="$(dirname "${PGDATA:-/var/lib/postgresql/data/pgdata}")"
install -d -o postgres -g postgres "${PGDATA_PARENT}"
chown -R postgres:postgres "${PGDATA_PARENT}" || true

# pgBackRest config from mounted file
if [[ -f /etc/pgbackrest/pgbackrest.conf ]]; then
  chown postgres:postgres /etc/pgbackrest/pgbackrest.conf || true
fi

exec su-exec postgres patroni /tmp/patroni.yml
```

- [ ] **Step 3: Add the `build` target to the Makefile**

Append to `<root>/Makefile`:
```makefile
.PHONY: build
build: check-env ## Build the custom tsdb-ha image
	docker build \
	  --build-arg TSDB_BASE_IMAGE=$(TSDB_BASE_IMAGE) \
	  --build-arg PATRONI_VERSION=$(PATRONI_VERSION) \
	  -t $(TSDB_HA_IMAGE_TAG) \
	  -f docker/Dockerfile.tsdb-ha \
	  docker
```

- [ ] **Step 4: Verify the image builds**

```bash
make build
```
Expected: build completes; final line `Successfully tagged tsdb-ha:2.27.1-pg18-patroni4.0.4-pgbackrest`. Run:
```bash
docker image inspect $(grep ^TSDB_HA_IMAGE_TAG .env | cut -d= -f2) --format '{{.Config.Entrypoint}}'
```
Expected: `[/sbin/tini -- /usr/local/bin/tsdb-entrypoint.sh]`.

- [ ] **Step 5: Verify Patroni + pgBackRest are present**

```bash
docker run --rm --entrypoint sh "$(grep ^TSDB_HA_IMAGE_TAG .env | cut -d= -f2)" -c 'patroni --version && pgbackrest version && which envsubst'
```
Expected: `patroni 4.0.4`, `pgBackRest <version>`, `/usr/bin/envsubst`.

- [ ] **Step 6: Commit**

```bash
cd /Users/vectolabs/apps/infra
git add timescaledb/docker/Dockerfile.tsdb-ha timescaledb/docker/entrypoint.sh timescaledb/Makefile
git commit -m "feat(timescaledb): custom tsdb-ha image with patroni + pgbackrest"
```

---

## Task 3: etcd compose unit

Bring up a single-node etcd as the Patroni DCS. Authenticated with a root password from `.env`. Bind-mount preserves state.

**Files:**
- Create: `<root>/etcd/docker-compose.yml`
- Modify: `<root>/Makefile` (add `net`, `up-etcd`, `down-etcd`)

- [ ] **Step 1: Write the etcd compose file**

`<root>/etcd/docker-compose.yml`:
```yaml
services:
  etcd:
    image: ${ETCD_IMAGE_TAG}
    container_name: etcd
    restart: unless-stopped
    environment:
      ALLOW_NONE_AUTHENTICATION: "no"
      ETCD_ROOT_PASSWORD: ${ETCD_ROOT_PASSWORD}
      ETCD_NAME: etcd
      ETCD_LISTEN_CLIENT_URLS: http://0.0.0.0:2379
      ETCD_ADVERTISE_CLIENT_URLS: http://etcd:2379
      ETCD_LISTEN_PEER_URLS: http://0.0.0.0:2380
      ETCD_INITIAL_ADVERTISE_PEER_URLS: http://etcd:2380
      ETCD_INITIAL_CLUSTER: etcd=http://etcd:2380
      ETCD_INITIAL_CLUSTER_TOKEN: tsdb-etcd-token
      ETCD_INITIAL_CLUSTER_STATE: new
    volumes:
      - ${ETCD_DATA}:/bitnami/etcd
    networks:
      - tsdb-net
    healthcheck:
      test: ["CMD-SHELL", "etcdctl --user root:${ETCD_ROOT_PASSWORD} endpoint health"]
      interval: 5s
      timeout: 3s
      retries: 12

networks:
  tsdb-net:
    name: ${DOCKER_NETWORK}
    external: true
```

- [ ] **Step 2: Add net + up-etcd + down-etcd targets**

Append to `<root>/Makefile`:
```makefile
.PHONY: net
net: check-env ## Create external docker network (idempotent)
	@docker network inspect $(DOCKER_NETWORK) >/dev/null 2>&1 || docker network create $(DOCKER_NETWORK)

.PHONY: up-etcd
up-etcd: check-env net ## Start etcd
	@mkdir -p $(ETCD_DATA)
	docker compose -f etcd/docker-compose.yml --env-file .env up -d
	@echo "Waiting for etcd to become healthy..."
	@for i in {1..30}; do \
	  if [ "$$(docker inspect -f '{{.State.Health.Status}}' etcd 2>/dev/null)" = "healthy" ]; then echo "etcd healthy."; exit 0; fi; \
	  sleep 1; \
	done; \
	echo "etcd did not become healthy in 30s" >&2; exit 1

.PHONY: down-etcd
down-etcd: check-env ## Stop etcd
	docker compose -f etcd/docker-compose.yml --env-file .env down
```

- [ ] **Step 3: Bring up etcd and verify**

```bash
make up-etcd
docker exec etcd etcdctl --user root:$(grep ^ETCD_ROOT_PASSWORD .env | cut -d= -f2) endpoint health
```
Expected: `127.0.0.1:2379 is healthy: ...`.

- [ ] **Step 4: Verify auth is enforced**

```bash
docker exec etcd etcdctl endpoint health 2>&1 | grep -i 'auth\|permission' || echo "AUTH NOT ENFORCED"
```
Expected: line with `auth` or `permission` keyword (i.e., unauthenticated query is rejected). If you see `AUTH NOT ENFORCED`, abort — check `ALLOW_NONE_AUTHENTICATION` and `ETCD_ROOT_PASSWORD`.

- [ ] **Step 5: Commit**

```bash
cd /Users/vectolabs/apps/infra
git add timescaledb/etcd/docker-compose.yml timescaledb/Makefile
git commit -m "feat(timescaledb): etcd compose unit with auth + healthcheck"
```

---

## Task 4: Primary node — Patroni-wrapped postgres

Bring up the first Patroni node. It bootstraps the cluster, runs `post-init.sh` to create app/monitoring roles and extensions, and registers itself in etcd as leader.

**Files:**
- Create: `<root>/primary/patroni.yml`
- Create: `<root>/primary/post-init.sh`
- Create: `<root>/primary/docker-compose.yml`
- Modify: `<root>/Makefile` (add `up-primary`, `down-primary`)

- [ ] **Step 1: Write Patroni config for primary**

`<root>/primary/patroni.yml`:
```yaml
scope: ${CLUSTER_SCOPE}
namespace: /service/
name: ${PRIMARY_NAME}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${PRIMARY_NAME}:8008

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
        shared_buffers: 768MB
        effective_cache_size: 2GB
        work_mem: 16MB
        maintenance_work_mem: 128MB
        wal_buffers: 16MB
        wal_level: replica
        max_wal_size: 2GB
        min_wal_size: 512MB
        checkpoint_completion_target: 0.9
        synchronous_commit: 'off'
        wal_compression: 'on'
        archive_mode: 'on'
        archive_command: 'pgbackrest --stanza=${CLUSTER_SCOPE} archive-push %p'
        max_wal_senders: 5
        max_replication_slots: 5
        hot_standby: 'on'
        hot_standby_feedback: 'on'
        wal_keep_size: 256MB
        max_worker_processes: 8
        max_parallel_workers: 2
        max_parallel_workers_per_gather: 1
        timescaledb.max_background_workers: 8
        log_min_duration_statement: 500ms
        log_checkpoints: 'on'
        log_lock_waits: 'on'
  post_init: /etc/patroni/post-init.sh
  initdb:
    - encoding: UTF8
    - data-checksums

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${PRIMARY_NAME}:5432
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

- [ ] **Step 2: Write `post-init.sh`**

`<root>/primary/post-init.sh`:
```bash
#!/usr/bin/env bash
# Runs ONCE on the first leader bootstrap. Connection string is passed by Patroni as $1.
set -euo pipefail

CONN="$1"

psql "${CONN}" <<SQL
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${APP_USER}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${APP_USER}', '${APP_PASSWORD}');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'monitoring') THEN
    EXECUTE format('CREATE ROLE monitoring LOGIN PASSWORD %L', '${MONITORING_PASSWORD}');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rewind_user') THEN
    EXECUTE format('CREATE ROLE rewind_user LOGIN PASSWORD %L', '${REWIND_PASSWORD}');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbouncer_auth') THEN
    EXECUTE format('CREATE ROLE pgbouncer_auth LOGIN PASSWORD %L', '${PGBOUNCER_AUTH_PASSWORD}');
  ELSE
    EXECUTE format('ALTER ROLE pgbouncer_auth PASSWORD %L', '${PGBOUNCER_AUTH_PASSWORD}');
  END IF;
END
\$\$;

GRANT pg_monitor TO monitoring;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text) TO rewind_user;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text) TO rewind_user;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO rewind_user;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO rewind_user;

-- pgBouncer auth lookup: SECURITY DEFINER function so pgbouncer_auth
-- doesn't need superuser to read pg_shadow.
CREATE SCHEMA IF NOT EXISTS pgbouncer;
CREATE OR REPLACE FUNCTION pgbouncer.user_lookup(in i_username text, out uname text, out phash text)
RETURNS record AS \$\$
BEGIN
  SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename = i_username INTO uname, phash;
  RETURN;
END;
\$\$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE ALL ON FUNCTION pgbouncer.user_lookup(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgbouncer.user_lookup(text) TO pgbouncer_auth;

SELECT 'CREATE DATABASE ${APP_DB} OWNER ${APP_USER}'
  WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${APP_DB}')
\gexec
SQL

# Templates for the operator (printed to logs):
cat <<'EOF'
-- ─────────────────────────────────────────────────────────────────────
-- Hypertable + continuous aggregate templates (operator applies per ds)
-- ─────────────────────────────────────────────────────────────────────
-- SELECT create_hypertable('measurements', 'ts', chunk_time_interval => INTERVAL '7 days');
-- ALTER TABLE measurements SET (timescaledb.compress, timescaledb.compress_segmentby = 'device_id');
-- SELECT add_compression_policy('measurements', INTERVAL '7 days');
-- SELECT add_retention_policy('measurements', INTERVAL '7 years');
--
-- CREATE MATERIALIZED VIEW measurements_1h
-- WITH (timescaledb.continuous) AS
-- SELECT time_bucket('1 hour', ts) AS bucket, device_id, avg(value) AS avg_value
-- FROM measurements GROUP BY bucket, device_id;
-- SELECT add_continuous_aggregate_policy('measurements_1h',
--   start_offset => INTERVAL '3 hours', end_offset => INTERVAL '1 hour',
--   schedule_interval => INTERVAL '1 hour');
EOF
```

- [ ] **Step 3: Write the primary compose file**

`<root>/primary/docker-compose.yml`:
```yaml
services:
  tsdb-primary:
    image: ${TSDB_HA_IMAGE_TAG}
    container_name: ${PRIMARY_NAME}
    hostname: ${PRIMARY_NAME}
    restart: unless-stopped
    environment:
      CLUSTER_SCOPE: ${CLUSTER_SCOPE}
      PRIMARY_NAME: ${PRIMARY_NAME}
      ETCD_ROOT_PASSWORD: ${ETCD_ROOT_PASSWORD}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      REPLICATOR_PASSWORD: ${REPLICATOR_PASSWORD}
      REWIND_PASSWORD: ${REWIND_PASSWORD}
      APP_USER: ${APP_USER}
      APP_PASSWORD: ${APP_PASSWORD}
      APP_DB: ${APP_DB}
      MONITORING_PASSWORD: ${MONITORING_PASSWORD}
      PGBOUNCER_AUTH_PASSWORD: ${PGBOUNCER_AUTH_PASSWORD}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - ${PRIMARY_PGDATA}:/var/lib/postgresql/data
      - ${BACKUP_REPO}:/var/lib/pgbackrest
      - ./patroni.yml:/etc/patroni/patroni.yml:ro
      - ./post-init.sh:/etc/patroni/post-init.sh:ro
    networks:
      - tsdb-net
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8008/health || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 24
      start_period: 30s

networks:
  tsdb-net:
    name: ${DOCKER_NETWORK}
    external: true
```

- [ ] **Step 4: Add `up-primary` / `down-primary` targets**

Append to `<root>/Makefile`:
```makefile
.PHONY: up-primary
up-primary: check-env net ## Start primary node
	@mkdir -p $(PRIMARY_PGDATA) $(BACKUP_REPO)
	@chmod +x primary/post-init.sh
	docker compose -f primary/docker-compose.yml --env-file .env up -d
	@echo "Waiting for primary to become healthy..."
	@for i in {1..60}; do \
	  if [ "$$(docker inspect -f '{{.State.Health.Status}}' $(PRIMARY_NAME) 2>/dev/null)" = "healthy" ]; then echo "primary healthy."; exit 0; fi; \
	  sleep 2; \
	done; \
	echo "primary did not become healthy in 120s" >&2; \
	docker logs --tail 50 $(PRIMARY_NAME); exit 1

.PHONY: down-primary
down-primary: check-env ## Stop primary node
	docker compose -f primary/docker-compose.yml --env-file .env down
```

- [ ] **Step 5: Bring up primary**

```bash
make up-primary
```
Expected: container starts; healthcheck reports `healthy` within ~30 s. Run:
```bash
docker exec -e PGPASSWORD=$(grep ^POSTGRES_PASSWORD .env | cut -d= -f2) tsdb-primary \
  psql -U postgres -h 127.0.0.1 -c "SELECT current_setting('shared_preload_libraries')"
```
Expected: `timescaledb,pg_stat_statements`.

- [ ] **Step 6: Verify Patroni reports leader**

```bash
docker exec tsdb-primary patronictl -c /tmp/patroni.yml list
```
Expected: one row with `Leader` role for `tsdb-primary` and `running` state.

- [ ] **Step 7: Verify extensions + roles created by post-init**

```bash
docker exec -e PGPASSWORD=$(grep ^POSTGRES_PASSWORD .env | cut -d= -f2) tsdb-primary \
  psql -U postgres -h 127.0.0.1 -c "SELECT extname FROM pg_extension WHERE extname IN ('timescaledb','pg_stat_statements')"
docker exec -e PGPASSWORD=$(grep ^POSTGRES_PASSWORD .env | cut -d= -f2) tsdb-primary \
  psql -U postgres -h 127.0.0.1 -c "SELECT rolname FROM pg_roles WHERE rolname IN ('app','monitoring','rewind_user','replicator') ORDER BY rolname"
docker exec -e PGPASSWORD=$(grep ^POSTGRES_PASSWORD .env | cut -d= -f2) tsdb-primary \
  psql -U postgres -h 127.0.0.1 -c "SELECT datname FROM pg_database WHERE datname = 'tsdb'"
```
Expected: two extensions, four roles, one database.

- [ ] **Step 8: Commit**

```bash
cd /Users/vectolabs/apps/infra
git add timescaledb/primary/ timescaledb/Makefile
git commit -m "feat(timescaledb): primary node compose + patroni config + post-init"
```

---

## Task 5: Proxy layer — HAProxy + pgBouncer

Stand up the stable endpoint layer in front of the cluster. HAProxy routes writes/reads using Patroni REST health checks; pgBouncer fronts writes for connection pooling. pgBackRest-cron will be added in Task 7.

**Files:**
- Create: `<root>/proxy/haproxy/haproxy.cfg`
- Create: `<root>/proxy/pgbouncer/pgbouncer.ini`
- Create: `<root>/proxy/pgbouncer/entrypoint.sh`
- Create: `<root>/proxy/docker-compose.yml`
- Modify: `<root>/Makefile` (add `up-proxy`, `down-proxy`)

- [ ] **Step 1: Write `haproxy.cfg`**

`<root>/proxy/haproxy/haproxy.cfg`:
```
global
    maxconn 1000
    log stdout format raw local0

defaults
    log global
    mode tcp
    retries 3
    timeout client 30m
    timeout connect 5s
    timeout server 30m
    timeout check 5s

resolvers docker
    nameserver dns1 127.0.0.11:53
    resolve_retries 3
    timeout resolve 1s
    timeout retry 1s
    hold valid 5s

listen postgres_write
    bind *:5000
    option httpchk
    http-check send meth GET uri /leader ver HTTP/1.1 hdr Host haproxy
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions resolvers docker init-addr libc,none
    server tsdb-primary tsdb-primary:5432 check port 8008
    server tsdb-replica tsdb-replica:5432 check port 8008

listen postgres_read
    bind *:5001
    balance roundrobin
    option httpchk
    http-check send meth GET uri /replica?lag=10MB ver HTTP/1.1 hdr Host haproxy
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions resolvers docker init-addr libc,none
    server tsdb-replica tsdb-replica:5432 check port 8008
    server tsdb-primary tsdb-primary:5432 check port 8008 backup

listen stats
    bind *:7000
    mode http
    stats enable
    stats uri /
    stats refresh 5s
```

- [ ] **Step 2: Write `pgbouncer.ini`**

`<root>/proxy/pgbouncer/pgbouncer.ini`:
```ini
[databases]
* = host=haproxy port=5000 auth_user=pgbouncer_auth

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 5432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
auth_user = pgbouncer_auth
auth_query = SELECT uname, phash FROM pgbouncer.user_lookup($1)

pool_mode = transaction
max_client_conn = 500
default_pool_size = 25
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3
server_reset_query = DISCARD ALL

ignore_startup_parameters = extra_float_digits,search_path

log_connections = 0
log_disconnections = 0
log_pooler_errors = 1
```

- [ ] **Step 3: Write the pgBouncer SCRAM userlist shim**

`<root>/proxy/pgbouncer/entrypoint.sh`:
```bash
#!/usr/bin/env sh
# Generates /etc/pgbouncer/userlist.txt at boot by fetching pgbouncer_auth's
# SCRAM hash from postgres (the role + auth function were created by
# primary's post-init.sh). Pattern mirrors the repo-split stack.
set -eu

USERLIST=/etc/pgbouncer/userlist.txt
AUTH_USER=pgbouncer_auth

echo "Waiting for haproxy:5000..."
i=0
while ! nc -z haproxy 5000; do
  i=$((i+1))
  if [ "$i" -gt 60 ]; then echo "haproxy:5000 not reachable" >&2; exit 1; fi
  sleep 1
done

# Wait until pgbouncer_auth role exists (post-init.sh on primary creates it).
echo "Waiting for pgbouncer_auth role to be created by post-init..."
i=0
while true; do
  HASH=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -h haproxy -p 5000 -U postgres -d postgres -At -c \
    "SELECT passwd FROM pg_shadow WHERE usename = '${AUTH_USER}'" 2>/dev/null || true)
  if [ -n "${HASH}" ]; then break; fi
  i=$((i+1))
  if [ "$i" -gt 60 ]; then echo "ERROR: pgbouncer_auth role not found after 60s" >&2; exit 1; fi
  sleep 1
done

printf '"%s" "%s"\n' "${AUTH_USER}" "${HASH}" > "${USERLIST}"
chmod 600 "${USERLIST}"
echo "userlist.txt written for ${AUTH_USER}"

exec /entrypoint.sh /etc/pgbouncer/pgbouncer.ini
```

- [ ] **Step 4: Write the proxy compose file**

`<root>/proxy/docker-compose.yml`:
```yaml
services:
  haproxy:
    image: ${HAPROXY_IMAGE_TAG}
    container_name: haproxy
    hostname: haproxy
    restart: unless-stopped
    volumes:
      - ./haproxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    ports:
      - "127.0.0.1:${HAPROXY_READ_HOST_PORT}:5001"
      - "127.0.0.1:${HAPROXY_STATS_HOST_PORT}:7000"
    networks:
      - tsdb-net
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:7000/ >/dev/null || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 12

  pgbouncer:
    image: ${PGBOUNCER_IMAGE_TAG}
    container_name: pgbouncer
    hostname: pgbouncer
    restart: unless-stopped
    depends_on:
      haproxy:
        condition: service_healthy
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      PGBOUNCER_AUTH_PASSWORD: ${PGBOUNCER_AUTH_PASSWORD}
    volumes:
      - ./pgbouncer/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro
      - ./pgbouncer/entrypoint.sh:/usr/local/bin/tsdb-pgbouncer-entrypoint.sh:ro
    entrypoint: ["/bin/sh", "/usr/local/bin/tsdb-pgbouncer-entrypoint.sh"]
    ports:
      - "${PGBOUNCER_HOST_PORT}:5432"
    networks:
      - tsdb-net

networks:
  tsdb-net:
    name: ${DOCKER_NETWORK}
    external: true
```

- [ ] **Step 5: Add `up-proxy` / `down-proxy` targets**

Append to `<root>/Makefile`:
```makefile
.PHONY: up-proxy
up-proxy: check-env net ## Start proxy layer (haproxy + pgbouncer)
	docker compose -f proxy/docker-compose.yml --env-file .env up -d
	@echo "Waiting for haproxy to become healthy..."
	@for i in {1..30}; do \
	  if [ "$$(docker inspect -f '{{.State.Health.Status}}' haproxy 2>/dev/null)" = "healthy" ]; then echo "haproxy healthy."; exit 0; fi; \
	  sleep 1; \
	done; \
	echo "haproxy did not become healthy in 30s" >&2; exit 1

.PHONY: down-proxy
down-proxy: check-env ## Stop proxy layer
	docker compose -f proxy/docker-compose.yml --env-file .env down
```

- [ ] **Step 6: Bring up proxy and verify HAProxy routes writes to primary**

```bash
make up-proxy
# Wait a few seconds for HAProxy health checks to settle
sleep 8
docker exec haproxy sh -c 'echo "show stat" | (which socat >/dev/null 2>&1 && socat /tmp/haproxy.sock - || echo "no socat; check via stats UI")'
curl -s http://127.0.0.1:7000/ | grep -E 'postgres_write|tsdb-primary' | head -5
```
Expected: HAProxy stats page shows `postgres_write` listener with `tsdb-primary` in `UP` state and `tsdb-replica` in `DOWN` state (replica isn't running yet).

- [ ] **Step 7: Verify pgBouncer is up and routes to primary**

```bash
docker logs pgbouncer 2>&1 | tail -20
PGPASSWORD=$(grep ^MONITORING_PASSWORD .env | cut -d= -f2) psql \
  -h 127.0.0.1 -p $(grep ^PGBOUNCER_HOST_PORT .env | cut -d= -f2) \
  -U pgbouncer_auth -d postgres -c "SELECT 1"
```
Expected: pgBouncer logs show userlist written; psql returns `1`.

- [ ] **Step 8: Commit**

```bash
cd /Users/vectolabs/apps/infra
git add timescaledb/proxy/ timescaledb/Makefile
git commit -m "feat(timescaledb): proxy layer with haproxy + pgbouncer scram shim"
```

---

## Task 6: Replica node

Bring up the second Patroni node. It sees the existing leader in etcd, runs `pg_basebackup` from the primary, and joins as a hot standby. HAProxy `:5001` now routes reads to it.

**Files:**
- Create: `<root>/replica/patroni.yml`
- Create: `<root>/replica/docker-compose.yml`
- Modify: `<root>/Makefile` (add `up-replica`, `down-replica`, `nuke-replica`)

- [ ] **Step 1: Write Patroni config for replica**

`<root>/replica/patroni.yml`:
```yaml
scope: ${CLUSTER_SCOPE}
namespace: /service/
name: ${REPLICA_NAME}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${REPLICA_NAME}:8008

etcd3:
  hosts: etcd:2379
  username: root
  password: ${ETCD_ROOT_PASSWORD}

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${REPLICA_NAME}:5432
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
  parameters:
    shared_buffers: 512MB
    work_mem: 32MB
    default_statistics_target: 200
  pg_hba:
    - host replication replicator 0.0.0.0/0 scram-sha-256
    - host all          all        0.0.0.0/0 scram-sha-256
    - host all          all        ::/0      scram-sha-256

tags:
  noloadbalance: false
  clonefrom: false
  nosync: false
```

> Note: no `bootstrap` block on the replica. Patroni reads cluster-wide config from etcd (populated by primary's first boot) and uses `pg_basebackup` to clone PGDATA from the current leader when its own PGDATA is empty.

- [ ] **Step 2: Write the replica compose file**

`<root>/replica/docker-compose.yml`:
```yaml
services:
  tsdb-replica:
    image: ${TSDB_HA_IMAGE_TAG}
    container_name: ${REPLICA_NAME}
    hostname: ${REPLICA_NAME}
    restart: unless-stopped
    environment:
      CLUSTER_SCOPE: ${CLUSTER_SCOPE}
      REPLICA_NAME: ${REPLICA_NAME}
      ETCD_ROOT_PASSWORD: ${ETCD_ROOT_PASSWORD}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      REPLICATOR_PASSWORD: ${REPLICATOR_PASSWORD}
      REWIND_PASSWORD: ${REWIND_PASSWORD}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - ${REPLICA_PGDATA}:/var/lib/postgresql/data
      - ${BACKUP_REPO}:/var/lib/pgbackrest
      - ./patroni.yml:/etc/patroni/patroni.yml:ro
    networks:
      - tsdb-net
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8008/health || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 36
      start_period: 60s

networks:
  tsdb-net:
    name: ${DOCKER_NETWORK}
    external: true
```

- [ ] **Step 3: Add `up-replica`, `down-replica`, `nuke-replica` targets**

Append to `<root>/Makefile`:
```makefile
.PHONY: up-replica
up-replica: check-env net ## Start replica node
	@mkdir -p $(REPLICA_PGDATA)
	docker compose -f replica/docker-compose.yml --env-file .env up -d
	@echo "Waiting for replica to become healthy (initial bootstrap can take a minute)..."
	@for i in {1..90}; do \
	  if [ "$$(docker inspect -f '{{.State.Health.Status}}' $(REPLICA_NAME) 2>/dev/null)" = "healthy" ]; then echo "replica healthy."; exit 0; fi; \
	  sleep 2; \
	done; \
	echo "replica did not become healthy in 180s" >&2; \
	docker logs --tail 50 $(REPLICA_NAME); exit 1

.PHONY: down-replica
down-replica: check-env ## Stop replica node
	docker compose -f replica/docker-compose.yml --env-file .env down

.PHONY: nuke-replica
nuke-replica: check-env ## DANGER: stop replica AND wipe its PGDATA (forces re-bootstrap)
	@read -p "Type 'NUKE' to confirm wiping $(REPLICA_PGDATA): " ans && [ "$$ans" = "NUKE" ] || (echo "aborted"; exit 1)
	docker compose -f replica/docker-compose.yml --env-file .env down
	rm -rf $(REPLICA_PGDATA)/*
	@echo "Replica PGDATA wiped. Run 'make up-replica' to re-bootstrap."
```

- [ ] **Step 4: Bring up replica and verify it joins the cluster**

```bash
make up-replica
docker exec tsdb-primary patronictl -c /tmp/patroni.yml list
```
Expected: two rows — `tsdb-primary` Leader + `tsdb-replica` Replica, both `running`, lag near 0.

- [ ] **Step 5: Verify the replica is read-only**

```bash
docker exec -e PGPASSWORD=$(grep ^POSTGRES_PASSWORD .env | cut -d= -f2) tsdb-replica \
  psql -U postgres -h 127.0.0.1 -c "CREATE TABLE _ro_check(x int)" 2>&1 | grep -i 'read-only\|cannot execute'
```
Expected: error message containing `cannot execute … in a read-only transaction`.

- [ ] **Step 6: Verify HAProxy routes :5001 to replica**

```bash
sleep 8
PGPASSWORD=$(grep ^POSTGRES_PASSWORD .env | cut -d= -f2) psql \
  -h 127.0.0.1 -p $(grep ^HAPROXY_READ_HOST_PORT .env | cut -d= -f2) \
  -U postgres -d postgres -At -c "SELECT pg_is_in_recovery()"
```
Expected: `t` (true — connection landed on the replica).

- [ ] **Step 7: Verify write traffic still lands on primary via pgBouncer**

```bash
PGPASSWORD=$(grep ^POSTGRES_PASSWORD .env | cut -d= -f2) psql \
  -h 127.0.0.1 -p $(grep ^PGBOUNCER_HOST_PORT .env | cut -d= -f2) \
  -U postgres -d postgres -At -c "SELECT pg_is_in_recovery()"
```
Expected: `f` (false — connection landed on the leader).

- [ ] **Step 8: Commit**

```bash
cd /Users/vectolabs/apps/infra
git add timescaledb/replica/ timescaledb/Makefile
git commit -m "feat(timescaledb): replica node compose + patroni config"
```

---

## Task 7: pgBackRest backups

Add `pgbackrest.conf` to the postgres image's bind-mount path on each node so `archive_command` works, and add a `pgbackrest-cron` container in `proxy/` that runs scheduled full/diff backups via HAProxy.

**Files:**
- Create: `<root>/proxy/pgbackrest/pgbackrest.conf`
- Create: `<root>/proxy/pgbackrest/crontab`
- Create: `<root>/proxy/pgbackrest/Dockerfile`
- Create: `<root>/proxy/pgbackrest/entrypoint.sh`
- Modify: `<root>/proxy/docker-compose.yml` (add `pgbackrest-cron` service)
- Modify: `<root>/primary/docker-compose.yml` (bind-mount the pgbackrest.conf)
- Modify: `<root>/replica/docker-compose.yml` (bind-mount the pgbackrest.conf)
- Modify: `<root>/Makefile` (add `backup`, `backup-info`)

- [ ] **Step 1: Write `pgbackrest.conf`**

`<root>/proxy/pgbackrest/pgbackrest.conf`:
```ini
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
repo1-retention-diff=6
process-max=2
compress-type=zst
compress-level=3
log-level-console=info
log-level-file=detail
log-path=/var/log/pgbackrest
start-fast=y
archive-async=y
spool-path=/var/spool/pgbackrest

[tsdb]
pg1-host=haproxy
pg1-port=5000
pg1-user=postgres
pg1-database=postgres
```

- [ ] **Step 2: Write the cron schedule**

`<root>/proxy/pgbackrest/crontab`:
```
# m  h  dom mon dow  command
  0  2  *   *   0    pgbackrest --stanza=tsdb --type=full backup >> /var/log/pgbackrest/cron.log 2>&1
  0  2  *   *   1-6  pgbackrest --stanza=tsdb --type=diff backup >> /var/log/pgbackrest/cron.log 2>&1
 30  2  *   *   *    pgbackrest --stanza=tsdb expire           >> /var/log/pgbackrest/cron.log 2>&1
```

- [ ] **Step 3: Write the pgbackrest-cron image**

`<root>/proxy/pgbackrest/Dockerfile`:
```dockerfile
FROM alpine:3.21
RUN apk add --no-cache pgbackrest bash tini dcron su-exec shadow \
 && (id -u postgres >/dev/null 2>&1 || (addgroup -S -g 70 postgres && adduser -S -D -H -u 70 -G postgres postgres)) \
 && install -d -o postgres -g postgres /var/log/pgbackrest /var/spool/pgbackrest /var/lib/pgbackrest /etc/pgbackrest
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY crontab /etc/crontabs/postgres
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/sbin/tini","--","/usr/local/bin/entrypoint.sh"]
```

> Note: Alpine 3.21 has `pgbackrest` in main repos. We create the `postgres` user/group (uid 70 to match the timescaledb image) so file ownership in the shared `/var/lib/pgbackrest` bind-mount matches across containers. No postgres-client package needed — `pgbackrest` brings its own libpq.

`<root>/proxy/pgbackrest/entrypoint.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

# Ensure log + spool dirs are writable
chown -R postgres:postgres /var/log/pgbackrest /var/spool/pgbackrest /var/lib/pgbackrest

# Wait for haproxy:5000 to reach the leader
echo "Waiting for haproxy:5000 → leader..."
i=0
until su-exec postgres pgbackrest --stanza=tsdb --log-level-console=warn check 2>/dev/null; do
  i=$((i+1))
  if [ "$i" -gt 60 ]; then
    echo "pgbackrest check did not succeed in 120s — attempting stanza-create" >&2
    su-exec postgres pgbackrest --stanza=tsdb --log-level-console=info stanza-create || true
    sleep 5
  fi
  sleep 2
done

echo "pgbackrest stanza check OK"

# Start crond in foreground
exec crond -f -l 2
```

- [ ] **Step 4: Add `pgbackrest-cron` to the proxy compose**

Append to `<root>/proxy/docker-compose.yml` (under `services:`):
```yaml
  pgbackrest-cron:
    build:
      context: ./pgbackrest
    image: tsdb-pgbackrest:local
    container_name: pgbackrest-cron
    restart: unless-stopped
    depends_on:
      haproxy:
        condition: service_healthy
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      PGPASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ./pgbackrest/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro
      - ${BACKUP_REPO}:/var/lib/pgbackrest
    networks:
      - tsdb-net
```

> Note: `PGPASSWORD` is read by libpq (which pgBackRest uses to talk to postgres via `haproxy:5000`). Setting it in the container env keeps it out of config files and logs.

- [ ] **Step 5: Create node-local pgbackrest config + mount into both pg nodes**

The `proxy/pgbackrest/pgbackrest.conf` from Step 1 targets postgres remotely (via `pg1-host=haproxy`) — correct for the cron container. The postgres nodes themselves run `archive-push` locally and need a different config without `pg1-host`. Create the local-node config:

`<root>/primary/pgbackrest.conf`:
```ini
[global]
repo1-path=/var/lib/pgbackrest
log-level-console=info
log-level-file=detail
log-path=/var/log/pgbackrest
archive-async=y
spool-path=/var/spool/pgbackrest

[tsdb]
pg1-path=/var/lib/postgresql/data/pgdata
pg1-user=postgres
pg1-database=postgres
```

`<root>/replica/pgbackrest.conf` — same content (identical file).

Mount it into both nodes. In `<root>/primary/docker-compose.yml`, add to `volumes:`:
```yaml
      - ./pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro
```

And the same line in `<root>/replica/docker-compose.yml`.

- [ ] **Step 6: Add `backup` and `backup-info` Makefile targets**

Append to `<root>/Makefile`:
```makefile
.PHONY: backup
backup: check-env ## Run an on-demand backup; TYPE=full|diff (default: diff)
	docker exec -e PGPASSWORD=$(POSTGRES_PASSWORD) pgbackrest-cron \
	  su-exec postgres pgbackrest --stanza=$(CLUSTER_SCOPE) --type=$${TYPE:-diff} backup

.PHONY: backup-info
backup-info: check-env ## Show backup repo info
	docker exec pgbackrest-cron su-exec postgres pgbackrest --stanza=$(CLUSTER_SCOPE) info
```

- [ ] **Step 7: Rebuild proxy and restart pg nodes to pick up new mounts**

```bash
make down-proxy
make down-replica
make down-primary
make up-primary && make up-proxy && make up-replica
```

Wait for all healthchecks to clear, then verify pgbackrest is functional:
```bash
docker exec -e PGPASSWORD=$(grep ^POSTGRES_PASSWORD .env | cut -d= -f2) pgbackrest-cron \
  su-exec postgres pgbackrest --stanza=tsdb info
```
Expected: stanza info — possibly empty backup list if no backups have run yet, but no errors.

- [ ] **Step 8: Trigger an on-demand backup and verify**

```bash
make backup TYPE=full
make backup-info
```
Expected: one full backup listed with type `full`, status `ok`.

- [ ] **Step 9: Verify WAL archiving is working**

```bash
docker exec -e PGPASSWORD=$(grep ^POSTGRES_PASSWORD .env | cut -d= -f2) tsdb-primary \
  psql -U postgres -h 127.0.0.1 -c "SELECT pg_switch_wal()"
sleep 5
ls $(grep ^BACKUP_REPO .env | cut -d= -f2)/archive/tsdb/*/ 2>/dev/null | head -3
```
Expected: at least one WAL segment file present under the archive directory.

- [ ] **Step 10: Commit**

```bash
cd /Users/vectolabs/apps/infra
git add timescaledb/proxy/pgbackrest/ timescaledb/proxy/docker-compose.yml \
        timescaledb/primary/pgbackrest.conf timescaledb/primary/docker-compose.yml \
        timescaledb/replica/pgbackrest.conf timescaledb/replica/docker-compose.yml \
        timescaledb/Makefile
git commit -m "feat(timescaledb): pgbackrest WAL archiving + scheduled backups"
```

---

## Task 8: postgres_exporter sidecars

Add one `postgres_exporter` to each pg node's compose unit. Bind only to host loopback so external Prometheus can scrape without exposing internals broadly.

**Files:**
- Modify: `<root>/primary/docker-compose.yml`
- Modify: `<root>/replica/docker-compose.yml`
- Modify: `<root>/Makefile` (add `exporter-curl`)

- [ ] **Step 1: Add exporter to primary compose**

Append to `services:` in `<root>/primary/docker-compose.yml`:
```yaml
  pg-exporter-primary:
    image: ${PG_EXPORTER_IMAGE_TAG}
    container_name: pg-exporter-primary
    restart: unless-stopped
    depends_on:
      tsdb-primary:
        condition: service_healthy
    environment:
      DATA_SOURCE_NAME: "postgresql://monitoring:${MONITORING_PASSWORD}@${PRIMARY_NAME}:5432/postgres?sslmode=disable"
    ports:
      - "127.0.0.1:${PRIMARY_EXPORTER_HOST_PORT}:9187"
    networks:
      - tsdb-net
```

- [ ] **Step 2: Add exporter to replica compose**

Append to `services:` in `<root>/replica/docker-compose.yml`:
```yaml
  pg-exporter-replica:
    image: ${PG_EXPORTER_IMAGE_TAG}
    container_name: pg-exporter-replica
    restart: unless-stopped
    depends_on:
      tsdb-replica:
        condition: service_healthy
    environment:
      DATA_SOURCE_NAME: "postgresql://monitoring:${MONITORING_PASSWORD}@${REPLICA_NAME}:5432/postgres?sslmode=disable"
    ports:
      - "127.0.0.1:${REPLICA_EXPORTER_HOST_PORT}:9187"
    networks:
      - tsdb-net
```

- [ ] **Step 3: Add `exporter-curl` smoke test**

Append to `<root>/Makefile`:
```makefile
.PHONY: exporter-curl
exporter-curl: check-env ## Curl both postgres_exporters + haproxy stats
	@echo "=== primary :$(PRIMARY_EXPORTER_HOST_PORT) ==="
	@curl -sf "http://127.0.0.1:$(PRIMARY_EXPORTER_HOST_PORT)/metrics" | grep -E '^pg_up|^pg_replication' | head -5 || echo "FAIL"
	@echo "=== replica :$(REPLICA_EXPORTER_HOST_PORT) ==="
	@curl -sf "http://127.0.0.1:$(REPLICA_EXPORTER_HOST_PORT)/metrics" | grep -E '^pg_up|^pg_replication' | head -5 || echo "FAIL"
	@echo "=== haproxy :$(HAPROXY_STATS_HOST_PORT) ==="
	@curl -sf "http://127.0.0.1:$(HAPROXY_STATS_HOST_PORT)/" >/dev/null && echo "OK" || echo "FAIL"
```

- [ ] **Step 4: Recreate pg nodes to attach exporters**

```bash
docker compose -f primary/docker-compose.yml --env-file .env up -d
docker compose -f replica/docker-compose.yml --env-file .env up -d
sleep 10
make exporter-curl
```
Expected: each exporter section prints `pg_up 1` plus replication metrics; HAProxy section prints `OK`.

- [ ] **Step 5: Commit**

```bash
cd /Users/vectolabs/apps/infra
git add timescaledb/primary/docker-compose.yml timescaledb/replica/docker-compose.yml timescaledb/Makefile
git commit -m "feat(timescaledb): postgres_exporter sidecars on each node"
```

---

## Task 9: Full Makefile + operational targets

Round out the Makefile with status, switchover, failover, reinit-replica, restore, psql variants, logs, and an aggregate `make up` / `make down`. These are all wrappers around docker/patronictl/pgbackrest — no new files needed beyond the Makefile.

**Files:**
- Modify: `<root>/Makefile`

- [ ] **Step 1: Add aggregate up/down + status**

Append to `<root>/Makefile`:
```makefile
.PHONY: up
up: check-env build net up-etcd up-primary up-proxy up-replica ## Full stack: build + bring everything up in order
	@echo
	@$(MAKE) status

.PHONY: down
down: check-env down-replica down-proxy down-primary down-etcd ## Stop everything (data preserved)

.PHONY: status
status: check-env ## One-screen cluster overview
	@echo "── Patroni cluster ──"
	@docker exec $(PRIMARY_NAME) patronictl -c /tmp/patroni.yml list 2>/dev/null || echo "primary not running"
	@echo
	@echo "── Replication lag ──"
	@docker exec -e PGPASSWORD=$(POSTGRES_PASSWORD) $(PRIMARY_NAME) \
	   psql -U postgres -h 127.0.0.1 -At -F'|' \
	   -c "SELECT application_name, state, sync_state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes FROM pg_stat_replication" 2>/dev/null || echo "no primary"
	@echo
	@echo "── etcd ──"
	@docker exec etcd etcdctl --user root:$(ETCD_ROOT_PASSWORD) endpoint health 2>&1 | head -1
	@echo
	@echo "── HAProxy backends ──"
	@curl -sf "http://127.0.0.1:$(HAPROXY_STATS_HOST_PORT)/;csv" 2>/dev/null | awk -F, 'NR>1 && ($$1=="postgres_write"||$$1=="postgres_read") && $$2!="FRONTEND" {printf "  %-18s %-15s %s\n", $$1, $$2, $$18}' || echo "haproxy not reachable"
	@echo
	@echo "── pgBackRest ──"
	@docker exec pgbackrest-cron su-exec postgres pgbackrest --stanza=$(CLUSTER_SCOPE) info 2>/dev/null | head -10 || echo "pgbackrest-cron not running"
```

- [ ] **Step 2: Add switchover + failover + reinit-replica**

```makefile
.PHONY: switchover
switchover: check-env ## Planned graceful role swap (primary <-> replica)
	docker exec $(PRIMARY_NAME) patronictl -c /tmp/patroni.yml switchover \
	  --master $(PRIMARY_NAME) --candidate $(REPLICA_NAME) --force

.PHONY: failover
failover: check-env ## DANGER: emergency manual promotion of replica
	@read -p "Type 'FAILOVER' to confirm: " ans && [ "$$ans" = "FAILOVER" ] || (echo "aborted"; exit 1)
	docker exec $(REPLICA_NAME) patronictl -c /tmp/patroni.yml failover \
	  --candidate $(REPLICA_NAME) --force

.PHONY: reinit-replica
reinit-replica: check-env ## Tell Patroni to wipe and re-bootstrap the replica from current leader
	@read -p "Type 'REINIT' to confirm: " ans && [ "$$ans" = "REINIT" ] || (echo "aborted"; exit 1)
	docker exec $(PRIMARY_NAME) patronictl -c /tmp/patroni.yml reinit $(CLUSTER_SCOPE) $(REPLICA_NAME) --force
```

- [ ] **Step 3: Add psql convenience targets**

```makefile
.PHONY: psql
psql: check-env ## psql to current leader via pgbouncer (writes path)
	@PGPASSWORD=$(POSTGRES_PASSWORD) psql -h 127.0.0.1 -p $(PGBOUNCER_HOST_PORT) -U postgres -d postgres

.PHONY: psql-replica
psql-replica: check-env ## psql to current replica via haproxy:5001 (reads path)
	@PGPASSWORD=$(POSTGRES_PASSWORD) psql -h 127.0.0.1 -p $(HAPROXY_READ_HOST_PORT) -U postgres -d postgres

.PHONY: psql-app
psql-app: check-env ## psql to the app database via pgbouncer as the app user
	@PGPASSWORD=$(APP_PASSWORD) psql -h 127.0.0.1 -p $(PGBOUNCER_HOST_PORT) -U $(APP_USER) -d $(APP_DB)
```

- [ ] **Step 4: Add restore target**

```makefile
.PHONY: restore
restore: check-env ## DANGER: PITR restore. Usage: make restore POINT_IN_TIME='2026-05-28 14:30:00'
	@test -n "$(POINT_IN_TIME)" || (echo "Usage: make restore POINT_IN_TIME='YYYY-MM-DD HH:MM:SS'"; exit 1)
	@read -p "Type 'RESTORE' to confirm PITR to $(POINT_IN_TIME): " ans && [ "$$ans" = "RESTORE" ] || (echo "aborted"; exit 1)
	@echo "Stopping replica and primary..."
	$(MAKE) down-replica
	$(MAKE) down-primary
	@echo "Wiping primary PGDATA and restoring from pgbackrest..."
	rm -rf $(PRIMARY_PGDATA)/pgdata
	docker run --rm \
	  --network $(DOCKER_NETWORK) \
	  -v $(PRIMARY_PGDATA):/var/lib/postgresql/data \
	  -v $(BACKUP_REPO):/var/lib/pgbackrest \
	  -v $$(pwd)/primary/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro \
	  --entrypoint pgbackrest \
	  --user postgres \
	  $(TSDB_HA_IMAGE_TAG) \
	  --stanza=$(CLUSTER_SCOPE) --type=time --target="$(POINT_IN_TIME)" --target-action=promote --pg1-path=/var/lib/postgresql/data/pgdata restore
	@echo "Bringing primary back up. Patroni will replay WAL to target and promote."
	$(MAKE) up-primary
	@echo "Wiping replica and re-bootstrapping..."
	rm -rf $(REPLICA_PGDATA)/pgdata
	$(MAKE) up-replica
```

- [ ] **Step 5: Add logs helper**

```makefile
.PHONY: logs
logs: check-env ## Tail logs for one service. Usage: make logs SERVICE=tsdb-primary
	@test -n "$(SERVICE)" || (echo "Usage: make logs SERVICE=<container-name>"; exit 1)
	docker logs -f --tail 100 $(SERVICE)
```

- [ ] **Step 6: Verify `make status`**

```bash
make status
```
Expected: prints five sections (Patroni cluster, Replication lag, etcd, HAProxy backends, pgBackRest). Cluster shows `tsdb-primary Leader` + `tsdb-replica Replica`; etcd reports healthy; HAProxy shows `tsdb-primary UP` on `postgres_write` and `tsdb-replica UP` on `postgres_read`; pgBackRest info lists at least the stanza.

- [ ] **Step 7: Verify `make switchover`**

```bash
make switchover
sleep 10
make status
```
Expected: roles swapped — `tsdb-replica` is now Leader, `tsdb-primary` is Replica. Reverse with another `make switchover` (but specifying the new candidate); for simplicity in this verification, re-run the switchover targeting the original primary:

```bash
docker exec tsdb-replica patronictl -c /tmp/patroni.yml switchover --master tsdb-replica --candidate tsdb-primary --force
```

- [ ] **Step 8: Commit**

```bash
cd /Users/vectolabs/apps/infra
git add timescaledb/Makefile
git commit -m "feat(timescaledb): status/switchover/failover/restore/psql make targets"
```

---

## Task 10: Verification drills

Three scripts that exercise the cluster end-to-end: kill the leader, kill the replica, and PITR-restore. Each script runs from the host, uses docker to perform the destructive action, and verifies expected behavior with timing.

**Files:**
- Create: `<root>/scripts/drills/failover.sh`
- Create: `<root>/scripts/drills/replica-kill.sh`
- Create: `<root>/scripts/drills/restore.sh`
- Modify: `<root>/Makefile` (add `drill-*` targets)

- [ ] **Step 1: Write `failover.sh`**

`<root>/scripts/drills/failover.sh`:
```bash
#!/usr/bin/env bash
# Kill the current Patroni leader, measure how long the write path stays down,
# verify the standby is promoted, and confirm the killed node rejoins automatically.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
set -a; . ./.env; set +a

PRIMARY_CONTAINER="${PRIMARY_NAME}"
REPLICA_CONTAINER="${REPLICA_NAME}"

current_leader() {
  docker exec "$PRIMARY_CONTAINER" patronictl -c /tmp/patroni.yml list --format json 2>/dev/null \
    | python3 -c 'import sys,json; [print(m["Member"]) for m in json.load(sys.stdin) if m["Role"]=="Leader"]'
}

LEADER="$(current_leader)"
echo "Current leader: $LEADER"

OTHER="$([ "$LEADER" = "$PRIMARY_CONTAINER" ] && echo "$REPLICA_CONTAINER" || echo "$PRIMARY_CONTAINER")"
echo "Will kill $LEADER; expect $OTHER to be promoted."

echo "Inserting sentinel before kill..."
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -p "$PGBOUNCER_HOST_PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 <<SQL
CREATE TABLE IF NOT EXISTS drill_failover (id serial primary key, ts timestamptz default now(), note text);
INSERT INTO drill_failover (note) VALUES ('before-kill');
SQL

START=$(date +%s)
docker kill -s SIGKILL "$LEADER"
echo "Killed $LEADER at t=0; polling write path..."

while true; do
  if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -p "$PGBOUNCER_HOST_PORT" -U postgres -d postgres -At -c "INSERT INTO drill_failover (note) VALUES ('after-kill') RETURNING id" >/dev/null 2>&1; then
    NOW=$(date +%s); break
  fi
  if [ $(( $(date +%s) - START )) -gt 60 ]; then
    echo "FAIL: write path never recovered within 60s" >&2; exit 1
  fi
  sleep 1
done
WRITE_DOWNTIME=$(( NOW - START ))
echo "Write path recovered in ${WRITE_DOWNTIME}s"

NEW_LEADER="$(current_leader)"
echo "New leader: $NEW_LEADER"
[ "$NEW_LEADER" = "$OTHER" ] || { echo "FAIL: expected $OTHER to be leader, got $NEW_LEADER"; exit 1; }

echo "Bringing the killed node back up..."
if [ "$LEADER" = "$PRIMARY_CONTAINER" ]; then make up-primary; else make up-replica; fi

echo "Waiting up to 60s for it to rejoin as Replica..."
for i in {1..30}; do
  if docker exec "$NEW_LEADER" patronictl -c /tmp/patroni.yml list --format json | grep -q '"Role": "Replica"'; then
    echo "PASS: rejoined as replica."
    [ "$WRITE_DOWNTIME" -le 30 ] || { echo "WARN: write downtime ${WRITE_DOWNTIME}s > 30s budget"; exit 1; }
    exit 0
  fi
  sleep 2
done
echo "FAIL: killed node did not rejoin as replica within 60s" >&2; exit 1
```

- [ ] **Step 2: Write `replica-kill.sh`**

`<root>/scripts/drills/replica-kill.sh`:
```bash
#!/usr/bin/env bash
# Kill the standby, verify writes continue, reads route to leader via HAProxy fallback,
# then bring the replica back and confirm it catches up.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
set -a; . ./.env; set +a

current_replica() {
  docker exec "$PRIMARY_NAME" patronictl -c /tmp/patroni.yml list --format json 2>/dev/null \
    | python3 -c 'import sys,json; [print(m["Member"]) for m in json.load(sys.stdin) if m["Role"]=="Replica"]'
}

REPLICA="$(current_replica)"
echo "Current replica: $REPLICA"
[ -n "$REPLICA" ] || { echo "no replica found"; exit 1; }

echo "Killing replica..."
docker kill -s SIGKILL "$REPLICA"
sleep 5

echo "Verifying writes still flow..."
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -p "$PGBOUNCER_HOST_PORT" -U postgres -d postgres -At -c "SELECT 1" >/dev/null || { echo "FAIL: writes broken"; exit 1; }

echo "Verifying reads fall back to leader..."
IS_IN_RECOVERY=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -p "$HAPROXY_READ_HOST_PORT" -U postgres -d postgres -At -c "SELECT pg_is_in_recovery()")
[ "$IS_IN_RECOVERY" = "f" ] || { echo "FAIL: expected reads to fall back to leader (pg_is_in_recovery=f), got $IS_IN_RECOVERY"; exit 1; }

echo "Restarting replica..."
if [ "$REPLICA" = "$PRIMARY_NAME" ]; then make up-primary; else make up-replica; fi

echo "Waiting up to 60s for replica to catch up..."
for i in {1..30}; do
  LAG=$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$PRIMARY_NAME" psql -U postgres -h 127.0.0.1 -At -c "SELECT COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn),0) FROM pg_stat_replication LIMIT 1" 2>/dev/null || echo "")
  if [ -n "$LAG" ] && [ "$LAG" -lt 1048576 ]; then echo "PASS: replica lag is $LAG bytes"; exit 0; fi
  sleep 2
done
echo "FAIL: replica did not catch up within 60s" >&2; exit 1
```

- [ ] **Step 3: Write `restore.sh`**

`<root>/scripts/drills/restore.sh`:
```bash
#!/usr/bin/env bash
# Insert sentinel A, wait 30s, insert sentinel B, PITR to between A and B,
# verify A survives and B does not.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
set -a; . ./.env; set +a

echo "Setting up drill table..."
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -p "$PGBOUNCER_HOST_PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 <<SQL
DROP TABLE IF EXISTS drill_restore;
CREATE TABLE drill_restore (id serial primary key, ts timestamptz default now(), note text);
SQL

echo "Forcing checkpoint + WAL switch to bound recovery boundary..."
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -p "$PGBOUNCER_HOST_PORT" -U postgres -d postgres -c "CHECKPOINT; SELECT pg_switch_wal()"

echo "Inserting sentinel A..."
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -p "$PGBOUNCER_HOST_PORT" -U postgres -d postgres -c "INSERT INTO drill_restore (note) VALUES ('A')"

# Capture the PITR target as UTC
make backup TYPE=diff
sleep 5
TARGET="$(date -u +'%Y-%m-%d %H:%M:%S')"
echo "PITR target: $TARGET"
sleep 35

echo "Inserting sentinel B (should not survive restore)..."
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -p "$PGBOUNCER_HOST_PORT" -U postgres -d postgres -c "INSERT INTO drill_restore (note) VALUES ('B')"

echo "Running restore..."
echo "RESTORE" | make restore POINT_IN_TIME="$TARGET"

echo "Verifying A exists and B does not..."
sleep 15
ROWS=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -p "$PGBOUNCER_HOST_PORT" -U postgres -d postgres -At -c "SELECT note FROM drill_restore ORDER BY id" | tr '\n' ',')
echo "Rows present: $ROWS"
[ "$ROWS" = "A," ] || { echo "FAIL: expected only A; got '$ROWS'"; exit 1; }
echo "PASS"
```

- [ ] **Step 4: Add drill targets to the Makefile**

Append to `<root>/Makefile`:
```makefile
.PHONY: drill-failover
drill-failover: check-env ## Failover drill (kills leader, measures recovery)
	@chmod +x scripts/drills/failover.sh
	bash scripts/drills/failover.sh

.PHONY: drill-replica-kill
drill-replica-kill: check-env ## Replica-kill drill (verifies read fallback)
	@chmod +x scripts/drills/replica-kill.sh
	bash scripts/drills/replica-kill.sh

.PHONY: drill-restore
drill-restore: check-env ## PITR drill (inserts sentinels, restores, verifies)
	@chmod +x scripts/drills/restore.sh
	bash scripts/drills/restore.sh
```

- [ ] **Step 5: Run `drill-failover`**

```bash
make drill-failover
```
Expected: ends with `PASS: rejoined as replica.` and write downtime ≤ 30 s.

- [ ] **Step 6: Run `drill-replica-kill`**

```bash
make drill-replica-kill
```
Expected: ends with `PASS: replica lag is <N> bytes`.

- [ ] **Step 7: Run `drill-restore`**

```bash
make drill-restore
```
Expected: ends with `PASS`.

- [ ] **Step 8: Commit**

```bash
cd /Users/vectolabs/apps/infra
git add timescaledb/scripts/ timescaledb/Makefile
git commit -m "feat(timescaledb): verification drills (failover, replica-kill, restore)"
```

---

## Task 11: Operator documentation

Write the runbook + supporting docs. These should be terse and example-driven — the spec already covers the why.

**Files:**
- Create: `<root>/docs/architecture.md`
- Create: `<root>/docs/operations.md`
- Create: `<root>/docs/tuning.md`
- Create: `<root>/docs/ha.md`
- Create: `<root>/docs/backup-restore.md`

- [ ] **Step 1: Write `docs/architecture.md`**

```markdown
# Architecture

Single-host topology, four docker-compose units on a shared external network.

See `docs/specs/2026-05-28-timescaledb-stack-design.md` §4 for the canonical
diagram and rationale.

## Compose units

| Unit | What's in it | Lifecycle |
|---|---|---|
| `etcd/` | etcd 3.5 (single-node) | Up first, down last. Holds Patroni DCS state. |
| `primary/` | tsdb-ha (postgres+patroni+pgbackrest), postgres_exporter | First pg node. |
| `proxy/` | haproxy, pgbouncer, pgbackrest-cron | Stable endpoint layer. Survives node swaps. |
| `replica/` | tsdb-ha, postgres_exporter | Second pg node. Bootstraps from current leader. |

## Stable endpoints

| Endpoint | Behind |
|---|---|
| `localhost:6432` (writes) | pgBouncer → HAProxy → current leader |
| `localhost:5001` (reads) | HAProxy → current replica (falls back to leader) |
| `127.0.0.1:7000` (stats) | HAProxy |
| `127.0.0.1:9187/9188` (metrics) | postgres_exporter |

## Boot order

1. `make net` — create `tsdb-net` docker network.
2. `make up-etcd` — DCS first.
3. `make up-primary` — first Patroni claims leadership, runs `post-init.sh`.
4. `make up-proxy` — HAProxy + pgBouncer + pgbackrest-cron.
5. `make up-replica` — second Patroni bootstraps via `pg_basebackup` from current leader.

`make up` does all of the above in order with health gates.
```

- [ ] **Step 2: Write `docs/operations.md`**

```markdown
# Operations Runbook

Commands assume you're in `infra/timescaledb/` with `.env` in place.

## First-time setup

```bash
cp .env.example .env
$EDITOR .env                  # set passwords + paths
make build
make up
make status
```

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

Shows: Patroni cluster, replication lag, etcd health, HAProxy backends, last
backup.

## Replica lag

```bash
docker exec tsdb-primary patronictl -c /tmp/patroni.yml list
docker exec -e PGPASSWORD=$POSTGRES_PASSWORD tsdb-primary \
  psql -U postgres -h 127.0.0.1 -c "SELECT * FROM pg_stat_replication"
```

Persistent lag > 30s or `wal_status != reserved` → `make reinit-replica`.

## Primary crash / OOM

No action required. Patroni promotes the standby within ~15s. Once the host
recovers:

```bash
make up-primary
```

`pg_rewind` runs automatically. If it fails, Patroni wipes PGDATA and runs
fresh `pg_basebackup` — also automatic, no operator action.

## Planned primary maintenance

```bash
make switchover                # Patroni picks the candidate based on cluster state
# old primary is now replica; do maintenance:
make down-replica
# work on the host
make up-replica
```

## Backup not running

```bash
make backup-info               # last backup age
docker logs --tail 100 pgbackrest-cron
docker exec pgbackrest-cron su-exec postgres pgbackrest --stanza=tsdb check
```

## Restore to a point in time

See `docs/backup-restore.md`.

## Verification drills

Run after any meaningful change (image bump, Patroni config change, tuning):

```bash
make drill-failover
make drill-replica-kill
make drill-restore
```
```

- [ ] **Step 3: Write `docs/tuning.md`**

```markdown
# Tuning Notes

Sized for a 1 vCPU / 4 GB ARM host running both pg nodes. All values are
cluster-wide unless noted.

## Memory

- `shared_buffers = 768MB` (primary), `512MB` (replica override) — keeps the
  pair under ~1.3GB so OS cache + haproxy + pgbouncer + etcd + exporters fit.
- `effective_cache_size = 2GB` — hint to the planner that ~half the host is
  available for OS cache.
- `work_mem = 16MB` (primary), `32MB` (replica) — replica favors analytics.
- `maintenance_work_mem = 128MB` — enough for VACUUM + CREATE INDEX without
  starving foreground.

## Write path

- `synchronous_commit = off` — biggest single ingest win. Durability bound to
  ~200ms (interval between WAL flushes). Acceptable because (a) WAL is
  archived continuously by pgBackRest, and (b) a hot standby is streaming.
- `wal_compression = on` — saves disk + network for IoT-style high-throughput
  inserts.
- `max_wal_size = 2GB` — large enough to avoid forced checkpoints during
  bursts.
- `checkpoint_completion_target = 0.9` — spread checkpoint I/O.

## Replication

- `wal_keep_size = 256MB` — safety margin alongside slots; lets a briefly
  disconnected replica catch up without slot fallback.
- `hot_standby_feedback = on` — replica reports its oldest xmin to primary,
  preventing snapshot-conflict cancellations on long analytical queries. The
  cost is some bloat back-pressure on primary; fine for IoT workloads.

## Parallelism

- `max_parallel_workers = 2` — single vCPU, anything more adds scheduling
  overhead.
- `timescaledb.max_background_workers = 8` — enough for concurrent
  compression + continuous aggregate refreshes.

## How to retune

All values live in `primary/patroni.yml` under
`bootstrap.dcs.postgresql.parameters`. Edit, then:

```bash
docker exec tsdb-primary patronictl -c /tmp/patroni.yml edit-config
```

or apply via the Patroni REST API. Patroni propagates the change to both
nodes; some parameters require a restart (`pending_restart` in
`patronictl list`).
```

- [ ] **Step 4: Write `docs/ha.md`**

```markdown
# HA Behavior

## Why Patroni + etcd + HAProxy

Apps never name a specific postgres. They write to `localhost:6432` and read
from `localhost:5001`. When the leader dies, Patroni promotes the standby
within ~15s and HAProxy starts routing the same endpoints to the new leader.
No `.env` edits, no app restarts.

## Failover timeline

```
t+0    leader becomes unreachable
t+5    standby Patroni notices missed heartbeat
t+10   etcd leader-key TTL expires
t+10   standby's Patroni acquires leader key
t+11   pg_promote() runs on standby
t+12   HAProxy /leader probe flips
t+12   on-marked-down shutdown-sessions resets stale conns
t+13   pgBouncer reconnects via HAProxy to new leader
```

## Timing knobs

In `primary/patroni.yml` under `bootstrap.dcs`:

- `ttl: 30` — how long the leader's etcd key lives without a heartbeat.
- `loop_wait: 10` — how often Patroni checks state.
- `retry_timeout: 10` — how long Patroni retries DCS operations.

Lower values = faster failover, more sensitive to transient blips. Defaults
above are conservative.

## Old primary rejoining

Patroni runs `pg_rewind` against the new leader using the `rewind_user` role.
If timelines have diverged too much, Patroni wipes PGDATA and runs fresh
`pg_basebackup`. Both paths are automatic.

## Manual switchover

```bash
make switchover
```

Graceful, no data loss, ~5s.

## When etcd is down

Patroni stops promoting. The current leader keeps serving (subject to
`master_start_timeout`); replicas stay replicas. Restore etcd, cluster
resumes.

## Single-host caveat

This is not host-failure HA. The whole stack lives on one host. The point of
the design is operational automation (no `.env` flips) and an upgrade path
to multi-host (see spec §12).
```

- [ ] **Step 5: Write `docs/backup-restore.md`**

```markdown
# Backup & Restore

pgBackRest with continuous WAL archiving + nightly full/diff backups.

## Schedule

| When | What |
|---|---|
| Sun 02:00 | `--type=full backup` |
| Mon–Sat 02:00 | `--type=diff backup` |
| Daily 02:30 | `expire` (applies retention) |
| Continuous | WAL archive via `archive_command` on whoever's leader |

Retention: 2 full backups + diffs that depend on them = ~2 weeks PITR.

## On-demand backup

```bash
make backup            # diff
make backup TYPE=full  # full
make backup-info       # repository state
```

## Restore to a point in time

```bash
make restore POINT_IN_TIME='2026-05-28 14:30:00'
```

The Makefile target:

1. Confirms with you (type `RESTORE`).
2. Stops replica + primary.
3. Wipes primary's PGDATA.
4. Runs `pgbackrest restore --type=time --target=...` into PGDATA.
5. Brings primary back; Patroni replays WAL to target and promotes.
6. Wipes replica's PGDATA and re-bootstraps.

Time is in the postgres-host timezone unless you append `+00`. Always test
with `make drill-restore` after a config change.

## Verifying archive_command is healthy

```bash
docker exec pgbackrest-cron su-exec postgres pgbackrest --stanza=tsdb check
```

Should print `WAL archive check successful` lines for each pg host.

## Off-host backups (S3)

`repo1-type=posix` writes to the local bind-mount. To move to S3, edit
`proxy/pgbackrest/pgbackrest.conf`:

```ini
repo1-type=s3
repo1-s3-bucket=...
repo1-s3-region=...
repo1-s3-endpoint=s3.amazonaws.com
repo1-s3-key=...
repo1-s3-key-secret=...
```

Then `docker compose -f proxy/docker-compose.yml restart pgbackrest-cron` and
run `make backup TYPE=full` to seed.
```

- [ ] **Step 6: Verify docs render**

```bash
ls -la <root>/docs/
```
Expected: five `.md` files + the existing `specs/` directory.

- [ ] **Step 7: Commit**

```bash
cd /Users/vectolabs/apps/infra
git add timescaledb/docs/architecture.md timescaledb/docs/operations.md timescaledb/docs/tuning.md timescaledb/docs/ha.md timescaledb/docs/backup-restore.md
git commit -m "docs(timescaledb): architecture, operations, tuning, ha, backup-restore"
```

---

## Done — final verification

- [ ] **Final step: Run the full bring-up from scratch and verify status**

```bash
make down
rm -rf data/
make up
make status
make exporter-curl
make drill-failover && make drill-replica-kill && make drill-restore
```

Expected: clean bring-up, all drills pass, status shows two-node cluster + healthy backups.

- [ ] **Final commit**

```bash
cd /Users/vectolabs/apps/infra
git status
# If clean, nothing to do. Otherwise:
git add -A timescaledb/
git commit -m "chore(timescaledb): final verification pass"
```
