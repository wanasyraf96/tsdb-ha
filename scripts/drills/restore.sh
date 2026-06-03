#!/usr/bin/env bash
# Insert sentinel A, wait 30s, insert sentinel B, PITR to between A and B,
# verify A survives and B does not.
#
# Destructive: wipes both primary PGDATA and the Patroni DCS state in etcd,
# then bootstraps a fresh cluster from the pgBackRest backup via Patroni's
# `pgbackrest_pitr` custom bootstrap method (see docs/backup-restore.md).
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

# Force the WAL containing A to flush + archive immediately so it's available
# for PITR. With archive-async=y the push otherwise batches.
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -p "$PGBOUNCER_HOST_PORT" -U postgres -d postgres -c "SELECT pg_switch_wal()"
sleep 3
make backup TYPE=diff
sleep 3

TARGET="$(date -u +'%Y-%m-%d %H:%M:%S')"
echo "PITR target: $TARGET"
sleep 35

echo "Inserting sentinel B (should not survive restore)..."
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -p "$PGBOUNCER_HOST_PORT" -U postgres -d postgres -c "INSERT INTO drill_restore (note) VALUES ('B')"
# Force WAL containing B to be archived too so recovery can find a stopping point past target.
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -p "$PGBOUNCER_HOST_PORT" -U postgres -d postgres -c "SELECT pg_switch_wal()"
sleep 5
# Wait for archive queue to drain
LEADER=$(docker exec "$PRIMARY_NAME" patronictl -c /tmp/patroni.yml list --format json 2>/dev/null | python3 -c "import sys,json;[print(m['Member']) for m in json.load(sys.stdin) if m['Role']=='Leader']")
for i in {1..30}; do
  PENDING=$(docker exec "$LEADER" su-exec postgres psql -h /var/run/postgresql -U postgres -At -c "SELECT count(*) FROM pg_stat_archiver WHERE last_failed_wal IS NULL" 2>/dev/null || echo "1")
  PEND_FILES=$(docker exec "$LEADER" sh -c 'find /var/spool/pgbackrest -name "*.ready" 2>/dev/null | wc -l' || echo "0")
  if [ "$PEND_FILES" = "0" ]; then echo "archive queue drained."; break; fi
  sleep 1
done

echo "Running restore..."
echo "RESTORE" | make restore POINT_IN_TIME="$TARGET"

echo "Verifying A exists and B does not..."
sleep 15
ROWS=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -p "$PGBOUNCER_HOST_PORT" -U postgres -d postgres -At -c "SELECT note FROM drill_restore ORDER BY id" | tr '\n' ',')
echo "Rows present: $ROWS"
[ "$ROWS" = "A," ] || { echo "FAIL: expected only A; got '$ROWS'"; exit 1; }
echo "PASS"
