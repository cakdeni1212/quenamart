#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST=127.0.0.1
PORT=55432
RUN_TAG="$(printf '%s' "$$-$(date +%s)" | tr -cd '[:alnum:]')"
DB="quena_p1b_staging_${RUN_TAG}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/quena-p1b.XXXXXX")"
CREATED=0
PIDS=()
umask 077

psql_db() {
  local db="$1"; shift
  env -u PGHOST -u PGHOSTADDR -u PGPORT -u PGDATABASE -u PGUSER -u PGSERVICE -u PGSERVICEFILE \
    -u PGPASSWORD -u PGPASSFILE -u PGOPTIONS -u DATABASE_URL -u SUPABASE_DB_URL -u SUPABASE_URL \
    -u SUPABASE_SERVICE_ROLE_KEY -u SUPABASE_ACCESS_TOKEN PGCONNECT_TIMEOUT=5 PGAPPNAME=quena_p1b_staging \
    psql -X -w -h "$HOST" -p "$PORT" -U postgres -d "$db" -v ON_ERROR_STOP=1 "$@"
}
cleanup() {
  for pid in "${PIDS[@]-}"; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in "${PIDS[@]-}"; do wait "$pid" 2>/dev/null || true; done
  if [[ "$CREATED" == 1 ]]; then
    psql_db postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid<>pg_backend_pid()" >/dev/null 2>&1 || true
    psql_db postgres -c "DROP DATABASE IF EXISTS \"$DB\"" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$TMP"
}
trap cleanup EXIT

expected_hashes=(
  '20260929290000_costing_purchase_receipt_acquisition_v1.sql:3bea5f2fe6bd83f49020c7bea5519bf847627299fff9e0505aa7a52f69455617'
  '20260929300000_costing_stock_opname_source_layers_v1.sql:69cec4c022992ee124179fcb140869fd3dae7a19b47ebb7c5f7cf0f10fcddcfc'
  '20260929310000_costing_manual_stock_correction_v1.sql:a9be97450943662e49276ad54ce0d47578a1e135def94b16fd7a6e7c1ba36db3'
  '20260929320000_costing_supplier_return_v1.sql:8a230ff29201e501f9b61f6005a79ee8d153ebba7fd0c103e7faa2019d0e8450'
)
for pair in "${expected_hashes[@]}"; do
  file="${pair%%:*}" expected="${pair##*:}"
  actual="$(shasum -a 256 "$ROOT/supabase/migrations/$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { echo "REFUSED: locked prerequisite hash mismatch: $file" >&2; exit 30; }
done
cart_sha="$(shasum -a 256 "$ROOT/supabase/migrations/20260929330000_pos_cart_foundation_v1.sql" | awk '{print $1}')"

base="$(psql_db quena_stock_staging -Atqc "SELECT current_database()='quena_stock_staging' AND inet_server_port()=$PORT AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1') AND current_setting('server_version_num')::integer/10000=15 AND current_setting('server_encoding')='UTF8' AND (SELECT name='quena_stock_staging' FROM quena_staging.environment) AND (SELECT version='20260929300000' FROM quena_staging.applied_migrations ORDER BY ordinal DESC LIMIT 1) AND NOT EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version>'20260929300000')")"
[[ "$base" == t ]] || { echo 'REFUSED: source must be isolated PostgreSQL 15 staging through migration 300000 only' >&2; exit 31; }
psql_db postgres -c "CREATE DATABASE \"$DB\" TEMPLATE quena_stock_staging" >/dev/null
CREATED=1

for file in \
  20260929310000_costing_manual_stock_correction_v1.sql \
  20260929320000_costing_supplier_return_v1.sql \
  20260929330000_pos_cart_foundation_v1.sql; do
  psql_db "$DB" -f "$ROOT/supabase/migrations/$file" >"$TMP/$file.log"
  version="${file%%_*}"
  ordinal="$(psql_db "$DB" -Atqc 'SELECT coalesce(max(ordinal),0)+1 FROM quena_staging.applied_migrations')"
  psql_db "$DB" -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename) VALUES($ordinal,'$version','$file')" >/dev/null
done

