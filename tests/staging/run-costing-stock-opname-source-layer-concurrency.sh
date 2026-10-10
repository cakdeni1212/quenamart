#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker
expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000\n20260929230000\n20260929240000\n20260929250000\n20260929260000\n20260929270000\n20260929280000\n20260929290000\n20260929300000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
[[ "$actual_versions" == "$expected_versions" ]] || { printf 'REFUSED: exact guarded C3B frontier required\n' >&2; exit 250; }
receipt_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929290000_costing_purchase_receipt_acquisition_v1.sql" | awk '{print $1}')"
[[ "$receipt_sha" == '3bea5f2fe6bd83f49020c7bea5519bf847627299fff9e0505aa7a52f69455617' ]] || { printf 'REFUSED: immutable C3A SHA mismatch\n' >&2; exit 251; }

RUN_TAG="$(printf '%s' "$$-$(date +%s)" | tr -cd '[:alnum:]')"
CLONE_DB="quena_c3b_race_${RUN_TAG}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quena-c3b-race.XXXXXX")"
CREATED=0
ACTIVE_PIDS=()

psql_db() {
  local database="$1"; shift
  env -u PGHOST -u PGHOSTADDR -u PGPORT -u PGDATABASE -u PGUSER \
    -u PGSERVICE -u PGSERVICEFILE -u PGPASSWORD -u PGPASSFILE -u PGOPTIONS \
    -u DATABASE_URL -u SUPABASE_DB_URL -u SUPABASE_URL \
    -u SUPABASE_SERVICE_ROLE_KEY -u SUPABASE_ACCESS_TOKEN \
    PGPASSFILE="$STAGING_PGPASSFILE" PGCONNECT_TIMEOUT=5 PGAPPNAME="${PGAPPNAME:-quena_c3b_staging}" \
    psql -X -w -h "$STAGING_HOST" -p "$STAGING_PORT" -U "$STAGING_USER" \
      -d "$database" -v ON_ERROR_STOP=1 "$@"
}

cleanup_c3b_race() {
  for pid in ${ACTIVE_PIDS[*]-}; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in ${ACTIVE_PIDS[*]-}; do wait "$pid" 2>/dev/null || true; done
  if [[ "$CREATED" == 1 ]]; then
    psql_db postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$CLONE_DB' AND pid<>pg_backend_pid()" >/dev/null 2>&1 || true
    psql_db postgres -c "DROP DATABASE IF EXISTS \"$CLONE_DB\"" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$WORK_DIR"
}
trap 'cleanup_c3b_race; cleanup_local_pgpass' EXIT

psql_db postgres -c "CREATE DATABASE \"$CLONE_DB\" TEMPLATE quena_stock_staging" >/dev/null
CREATED=1
CLONE_OK="$(psql_db "$CLONE_DB" -Atqc "SELECT current_database()='$CLONE_DB'
  AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1') AND inet_server_port()=$STAGING_PORT
  AND current_setting('server_version_num')::integer/10000=15
  AND EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929300000')")"
[[ "$CLONE_OK" == t ]] || { printf 'REFUSED: disposable clone identity/schema guard failed\n' >&2; exit 252; }

OWNER='a0000000-0000-4000-8000-000000000001'
OUTLET="$(psql_db "$CLONE_DB" -Atqc "SELECT id FROM public.outlets WHERE code='QUENA-MART-1' AND is_active")"
PRODUCT="$(psql_db "$CLONE_DB" -Atqc "SELECT id FROM public.products WHERE sku='STG-FULL-A'")"
[[ "$OUTLET" =~ ^[0-9a-f-]{36}$ && "$PRODUCT" =~ ^[0-9a-f-]{36}$ ]] || { printf 'REFUSED: synthetic staging fixture missing\n' >&2; exit 253; }

cat >"$WORK_DIR/create-opname.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.apply_stock_operation_intent(public.issue_stock_operation_intent('CREATE_SESSION',
  jsonb_build_object('outlet_id','$OUTLET'::uuid,'scope_type','PARTIAL','product_ids',jsonb_build_array('$PRODUCT'::uuid))))->>'sessionId' AS session_id \\gset
