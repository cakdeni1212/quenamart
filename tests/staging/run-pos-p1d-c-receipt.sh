#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST=127.0.0.1
PORT=55432
RUN_TAG="$(printf '%s' "$$-$(date +%s)" | tr -cd '[:alnum:]')"
DB="quena_p1d_b_staging_${RUN_TAG}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/quena-p1d-c.XXXXXX")"
CREATED=0
umask 077

psql_db() {
  local db="$1"; shift
  env -u PGHOST -u PGHOSTADDR -u PGPORT -u PGDATABASE -u PGUSER -u PGSERVICE -u PGSERVICEFILE \
    -u PGPASSWORD -u PGPASSFILE -u PGOPTIONS -u DATABASE_URL -u SUPABASE_DB_URL -u SUPABASE_URL \
    -u SUPABASE_SERVICE_ROLE_KEY -u SUPABASE_ACCESS_TOKEN PGCONNECT_TIMEOUT=5 PGAPPNAME=quena_p1d_c_staging \
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

expected_hashes=(
  '20260929300000_costing_stock_opname_source_layers_v1.sql:69cec4c022992ee124179fcb140869fd3dae7a19b47ebb7c5f7cf0f10fcddcfc'
  '20260929310000_costing_manual_stock_correction_v1.sql:a9be97450943662e49276ad54ce0d47578a1e135def94b16fd7a6e7c1ba36db3'
  '20260929320000_costing_supplier_return_v1.sql:8a230ff29201e501f9b61f6005a79ee8d153ebba7fd0c103e7faa2019d0e8450'
  '20260929330000_pos_cart_foundation_v1.sql:c99aa7544f55c2942b16a064e2b651ef920934ea274a0db25f80aedd94265f31'
  '20260929340000_pos_sales_evidence_v1.sql:e343110860cdc4101553085f1390619f1f046ca67897f739b2732e0991c716b8'
  '20260929350000_pos_atomic_checkout_v1.sql:3e61395b84df723e76f1406ccbc135f9b2060f141e6a618d1989a20cfc7ad30b'
)
for pair in "${expected_hashes[@]}"; do
  file="${pair%%:*}" expected="${pair##*:}"
  actual="$(shasum -a 256 "$ROOT/supabase/migrations/$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { echo "REFUSED: locked prerequisite hash mismatch: $file" >&2; exit 30; }
done

base="$(psql_db quena_stock_staging -Atqc "SELECT current_database()='quena_stock_staging' AND inet_server_port()=$PORT AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1') AND current_setting('server_version_num')::integer/10000=15 AND current_setting('server_encoding')='UTF8' AND (SELECT name='quena_stock_staging' FROM quena_staging.environment) AND (SELECT version='20260929300000' FROM quena_staging.applied_migrations ORDER BY ordinal DESC LIMIT 1) AND NOT EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version>'20260929300000')")"
[[ "$base" == t ]] || { echo 'REFUSED: source must be isolated local PostgreSQL 15 staging through 300000; no tests run' >&2; exit 31; }
psql_db postgres -c "CREATE DATABASE \"$DB\" TEMPLATE quena_stock_staging" >/dev/null
CREATED=1

for file in \
  20260929310000_costing_manual_stock_correction_v1.sql \
  20260929320000_costing_supplier_return_v1.sql \
  20260929330000_pos_cart_foundation_v1.sql \
  20260929340000_pos_sales_evidence_v1.sql \
  20260929350000_pos_atomic_checkout_v1.sql; do
  psql_db "$DB" -f "$ROOT/supabase/migrations/$file" >"$TMP/$file.log"
  version="${file%%_*}"
  ordinal="$(psql_db "$DB" -Atqc 'SELECT coalesce(max(ordinal),0)+1 FROM quena_staging.applied_migrations')"
  psql_db "$DB" -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename) VALUES($ordinal,'$version','$file')" >/dev/null
done

psql_db "$DB" -f "$ROOT/tests/staging/runtime-pos-p1d-b-checkout.sql" >"$TMP/p1d-b-runtime.log"
file=20260929360000_pos_receipt_read_v1.sql
psql_db "$DB" -f "$ROOT/supabase/migrations/$file" >"$TMP/$file.log"
ordinal="$(psql_db "$DB" -Atqc 'SELECT coalesce(max(ordinal),0)+1 FROM quena_staging.applied_migrations')"
psql_db "$DB" -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename) VALUES($ordinal,'20260929360000','$file')" >/dev/null
psql_db "$DB" -f "$ROOT/tests/staging/runtime-pos-p1d-c-receipt.sql"
echo "PASS: migrations through 360000 and bounded receipt read verified on disposable clone $DB"
echo 'PASS: clone is dropped on exit; no linked Supabase project is contacted'
