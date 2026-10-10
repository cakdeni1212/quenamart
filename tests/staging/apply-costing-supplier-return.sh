#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST=localhost
PORT=55432
RUN_TAG="$(printf '%s' "$$-$(date +%s)" | tr -cd '[:alnum:]')"
DB="quena_c3d_staging_${RUN_TAG}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/quena-c3d-runtime.XXXXXX")"
CREATED=0
umask 077

psql_db() {
  local db="$1"; shift
  env -u PGHOST -u PGHOSTADDR -u PGPORT -u PGDATABASE -u PGUSER -u PGSERVICE -u PGSERVICEFILE \
    -u PGPASSWORD -u PGPASSFILE -u PGOPTIONS -u DATABASE_URL -u SUPABASE_DB_URL -u SUPABASE_URL \
    -u SUPABASE_SERVICE_ROLE_KEY -u SUPABASE_ACCESS_TOKEN PGCONNECT_TIMEOUT=5 PGAPPNAME=quena_c3d_staging \
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
  '20260929300000_costing_stock_opname_source_layers_v1.sql:69cec4c022992ee124179fcb140869fd3dae7a19b47ebb7c5f7cf0f10fcddcfc' \
  '20260929310000_costing_manual_stock_correction_v1.sql:a9be97450943662e49276ad54ce0d47578a1e135def94b16fd7a6e7c1ba36db3'; do
  file="${pair%%:*}" expected="${pair##*:}"
  actual="$(shasum -a 256 "$ROOT/supabase/migrations/$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { echo "REFUSED: immutable prerequisite checksum mismatch: $file" >&2; exit 30; }
done
sha320="$(shasum -a 256 "$ROOT/supabase/migrations/20260929320000_costing_supplier_return_v1.sql" | awk '{print $1}')"
[[ "$sha320" =~ ^[0-9a-f]{64}$ ]] || { echo 'REFUSED: C3D migration is unavailable' >&2; exit 31; }
base="$(psql_db quena_stock_staging -Atqc "SELECT current_database()='quena_stock_staging' AND inet_server_port()=$PORT AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1') AND current_setting('server_version_num')::integer/10000=15 AND (SELECT version='20260929300000' FROM quena_staging.applied_migrations ORDER BY ordinal DESC LIMIT 1) AND NOT EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version>'20260929300000')")"
[[ "$base" == t ]] || { echo 'REFUSED: base is not isolated PostgreSQL 15 C3B frontier through 300000' >&2; exit 32; }
psql_db postgres -c "CREATE DATABASE \"$DB\" TEMPLATE quena_stock_staging" >/dev/null
CREATED=1
psql_db "$DB" -f "$ROOT/supabase/migrations/20260929310000_costing_manual_stock_correction_v1.sql" >"$TMP/apply-310000.log"
psql_db "$DB" -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename) VALUES(24,'20260929310000','20260929310000_costing_manual_stock_correction_v1.sql')" >/dev/null
psql_db "$DB" -f "$ROOT/supabase/migrations/20260929320000_costing_supplier_return_v1.sql" >"$TMP/apply-320000.log"
psql_db "$DB" -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename) VALUES(25,'20260929320000','20260929320000_costing_supplier_return_v1.sql')" >/dev/null
guard="$(psql_db "$DB" -Atqc "SELECT current_database()='$DB' AND inet_server_port()=$PORT AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1') AND current_setting('server_version_num')::integer/10000=15 AND EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929320000') AND to_regprocedure('public.post_supplier_return(uuid,uuid)') IS NOT NULL AND to_regprocedure('public.inventory_cost_apply_supplier_return(uuid,uuid,uuid)') IS NOT NULL")"
[[ "$guard" == t ]] || { echo 'REFUSED: clone/frontier or C3D object guard failed' >&2; exit 33; }
before="$(psql_db "$DB" -Atq -f "$ROOT/tests/staging/supplier-return-state.sql")"
psql_db "$DB" -f "$ROOT/tests/staging/runtime-costing-supplier-return.sql" >"$TMP/runtime.log"
after="$(psql_db "$DB" -Atq -f "$ROOT/tests/staging/supplier-return-state.sql")"
[[ "$before" == "$after" ]] || { echo 'FAIL: rollback-only C3D matrix changed durable fixture fingerprints' >&2; echo "before=$before" >&2; echo "after=$after" >&2; exit 34; }
echo "PASS: C3D migration applied to isolated disposable clone $DB on localhost:$PORT (frontier 320000)"
echo "C3D_SHA256=$sha320"
echo 'PASS: C3D rollback-only supplier-return runtime matrix; stock/cost/receipt/payable fingerprints unchanged'