SELECT revision_no AS revision_no FROM public.stock_opname_items WHERE session_id=:'session_id'::uuid AND product_id='$PRODUCT'::uuid \\gset
SELECT public.apply_stock_operation_intent(public.issue_stock_operation_intent('RECORD_COUNT',jsonb_build_object(
  'session_id',:'session_id'::uuid,'product_id','$PRODUCT'::uuid,
  'physical_quantity',(SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid),
  'expected_revision',:'revision_no'::integer)));
SELECT public.apply_stock_operation_intent(public.issue_stock_operation_intent('SUBMIT_REVIEW',jsonb_build_object('session_id',:'session_id'::uuid)));
SELECT public.issue_stock_operation_intent('POST_SESSION',jsonb_build_object('session_id',:'session_id'::uuid)) AS post_request \\gset
COMMIT;
\\echo REQUEST_ID=:'post_request'
SQL
OPNAME_SETUP_LOG="$(psql_db "$CLONE_DB" -Atq -f "$WORK_DIR/create-opname.sql" 2>&1 || true)"
OPNAME_REQUEST="$(printf '%s\n' "$OPNAME_SETUP_LOG" | sed -n "s/^REQUEST_ID=['\"]\{0,1\}\([0-9a-f-]*\)['\"]\{0,1\}$/\1/p")"
[[ "$OPNAME_REQUEST" =~ ^[0-9a-f-]{36}$ ]] || { printf 'FAIL: did not create synthetic pending opname request\n%s\n' "$OPNAME_SETUP_LOG" >&2; exit 254; }
BASE_QTY="$(psql_db "$CLONE_DB" -Atqc "SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid")"
REVERSAL_PRODUCT="$(psql_db "$CLONE_DB" -Atqc "SELECT id FROM public.products WHERE sku='STG-FULL-B'")"
[[ "$REVERSAL_PRODUCT" =~ ^[0-9a-f-]{36}$ ]] || { printf 'REFUSED: reversal staging fixture missing\n' >&2; exit 253; }
cat >"$WORK_DIR/create-reversal.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.apply_stock_operation_intent(public.issue_stock_operation_intent('CREATE_SESSION',
  jsonb_build_object('outlet_id','$OUTLET'::uuid,'scope_type','PARTIAL','product_ids',jsonb_build_array('$REVERSAL_PRODUCT'::uuid))))->>'sessionId' AS session_id \\gset
