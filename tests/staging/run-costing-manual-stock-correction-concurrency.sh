#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PORT=55432
HOST=localhost
RUN_TAG="$(printf '%s' "$$-$(date +%s)" | tr -cd '[:alnum:]')"
DB="quena_c3c_race_${RUN_TAG}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/quena-c3c-race.XXXXXX")"
CREATED=0
PIDS=()
umask 077

psql_db() {
  local db="$1"; shift
  env -u PGHOST -u PGHOSTADDR -u PGPORT -u PGDATABASE -u PGUSER -u PGSERVICE -u PGSERVICEFILE \
    -u PGPASSWORD -u PGPASSFILE -u PGOPTIONS -u DATABASE_URL -u SUPABASE_DB_URL -u SUPABASE_URL \
    -u SUPABASE_SERVICE_ROLE_KEY -u SUPABASE_ACCESS_TOKEN PGCONNECT_TIMEOUT=5 PGAPPNAME="quena_c3c_local" \
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

sha290="$(shasum -a 256 "$ROOT/supabase/migrations/20260929290000_costing_purchase_receipt_acquisition_v1.sql" | awk '{print $1}')"
sha300="$(shasum -a 256 "$ROOT/supabase/migrations/20260929300000_costing_stock_opname_source_layers_v1.sql" | awk '{print $1}')"
[[ "$sha290" == 3bea5f2fe6bd83f49020c7bea5519bf847627299fff9e0505aa7a52f69455617 ]] || { echo 'REFUSED: 290000 checksum mismatch' >&2; exit 20; }
[[ "$sha300" == 69cec4c022992ee124179fcb140869fd3dae7a19b47ebb7c5f7cf0f10fcddcfc ]] || { echo 'REFUSED: 300000 checksum mismatch' >&2; exit 21; }
base="$(psql_db quena_stock_staging -Atqc "SELECT current_database()='quena_stock_staging' AND inet_server_port()=$PORT AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1') AND current_setting('server_version_num')::integer/10000=15 AND EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929300000')")"
[[ "$base" == t ]] || { echo 'REFUSED: base is not guarded local PostgreSQL 15 C3B staging' >&2; exit 22; }
psql_db postgres -c "CREATE DATABASE \"$DB\" TEMPLATE quena_stock_staging" >/dev/null
CREATED=1
psql_db "$DB" -f "$ROOT/supabase/migrations/20260929310000_costing_manual_stock_correction_v1.sql" >/dev/null
psql_db "$DB" -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename) VALUES(24,'20260929310000','20260929310000_costing_manual_stock_correction_v1.sql')" >/dev/null
guard="$(psql_db "$DB" -Atqc "SELECT current_database()='$DB' AND inet_server_port()=$PORT AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1') AND EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929310000')")"
[[ "$guard" == t ]] || { echo 'REFUSED: disposable C3C race clone guard failed' >&2; exit 23; }

OWNER='a0000000-0000-4000-8000-000000000001'
OUTLET="$(psql_db "$DB" -Atqc "SELECT id FROM public.outlets WHERE code='QUENA-MART-1' AND is_active")"
PRODUCT="$(psql_db "$DB" -Atqc "SELECT id FROM public.products WHERE sku='STG-BASE20'")"
CORRECTION="$(psql_db "$DB" -Atqc "SET ROLE authenticated; SET request.jwt.claim.sub='$OWNER'; SELECT public.create_manual_stock_correction('$OUTLET'::uuid,'FOUND','Concurrent request replay fixture',jsonb_build_array(jsonb_build_object('product_id','$PRODUCT'::uuid,'quantity_delta',1)))->>'id'")"
REQUEST="$(python3 -c 'import uuid; print(uuid.uuid4())')"
BASE_QTY="$(psql_db "$DB" -Atqc "SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid")"