installed="$(psql_db "$DB" -Atqc "SELECT current_database()='$DB' AND inet_server_port()=$PORT AND EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929330000') AND to_regprocedure('public.pos_cart_create(uuid)') IS NOT NULL AND to_regprocedure('public.pos_cart_add_item(uuid,uuid,numeric,bigint,uuid)') IS NOT NULL AND to_regprocedure('public.pos_cart_workspace_read(uuid,integer)') IS NOT NULL")"
[[ "$installed" == t ]] || { echo 'FAIL: P1B schema/frontier guard failed' >&2; exit 32; }

before="$(psql_db "$DB" -Atq -f "$ROOT/tests/staging/pos-cart-state.sql")"
psql_db "$DB" -f "$ROOT/tests/staging/runtime-pos-cart-foundation.sql" >"$TMP/runtime.log"
after="$(psql_db "$DB" -Atq -f "$ROOT/tests/staging/pos-cart-state.sql")"
[[ "$before" == "$after" ]] || { echo 'FAIL: P1B rollback matrix changed protected operational fingerprints' >&2; echo "before=$before" >&2; echo "after=$after" >&2; exit 33; }

# Verify concurrent exact replay: request uniqueness serializes the second
# caller; it receives the first saved result and the line increments once.
cart_result="$(psql_db "$DB" -Atqc "SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',false); SET ROLE authenticated; SELECT public.pos_cart_create('f2000000-0000-4000-8000-000000000001'::uuid)::text" | tail -n 1)"
cart_id="$(printf '%s' "$cart_result" | sed -n 's/.*"cart_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[[ "$cart_id" =~ ^[0-9a-f-]{36}$ ]] || { echo 'FAIL: concurrent cart fixture creation returned no cart ID' >&2; exit 34; }
scan_product="$(psql_db "$DB" -Atqc "SELECT id FROM public.products WHERE sku='STG-FULL-A'")"
[[ "$scan_product" =~ ^[0-9a-f-]{36}$ ]] || { echo 'FAIL: concurrent scan fixture product is unavailable' >&2; exit 34; }
cat >"$TMP/pos-scan-holder.sql" <<SQL
BEGIN;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
SET LOCAL ROLE authenticated;
SELECT public.pos_cart_add_item('$cart_id'::uuid,'$scan_product'::uuid,1,1,'f2000000-0000-4000-8000-000000000002'::uuid);
SELECT pg_sleep(1);
COMMIT;
SQL
cat >"$TMP/pos-scan-retry.sql" <<SQL
BEGIN;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
SET LOCAL ROLE authenticated;
SELECT public.pos_cart_add_item('$cart_id'::uuid,'$scan_product'::uuid,1,1,'f2000000-0000-4000-8000-000000000002'::uuid);
COMMIT;
SQL
psql_db "$DB" -f "$TMP/pos-scan-holder.sql" >"$TMP/pos-scan-holder.log" 2>&1 & holder=$!; PIDS+=("$holder")
sleep 0.15
psql_db "$DB" -f "$TMP/pos-scan-retry.sql" >"$TMP/pos-scan-retry.log" 2>&1 & retry=$!; PIDS+=("$retry")
wait "$holder" || { cat "$TMP/pos-scan-holder.log" >&2; echo 'FAIL: first concurrent scan failed' >&2; exit 35; }
wait "$retry" || { cat "$TMP/pos-scan-retry.log" >&2; echo 'FAIL: exact concurrent retry failed' >&2; exit 36; }
PIDS=()
concurrent="$(psql_db "$DB" -Atqc "SELECT count(*)=1 AND max(quantity)=1 FROM public.pos_cart_items WHERE cart_id='$cart_id'::uuid AND product_id='$scan_product'::uuid AND (SELECT count(*) FROM public.pos_cart_events WHERE cart_id='$cart_id'::uuid AND event_type='ITEM_ADDED')=1")"
[[ "$concurrent" == t ]] || { echo 'FAIL: concurrent same-request scan applied more than once' >&2; exit 37; }
echo "PASS: migration 330000 and rollback matrix on isolated disposable clone $DB at localhost:$PORT"
echo "P1B_SHA256=$cart_sha"
echo 'PASS: barcode/search, cashier authorization, cart lifecycle, replay, revisions, price change, and role/read isolation'
echo 'PASS: stock, costing/source layers, receipts, opname, corrections, returns, HPP acceptance, and payables unchanged after rollback'
echo 'PASS: overlapping same-request barcode submission committed one item increment and one event'
