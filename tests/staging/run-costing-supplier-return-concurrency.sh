#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST=localhost PORT=55432
TAG="$(printf '%s' "$$-$(date +%s)" | tr -cd '[:alnum:]')"
DB="quena_c3d_race_${TAG}" TMP="$(mktemp -d "${TMPDIR:-/tmp}/quena-c3d-race.XXXXXX")"
CREATED=0 PIDS=()
OWNER=a0000000-0000-4000-8000-000000000001
trap 'for p in "${PIDS[@]-}"; do kill -TERM "$p" 2>/dev/null || true; done; for p in "${PIDS[@]-}"; do wait "$p" 2>/dev/null || true; done; if [[ "$CREATED" == 1 ]]; then psql_db postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid<>pg_backend_pid()" >/dev/null 2>&1 || true; psql_db postgres -c "DROP DATABASE IF EXISTS \"$DB\"" >/dev/null 2>&1 || true; fi; rm -rf -- "$TMP"' EXIT
umask 077

psql_db() {
  local db="$1"; shift
  env -u PGHOST -u PGHOSTADDR -u PGPORT -u PGDATABASE -u PGUSER -u PGSERVICE -u PGSERVICEFILE \
    -u PGPASSWORD -u PGPASSFILE -u PGOPTIONS -u DATABASE_URL -u SUPABASE_DB_URL -u SUPABASE_URL \
    -u SUPABASE_SERVICE_ROLE_KEY -u SUPABASE_ACCESS_TOKEN PGCONNECT_TIMEOUT=5 PGAPPNAME=quena_c3d_race \
    psql -X -w -h "$HOST" -p "$PORT" -U postgres -d "$db" -v ON_ERROR_STOP=1 "$@"
}
new_uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
as_owner() { psql_db "$DB" -Atqc "SET ROLE authenticated; SET request.jwt.claim.sub='$OWNER'; $1"; }
create_return() {
  local product="$1" qty="$2" reason="$3" result
  result="$(as_owner "SELECT public.create_supplier_return('$OUTLET'::uuid,'$SUPPLIER'::uuid,'DAMAGED','$reason',NULL,jsonb_build_array(jsonb_build_object('product_id','$product'::uuid,'quantity',$qty)))")"
  python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$result"
}
assert_invariants() {
  local ok
  ok="$(psql_db "$DB" -Atqc "SELECT NOT EXISTS(SELECT 1 FROM public.inventory_cost_projections c JOIN public.stock_balance_projection s USING(outlet_id,product_id) WHERE c.physical_quantity IS DISTINCT FROM s.effective_quantity) AND NOT EXISTS(SELECT 1 FROM public.inventory_cost_projections c WHERE c.valued_quantity<>(SELECT coalesce(sum(b.remaining_valued_quantity),0) FROM public.inventory_cost_source_layer_balances b WHERE b.outlet_id=c.outlet_id AND b.product_id=c.product_id) OR c.unvalued_quantity<>(SELECT coalesce(sum(b.remaining_unvalued_quantity),0) FROM public.inventory_cost_source_layer_balances b WHERE b.outlet_id=c.outlet_id AND b.product_id=c.product_id) OR c.provisional_quantity<>(SELECT coalesce(sum(b.remaining_provisional_quantity),0) FROM public.inventory_cost_source_layer_balances b WHERE b.outlet_id=c.outlet_id AND b.product_id=c.product_id)) AND NOT EXISTS(SELECT 1 FROM public.inventory_cost_source_layer_balances WHERE remaining_valued_quantity<0 OR remaining_unvalued_quantity<0 OR remaining_provisional_quantity<0 OR remaining_provisional_quantity>remaining_valued_quantity)" )"
  [[ "$ok" == t ]] || { echo 'FAIL: C3D race left stock/cost/source-layer projection drift' >&2; exit 40; }
}

for pair in \
  '20260929290000_costing_purchase_receipt_acquisition_v1.sql:3bea5f2fe6bd83f49020c7bea5519bf847627299fff9e0505aa7a52f69455617' \
  '20260929300000_costing_stock_opname_source_layers_v1.sql:69cec4c022992ee124179fcb140869fd3dae7a19b47ebb7c5f7cf0f10fcddcfc' \
  '20260929310000_costing_manual_stock_correction_v1.sql:a9be97450943662e49276ad54ce0d47578a1e135def94b16fd7a6e7c1ba36db3'; do
  f="${pair%%:*}" expected="${pair##*:}"
  [[ "$(shasum -a 256 "$ROOT/supabase/migrations/$f" | awk '{print $1}')" == "$expected" ]] || { echo "REFUSED: prerequisite hash mismatch: $f" >&2; exit 20; }
