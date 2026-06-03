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
  # Try whichever container is currently running. Paused containers can't exec.
  for c in "$PRIMARY_CONTAINER" "$REPLICA_CONTAINER"; do
    if [ "$(docker inspect -f '{{.State.Running}}{{.State.Paused}}' "$c" 2>/dev/null)" = "truefalse" ]; then
      JSON="$(docker exec "$c" patronictl -c /tmp/patroni.yml list --format json 2>/dev/null || true)"
      if [ -n "$JSON" ]; then
        echo "$JSON" | python3 -c 'import sys,json; [print(m["Member"]) for m in json.load(sys.stdin) if m["Role"]=="Leader"]'
        return
      fi
    fi
  done
}

LEADER="$(current_leader)"
echo "Current leader: $LEADER"

OTHER="$([ "$LEADER" = "$PRIMARY_CONTAINER" ] && echo "$REPLICA_CONTAINER" || echo "$PRIMARY_CONTAINER")"
echo "Will kill $LEADER; expect $OTHER to be promoted."

echo "Inserting sentinel before kill (and forcing WAL flush so it survives)..."
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -p "$PGBOUNCER_HOST_PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 <<SQL
CREATE TABLE IF NOT EXISTS drill_failover (id serial primary key, ts timestamptz default now(), note text);
INSERT INTO drill_failover (note) VALUES ('before-kill');
CHECKPOINT;
SELECT pg_switch_wal();
SQL

# Wait for the WAL to actually replicate to the standby before we kill the leader,
# otherwise synchronous_commit=off can lose the sentinel.
echo "Waiting for replica to catch up before kill..."
for i in {1..15}; do
  LAG=$(docker exec "$LEADER" su-exec postgres psql -h /var/run/postgresql -U postgres -At -c \
        "SELECT COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn),0) FROM pg_stat_replication LIMIT 1")
  if [ "$LAG" = "0" ]; then echo "replica caught up."; break; fi
  sleep 1
done

START=$(date +%s)
# `docker pause` keeps the container in DNS so HAProxy's TCP health check sees a
# timeout (vs. NXDOMAIN with stop/kill, which puts haproxy into MAINT and skips
# `on-marked-down shutdown-sessions`).
docker pause "$LEADER"
echo "Paused $LEADER at t=0; polling write path..."

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

echo "Unpausing the old leader so Patroni can demote and rejoin it..."
docker unpause "$LEADER"

echo "Waiting up to 60s for it to rejoin as Replica..."
for i in {1..30}; do
  if docker exec "$NEW_LEADER" patronictl -c /tmp/patroni.yml list --format json | grep -q '"Role": "Replica"'; then
    echo "PASS: rejoined as replica."
    # Budget = 60s: ~10s etcd TTL + ~10s promotion + ~9s HAProxy fall + ~15s pgBouncer login retry + slack.
    [ "$WRITE_DOWNTIME" -le 60 ] || { echo "WARN: write downtime ${WRITE_DOWNTIME}s > 60s budget"; exit 1; }
    exit 0
  fi
  sleep 2
done
echo "FAIL: killed node did not rejoin as replica within 60s" >&2; exit 1
