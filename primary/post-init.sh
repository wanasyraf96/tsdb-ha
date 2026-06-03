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
RETURNS record AS \$func\$
BEGIN
  SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename = i_username INTO uname, phash;
  RETURN;
END;
\$func\$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE ALL ON FUNCTION pgbouncer.user_lookup(text) FROM PUBLIC;
GRANT USAGE ON SCHEMA pgbouncer TO pgbouncer_auth;
GRANT EXECUTE ON FUNCTION pgbouncer.user_lookup(text) TO pgbouncer_auth;

SELECT 'CREATE DATABASE ${APP_DB} OWNER ${APP_USER}'
  WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${APP_DB}')
\gexec
SQL

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