done
base="$(psql_db quena_stock_staging -Atqc "SELECT current_database()='quena_stock_staging' AND inet_server_port()=$PORT AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1') AND current_setting('server_version_num')::integer/10000=15 AND (SELECT version='20260929300000' FROM quena_staging.applied_migrations ORDER BY ordinal DESC LIMIT 1) AND NOT EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version>'20260929300000')")"
[[ "$base" == t ]] || { echo 'REFUSED: base is not guarded isolated C3B staging through 300000' >&2; exit 21; }
psql_db postgres -c "CREATE DATABASE \"$DB\" TEMPLATE quena_stock_staging" >/dev/null; CREATED=1
psql_db "$DB" -f "$ROOT/supabase/migrations/20260929310000_costing_manual_stock_correction_v1.sql" >/dev/null
psql_db "$DB" -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename) VALUES(24,'20260929310000','20260929310000_costing_manual_stock_correction_v1.sql')" >/dev/null
psql_db "$DB" -f "$ROOT/supabase/migrations/20260929320000_costing_supplier_return_v1.sql" >/dev/null
psql_db "$DB" -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename) VALUES(25,'20260929320000','20260929320000_costing_supplier_return_v1.sql')" >/dev/null
guard="$(psql_db "$DB" -Atqc "SELECT current_database()='$DB' AND inet_server_port()=$PORT AND to_regprocedure('public.post_supplier_return(uuid,uuid)') IS NOT NULL AND EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929320000')")"
[[ "$guard" == t ]] || { echo 'REFUSED: disposable C3D race clone guard failed' >&2; exit 22; }
OUTLET="$(psql_db "$DB" -Atqc "SELECT id FROM public.outlets WHERE code='QUENA-MART-1' AND is_active")"
PRODUCT="$(psql_db "$DB" -Atqc "SELECT id FROM public.products WHERE sku='STG-BASE20'")"
PRODUCT2="$(psql_db "$DB" -Atqc "SELECT id FROM public.products WHERE sku='STG-FULL-B'")"
SUPPLIER="$(as_owner "SELECT public.purchase_supplier_upsert(NULL,'C3D concurrent supplier',NULL,NULL,NULL,true)")"

# Establish BOOTSTRAP_READY first while a return post waits on the same cutover key.
psql_db "$DB" -c "INSERT INTO public.product_field_audit_reviews(product_id,outlet_id,field_key,status,source_import_row_id,reviewer_id,evidence_notes,request_id) SELECT '$PRODUCT'::uuid,'$OUTLET'::uuid,'hpp','SUDAH_DIVERIFIKASI',source_import_row_id,'$OWNER'::uuid,'C3D concurrent bootstrap',gen_random_uuid() FROM public.product_costs WHERE product_id='$PRODUCT'::uuid AND outlet_id='$OUTLET'::uuid" >/dev/null
REQUEST_RETURN="$(create_return "$PRODUCT" 0.001 'Cutover serialization return')"
BOOT_REQ="$(new_uuid)" RETURN_REQ="$(new_uuid)"
cat >"$TMP/bootstrap-holder.sql" <<SQL
BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.inventory_cost_bootstrap_outlet('$OUTLET'::uuid,'$BOOT_REQ'::uuid);
SELECT pg_sleep(1); COMMIT;
SQL
cat >"$TMP/return-bootstrap-waiter.sql" <<SQL
BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.post_supplier_return('$REQUEST_RETURN'::uuid,'$RETURN_REQ'::uuid); COMMIT;
SQL
psql_db "$DB" -Atq -f "$TMP/bootstrap-holder.sql" >"$TMP/bootstrap.log" 2>&1 & bp=$!; PIDS+=("$bp")
sleep 0.15
psql_db "$DB" -Atq -f "$TMP/return-bootstrap-waiter.sql" >"$TMP/return-bootstrap.log" 2>&1 & rp=$!; PIDS+=("$rp")
wait "$bp"; brc=$?; set +e; wait "$rp"; rrc=$?; set -e; PIDS=()
[[ "$brc" == 0 && "$rrc" != 0 ]] || { cat "$TMP/bootstrap.log" "$TMP/return-bootstrap.log" >&2; echo 'FAIL: bootstrap/return serialization outcome unexpected' >&2; exit 23; }
bootstrap_state="$(psql_db "$DB" -Atqc "SELECT (SELECT status='BOOTSTRAP_READY' FROM public.inventory_costing_outlet_authority WHERE outlet_id='$OUTLET'::uuid) AND (SELECT status='DRAFT' FROM public.supplier_returns WHERE id='$REQUEST_RETURN'::uuid) AND NOT EXISTS(SELECT 1 FROM public.stock_movements WHERE supplier_return_id='$REQUEST_RETURN'::uuid)")"
[[ "$bootstrap_state" == t ]] || { echo 'FAIL: return mutated stock after BOOTSTRAP_READY won the cutover lock' >&2; exit 24; }
echo 'PASS: bootstrap/cutover serialized before supplier return; return stayed draft with no stock mutation'
psql_db "$DB" -c "SET request.jwt.claim.sub='$OWNER'; UPDATE public.inventory_costing_outlet_authority SET status='WAC_ACTIVE',activated_by='$OWNER'::uuid,activated_at=now() WHERE outlet_id='$OUTLET'::uuid" >/dev/null

