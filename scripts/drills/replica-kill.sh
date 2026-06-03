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

echo "Pausing replica (keeps DNS so HAProxy sees TCP failure cleanly)..."
docker pause "$REPLICA"
sleep 5

echo "Verifying writes still flow..."
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -p "$PGBOUNCER_HOST_PORT" -U postgres -d postgres -At -c "SELECT 1" >/dev/null || { echo "FAIL: writes broken"; exit 1; }

echo "Verifying reads fall back to leader (HAProxy needs ~10s to fail the replica check)..."
for i in {1..30}; do
  IS_IN_RECOVERY=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -p "$HAPROXY_READ_HOST_PORT" -U postgres -d postgres -At -c "SELECT pg_is_in_recovery()" 2>/dev/null || true)
  if [ "$IS_IN_RECOVERY" = "f" ]; then echo "reads now routed to leader."; break; fi
  if [ "$i" = "30" ]; then echo "FAIL: read fallback never happened (last value '$IS_IN_RECOVERY')"; exit 1; fi
  sleep 1
done

echo "Unpausing replica..."
docker unpause "$REPLICA"

echo "Waiting up to 60s for replica to catch up..."
current_leader_container() {
  for c in "$PRIMARY_NAME" "$REPLICA_NAME"; do
    if [ "$(docker inspect -f '{{.State.Running}}{{.State.Paused}}' "$c" 2>/dev/null)" = "truefalse" ]; then
      ROLE=$(docker exec "$c" patronictl -c /tmp/patroni.yml list --format json 2>/dev/null \
        | python3 -c "import sys,json;[print(m['Member']) for m in json.load(sys.stdin) if m['Role']=='Leader']" 2>/dev/null)
      [ -n "$ROLE" ] && { echo "$ROLE"; return; }
    fi
  done
}
LEADER=$(current_leader_container)
for i in {1..30}; do
  LAG=$(docker exec "$LEADER" su-exec postgres psql -h /var/run/postgresql -U postgres -At -c "SELECT COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn),0) FROM pg_stat_replication LIMIT 1" 2>/dev/null || echo "")
  if [ -n "$LAG" ] && [ "$LAG" -lt 1048576 ]; then echo "PASS: replica lag is $LAG bytes"; exit 0; fi
  sleep 2
done
echo "FAIL: replica did not catch up within 60s" >&2; exit 1
