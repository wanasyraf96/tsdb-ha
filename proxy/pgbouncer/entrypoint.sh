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

echo "Waiting for pgbouncer_auth role to be ready..."
i=0
while ! PGPASSWORD="${PGBOUNCER_AUTH_PASSWORD}" psql -h haproxy -p 5000 -U "${AUTH_USER}" -d postgres -At -c "SELECT 1" >/dev/null 2>&1; do
  i=$((i+1))
  if [ "$i" -gt 60 ]; then echo "ERROR: pgbouncer_auth role not reachable after 60s" >&2; exit 1; fi
  sleep 1
done

# scram-sha-256 + auth_user requires the cleartext password in userlist.txt so
# pgbouncer can complete the SCRAM handshake against postgres on behalf of the
# auth_user. (SCRAM hashes work for verifying inbound clients but cannot be
# used to authenticate pgbouncer's own outbound connection.)
printf '"%s" "%s"\n' "${AUTH_USER}" "${PGBOUNCER_AUTH_PASSWORD}" > "${USERLIST}"
chmod 600 "${USERLIST}"
echo "userlist.txt written for ${AUTH_USER} (cleartext)"

exec pgbouncer /etc/pgbouncer/pgbouncer.ini