# Duplicate same request, two concurrent workers: one post and one exact replay.
RETURN_DUP="$(create_return "$PRODUCT" 0.001 'Concurrent duplicate request')"; DUP_REQ="$(new_uuid)"
cat >"$TMP/duplicate.sql" <<SQL
BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.post_supplier_return('$RETURN_DUP'::uuid,'$DUP_REQ'::uuid); COMMIT;
SQL
psql_db "$DB" -Atq -f "$TMP/duplicate.sql" >"$TMP/dup1.log" 2>&1 & d1=$!; PIDS+=("$d1")
psql_db "$DB" -Atq -f "$TMP/duplicate.sql" >"$TMP/dup2.log" 2>&1 & d2=$!; PIDS+=("$d2")
wait "$d1"; d1rc=$?; wait "$d2"; d2rc=$?; PIDS=()
[[ "$d1rc" == 0 && "$d2rc" == 0 ]] || { cat "$TMP/dup1.log" "$TMP/dup2.log" >&2; echo 'FAIL: concurrent duplicate same-request post' >&2; exit 25; }
[[ "$(psql_db "$DB" -Atqc "SELECT count(*)=1 FROM public.stock_movements WHERE supplier_return_id='$RETURN_DUP'::uuid")" == t ]] || { echo 'FAIL: duplicate request created multiple movements' >&2; exit 26; }
assert_invariants
echo 'PASS: concurrent duplicate supplier-return request replayed once'

