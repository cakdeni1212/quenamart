#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST=127.0.0.1
PORT=55432
RUN_TAG="$(printf '%s' "$$-$(date +%s)" | tr -cd '[:alnum:]')"
DB="quena_native_product_${RUN_TAG}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/quena-native-product.XXXXXX")"
CREATED=0
umask 077

psql_db() {
  local db="$1"; shift
  env -u PGHOST -u PGHOSTADDR -u PGPORT -u PGDATABASE -u PGUSER -u PGSERVICE -u PGSERVICEFILE \
    -u PGPASSWORD -u PGPASSFILE -u PGOPTIONS -u DATABASE_URL -u SUPABASE_DB_URL -u SUPABASE_URL \
    -u SUPABASE_SERVICE_ROLE_KEY -u SUPABASE_ACCESS_TOKEN PGCONNECT_TIMEOUT=5 PGAPPNAME=quena_native_product_staging \
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
  '20260929310000_costing_manual_stock_correction_v1.sql:a9be97450943662e49276ad54ce0d47578a1e135def94b16fd7a6e7c1ba36db3'
  '20260929320000_costing_supplier_return_v1.sql:8a230ff29201e501f9b61f6005a79ee8d153ebba7fd0c103e7faa2019d0e8450'
  '20260929330000_pos_cart_foundation_v1.sql:c99aa7544f55c2942b16a064e2b651ef920934ea274a0db25f80aedd94265f31'
  '20260929340000_pos_sales_evidence_v1.sql:e343110860cdc4101553085f1390619f1f046ca67897f739b2732e0991c716b8'
  '20260929350000_pos_atomic_checkout_v1.sql:3e61395b84df723e76f1406ccbc135f9b2060f141e6a618d1989a20cfc7ad30b'
  '20260929360000_pos_receipt_read_v1.sql:182214378d1ec4fc421f253c74e9379d5af93a147d3a927e893626e3ca604a67'
  '20260929370000_stock_opening_cutover_v1.sql:e63ae5c5b65d61563e8a978850eda6a582316c21cfd1358490e6835dc2641ddb'
)
for pair in "${expected_hashes[@]}"; do
  file="${pair%%:*}" expected="${pair##*:}"
  actual="$(shasum -a 256 "$ROOT/supabase/migrations/$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { echo "REFUSED: prerequisite hash mismatch: $file" >&2; exit 30; }
done

base="$(psql_db quena_stock_staging -Atqc "SELECT current_database()='quena_stock_staging' AND inet_server_port()=$PORT AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1') AND current_setting('server_version_num')::integer/10000=15 AND current_setting('server_encoding')='UTF8' AND (SELECT name='quena_stock_staging' FROM quena_staging.environment) AND (SELECT version='20260929300000' FROM quena_staging.applied_migrations ORDER BY ordinal DESC LIMIT 1) AND NOT EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version>'20260929300000')")"
[[ "$base" == t ]] || { echo 'REFUSED: source must be the disposable PostgreSQL 15 staging baseline through 300000; no tests run' >&2; exit 31; }
psql_db postgres -c "CREATE DATABASE \"$DB\" TEMPLATE quena_stock_staging" >/dev/null
CREATED=1

for file in \
  20260929310000_costing_manual_stock_correction_v1.sql \
  20260929320000_costing_supplier_return_v1.sql \
  20260929330000_pos_cart_foundation_v1.sql \
  20260929340000_pos_sales_evidence_v1.sql \
  20260929350000_pos_atomic_checkout_v1.sql \
  20260929360000_pos_receipt_read_v1.sql \
  20260929370000_stock_opening_cutover_v1.sql \
  20260929380000_native_product_creation_v1.sql; do
  psql_db "$DB" -f "$ROOT/supabase/migrations/$file" >"$TMP/$file.log"
  version="${file%%_*}"
  ordinal="$(psql_db "$DB" -Atqc 'SELECT coalesce(max(ordinal),0)+1 FROM quena_staging.applied_migrations')"
  psql_db "$DB" -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename) VALUES($ordinal,'$version','$file')" >/dev/null
done

psql_db "$DB" -f "$ROOT/tests/staging/runtime-native-product-creation.sql" >"$TMP/runtime.log"
cat "$TMP/runtime.log"
psql_db "$DB" -f "$ROOT/tests/staging/runtime-costing-purchase-receipt.sql" >"$TMP/receipt.log"
cat "$TMP/receipt.log"
psql_db "$DB" -f "$ROOT/tests/staging/runtime-stock-opening-cutover.sql" >"$TMP/cutover.log"
cat "$TMP/cutover.log"

