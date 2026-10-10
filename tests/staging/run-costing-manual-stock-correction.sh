#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST=localhost
PORT=55432
RUN_TAG="$(printf '%s' "$$-$(date +%s)" | tr -cd '[:alnum:]')"
DB="quena_c3c_staging_${RUN_TAG}"
CREATED=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/quena-c3c-runtime.XXXXXX")"
umask 077

psql_db() {
  local db="$1"; shift
  env -u PGHOST -u PGHOSTADDR -u PGPORT -u PGDATABASE -u PGUSER -u PGSERVICE -u PGSERVICEFILE \
    -u PGPASSWORD -u PGPASSFILE -u PGOPTIONS -u DATABASE_URL -u SUPABASE_DB_URL -u SUPABASE_URL \
    -u SUPABASE_SERVICE_ROLE_KEY -u SUPABASE_ACCESS_TOKEN PGCONNECT_TIMEOUT=5 PGAPPNAME="quena_c3c_runtime" \
    psql -X -w -h "$HOST" -p "$PORT" -U postgres -d "$db" -v ON_ERROR_STOP=1 "$@"
}

cleanup() {
  if [[ "$CREATED" == 1 ]]; then
    psql_db postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid<>pg_backend_pid()" >/dev/null 2>&1 || true
    psql_db postgres -c "DROP DATABASE IF EXISTS \"$DB\"" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$TMP"
}
trap cleanup EXIT

for pair in \
  '20260929290000_costing_purchase_receipt_acquisition_v1.sql:3bea5f2fe6bd83f49020c7bea5519bf847627299fff9e0505aa7a52f69455617' \
  '20260929300000_costing_stock_opname_source_layers_v1.sql:69cec4c022992ee124179fcb140869fd3dae7a19b47ebb7c5f7cf0f10fcddcfc'; do
  file="${pair%%:*}" expected="${pair##*:}"
  actual="$(shasum -a 256 "$ROOT/supabase/migrations/$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { echo "REFUSED: immutable prerequisite checksum mismatch: $file" >&2; exit 30; }
done
base="$(psql_db quena_stock_staging -Atqc "SELECT current_database()='quena_stock_staging' AND inet_server_port()=$PORT AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1') AND current_setting('server_version_num')::integer/10000=15 AND current_setting('server_encoding')='UTF8' AND (SELECT version='20260929300000' FROM quena_staging.applied_migrations ORDER BY ordinal DESC LIMIT 1) AND NOT EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version>'20260929300000')")"
[[ "$base" == t ]] || { echo 'REFUSED: base database is not isolated PostgreSQL 15 C3B frontier through 300000' >&2; exit 31; }
psql_db postgres -c "CREATE DATABASE \"$DB\" TEMPLATE quena_stock_staging" >/dev/null
CREATED=1
psql_db "$DB" -f "$ROOT/supabase/migrations/20260929310000_costing_manual_stock_correction_v1.sql" >"$TMP/apply.log"
psql_db "$DB" -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename) VALUES(24,'20260929310000','20260929310000_costing_manual_stock_correction_v1.sql')" >/dev/null
guard="$(psql_db "$DB" -Atqc "SELECT current_database()='$DB' AND inet_server_port()=$PORT AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1') AND current_setting('server_version_num')::integer/10000=15 AND EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929310000') AND to_regprocedure('public.post_manual_stock_correction(uuid,uuid)') IS NOT NULL")"
[[ "$guard" == t ]] || { echo 'REFUSED: C3C clone guard or migration object check failed' >&2; exit 32; }
before="$(psql_db "$DB" -Atq -f "$ROOT/tests/staging/costing-manual-stock-correction-state.sql")"
psql_db "$DB" -v ON_ERROR_STOP=1 -f "$ROOT/tests/staging/runtime-costing-manual-stock-correction.sql"
after="$(psql_db "$DB" -Atq -f "$ROOT/tests/staging/costing-manual-stock-correction-state.sql")"
[[ "$before" == "$after" ]] || { echo 'FAIL: rollback-only C3C runtime matrix changed durable fixture fingerprints' >&2; echo "before=$before" >&2; echo "after=$after" >&2; exit 33; }
echo 'PASS: C3C rollback-only runtime matrix; all durable stock/cost/correction fingerprints unchanged'