# Return post versus WAC_ACTIVE purchase receipt post; both share the cutover lock.
RETURN_RECEIPT="$(create_return "$PRODUCT" 0.001 'Concurrent receipt post')"
RECEIPT_DATA="$(psql_db "$DB" -Atq <<SQL
BEGIN; SET ROLE authenticated; SET request.jwt.claim.sub='$OWNER';
SELECT public.purchase_receipt_create_draft('$OUTLET'::uuid,'$SUPPLIER'::uuid,now(),'C3D return/receipt race') AS rid \\gset
SELECT public.purchase_receipt_save_draft(:'rid'::uuid,1,now(),NULL,jsonb_build_array(jsonb_build_object('product_id','$PRODUCT'::uuid,'accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0)));
SELECT id AS iid FROM public.purchase_receipt_items WHERE receipt_id=:'rid'::uuid AND product_id='$PRODUCT'::uuid \\gset
SELECT public.purchase_receipt_acquisition_estimate_save(:'rid'::uuid,:'iid'::uuid,2,0,'MANAGER_ESTIMATE',9000,NULL,'concurrent test');
SELECT public.issue_purchase_receipt_post_intent(:'rid'::uuid) AS req \\gset
COMMIT;
\\echo R=:'rid' Q=:'req'
SQL
)"
RECEIPT_ID="$(printf '%s\n' "$RECEIPT_DATA" | sed -n "s/^R=['\"]\{0,1\}\([0-9a-f-]*\)['\"]\{0,1\} Q=.*/\1/p")"
RECEIPT_REQ="$(printf '%s\n' "$RECEIPT_DATA" | sed -n "s/^R=.* Q=['\"]\{0,1\}\([0-9a-f-]*\)['\"]\{0,1\}$/\1/p")"
[[ "$RECEIPT_ID" =~ ^[0-9a-f-]{36}$ && "$RECEIPT_REQ" =~ ^[0-9a-f-]{36}$ ]] || { echo "FAIL: receipt race fixture failed: $RECEIPT_DATA" >&2; exit 27; }
RETURN_REQ="$(new_uuid)"
cat >"$TMP/return-holder.sql" <<SQL
BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.post_supplier_return('$RETURN_RECEIPT'::uuid,'$RETURN_REQ'::uuid); SELECT pg_sleep(1); COMMIT;
SQL
cat >"$TMP/receipt-waiter.sql" <<SQL
BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.apply_purchase_receipt_post_intent('$RECEIPT_REQ'::uuid); COMMIT;
SQL
psql_db "$DB" -Atq -f "$TMP/return-holder.sql" >"$TMP/return-holder.log" 2>&1 & h=$!; PIDS+=("$h")
sleep 0.15
psql_db "$DB" -Atq -f "$TMP/receipt-waiter.sql" >"$TMP/receipt-waiter.log" 2>&1 & w=$!; PIDS+=("$w")
wait "$h"; hrc=$?; wait "$w"; wrc=$?; PIDS=()
[[ "$hrc" == 0 && "$wrc" == 0 ]] || { cat "$TMP/return-holder.log" "$TMP/receipt-waiter.log" >&2; echo 'FAIL: return/receipt race' >&2; exit 28; }
assert_invariants
echo 'PASS: supplier return and purchase receipt postings serialized without split stock/cost state'

# Return versus manual correction uses a separate product to keep both outcomes valid.
RETURN_CORR="$(create_return "$PRODUCT2" 0.001 'Concurrent correction')"
CORR_JSON="$(as_owner "SELECT public.create_manual_stock_correction('$OUTLET'::uuid,'FOUND','C3D race manual correction',jsonb_build_array(jsonb_build_object('product_id','$PRODUCT2'::uuid,'quantity_delta',0.001)))")"
CORR_ID="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["id"])' "$CORR_JSON")" CORR_REQ="$(new_uuid)" RETURN_REQ="$(new_uuid)"
cat >"$TMP/return-correction-holder.sql" <<SQL
BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.post_supplier_return('$RETURN_CORR'::uuid,'$RETURN_REQ'::uuid); SELECT pg_sleep(1); COMMIT;
SQL
cat >"$TMP/correction-waiter.sql" <<SQL
BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.post_manual_stock_correction('$CORR_ID'::uuid,'$CORR_REQ'::uuid); COMMIT;
SQL
psql_db "$DB" -Atq -f "$TMP/return-correction-holder.sql" >"$TMP/return-correction.log" 2>&1 & h=$!; PIDS+=("$h")
sleep 0.15
psql_db "$DB" -Atq -f "$TMP/correction-waiter.sql" >"$TMP/correction-waiter.log" 2>&1 & w=$!; PIDS+=("$w")
wait "$h"; hrc=$?; wait "$w"; wrc=$?; PIDS=()
[[ "$hrc" == 0 && "$wrc" == 0 ]] || { cat "$TMP/return-correction.log" "$TMP/correction-waiter.log" >&2; echo 'FAIL: return/correction race' >&2; exit 29; }
assert_invariants
echo 'PASS: supplier return and manual correction serialized with costing invariants intact'

# Return versus opname post, using a separate product so both approved facts can commit.
SESSION_DATA="$(as_owner "SELECT public.apply_stock_operation_intent(public.issue_stock_operation_intent('CREATE_SESSION',jsonb_build_object('outlet_id','$OUTLET'::uuid,'scope_type','PARTIAL','product_ids',jsonb_build_array('$PRODUCT2'::uuid))))")"
SESSION_ID="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["sessionId"])' "$SESSION_DATA")"
REVISION="$(psql_db "$DB" -Atqc "SELECT revision_no FROM public.stock_opname_items WHERE session_id='$SESSION_ID'::uuid AND product_id='$PRODUCT2'::uuid")"
COUNT_QTY="$(psql_db "$DB" -Atqc "SELECT effective_quantity-0.001 FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT2'::uuid")"
as_owner "SELECT public.apply_stock_operation_intent(public.issue_stock_operation_intent('RECORD_COUNT',jsonb_build_object('session_id','$SESSION_ID'::uuid,'product_id','$PRODUCT2'::uuid,'physical_quantity',$COUNT_QTY,'expected_revision',$REVISION::integer)))" >/dev/null
as_owner "SELECT public.apply_stock_operation_intent(public.issue_stock_operation_intent('SUBMIT_REVIEW',jsonb_build_object('session_id','$SESSION_ID'::uuid)))" >/dev/null
OPNAME_REQ="$(as_owner "SELECT public.issue_stock_operation_intent('POST_SESSION',jsonb_build_object('session_id','$SESSION_ID'::uuid))")"
RETURN_OPNAME="$(create_return "$PRODUCT" 0.001 'Concurrent opname post')"; RETURN_REQ="$(new_uuid)"
cat >"$TMP/return-opname-holder.sql" <<SQL
BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.post_supplier_return('$RETURN_OPNAME'::uuid,'$RETURN_REQ'::uuid); SELECT pg_sleep(1); COMMIT;
SQL
cat >"$TMP/opname-waiter.sql" <<SQL
BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.apply_stock_operation_intent('$OPNAME_REQ'::uuid); COMMIT;
SQL
psql_db "$DB" -Atq -f "$TMP/return-opname-holder.sql" >"$TMP/return-opname.log" 2>&1 & h=$!; PIDS+=("$h")
sleep 0.15
psql_db "$DB" -Atq -f "$TMP/opname-waiter.sql" >"$TMP/opname-waiter.log" 2>&1 & w=$!; PIDS+=("$w")
wait "$h"; hrc=$?; wait "$w"; wrc=$?; PIDS=()
[[ "$hrc" == 0 && "$wrc" == 0 ]] || { cat "$TMP/return-opname.log" "$TMP/opname-waiter.log" >&2; echo 'FAIL: return/opname race' >&2; exit 30; }
assert_invariants
echo 'PASS: supplier return and opname posts serialized without deadlock or stock/cost drift'

# Reverse a previously posted return while another product's supplier return posts.
REV_RETURN="$(create_return "$PRODUCT2" 0.001 'Concurrent reversal source')"; REV_RETURN_REQ="$(new_uuid)"
as_owner "SELECT public.post_supplier_return('$REV_RETURN'::uuid,'$REV_RETURN_REQ'::uuid)" >/dev/null
REV_MOVEMENT="$(psql_db "$DB" -Atqc "SELECT m.id FROM public.stock_movement_batches b JOIN public.stock_movements m ON m.batch_id=b.id WHERE b.operation_request_id='$REV_RETURN_REQ'::uuid")"
REV_REQ="$(as_owner "SELECT public.issue_stock_operation_intent('REVERSE_MOVEMENT',jsonb_build_object('movement_id','$REV_MOVEMENT'::uuid,'reason','C3D concurrent reversal'))")"
RETURN_REV="$(create_return "$PRODUCT" 0.001 'Concurrent return with reversal')"; RETURN_REQ="$(new_uuid)"
cat >"$TMP/reversal-holder.sql" <<SQL
BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.apply_stock_operation_intent('$REV_REQ'::uuid); SELECT pg_sleep(1); COMMIT;
SQL
cat >"$TMP/return-reversal-waiter.sql" <<SQL
BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.post_supplier_return('$RETURN_REV'::uuid,'$RETURN_REQ'::uuid); COMMIT;
SQL
psql_db "$DB" -Atq -f "$TMP/reversal-holder.sql" >"$TMP/reversal-holder.log" 2>&1 & h=$!; PIDS+=("$h")
sleep 0.15
psql_db "$DB" -Atq -f "$TMP/return-reversal-waiter.sql" >"$TMP/return-reversal.log" 2>&1 & w=$!; PIDS+=("$w")
wait "$h"; hrc=$?; wait "$w"; wrc=$?; PIDS=()
[[ "$hrc" == 0 && "$wrc" == 0 ]] || { cat "$TMP/reversal-holder.log" "$TMP/return-reversal.log" >&2; echo 'FAIL: return/reversal race' >&2; exit 31; }
assert_invariants
echo 'PASS: supplier return and standard movement reversal serialized with exact layer/cost invariants'

echo 'PASS: C3D expanded concurrency harness; disposable clone only'