cat >"$TMP/post.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.post_manual_stock_correction('$CORRECTION'::uuid,'$REQUEST'::uuid);
COMMIT;
SQL
psql_db "$DB" -Atq -f "$TMP/post.sql" >"$TMP/one.log" 2>&1 & PIDS+=("$!")
psql_db "$DB" -Atq -f "$TMP/post.sql" >"$TMP/two.log" 2>&1 & PIDS+=("$!")
set +e
wait "${PIDS[0]}"; one_rc=$?
wait "${PIDS[1]}"; two_rc=$?
set -e
PIDS=()
if [[ "$one_rc" != 0 || "$two_rc" != 0 ]]; then cat "$TMP/one.log" "$TMP/two.log" >&2; echo 'FAIL: same-request post race failed or deadlocked' >&2; exit 24; fi
replay="$(psql_db "$DB" -Atqc "SELECT count(*)=1 AND (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid)='$BASE_QTY'::numeric+1 FROM public.stock_movements WHERE manual_stock_correction_id='$CORRECTION'::uuid")"
[[ "$replay" == t ]] || { echo 'FAIL: concurrent same-request post duplicated stock movement or stock delta' >&2; exit 25; }
echo 'PASS: concurrent same-request manual post serialized and replayed once'

# Receipt-post commits first while manual correction waits on the shared outlet lock.
CORRECTION3="$(psql_db "$DB" -Atqc "SET ROLE authenticated; SET request.jwt.claim.sub='$OWNER'; SELECT public.create_manual_stock_correction('$OUTLET'::uuid,'FOUND','Receipt race correction fixture',jsonb_build_array(jsonb_build_object('product_id','$PRODUCT'::uuid,'quantity_delta',1)))->>'id'")"
REQUEST3="$(python3 -c 'import uuid; print(uuid.uuid4())')"
RECEIPT_SETUP_LOG="$(psql_db "$DB" -Atq <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.purchase_supplier_upsert(NULL,'C3C concurrent receipt supplier',NULL,NULL,NULL,true) AS supplier \\gset
SELECT public.purchase_receipt_create_draft('$OUTLET'::uuid,:'supplier'::uuid,now(),'C3C receipt/correction race') AS receipt \\gset
SELECT public.purchase_receipt_save_draft(:'receipt'::uuid,1,now(),NULL,jsonb_build_array(jsonb_build_object('product_id','$PRODUCT'::uuid,'accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0)));
SELECT id AS item FROM public.purchase_receipt_items WHERE receipt_id=:'receipt'::uuid AND product_id='$PRODUCT'::uuid \\gset
SELECT public.purchase_receipt_acquisition_estimate_save(:'receipt'::uuid,:'item'::uuid,2,0,'MANAGER_ESTIMATE',1000,NULL,'C3C receipt race fixture');
SELECT public.issue_purchase_receipt_post_intent(:'receipt'::uuid) AS request \\gset
COMMIT;
\\echo RECEIPT_ID=:'receipt'
\\echo RECEIPT_REQUEST=:'request'
SQL
  2>&1 || true)"
RECEIPT_ID="$(printf '%s\n' "$RECEIPT_SETUP_LOG" | sed -n "s/^RECEIPT_ID=['\"]\{0,1\}\([0-9a-f-]*\)['\"]\{0,1\}$/\1/p")"
RECEIPT_REQUEST="$(printf '%s\n' "$RECEIPT_SETUP_LOG" | sed -n "s/^RECEIPT_REQUEST=['\"]\{0,1\}\([0-9a-f-]*\)['\"]\{0,1\}$/\1/p")"
[[ "$RECEIPT_ID" =~ ^[0-9a-f-]{36}$ && "$RECEIPT_REQUEST" =~ ^[0-9a-f-]{36}$ ]] || { echo "FAIL: receipt race fixture setup failed: $RECEIPT_SETUP_LOG" >&2; exit 29; }
RACE_BASE="$(psql_db "$DB" -Atqc "SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid")"
cat >"$TMP/receipt-holder.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT pg_advisory_xact_lock(hashtextextended('COST_BOOTSTRAP_OUTLET:'||'$OUTLET',73190411));
SELECT public.apply_purchase_receipt_post_intent('$RECEIPT_REQUEST'::uuid);
SELECT pg_sleep(2);
COMMIT;
SQL
cat >"$TMP/correction-receipt-waiter.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.post_manual_stock_correction('$CORRECTION3'::uuid,'$REQUEST3'::uuid);
COMMIT;
SQL
psql_db "$DB" -Atq -f "$TMP/receipt-holder.sql" >"$TMP/receipt-holder.log" 2>&1 & holder_pid=$!; PIDS+=("$holder_pid")
sleep 0.15
psql_db "$DB" -Atq -f "$TMP/correction-receipt-waiter.sql" >"$TMP/correction-receipt.log" 2>&1 & waiter_pid=$!; PIDS+=("$waiter_pid")
set +e
wait "$holder_pid"; holder_rc=$?
wait "$waiter_pid"; waiter_rc=$?
set -e
PIDS=()
if [[ "$holder_rc" != 0 || "$waiter_rc" != 0 ]]; then cat "$TMP/receipt-holder.log" "$TMP/correction-receipt.log" >&2; echo 'FAIL: receipt/correction race deadlocked or failed' >&2; exit 30; fi
receipt_correction_state="$(psql_db "$DB" -Atqc "SELECT (SELECT status='POSTED' FROM public.purchase_receipts WHERE id='$RECEIPT_ID'::uuid) AND (SELECT status='POSTED' FROM public.manual_stock_corrections WHERE id='$CORRECTION3'::uuid) AND (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid)='$RACE_BASE'::numeric+2")"
[[ "$receipt_correction_state" == t ]] || { echo 'FAIL: receipt/correction race left inconsistent stock or lifecycle' >&2; exit 31; }
echo 'PASS: receipt post and manual correction serialized on shared cutover lock'

# Manual correction commits before an already-counted opname; the opname must be stale, never double-adjust stock.
OPNAME_SETUP_LOG="$(psql_db "$DB" -Atq <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.apply_stock_operation_intent(public.issue_stock_operation_intent('CREATE_SESSION',jsonb_build_object('outlet_id','$OUTLET'::uuid,'scope_type','PARTIAL','product_ids',jsonb_build_array('$PRODUCT'::uuid))))->>'sessionId' AS session_id \\gset
SELECT revision_no FROM public.stock_opname_items WHERE session_id=:'session_id'::uuid AND product_id='$PRODUCT'::uuid \\gset
SELECT public.apply_stock_operation_intent(public.issue_stock_operation_intent('RECORD_COUNT',jsonb_build_object('session_id',:'session_id'::uuid,'product_id','$PRODUCT'::uuid,'physical_quantity',(SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid),'expected_revision',:'revision_no'::integer)));
SELECT public.apply_stock_operation_intent(public.issue_stock_operation_intent('SUBMIT_REVIEW',jsonb_build_object('session_id',:'session_id'::uuid)));
SELECT public.issue_stock_operation_intent('POST_SESSION',jsonb_build_object('session_id',:'session_id'::uuid)) AS request_id \\gset
COMMIT;
\\echo OPNAME_REQUEST=:'request_id'
SQL
  2>&1 || true)"
OPNAME_REQUEST="$(printf '%s\n' "$OPNAME_SETUP_LOG" | sed -n "s/^OPNAME_REQUEST=['\"]\{0,1\}\([0-9a-f-]*\)['\"]\{0,1\}$/\1/p")"
[[ "$OPNAME_REQUEST" =~ ^[0-9a-f-]{36}$ ]] || { echo "FAIL: opname race setup failed: $OPNAME_SETUP_LOG" >&2; exit 32; }
CORRECTION4="$(psql_db "$DB" -Atqc "SET ROLE authenticated; SET request.jwt.claim.sub='$OWNER'; SELECT public.create_manual_stock_correction('$OUTLET'::uuid,'FOUND','Opname race correction fixture',jsonb_build_array(jsonb_build_object('product_id','$PRODUCT'::uuid,'quantity_delta',1)))->>'id'")"
REQUEST4="$(python3 -c 'import uuid; print(uuid.uuid4())')"
OPNAME_BASE="$(psql_db "$DB" -Atqc "SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid")"
cat >"$TMP/correction-holder.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.post_manual_stock_correction('$CORRECTION4'::uuid,'$REQUEST4'::uuid);
SELECT pg_sleep(2);
COMMIT;
SQL
cat >"$TMP/opname-waiter.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.apply_stock_operation_intent('$OPNAME_REQUEST'::uuid);
COMMIT;
SQL
psql_db "$DB" -Atq -f "$TMP/correction-holder.sql" >"$TMP/correction-holder.log" 2>&1 & holder_pid=$!; PIDS+=("$holder_pid")
sleep 0.15
psql_db "$DB" -Atq -f "$TMP/opname-waiter.sql" >"$TMP/opname-waiter.log" 2>&1 & waiter_pid=$!; PIDS+=("$waiter_pid")
set +e
wait "$holder_pid"; holder_rc=$?
wait "$waiter_pid"; waiter_rc=$?
set -e
PIDS=()
if [[ "$holder_rc" != 0 || "$waiter_rc" != 0 ]] || ! grep -q 'STALE_BASELINE' "$TMP/opname-waiter.log"; then
  cat "$TMP/correction-holder.log" "$TMP/opname-waiter.log" >&2; echo 'FAIL: correction/opname race did not serialize into stale-baseline protection' >&2; exit 33
fi
opname_correction_state="$(psql_db "$DB" -Atqc "SELECT (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid)='$OPNAME_BASE'::numeric+1 AND NOT EXISTS(SELECT 1 FROM public.stock_movement_batches WHERE operation_request_id='$OPNAME_REQUEST'::uuid) AND (SELECT state='STALE' FROM public.stock_operation_requests WHERE request_id='$OPNAME_REQUEST'::uuid)")"
[[ "$opname_correction_state" == t ]] || { echo 'FAIL: correction/opname race left duplicate or stale stock state' >&2; exit 34; }
echo 'PASS: correction/opname race serialized; stale opname created no movement'

# A manual correction and a standard reversal also share the outlet cutover lock.
CORRECTION5="$(psql_db "$DB" -Atqc "SET ROLE authenticated; SET request.jwt.claim.sub='$OWNER'; SELECT public.create_manual_stock_correction('$OUTLET'::uuid,'FOUND','Reversal race source fixture',jsonb_build_array(jsonb_build_object('product_id','$PRODUCT'::uuid,'quantity_delta',1)))->>'id'")"
REQUEST5="$(python3 -c 'import uuid; print(uuid.uuid4())')"
psql_db "$DB" -Atqc "SET ROLE authenticated; SET request.jwt.claim.sub='$OWNER'; SELECT public.post_manual_stock_correction('$CORRECTION5'::uuid,'$REQUEST5'::uuid)" >/dev/null
MOVEMENT5="$(psql_db "$DB" -Atqc "SELECT m.id FROM public.stock_movement_batches b JOIN public.stock_movements m ON m.batch_id=b.id WHERE b.operation_request_id='$REQUEST5'::uuid")"
REVERSAL_REQUEST5="$(psql_db "$DB" -Atqc "SET ROLE authenticated; SET request.jwt.claim.sub='$OWNER'; SELECT public.issue_stock_operation_intent('REVERSE_MOVEMENT',jsonb_build_object('movement_id','$MOVEMENT5'::uuid,'reason','C3C correction/reversal concurrency fixture'))")"
CORRECTION6="$(psql_db "$DB" -Atqc "SET ROLE authenticated; SET request.jwt.claim.sub='$OWNER'; SELECT public.create_manual_stock_correction('$OUTLET'::uuid,'FOUND','Correction reversal race fixture',jsonb_build_array(jsonb_build_object('product_id','$PRODUCT'::uuid,'quantity_delta',1)))->>'id'")"
REQUEST6="$(python3 -c 'import uuid; print(uuid.uuid4())')"
REVERSAL_RACE_BASE="$(psql_db "$DB" -Atqc "SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid")"
cat >"$TMP/correction-reversal-holder.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.post_manual_stock_correction('$CORRECTION6'::uuid,'$REQUEST6'::uuid);
SELECT pg_sleep(2);
COMMIT;
SQL
cat >"$TMP/reversal-waiter.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.apply_stock_operation_intent('$REVERSAL_REQUEST5'::uuid);
COMMIT;
SQL
psql_db "$DB" -Atq -f "$TMP/correction-reversal-holder.sql" >"$TMP/correction-reversal-holder.log" 2>&1 & holder_pid=$!; PIDS+=("$holder_pid")
sleep 0.15
psql_db "$DB" -Atq -f "$TMP/reversal-waiter.sql" >"$TMP/reversal-waiter.log" 2>&1 & waiter_pid=$!; PIDS+=("$waiter_pid")
set +e
wait "$holder_pid"; holder_rc=$?
wait "$waiter_pid"; waiter_rc=$?
set -e
PIDS=()
if [[ "$holder_rc" != 0 || "$waiter_rc" != 0 ]]; then cat "$TMP/correction-reversal-holder.log" "$TMP/reversal-waiter.log" >&2; echo 'FAIL: correction/reversal race failed or deadlocked' >&2; exit 35; fi
reversal_state="$(psql_db "$DB" -Atqc "SELECT (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid)='$REVERSAL_RACE_BASE'::numeric AND EXISTS(SELECT 1 FROM public.stock_movement_batches WHERE operation_request_id='$REQUEST6'::uuid) AND EXISTS(SELECT 1 FROM public.stock_movement_batches WHERE operation_request_id='$REVERSAL_REQUEST5'::uuid)")"
[[ "$reversal_state" == t ]] || { echo 'FAIL: correction/reversal race did not produce the serialized net quantity' >&2; exit 36; }
echo 'PASS: manual correction and standard reversal serialized on shared cutover lock'

# Verify the BOOTSTRAP_READY gate after waiting on the same outlet cutover lock.
psql_db "$DB" -c "SET ROLE postgres" >/dev/null
psql_db "$DB" -c "INSERT INTO public.product_field_audit_reviews(product_id,outlet_id,field_key,status,source_import_row_id,reviewer_id,evidence_notes,request_id) SELECT '$PRODUCT'::uuid,'$OUTLET'::uuid,'hpp','SUDAH_DIVERIFIKASI',source_import_row_id,'$OWNER'::uuid,'C3C bootstrap race fixture',gen_random_uuid() FROM public.product_costs WHERE product_id='$PRODUCT'::uuid AND outlet_id='$OUTLET'::uuid" >/dev/null
AUTHORITY="$(psql_db "$DB" -Atqc "SET ROLE authenticated; SET request.jwt.claim.sub='$OWNER'; SELECT public.inventory_cost_bootstrap_outlet('$OUTLET'::uuid,gen_random_uuid())->>'code'")"
[[ "$AUTHORITY" == BOOTSTRAP_READY ]] || { echo "FAIL: bootstrap did not reach BOOTSTRAP_READY: $AUTHORITY" >&2; exit 26; }
CORRECTION2="$(psql_db "$DB" -Atqc "SET ROLE authenticated; SET request.jwt.claim.sub='$OWNER'; SELECT public.create_manual_stock_correction('$OUTLET'::uuid,'FOUND','Bootstrap race retry fixture',jsonb_build_array(jsonb_build_object('product_id','$PRODUCT'::uuid,'quantity_delta',1)))->>'id'")"
REQUEST2="$(python3 -c 'import uuid; print(uuid.uuid4())')"
BASE_QTY2="$(psql_db "$DB" -Atqc "SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid")"
cat >"$TMP/bootstrap-holder.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT pg_advisory_xact_lock(hashtextextended('COST_BOOTSTRAP_OUTLET:'||'$OUTLET',73190411));
SELECT pg_sleep(2);
COMMIT;
SQL
cat >"$TMP/correction-waiter.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.post_manual_stock_correction('$CORRECTION2'::uuid,'$REQUEST2'::uuid);
COMMIT;
SQL
psql_db "$DB" -Atq -f "$TMP/bootstrap-holder.sql" >"$TMP/bootstrap.log" 2>&1 & hold_pid=$!; PIDS+=("$hold_pid")
sleep 0.15
psql_db "$DB" -Atq -f "$TMP/correction-waiter.sql" >"$TMP/correction.log" 2>&1 & wait_pid=$!; PIDS+=("$wait_pid")
set +e
wait "$hold_pid"; hold_rc=$?
wait "$wait_pid"; correction_rc=$?
set -e
PIDS=()
if [[ "$hold_rc" != 0 || "$correction_rc" == 0 ]] || ! grep -q 'Perubahan stok ditahan' "$TMP/correction.log"; then
  cat "$TMP/bootstrap.log" "$TMP/correction.log" >&2
  echo 'FAIL: correction/bootstrap race did not serialize to BOOTSTRAP_READY gate' >&2; exit 27
fi
unchanged="$(psql_db "$DB" -Atqc "SELECT (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid)='$BASE_QTY2'::numeric AND NOT EXISTS(SELECT 1 FROM public.stock_movements WHERE manual_stock_correction_id='$CORRECTION2'::uuid) AND NOT EXISTS(SELECT 1 FROM public.stock_operation_requests WHERE request_id='$REQUEST2'::uuid)")"
[[ "$unchanged" == t ]] || { echo 'FAIL: bootstrap/correction gate left partial stock or request state' >&2; exit 28; }
echo 'PASS: correction waited behind cutover lock and BOOTSTRAP_READY blocked it before mutation'
