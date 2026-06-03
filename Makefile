SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

# Load .env if present
ifneq (,$(wildcard ./.env))
include .env
export
endif

# .env's DATA_ROOT/*_PGDATA/etc. may be relative (e.g. ./data). Docker Compose
# resolves relative paths against each compose file's own dir, which would give
# us four separate `data/` subdirs. Override here with absolute paths so all
# compose units share one repository.
override DATA_ROOT := $(abspath ./data)
override PRIMARY_PGDATA := $(DATA_ROOT)/primary
override REPLICA_PGDATA := $(DATA_ROOT)/replica
override ETCD_DATA := $(DATA_ROOT)/etcd
override BACKUP_REPO := $(DATA_ROOT)/backups
export DATA_ROOT PRIMARY_PGDATA REPLICA_PGDATA ETCD_DATA BACKUP_REPO

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@echo "TimescaleDB HA stack — Makefile targets"
	@echo
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: check-env
check-env:
	@test -f .env || (echo "ERROR: .env not found. Copy .env.example to .env and edit." && exit 1)

.PHONY: build
build: check-env ## Build the custom tsdb-ha image
	docker build \
	  --build-arg TSDB_BASE_IMAGE=$(TSDB_BASE_IMAGE) \
	  --build-arg PATRONI_VERSION=$(PATRONI_VERSION) \
	  -t $(TSDB_HA_IMAGE_TAG) \
	  -f docker/Dockerfile.tsdb-ha \
	  docker

.PHONY: pull
pull: check-env ## Pull the published tsdb-ha image (set TSDB_HA_IMAGE_TAG to a published tag in .env first)
	docker pull $(TSDB_HA_IMAGE_TAG)

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

define LEADER_CONTAINER
$$(docker exec $(PRIMARY_NAME) patronictl -c /tmp/patroni.yml list --format json 2>/dev/null | python3 -c 'import sys,json; [print(m["Member"]) for m in json.load(sys.stdin) if m["Role"]=="Leader"]')
endef

.PHONY: stanza-create
stanza-create: check-env ## Initialize the pgBackRest stanza on the current leader
	@LEADER=$(LEADER_CONTAINER); test -n "$$LEADER" || (echo "no leader found" >&2; exit 1); \
	echo "Creating stanza on $$LEADER..."; \
	docker exec $$LEADER su-exec postgres pgbackrest --stanza=$(CLUSTER_SCOPE) --log-level-console=info stanza-create

.PHONY: backup
backup: check-env ## Run an on-demand backup on the current leader; TYPE=full|diff (default: diff)
	@LEADER=$(LEADER_CONTAINER); test -n "$$LEADER" || (echo "no leader found" >&2; exit 1); \
	docker exec $$LEADER su-exec postgres pgbackrest --stanza=$(CLUSTER_SCOPE) --log-level-console=warn stanza-create; \
	echo "Backing up from $$LEADER (type=$${TYPE:-diff})..."; \
	docker exec $$LEADER su-exec postgres pgbackrest --stanza=$(CLUSTER_SCOPE) --type=$${TYPE:-diff} backup

.PHONY: backup-info
backup-info: check-env ## Show backup repo info
	@LEADER=$(LEADER_CONTAINER); test -n "$$LEADER" || (echo "no leader found" >&2; exit 1); \
	docker exec $$LEADER su-exec postgres pgbackrest --stanza=$(CLUSTER_SCOPE) info

.PHONY: exporter-curl
exporter-curl: check-env ## Curl both postgres_exporters + haproxy stats
	@echo "=== primary :$(PRIMARY_EXPORTER_HOST_PORT) ==="
	@curl -sf "http://127.0.0.1:$(PRIMARY_EXPORTER_HOST_PORT)/metrics" | grep -E '^pg_up|^pg_replication' | head -5 || echo "FAIL"
	@echo "=== replica :$(REPLICA_EXPORTER_HOST_PORT) ==="
	@curl -sf "http://127.0.0.1:$(REPLICA_EXPORTER_HOST_PORT)/metrics" | grep -E '^pg_up|^pg_replication' | head -5 || echo "FAIL"
	@echo "=== haproxy :$(HAPROXY_STATS_HOST_PORT) ==="
	@curl -sf "http://127.0.0.1:$(HAPROXY_STATS_HOST_PORT)/" >/dev/null && echo "OK" || echo "FAIL"

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
	@docker exec $(PRIMARY_NAME) su-exec postgres psql -h /var/run/postgresql -U postgres -d postgres -At -F'|' \
	   -c "SELECT application_name, state, sync_state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes FROM pg_stat_replication" 2>/dev/null || echo "no primary"
	@echo
	@echo "── etcd ──"
	@docker exec etcd etcdctl --user root:$(ETCD_ROOT_PASSWORD) endpoint health 2>&1 | head -1
	@echo
	@echo "── HAProxy backends ──"
	@curl -sf "http://127.0.0.1:$(HAPROXY_STATS_HOST_PORT)/;csv" 2>/dev/null | awk -F, 'NR>1 && ($$1=="postgres_write"||$$1=="postgres_read") && $$2!="FRONTEND" {printf "  %-18s %-15s %s\n", $$1, $$2, $$18}' || echo "haproxy not reachable"
	@echo
	@echo "── pgBackRest ──"
	@LEADER=$(LEADER_CONTAINER); test -n "$$LEADER" && docker exec $$LEADER su-exec postgres pgbackrest --stanza=$(CLUSTER_SCOPE) info 2>/dev/null | head -10 || echo "no leader"

