#!/usr/bin/env bash
# Patroni custom bootstrap method: restore PGDATA from pgBackRest at the
# requested point in time, then let Patroni configure recovery_conf and start
# postgres. Only fires when:
#   - DCS has no /initialize key for this cluster (i.e. wiped or fresh), AND
#   - PGDATA is empty (Patroni clears it before invoking us).
#
# Patroni invokes:
#   pitr-bootstrap.sh --scope <cluster_scope> --datadir <pgdata_path>
#
# POINT_IN_TIME is read from the environment (passed through docker-compose).
# `make restore POINT_IN_TIME=...` is the only supported entry point.
set -euo pipefail

SCOPE=""
DATADIR=""
# Patroni passes args as --key=value (single token), not --key value.
for arg in "$@"; do
  case "${arg}" in
    --scope=*)   SCOPE="${arg#*=}" ;;
    --datadir=*) DATADIR="${arg#*=}" ;;
  esac
done

: "${POINT_IN_TIME:?POINT_IN_TIME must be set for PITR bootstrap}"
: "${SCOPE:?--scope required from Patroni}"
: "${DATADIR:?--datadir required from Patroni}"

echo "[pitr-bootstrap] stanza=${SCOPE} target='${POINT_IN_TIME}' datadir=${DATADIR}"

# pgBackRest refuses to restore into a non-empty path; Patroni leaves the
# directory in place. Wipe it before restore so pgbackrest can repopulate.
rm -rf "${DATADIR}"

exec pgbackrest \
  --stanza="${SCOPE}" \
  --type=time \
  --target="${POINT_IN_TIME}" \
  --target-action=promote \
  --pg1-path="${DATADIR}" \
  restore