# Independent sessions race on one manual SKU: the products unique constraint
# and RPC domain mapping must allow exactly one creation.
sku="NATIVE-RACE-$RUN_TAG"
request_a="$(psql_db "$DB" -Atqc 'SELECT gen_random_uuid()')"
request_b="$(psql_db "$DB" -Atqc 'SELECT gen_random_uuid()')"
call_sql() {
  local request="$1" name="$2"
  psql_db "$DB" -Atqc "SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false); SELECT public.native_product_create('$request'::uuid,'$sku','$name','Race','pcs',NULL,NULL,NULL,1000)"
}
call_sql "$request_a" 'Native race A' >"$TMP/sku-a.log" 2>&1 & pid_a=$!
call_sql "$request_b" 'Native race B' >"$TMP/sku-b.log" 2>&1 & pid_b=$!
set +e
wait "$pid_a"; rc_a=$?
wait "$pid_b"; rc_b=$?
set -e
if ! { [[ $rc_a -eq 0 && $rc_b -ne 0 ]] || [[ $rc_b -eq 0 && $rc_a -ne 0 ]]; }; then
  cat "$TMP/sku-a.log" "$TMP/sku-b.log"
  echo "FAIL: concurrent duplicate SKU expected one success/one rejection ($rc_a,$rc_b)" >&2
  exit 32
fi
if [[ $rc_a -ne 0 ]] && ! rg -q 'NATIVE_PRODUCT_SKU_EXISTS' "$TMP/sku-a.log"; then cat "$TMP/sku-a.log"; exit 33; fi
if [[ $rc_b -ne 0 ]] && ! rg -q 'NATIVE_PRODUCT_SKU_EXISTS' "$TMP/sku-b.log"; then cat "$TMP/sku-b.log"; exit 33; fi

# Independent sessions race on a barcode. The serialized active-barcode
# check must ensure it is attached to at most one product.
barcode="NATIVEBC$RUN_TAG"
request_a="$(psql_db "$DB" -Atqc 'SELECT gen_random_uuid()')"
request_b="$(psql_db "$DB" -Atqc 'SELECT gen_random_uuid()')"
call_barcode() {
  local request="$1" sku_value="$2" name="$3"
  psql_db "$DB" -Atqc "SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false); SELECT public.native_product_create('$request'::uuid,'$sku_value','$name','Race','pcs',NULL,NULL,'$barcode',1000)"
}
call_barcode "$request_a" "NATIVE-BA-$RUN_TAG" 'Native barcode race A' >"$TMP/barcode-a.log" 2>&1 & pid_a=$!
call_barcode "$request_b" "NATIVE-BB-$RUN_TAG" 'Native barcode race B' >"$TMP/barcode-b.log" 2>&1 & pid_b=$!
set +e
wait "$pid_a"; rc_a=$?
wait "$pid_b"; rc_b=$?
set -e
if ! { [[ $rc_a -eq 0 && $rc_b -ne 0 ]] || [[ $rc_b -eq 0 && $rc_a -ne 0 ]]; }; then
  cat "$TMP/barcode-a.log" "$TMP/barcode-b.log"
  echo "FAIL: concurrent duplicate barcode expected one success/one rejection ($rc_a,$rc_b)" >&2
  exit 34
fi
if [[ $rc_a -ne 0 ]] && ! rg -q 'NATIVE_PRODUCT_BARCODE_EXISTS' "$TMP/barcode-a.log"; then cat "$TMP/barcode-a.log"; exit 35; fi
if [[ $rc_b -ne 0 ]] && ! rg -q 'NATIVE_PRODUCT_BARCODE_EXISTS' "$TMP/barcode-b.log"; then cat "$TMP/barcode-b.log"; exit 35; fi
attached="$(psql_db "$DB" -Atqc "SELECT count(*) FROM public.product_barcodes WHERE barcode='$barcode' AND is_active")"
[[ "$attached" == 1 ]] || { echo "FAIL: concurrent barcode attached to $attached products" >&2; exit 36; }

echo "PASS: migrations 310000–380000 and native product runtime verified on disposable clone $DB"
echo 'PASS: concurrent duplicate SKU and barcode each produced one creation and one friendly conflict'
echo 'PASS: clone is dropped on exit; no linked Supabase project is contacted'