.PHONY: switchover
switchover: check-env ## Planned graceful role swap (primary <-> replica)
	docker exec $(PRIMARY_NAME) patronictl -c /tmp/patroni.yml switchover \
	  --primary $(PRIMARY_NAME) --candidate $(REPLICA_NAME) --force

.PHONY: failover
failover: check-env ## DANGER: emergency manual promotion of replica
	@read -p "Type 'FAILOVER' to confirm: " ans && [ "$$ans" = "FAILOVER" ] || (echo "aborted"; exit 1)
	docker exec $(REPLICA_NAME) patronictl -c /tmp/patroni.yml failover \
	  --candidate $(REPLICA_NAME) --force

.PHONY: reinit-replica
reinit-replica: check-env ## Tell Patroni to wipe and re-bootstrap the replica from current leader
	@read -p "Type 'REINIT' to confirm: " ans && [ "$$ans" = "REINIT" ] || (echo "aborted"; exit 1)
	docker exec $(PRIMARY_NAME) patronictl -c /tmp/patroni.yml reinit $(CLUSTER_SCOPE) $(REPLICA_NAME) --force

.PHONY: psql
psql: check-env ## psql to current leader via pgbouncer (writes path)
	@PGPASSWORD=$(POSTGRES_PASSWORD) psql -h 127.0.0.1 -p $(PGBOUNCER_HOST_PORT) -U postgres -d postgres

.PHONY: psql-replica
psql-replica: check-env ## psql to current replica via haproxy:5001 (reads path)
	@PGPASSWORD=$(POSTGRES_PASSWORD) psql -h 127.0.0.1 -p $(HAPROXY_READ_HOST_PORT) -U postgres -d postgres

.PHONY: psql-app
psql-app: check-env ## psql to the app database via pgbouncer as the app user
	@PGPASSWORD=$(APP_PASSWORD) psql -h 127.0.0.1 -p $(PGBOUNCER_HOST_PORT) -U $(APP_USER) -d $(APP_DB)

.PHONY: logs
logs: check-env ## Tail logs for one service. Usage: make logs SERVICE=tsdb-primary
	@test -n "$(SERVICE)" || (echo "Usage: make logs SERVICE=<container-name>"; exit 1)
	docker logs -f --tail 100 $(SERVICE)

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

.PHONY: restore
restore: check-env ## DANGER: PITR restore. Usage: make restore POINT_IN_TIME='2026-05-28 14:30:00'
	@test -n "$(POINT_IN_TIME)" || (echo "Usage: make restore POINT_IN_TIME='YYYY-MM-DD HH:MM:SS'"; exit 1)
	@read -p "Type 'RESTORE' to confirm PITR to $(POINT_IN_TIME): " ans && [ "$$ans" = "RESTORE" ] || (echo "aborted"; exit 1)
	@echo "Stopping replica and primary..."
	$(MAKE) down-replica
	$(MAKE) down-primary
	@echo "Wiping Patroni cluster state in etcd so the restored primary bootstraps as a fresh leader..."
	docker exec etcd etcdctl --user root:$(ETCD_ROOT_PASSWORD) del --prefix /service/$(CLUSTER_SCOPE)/
	@echo "Wiping primary PGDATA so Patroni's pgbackrest_pitr bootstrap method fires..."
	rm -rf $(PRIMARY_PGDATA)/pgdata
	@echo "Bringing primary up with POINT_IN_TIME=$(POINT_IN_TIME). Patroni will run pitr-bootstrap.sh, then replay WAL to target and promote."
	POINT_IN_TIME='$(POINT_IN_TIME)' $(MAKE) up-primary
	@echo "Restarting pgbouncer to refresh its connection to the restored cluster..."
	docker restart pgbouncer >/dev/null
	@echo "Wiping replica and re-bootstrapping from the restored leader..."
	rm -rf $(REPLICA_PGDATA)/pgdata
	$(MAKE) up-replica
