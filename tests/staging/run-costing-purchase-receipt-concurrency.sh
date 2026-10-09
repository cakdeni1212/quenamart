#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker
versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
[[ "$versions" == *$'20260929290000' ]] || { printf 'REFUSED: C3A frontier is not applied\n' >&2; exit 230; }
expected_sha='3bea5f2fe6bd83f49020c7bea5519bf847627299fff9e0505aa7a52f69455617'
actual_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929290000_costing_purchase_receipt_acquisition_v1.sql" | awk '{print $1}')"
[[ "$actual_sha" == "$expected_sha" ]] || { printf 'REFUSED: C3A checksum mismatch; no clone created\n' >&2; exit 231; }

RUN_TAG="$(printf '%s' "$$-$(date +%s)" | tr -cd '[:alnum:]')"
CLONE_DB="quena_c3a_race_${RUN_TAG}"
[[ "$CLONE_DB" =~ ^[a-z0-9_]{1,63}$ ]] || exit 232
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quena-c3a-race.XXXXXX")"
CREATED=0
ACTIVE_PIDS=()

psql_db() {
  local database="$1"; shift
  env -u PGHOST -u PGHOSTADDR -u PGPORT -u PGDATABASE -u PGUSER \
    -u PGSERVICE -u PGSERVICEFILE -u PGPASSWORD -u PGPASSFILE -u PGOPTIONS \
    -u DATABASE_URL -u SUPABASE_DB_URL -u SUPABASE_URL \
    -u SUPABASE_SERVICE_ROLE_KEY -u SUPABASE_ACCESS_TOKEN \
    PGPASSFILE="$STAGING_PGPASSFILE" PGCONNECT_TIMEOUT=5 PGAPPNAME="${PGAPPNAME:-quena_c3a_staging}" \
    psql -X -w -h "$STAGING_HOST" -p "$STAGING_PORT" -U "$STAGING_USER" \
      -d "$database" -v ON_ERROR_STOP=1 "$@"
}

cleanup_race() {
  for pid in ${ACTIVE_PIDS[*]-}; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in ${ACTIVE_PIDS[*]-}; do wait "$pid" 2>/dev/null || true; done
  ACTIVE_PIDS=()
  if [[ "$CREATED" == 1 ]]; then
    psql_db postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$CLONE_DB' AND pid<>pg_backend_pid()" >/dev/null 2>&1 || true
    psql_db postgres -c "DROP DATABASE IF EXISTS \"$CLONE_DB\"" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$WORK_DIR"
}
trap 'cleanup_race; cleanup_local_pgpass' EXIT

psql_db postgres -c "CREATE DATABASE \"$CLONE_DB\" TEMPLATE quena_stock_staging" >/dev/null
CREATED=1
CLONE_GUARD="$(psql_db "$CLONE_DB" -Atqc "SELECT current_database()='$CLONE_DB'
  AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1') AND inet_server_port()=5432
  AND current_setting('server_version_num')::integer/10000=15 AND current_setting('server_encoding')='UTF8'
  AND EXISTS(SELECT 1 FROM quena_staging.environment WHERE name='quena_stock_staging')
  AND EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929290000')")"
[[ "$CLONE_GUARD" == t ]] || { printf 'REFUSED: disposable database is not an exact clone of guarded C3A staging\n' >&2; exit 232; }

OUTLET="$(psql_db "$CLONE_DB" -Atqc "SELECT id FROM public.outlets WHERE code='QUENA-MART-1' AND is_active")"
PRODUCT="$(psql_db "$CLONE_DB" -Atqc "SELECT id FROM public.products WHERE sku='STG-FULL-A'")"
for value in "$OUTLET" "$PRODUCT"; do
  [[ "$value" =~ ^[0-9a-f-]{36}$ ]] || { printf 'REFUSED: required synthetic staging seed is missing\n' >&2; exit 233; }
done
OWNER='a0000000-0000-4000-8000-000000000001'
GUDANG='a0000000-0000-4000-8000-000000000003'

auth_sql() {
  local database="$1" actor="$2" sql="$3"
  psql_db "$database" -Atqc "BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='$actor'; $sql; COMMIT"
}

SUPPLIER="$(auth_sql "$CLONE_DB" "$OWNER" "SELECT public.purchase_supplier_upsert(NULL,'C3A concurrency supplier',NULL,NULL,NULL,true)")"
[[ "$SUPPLIER" =~ ^[0-9a-f-]{36}$ ]] || { printf 'REFUSED: could not create isolated synthetic supplier\n' >&2; exit 233; }

# Bootstrap and activation are deliberately confined to the throwaway cloned database.
auth_sql "$CLONE_DB" "$OWNER" "SELECT public.inventory_cost_bootstrap_outlet('$OUTLET'::uuid,gen_random_uuid())" >/dev/null
psql_db "$CLONE_DB" -c "SELECT set_config('request.jwt.claim.sub','$OWNER',false); UPDATE public.inventory_costing_outlet_authority SET status='WAC_ACTIVE',activated_by='$OWNER',activated_at=now() WHERE outlet_id='$OUTLET'::uuid" >/dev/null

RECEIPT="$(auth_sql "$CLONE_DB" "$GUDANG" "SELECT public.purchase_receipt_create_draft('$OUTLET'::uuid,'$SUPPLIER'::uuid,now(),'C3A issue/apply lock race')")"
auth_sql "$CLONE_DB" "$GUDANG" "SELECT public.purchase_receipt_save_draft('$RECEIPT'::uuid,1,now(),NULL,jsonb_build_array(jsonb_build_object('product_id','$PRODUCT','accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0)))" >/dev/null
REQUEST="$(auth_sql "$CLONE_DB" "$GUDANG" "SELECT public.issue_purchase_receipt_post_intent('$RECEIPT'::uuid)")"
BEFORE="$(psql_db "$CLONE_DB" -Atqc "SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid")"