SELECT revision_no FROM public.stock_opname_items WHERE session_id=:'session_id'::uuid AND product_id='$REVERSAL_PRODUCT'::uuid \\gset
SELECT public.apply_stock_operation_intent(public.issue_stock_operation_intent('RECORD_COUNT',jsonb_build_object(
  'session_id',:'session_id'::uuid,'product_id','$REVERSAL_PRODUCT'::uuid,
  'physical_quantity',(SELECT effective_quantity+1 FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$REVERSAL_PRODUCT'::uuid),
  'expected_revision',:'revision_no'::integer)));
SELECT public.apply_stock_operation_intent(public.issue_stock_operation_intent('SUBMIT_REVIEW',jsonb_build_object('session_id',:'session_id'::uuid)));
SELECT public.issue_stock_operation_intent('POST_SESSION',jsonb_build_object('session_id',:'session_id'::uuid)) AS post_request \\gset
SELECT public.apply_stock_operation_intent(:'post_request'::uuid);
SELECT m.id AS movement_id FROM public.stock_movement_batches b JOIN public.stock_movements m ON m.batch_id=b.id
  WHERE b.operation_request_id=:'post_request'::uuid \\gset
SELECT public.issue_stock_operation_intent('REVERSE_MOVEMENT',jsonb_build_object(
  'movement_id',:'movement_id'::uuid,'reason','C3B concurrent reversal fixture')) AS reverse_request \\gset
COMMIT;
\\echo REVERSE_REQUEST=:'reverse_request'
SQL
REVERSAL_SETUP_LOG="$(psql_db "$CLONE_DB" -Atq -f "$WORK_DIR/create-reversal.sql" 2>&1 || true)"
REVERSAL_REQUEST="$(printf '%s\n' "$REVERSAL_SETUP_LOG" | sed -n "s/^REVERSE_REQUEST=['\"]\{0,1\}\([0-9a-f-]*\)['\"]\{0,1\}$/\1/p")"
[[ "$REVERSAL_REQUEST" =~ ^[0-9a-f-]{36}$ ]] || { printf 'FAIL: could not prepare pending reversal fixture\n%s\n' "$REVERSAL_SETUP_LOG" >&2; exit 254; }
REVERSAL_BASE_QTY="$(psql_db "$CLONE_DB" -Atqc "SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$REVERSAL_PRODUCT'::uuid")"

cat >"$WORK_DIR/bootstrap-holder.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT pg_advisory_xact_lock(hashtextextended('COST_BOOTSTRAP_OUTLET:'||'$OUTLET',73190411));
\\echo CUTOVER_LOCK_HELD
SELECT public.inventory_cost_bootstrap_outlet('$OUTLET'::uuid,gen_random_uuid());
SELECT pg_sleep(3);
COMMIT;
SQL
PGAPPNAME="c3b_${RUN_TAG}_bootstrap" psql_db "$CLONE_DB" -Atq -f "$WORK_DIR/bootstrap-holder.sql" >"$WORK_DIR/bootstrap.log" 2>&1 &
BOOT_PID=$!; ACTIVE_PIDS+=("$BOOT_PID")
for ((i=0; i<120; i++)); do grep -Fq CUTOVER_LOCK_HELD "$WORK_DIR/bootstrap.log" 2>/dev/null && break; sleep 0.05; done
grep -Fq CUTOVER_LOCK_HELD "$WORK_DIR/bootstrap.log" 2>/dev/null || { printf 'FAIL: bootstrap holder did not acquire cutover lock\n' >&2; cat "$WORK_DIR/bootstrap.log" >&2; exit 255; }

set +e
PGAPPNAME="c3b_${RUN_TAG}_opname_bootstrap" psql_db "$CLONE_DB" -Atqc "BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='$OWNER'; SELECT public.apply_stock_operation_intent('$OPNAME_REQUEST'::uuid); COMMIT" >"$WORK_DIR/opname-bootstrap.log" 2>&1 &
OPNAME_PID=$!; ACTIVE_PIDS+=("$OPNAME_PID")
WAIT_LOG="$(psql_db "$CLONE_DB" -q -c "DO \$wait\$ BEGIN FOR i IN 1..80 LOOP IF EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND NOT granted) THEN RAISE NOTICE 'ADVISORY_WAIT_OBSERVED'; RETURN; END IF; PERFORM pg_sleep(0.05); END LOOP; RAISE EXCEPTION 'ADVISORY_WAIT_NOT_OBSERVED'; END \$wait\$" 2>&1)"
WAIT_RC=$?
set -e
if [[ "$WAIT_RC" -ne 0 || "$WAIT_LOG" != *ADVISORY_WAIT_OBSERVED* ]]; then
  printf 'FAIL: opname apply was not observed waiting behind bootstrap\n' >&2
  cat "$WORK_DIR/bootstrap.log" "$WORK_DIR/opname-bootstrap.log" >&2
  exit 256
fi

set +e
PGAPPNAME="c3b_${RUN_TAG}_reversal_bootstrap" psql_db "$CLONE_DB" -Atqc "BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='$OWNER'; SELECT public.apply_stock_operation_intent('$REVERSAL_REQUEST'::uuid); COMMIT" >"$WORK_DIR/reversal-bootstrap.log" 2>&1 &
REVERSAL_PID=$!; ACTIVE_PIDS+=("$REVERSAL_PID")
WAIT_LOG="$(psql_db "$CLONE_DB" -q -c "DO \$wait\$ BEGIN FOR i IN 1..80 LOOP IF (SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND NOT granted)>=2 THEN RAISE NOTICE 'TWO_ADVISORY_WAITS_OBSERVED'; RETURN; END IF; PERFORM pg_sleep(0.05); END LOOP; RAISE EXCEPTION 'TWO_ADVISORY_WAITS_NOT_OBSERVED'; END \$wait\$" 2>&1)"
WAIT_RC=$?
set -e
if [[ "$WAIT_RC" -ne 0 || "$WAIT_LOG" != *TWO_ADVISORY_WAITS_OBSERVED* ]]; then
  printf 'FAIL: opname and reversal were not both observed waiting behind bootstrap\n' >&2
  cat "$WORK_DIR/bootstrap.log" "$WORK_DIR/opname-bootstrap.log" "$WORK_DIR/reversal-bootstrap.log" >&2
  exit 256
