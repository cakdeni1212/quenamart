#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST=127.0.0.1
PORT=55432
RUN_TAG="$(printf '%s' "$$-$(date +%s)" | tr -cd '[:alnum:]')"
DB="quena_p1d_b_staging_${RUN_TAG}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/quena-p1d-b.XXXXXX")"
CREATED=0
umask 077

psql_db() {
  local db="$1"; shift
  env -u PGHOST -u PGHOSTADDR -u PGPORT -u PGDATABASE -u PGUSER -u PGSERVICE -u PGSERVICEFILE \
    -u PGPASSWORD -u PGPASSFILE -u PGOPTIONS -u DATABASE_URL -u SUPABASE_DB_URL -u SUPABASE_URL \
    -u SUPABASE_SERVICE_ROLE_KEY -u SUPABASE_ACCESS_TOKEN PGCONNECT_TIMEOUT=5 PGAPPNAME=quena_p1d_b_staging \
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

psql_db "$DB" -c "SELECT pg_get_constraintdef(oid) AS inventory_cost_event_projection_state_valid FROM pg_constraint WHERE conrelid='public.inventory_cost_events'::regclass AND conname='inventory_cost_event_projection_state_valid'"
psql_db "$DB" -f "$ROOT/tests/staging/runtime-pos-p1d-b-checkout.sql" >"$TMP/runtime.log"
cat "$TMP/runtime.log"
if ! psql_db "$DB" -f "$ROOT/tests/staging/runtime-pos-p1d-b-commercial-matrix.sql" >"$TMP/commercial-matrix.log" 2>&1; then
  cat "$TMP/commercial-matrix.log"
  exit 36
fi
cat "$TMP/commercial-matrix.log"
if ! psql_db "$DB" -f "$ROOT/tests/staging/runtime-pos-p1d-b-costing-edge-cases.sql" >"$TMP/costing-edge-cases.log" 2>&1; then
  cat "$TMP/costing-edge-cases.log"
  exit 37
fi
cat "$TMP/costing-edge-cases.log"
psql_db "$DB" -f "$ROOT/tests/staging/runtime-pos-p1d-b-concurrency-setup.sql" >"$TMP/race-setup.log"
psql_db "$DB" -v use_b=false -f "$ROOT/tests/staging/runtime-pos-p1d-b-concurrency-session.sql" >"$TMP/race-a.log" 2>&1 & race_a_pid=$!
psql_db "$DB" -v use_b=true -f "$ROOT/tests/staging/runtime-pos-p1d-b-concurrency-session.sql" >"$TMP/race-b.log" 2>&1 & race_b_pid=$!
ready=0
for _ in {1..1000}; do
  if rg -q 'READY' "$TMP/race-a.log" && rg -q 'READY' "$TMP/race-b.log"; then ready=1; break; fi
  sleep 0.01
done
if [[ "$ready" != 1 ]]; then cat "$TMP/race-a.log" "$TMP/race-b.log"; echo 'FAIL: concurrent checkout sessions did not reach barrier' >&2; exit 32; fi
psql_db "$DB" -c 'UPDATE quena_staging.p1d_b_race_gate SET go=true' >/dev/null
wait "$race_a_pid"
wait "$race_b_pid"
cat "$TMP/race-a.log" "$TMP/race-b.log"
successes="$(rg -o 'RESULT=SUCCESS' "$TMP/race-a.log" "$TMP/race-b.log" | wc -l | tr -d ' ')"
shortages="$(rg -o 'RESULT=POS_INSUFFICIENT_STOCK' "$TMP/race-a.log" "$TMP/race-b.log" | wc -l | tr -d ' ')"
[[ "$successes" == 1 && "$shortages" == 1 ]] || { echo "FAIL: expected one concurrent success and one stock rejection; successes=$successes shortages=$shortages" >&2; exit 33; }
race_invariants="$(psql_db "$DB" -Atqc "SELECT (SELECT effective_quantity=0 FROM public.stock_balance_projection WHERE outlet_id=f.outlet_id AND product_id=f.product_id) AND (SELECT count(*)=1 FROM public.sales s WHERE s.pos_cart_id IN(f.cart_a,f.cart_b)) AND (SELECT count(*)=1 FROM public.sale_payments p JOIN public.sales s ON s.id=p.sale_id WHERE s.pos_cart_id IN(f.cart_a,f.cart_b)) AND (SELECT count(*)=1 FROM public.stock_movements m JOIN public.sales s ON s.id=m.pos_sale_id WHERE s.pos_cart_id IN(f.cart_a,f.cart_b) AND m.movement_type='SALE' AND m.source_system='QUENA_POS') AND (SELECT count(*)=1 FROM public.inventory_cost_events e JOIN public.sales s ON s.checkout_request_id=e.operation_request_id WHERE s.pos_cart_id IN(f.cart_a,f.cart_b) AND e.event_type='SALE_COGS') AND (SELECT count(*)=1 FROM public.pos_carts WHERE id IN(f.cart_a,f.cart_b) AND status='ACTIVE') FROM quena_staging.p1d_b_race_fixture f")"
[[ "$race_invariants" == t ]] || { echo 'FAIL: final-unit concurrency invariants did not hold' >&2; exit 34; }
echo 'PASS: two independent PostgreSQL sessions produced one success, one POS_INSUFFICIENT_STOCK, and no negative stock'
if ! psql_db "$DB" -f "$ROOT/tests/staging/runtime-pos-p1d-b-cost-link-negative.sql" >"$TMP/negative-links.log" 2>&1; then
  cat "$TMP/negative-links.log"
  exit 35
fi
cat "$TMP/negative-links.log"
echo "PASS: P1D-B migration applied through 350000 on disposable PostgreSQL 15 clone $DB"
echo 'PASS: clone is dropped on exit; no linked Supabase project is contacted'