APP_A="c3a_${RUN_TAG}_issue"
APP_B="c3a_${RUN_TAG}_apply"
cat >"$WORK_DIR/issue.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='$GUDANG';
SELECT pg_advisory_xact_lock(hashtextextended('COST_BOOTSTRAP_OUTLET:'||'$OUTLET',73190411));
\\echo CUTOVER_LOCK_HELD
SELECT pg_sleep(3);
SELECT public.issue_purchase_receipt_post_intent('$RECEIPT'::uuid);
COMMIT;
SQL
PGAPPNAME="$APP_A" psql_db "$CLONE_DB" -Atq -f "$WORK_DIR/issue.sql" >"$WORK_DIR/issue.log" 2>&1 &
PID_A=$!; ACTIVE_PIDS+=("$PID_A")
for ((i=0; i<120; i++)); do grep -Fq CUTOVER_LOCK_HELD "$WORK_DIR/issue.log" 2>/dev/null && break; sleep 0.05; done
if ! grep -Fq CUTOVER_LOCK_HELD "$WORK_DIR/issue.log" 2>/dev/null; then
  printf 'FAIL: issue session did not acquire outlet cutover lock\n' >&2; cat "$WORK_DIR/issue.log" >&2; exit 234
fi
LOCK_PROBE="$(psql_db "$CLONE_DB" -Atqc "BEGIN; SELECT pg_try_advisory_xact_lock(hashtextextended('COST_BOOTSTRAP_OUTLET:'||'$OUTLET',73190411)); ROLLBACK")"
[[ "$LOCK_PROBE" == f ]] || { printf 'FAIL: issue session did not retain the outlet transaction lock (probe=%s)\n' "$LOCK_PROBE" >&2; exit 239; }

PGAPPNAME="$APP_B" auth_sql "$CLONE_DB" "$GUDANG" "SELECT public.apply_purchase_receipt_post_intent('$REQUEST'::uuid)" >"$WORK_DIR/apply.log" 2>&1 &
PID_B=$!; ACTIVE_PIDS+=("$PID_B")
set +e
WAIT_LOG="$(psql_db "$CLONE_DB" -q -c "DO \$wait_guard\$ BEGIN FOR i IN 1..80 LOOP IF EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND NOT granted AND database=(SELECT oid FROM pg_database WHERE datname=current_database())) THEN RAISE NOTICE 'ADVISORY_WAIT_OBSERVED'; RETURN; END IF; PERFORM pg_sleep(0.05); END LOOP; RAISE EXCEPTION 'ADVISORY_WAIT_NOT_OBSERVED'; END \$wait_guard\$" 2>&1)"
WAIT_RC=$?
set -e
if [[ "$WAIT_RC" -ne 0 || "$WAIT_LOG" != *ADVISORY_WAIT_OBSERVED* ]]; then
  printf 'FAIL: apply was not observed waiting on the issue session; overlap was not demonstrated\n' >&2
  psql_db "$CLONE_DB" -x -c "SELECT l.pid,a.application_name,l.locktype,l.classid,l.objid,l.objsubid,l.granted,a.state,a.wait_event_type,a.wait_event,a.query FROM pg_locks l LEFT JOIN pg_stat_activity a ON a.pid=l.pid WHERE l.locktype='advisory'" >&2 || true
  cat "$WORK_DIR/issue.log" "$WORK_DIR/apply.log" >&2
  exit 235
fi

set +e
wait "$PID_A"; RC_A=$?
wait "$PID_B"; RC_B=$?
set -e
ACTIVE_PIDS=()
if [[ "$RC_A" -ne 0 || "$RC_B" -ne 0 ]]; then
  printf 'FAIL: issue/apply race returned nonzero (issue=%s apply=%s)\n' "$RC_A" "$RC_B" >&2
  cat "$WORK_DIR/issue.log" "$WORK_DIR/apply.log" >&2
  exit 236
fi
grep -Fq "$REQUEST" "$WORK_DIR/issue.log" || { printf 'FAIL: overlapping issue did not replay the original request\n' >&2; exit 237; }

ASSERTION="$(psql_db "$CLONE_DB" -Atqc "SELECT
  (SELECT status='POSTED' FROM public.purchase_receipts WHERE id='$RECEIPT'::uuid)
  AND (SELECT state='COMPLETED' FROM public.stock_operation_requests WHERE request_id='$REQUEST'::uuid)
  AND (SELECT effective_quantity='$BEFORE'::numeric+1 FROM public.stock_balance_projection WHERE outlet_id='$OUTLET'::uuid AND product_id='$PRODUCT'::uuid)
  AND (SELECT count(*)=1 FROM public.stock_movements WHERE purchase_receipt_item_id=(SELECT id FROM public.purchase_receipt_items WHERE receipt_id='$RECEIPT'::uuid))
  AND (SELECT count(*)=1 FROM public.inventory_cost_events WHERE receipt_id='$RECEIPT'::uuid AND event_type='PURCHASE_RECEIPT')")"
[[ "$ASSERTION" == t ]] || { printf 'FAIL: race left invalid stock/costing state\n' >&2; cat "$WORK_DIR/issue.log" "$WORK_DIR/apply.log" >&2; exit 238; }
printf 'PASS: cloned-staging issue/apply race waited without deadlock; same request replayed and stock/cost event each occurred once\n'