fi

set +e
wait "$BOOT_PID"; BOOT_RC=$?
wait "$OPNAME_PID"; OPNAME_RC=$?
wait "$REVERSAL_PID"; REVERSAL_RC=$?
set -e
ACTIVE_PIDS=()
if [[ "$BOOT_RC" -ne 0 || "$OPNAME_RC" -eq 0 || "$REVERSAL_RC" -eq 0 ]] \
  || ! grep -Fq 'Perubahan stok ditahan' "$WORK_DIR/opname-bootstrap.log" \
  || ! grep -Fq 'Perubahan stok ditahan' "$WORK_DIR/reversal-bootstrap.log"; then
  printf 'FAIL: bootstrap/opname overlap did not produce a bounded gate conflict without deadlock\n' >&2
  cat "$WORK_DIR/bootstrap.log" "$WORK_DIR/opname-bootstrap.log" "$WORK_DIR/reversal-bootstrap.log" >&2
  exit 257
fi
AFTER="$(psql_db "$CLONE_DB" -Atqc "SELECT
  (SELECT state='PENDING' FROM public.stock_operation_requests WHERE request_id='$OPNAME_REQUEST'::uuid)
  AND (SELECT effective_quantity='$BASE_QTY'::numeric FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid)
  AND (SELECT state='PENDING' FROM public.stock_operation_requests WHERE request_id='$REVERSAL_REQUEST'::uuid)
  AND (SELECT effective_quantity='$REVERSAL_BASE_QTY'::numeric FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$REVERSAL_PRODUCT'::uuid)
  AND NOT EXISTS(SELECT 1 FROM public.stock_movement_batches WHERE operation_request_id='$OPNAME_REQUEST'::uuid)
  AND (SELECT status='BOOTSTRAP_READY' FROM public.inventory_costing_outlet_authority WHERE outlet_id='$OUTLET'::uuid)")"
[[ "$AFTER" == t ]] || { printf 'FAIL: bootstrap/opname race left partial stock or terminal request state\n' >&2; exit 258; }
printf 'PASS: actual concurrent bootstrap/opname/reversal applies serialized on the outlet lock; gates left stock unchanged and requests pending\n'

# Second race: a receipt post owns the cutover lock while an already-counted
# opname tries to post. The receipt commits first; the stale opname must not
# apply an obsolete count or create any costing event.
# Test-only authority fixture: the authenticated actor claim satisfies the
# transition guard; postgres role is needed because clients cannot update this table.
psql_db "$CLONE_DB" -c "BEGIN; SET LOCAL ROLE postgres; SET LOCAL request.jwt.claim.sub='$OWNER'; UPDATE public.inventory_costing_outlet_authority SET status='WAC_ACTIVE',activated_by='$OWNER',activated_at=now() WHERE outlet_id='$OUTLET'::uuid; COMMIT" >/dev/null
psql_db "$CLONE_DB" -Atqc "SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid" >"$WORK_DIR/receipt-race-before"
RECEIPT_RACE_BEFORE="$(cat "$WORK_DIR/receipt-race-before")"
[[ "$RECEIPT_RACE_BEFORE" =~ ^[0-9]+([.]([0-9]+))?$ ]] || { printf 'FAIL: receipt-race baseline is unavailable\n' >&2; exit 259; }

# Reuse the pending, already-counted request from the bootstrap race. Bootstrap
# did not change stock quantity, and the active session correctly prevents a
# second overlapping opname for this product.
OPNAME_RACE_REQUEST="$OPNAME_REQUEST"

cat >"$WORK_DIR/create-receipt.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT public.purchase_supplier_upsert(NULL,'C3B concurrent receipt supplier',NULL,NULL,NULL,true) AS supplier \\gset
SELECT public.purchase_receipt_create_draft('$OUTLET'::uuid,:'supplier'::uuid,now(),'C3B receipt/opname concurrency') AS receipt \\gset
SELECT public.purchase_receipt_save_draft(:'receipt'::uuid,1,now(),NULL,jsonb_build_array(jsonb_build_object(
  'product_id','$PRODUCT'::uuid,'accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0)));
SELECT id AS item FROM public.purchase_receipt_items WHERE receipt_id=:'receipt'::uuid AND product_id='$PRODUCT'::uuid \\gset
SELECT public.purchase_receipt_acquisition_estimate_save(:'receipt'::uuid,:'item'::uuid,2,0,
  'MANAGER_ESTIMATE',1000,NULL,'C3B concurrent receipt fixture');
SELECT public.issue_purchase_receipt_post_intent(:'receipt'::uuid) AS request \\gset
COMMIT;
\\echo RECEIPT_ID=:'receipt'
\\echo RECEIPT_REQUEST=:'request'
SQL
RECEIPT_SETUP_LOG="$(psql_db "$CLONE_DB" -Atq -f "$WORK_DIR/create-receipt.sql" 2>&1 || true)"
RECEIPT_ID="$(printf '%s\n' "$RECEIPT_SETUP_LOG" | sed -n "s/^RECEIPT_ID=['\"]\{0,1\}\([0-9a-f-]*\)['\"]\{0,1\}$/\1/p")"
RECEIPT_REQUEST="$(printf '%s\n' "$RECEIPT_SETUP_LOG" | sed -n "s/^RECEIPT_REQUEST=['\"]\{0,1\}\([0-9a-f-]*\)['\"]\{0,1\}$/\1/p")"
if [[ ! "$RECEIPT_ID" =~ ^[0-9a-f-]{36}$ || ! "$RECEIPT_REQUEST" =~ ^[0-9a-f-]{36}$ ]]; then
  printf 'FAIL: concurrent receipt fixture setup failed\n%s\n' "$RECEIPT_SETUP_LOG" >&2; exit 262
fi

cat >"$WORK_DIR/receipt-holder.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$OWNER';
SELECT pg_advisory_xact_lock(hashtextextended('COST_BOOTSTRAP_OUTLET:'||'$OUTLET',73190411));
\\echo RECEIPT_LOCK_HELD
SELECT public.apply_purchase_receipt_post_intent('$RECEIPT_REQUEST'::uuid);
SELECT pg_sleep(3);
COMMIT;
SQL
PGAPPNAME="c3b_${RUN_TAG}_receipt" psql_db "$CLONE_DB" -Atq -f "$WORK_DIR/receipt-holder.sql" >"$WORK_DIR/receipt-holder.log" 2>&1 &
RECEIPT_PID=$!; ACTIVE_PIDS+=("$RECEIPT_PID")
for ((i=0; i<120; i++)); do grep -Fq RECEIPT_LOCK_HELD "$WORK_DIR/receipt-holder.log" 2>/dev/null && break; sleep 0.05; done
grep -Fq RECEIPT_LOCK_HELD "$WORK_DIR/receipt-holder.log" 2>/dev/null || { printf 'FAIL: receipt holder did not acquire cutover lock\n' >&2; cat "$WORK_DIR/receipt-holder.log" >&2; exit 263; }
PGAPPNAME="c3b_${RUN_TAG}_opname_receipt" psql_db "$CLONE_DB" -Atqc "BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='$OWNER'; SELECT public.apply_stock_operation_intent('$OPNAME_RACE_REQUEST'::uuid); COMMIT" >"$WORK_DIR/opname-receipt.log" 2>&1 &
OPNAME_RECEIPT_PID=$!; ACTIVE_PIDS+=("$OPNAME_RECEIPT_PID")
set +e
WAIT_LOG="$(psql_db "$CLONE_DB" -q -c "DO \$wait\$ BEGIN FOR i IN 1..80 LOOP IF EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND NOT granted) THEN RAISE NOTICE 'ADVISORY_WAIT_OBSERVED'; RETURN; END IF; PERFORM pg_sleep(0.05); END LOOP; RAISE EXCEPTION 'ADVISORY_WAIT_NOT_OBSERVED'; END \$wait\$" 2>&1)"
WAIT_RC=$?
set -e
if [[ "$WAIT_RC" -ne 0 || "$WAIT_LOG" != *ADVISORY_WAIT_OBSERVED* ]]; then
  printf 'FAIL: opname apply was not observed waiting behind receipt post\n' >&2
  cat "$WORK_DIR/receipt-holder.log" "$WORK_DIR/opname-receipt.log" >&2; exit 264
fi
set +e
wait "$RECEIPT_PID"; RECEIPT_RC=$?
wait "$OPNAME_RECEIPT_PID"; OPNAME_RECEIPT_RC=$?
set -e
ACTIVE_PIDS=()
if [[ "$RECEIPT_RC" -ne 0 || "$OPNAME_RECEIPT_RC" -ne 0 ]] || ! grep -Fq 'STALE_BASELINE' "$WORK_DIR/opname-receipt.log"; then
  printf 'FAIL: receipt/opname race did not resolve as receipt-post plus stale opname\n' >&2
  cat "$WORK_DIR/receipt-holder.log" "$WORK_DIR/opname-receipt.log" >&2; exit 265
fi
ASSERTION="$(psql_db "$CLONE_DB" -Atqc "SELECT
  (SELECT status='POSTED' FROM public.purchase_receipts WHERE id='$RECEIPT_ID'::uuid)
  AND (SELECT state='STALE' FROM public.stock_operation_requests WHERE request_id='$OPNAME_RACE_REQUEST'::uuid)
  AND (SELECT effective_quantity='$RECEIPT_RACE_BEFORE'::numeric+1 FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid)
  AND (SELECT physical_quantity=effective_quantity FROM public.inventory_cost_projections cp JOIN public.stock_balance_projection sp USING(outlet_id,product_id) WHERE cp.outlet_id='$OUTLET'::uuid AND cp.product_id='$PRODUCT'::uuid)
  AND (SELECT cp.valued_quantity=coalesce(sum(b.remaining_valued_quantity),0)
      AND cp.unvalued_quantity=coalesce(sum(b.remaining_unvalued_quantity),0)
      AND cp.provisional_quantity=coalesce(sum(b.remaining_provisional_quantity),0)
      AND cp.physical_quantity=coalesce(sum(b.remaining_physical_quantity),0)
      FROM public.inventory_cost_projections cp LEFT JOIN public.inventory_cost_source_layer_balances b
        ON b.outlet_id=cp.outlet_id AND b.product_id=cp.product_id
      WHERE cp.outlet_id='$OUTLET'::uuid AND cp.product_id='$PRODUCT'::uuid GROUP BY cp.valued_quantity,cp.unvalued_quantity,cp.provisional_quantity,cp.physical_quantity)
  AND NOT EXISTS(SELECT 1 FROM public.inventory_cost_source_layer_balances WHERE outlet_id='$OUTLET'::uuid
      AND product_id='$PRODUCT'::uuid AND (remaining_valued_quantity<0 OR remaining_unvalued_quantity<0
        OR remaining_provisional_quantity<0 OR remaining_provisional_quantity>remaining_valued_quantity))
  AND (SELECT valued_quantity=0 AND current_wac IS NULL AND (inventory_value IS NULL OR inventory_value=0)
      OR valued_quantity>0 AND current_wac=round(inventory_value/valued_quantity,8)
      FROM public.inventory_cost_projections WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid)
  AND (SELECT count(*)=1 FROM public.inventory_cost_events WHERE receipt_id='$RECEIPT_ID'::uuid AND event_type='PURCHASE_RECEIPT')
  AND (SELECT count(*)=1 FROM public.inventory_cost_source_layers l JOIN public.inventory_cost_events e ON e.id=l.opening_cost_event_id
      WHERE e.receipt_id='$RECEIPT_ID'::uuid AND e.product_id='$PRODUCT'::uuid)
  AND NOT EXISTS(SELECT 1 FROM public.inventory_cost_events WHERE operation_request_id='$OPNAME_RACE_REQUEST'::uuid AND event_type='OPNAME_ADJUSTMENT')")"
[[ "$ASSERTION" == t ]] || { printf 'FAIL: concurrent receipt/opname state is not atomic/consistent\n' >&2; exit 266; }
printf 'PASS: actual concurrent receipt/opname apply serialized without deadlock; receipt costed once and stale opname made no stock/cost change\n'
