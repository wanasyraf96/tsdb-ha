#!/usr/bin/env bash
set -euo pipefail

# Activate the PITR custom bootstrap method only when POINT_IN_TIME is set.
# Without this, `method: pgbackrest_pitr` is absent and Patroni falls through
# to the default initdb bootstrap.
if [[ -n "${POINT_IN_TIME:-}" ]]; then
  export PATRONI_BOOTSTRAP_METHOD_LINE="  method: pgbackrest_pitr"
  echo "PITR mode: POINT_IN_TIME=${POINT_IN_TIME}"
else
  export PATRONI_BOOTSTRAP_METHOD_LINE=""
fi

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
