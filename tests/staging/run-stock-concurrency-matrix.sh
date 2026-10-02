#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

# Local filesystem lock prevents two harness runs from cleaning each other's fixtures.
RUN_LOCK="${TMPDIR:-/tmp}/quena-stock-concurrency-run.lock"
if ! mkdir "$RUN_LOCK" 2>/dev/null; then
  LOCK_PID=''
  [[ -f "$RUN_LOCK/pid" ]] && LOCK_PID="$(cat "$RUN_LOCK/pid")"
  if [[ "$LOCK_PID" =~ ^[0-9]+$ ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
    printf 'REFUSED: another stock concurrency harness is running as PID %s\n' "$LOCK_PID" >&2
    exit 50
  fi
  if [[ ! "$LOCK_PID" =~ ^[0-9]+$ ]]; then
    printf 'REFUSED: stale/unfinished harness lock has no valid PID; inspect %s before removing it\n' "$RUN_LOCK" >&2
    exit 50
  fi
  rm -rf -- "$RUN_LOCK"
  mkdir "$RUN_LOCK"
fi
printf '%s\n' "$$" > "$RUN_LOCK/pid"
RUN_ID="$(date +%Y%m%d%H%M%S)-$$"
RUN_ID="$(printf '%s' "$RUN_ID" | tr -cd '[:alnum:]')"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quena-stock-concurrency.XXXXXX")"
RELEASE_FILE="$WORK_DIR/release"
export STOCK_BARRIER_RELEASE="$RELEASE_FILE"
export STOCK_BARRIER_COMMIT="$WORK_DIR/commit"
ACTIVE_PIDS=()
WATCHDOG_PID=''
OWNER='a0000000-0000-4000-8000-000000000001'
ADMIN='a0000000-0000-4000-8000-000000000002'
PRODUCT=''
OUTLET=''
CURRENT_SESSION=''
CURRENT_SCENARIO='startup'
LOCK_DETAILS=''

cleanup_local_files() {
  rm -f "$STOCK_BARRIER_COMMIT" 2>/dev/null || true
  if [[ -n "${WATCHDOG_PID:-}" ]]; then
    kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
    WATCHDOG_PID=''
  fi
  for active_pid in ${ACTIVE_PIDS[*]-}; do kill -TERM "$active_pid" 2>/dev/null || true; done
  touch "$RELEASE_FILE" 2>/dev/null || true
  for active_pid in ${ACTIVE_PIDS[*]-}; do wait "$active_pid" 2>/dev/null || true; done
  ACTIVE_PIDS=()
  rm -rf -- "$WORK_DIR" "$RUN_LOCK"
}
trap 'cleanup_local_files; cleanup_local_pgpass' EXIT

guard_local_target
assert_local_staging_marker
for version in 20260929171000 20260929180000; do
  if [[ "$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '$version')")" != t ]]; then
    printf 'REFUSED: required local migration %s is not recorded as applied\n' "$version" >&2
    exit 51
  fi
done
if [[ "$(psql_local -Atqc "SELECT count(*) FROM quena_staging.applied_migrations WHERE version > '20260929180000'")" != 0 ]]; then
  printf 'REFUSED: unexpected migration exists after stock foundation\n' >&2
  exit 52
fi
OUTLET="$(psql_local -Atqc "SELECT id FROM public.outlets WHERE code = 'QUENA-MART-1' AND is_active")"
PRODUCT="$(psql_local -Atqc "SELECT id FROM public.products WHERE sku = 'STG-CONCURRENT'")"
if [[ ! "$OUTLET" =~ ^[0-9a-f-]{36}$ || ! "$PRODUCT" =~ ^[0-9a-f-]{36}$ ]]; then
  printf 'REFUSED: expected synthetic outlet/product fixture is missing\n' >&2
  exit 53
fi

auth_sql() {
  local actor="$1" sql="$2"
  psql_local -Atq -c "BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub = '$actor'; $sql; COMMIT"
}

issue_intent() {
  local actor="$1" operation="$2" payload="$3"
  auth_sql "$actor" "SELECT public.issue_stock_operation_intent('$operation', $payload)"
}

apply_intent() {
  local actor="$1" request="$2"
  auth_sql "$actor" "SELECT public.apply_stock_operation_intent('$request'::uuid)"
}

new_session() {
  local actor="$1" product="$2" label="$3" request
  request="$(issue_intent "$actor" CREATE_SESSION "jsonb_build_object('outlet_id', '$OUTLET'::uuid, 'scope_type', 'PARTIAL', 'product_ids', jsonb_build_array('$product'::uuid), 'note', 'CC:$RUN_ID:$label')")"
  result_session_id "$actor" "$request"
}

result_session_id() {
  local actor="$1" request="$2"
  auth_sql "$actor" "SELECT (public.apply_stock_operation_intent('$request'::uuid)->>'sessionId')"
}

cancel_session() {
  local session="$1" request
  request="$(issue_intent "$OWNER" CANCEL_SESSION "jsonb_build_object('session_id', '$session'::uuid)")"
  apply_intent "$OWNER" "$request" >/dev/null
}

prepare_reviewed_session() {
  local actor="$1" delta="$2" label="$3"
  local session revision target request result
  session="$(new_session "$actor" "$PRODUCT" "$label")"
  [[ "$session" =~ ^[0-9a-f-]{36}$ ]] || { printf 'Could not create session for %s\n' "$label" >&2; return 1; }
  revision="$(psql_local -Atqc "SELECT revision_no FROM public.stock_opname_items WHERE session_id = '$session'::uuid AND product_id = '$PRODUCT'::uuid")"
  target="$(psql_local -Atqc "SELECT baseline_quantity + ($delta)::numeric FROM public.stock_opname_items WHERE session_id = '$session'::uuid AND product_id = '$PRODUCT'::uuid")"
  request="$(issue_intent "$actor" RECORD_COUNT "jsonb_build_object('session_id', '$session'::uuid, 'product_id', '$PRODUCT'::uuid, 'physical_quantity', ($target)::numeric, 'expected_revision', ($revision)::integer, 'barcode_id', null)")"
  result="$(apply_intent "$actor" "$request")"
  if [[ "$result" != *'"ok": true'* ]]; then printf 'Count setup failed (%s): %s\n' "$label" "$result" >&2; return 1; fi
  request="$(issue_intent "$actor" SUBMIT_REVIEW "jsonb_build_object('session_id', '$session'::uuid)")"
  apply_intent "$actor" "$request" >/dev/null
  printf '%s\n' "$session"
}

post_delta() {
  local actor="$1" delta="$2" label="$3"
  local session request result movement
  session="$(prepare_reviewed_session "$actor" "$delta" "$label")"
  request="$(issue_intent "$actor" POST_SESSION "jsonb_build_object('session_id', '$session'::uuid)")"
  result="$(apply_intent "$actor" "$request")"
  if [[ "$result" != *'"status": "POSTED"'* ]]; then printf 'Post setup failed (%s): %s\n' "$label" "$result" >&2; return 1; fi
  movement="$(psql_local -Atqc "SELECT m.id FROM public.stock_movements m JOIN public.stock_opname_items i ON i.id = m.opname_item_id WHERE i.session_id = '$session'::uuid ORDER BY m.created_at, m.id LIMIT 1")"
  printf '%s|%s|%s\n' "$session" "$movement" "$result"
}

forensic() {
  local product="${1:-$PRODUCT}"
  printf '\n--- FORENSICS scenario=%s run=%s ---\n' "$CURRENT_SCENARIO" "$RUN_ID" >&2
  for f in "$WORK_DIR"/*.log; do [[ -f "$f" ]] && { printf '\n--- %s ---\n' "${f##*/}" >&2; cat "$f" >&2; }; done
  psql_local -x -c "SELECT p.product_id, p.outlet_id, p.baseline_quantity, p.unreconciled_movement_delta, p.effective_quantity, p.balance_version, p.last_observation_source_import_row_id, p.last_observation_status FROM public.stock_balance_projection p WHERE p.product_id = '$product'::uuid" >&2 || true
  psql_local -x -c "SELECT s.id, s.status, s.note, i.product_id, i.physical_quantity, i.revision_no, i.requires_recount FROM public.stock_opname_sessions s JOIN public.stock_opname_items i ON i.session_id = s.id WHERE s.note LIKE 'CC:%' AND i.product_id = '$product'::uuid ORDER BY s.created_at DESC LIMIT 25" >&2 || true
  psql_local -x -c "SELECT e.item_id, e.request_id, e.event_type, e.revision_no, e.physical_quantity, e.note FROM public.stock_opname_count_events e JOIN public.stock_opname_items i ON i.id = e.item_id JOIN public.stock_opname_sessions s ON s.id = i.session_id WHERE s.note LIKE 'CC:%' AND i.product_id = '$product'::uuid ORDER BY e.created_at DESC LIMIT 35" >&2 || true
  psql_local -x -c "SELECT m.id, m.movement_type, m.quantity_delta, m.balance_before, m.balance_after, m.reverses_movement_id, r.id AS reconciliation_id, r.reconciliation_group_id FROM public.stock_movements m LEFT JOIN public.stock_movement_source_reconciliations r ON r.movement_id = m.id WHERE m.product_id = '$product'::uuid ORDER BY m.created_at DESC LIMIT 30" >&2 || true
  psql_local -x -c "SELECT q.request_id, q.actor_id, q.operation_key, q.state, q.result FROM public.stock_operation_requests q WHERE q.target_key LIKE '%' || '$product' || '%' OR q.target_key IN (SELECT s.id::text FROM public.stock_opname_sessions s WHERE s.note LIKE 'CC:%') ORDER BY q.created_at DESC LIMIT 30" >&2 || true
  psql_local -x -c "SELECT r.id AS source_row_id, r.product_id, r.outlet_id, r.status AS raw_status, b.status AS batch_status, nc.status AS commit_status, cr.action FROM public.ipos_import_rows r LEFT JOIN public.ipos_import_batches b ON b.id = r.batch_id LEFT JOIN public.ipos_normalization_commit_rows cr ON cr.source_row_id = r.id AND cr.product_id = r.product_id LEFT JOIN public.ipos_normalization_commits nc ON nc.id = cr.commit_id WHERE r.product_id = '$product'::uuid ORDER BY r.created_at DESC LIMIT 8" >&2 || true
}

fail() { printf 'FAIL scenario=%s: %s\n' "$CURRENT_SCENARIO" "$*" >&2; forensic; exit 1; }

wait_for_text() {
  local file="$1" needle="$2" i
  for ((i=0; i<200; i++)); do
    grep -Fq "$needle" "$file" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}

wait_for_lock() {
  local app="$1" holder_app="$2" i lock_row
  for ((i=0; i<200; i++)); do
    lock_row="$(psql_local -Atqc "SELECT a.wait_event_type || '|' || coalesce(a.wait_event, '') || '|blockers=' || array_to_string(pg_blocking_pids(a.pid), ',') || '|holder=' || h.application_name || '|query=' || left(coalesce(a.query, ''), 160) FROM pg_stat_activity a JOIN LATERAL unnest(pg_blocking_pids(a.pid)) AS blocked(pid) ON true JOIN pg_stat_activity h ON h.pid = blocked.pid WHERE a.application_name = '$app' AND a.wait_event_type = 'Lock' AND h.application_name = '$holder_app' LIMIT 1")"
    if [[ -n "$lock_row" ]]; then LOCK_DETAILS="$lock_row"; return 0; fi
    sleep 0.05
  done
  return 1
}

run_race() {
  local scenario="$1" actor_a="$2" req_a="$3" actor_b="$4" req_b="$5" b_mode="$6" b_expected="$7"
  local app_a="cc_${RUN_ID}_a" app_b="cc_${RUN_ID}_b" pid_a pid_b rc_a rc_b
  CURRENT_SCENARIO="$scenario"
  rm -f "$RELEASE_FILE" "$STOCK_BARRIER_COMMIT"
  PGAPPNAME="$app_a" psql_local -v actor_id="$actor_a" -v request_id="$req_a" \
    -f "$SCRIPT_DIR/stock-concurrency-held-worker.sql" >"$WORK_DIR/$scenario-a.log" 2>&1 &
  pid_a=$!
  ACTIVE_PIDS=("$pid_a")
  if ! wait_for_text "$WORK_DIR/$scenario-a.log" CONCURRENCY_HOLDER_APPLIED; then
    touch "$RELEASE_FILE"; wait "$pid_a" || true; ACTIVE_PIDS=(); fail 'session A did not reach the holding barrier'
  fi
  PGAPPNAME="$app_b" psql_local -v actor_id="$actor_b" -v request_id="$req_b" \
    -f "$SCRIPT_DIR/stock-concurrency-waiter.sql" >"$WORK_DIR/$scenario-b.log" 2>&1 &
  pid_b=$!
  ACTIVE_PIDS+=("$pid_b")
  if ! wait_for_lock "$app_b" "$app_a"; then
    touch "$RELEASE_FILE"; wait "$pid_a" || true; wait "$pid_b" || true; ACTIVE_PIDS=()
    fail 'session B never appeared blocked by session A; overlap was not proven'
  fi
  ( sleep 40; touch "$RELEASE_FILE"; kill -TERM "$pid_a" "$pid_b" 2>/dev/null || true ) &
  WATCHDOG_PID=$!
  touch "$STOCK_BARRIER_COMMIT"
  touch "$RELEASE_FILE"
  set +e
  wait "$pid_a"; rc_a=$?
  wait "$pid_b"; rc_b=$?
  set -e
  ACTIVE_PIDS=()
  kill "$WATCHDOG_PID" 2>/dev/null || true
  wait "$WATCHDOG_PID" 2>/dev/null || true
  WATCHDOG_PID=''
  [[ $rc_a -eq 0 ]] || fail "session A failed (exit $rc_a)"
  if [[ "$b_mode" == stale-json ]]; then
    [[ $rc_b -eq 0 ]] || fail "session B failed (exit $rc_b; expected stale JSON result)"
    grep -Fq "$b_expected" "$WORK_DIR/$scenario-b.log" || fail 'session B returned the wrong stale result'
  else
    [[ $rc_b -ne 0 ]] || fail 'session B unexpectedly succeeded'
    grep -Fq "$b_expected" "$WORK_DIR/$scenario-b.log" || fail 'session B failed for an unexpected reason'
  fi
  printf 'Observed lock wait (wait_type|wait_event|blocker_pids): %s\n' "$LOCK_DETAILS"
  printf 'PASS: %s — separate sessions overlapped; B was observed waiting on a database row/transaction lock\n' "$scenario"
}

new_request_for_post() {
  local actor="$1" session="$2"
  issue_intent "$actor" POST_SESSION "jsonb_build_object('session_id', '$session'::uuid)"
}

new_request_for_reverse() {
  local actor="$1" movement="$2" reason="$3"
  issue_intent "$actor" REVERSE_MOVEMENT "jsonb_build_object('movement_id', '$movement'::uuid, 'reason', '$reason')"
}

new_request_for_reconcile() {
  local actor="$1" movement="$2" source="$3" reason="$4"
  issue_intent "$actor" RECONCILE_MOVEMENT "jsonb_build_object('movement_id', '$movement'::uuid, 'source_import_row_id', '$source'::uuid, 'reason', '$reason')"
}

cleanup_tagged_data() {
  local prefix="$1" sessions id status movement source request existing movements
  sessions="$(psql_local -Atqc "SELECT id::text || '|' || status::text FROM public.stock_opname_sessions WHERE note LIKE '$prefix%' ORDER BY created_at")"
  while IFS='|' read -r id status; do
    [[ -n "$id" ]] || continue
    if [[ "$status" == COUNTING || "$status" == REVIEW ]]; then
      request="$(issue_intent "$OWNER" CANCEL_SESSION "jsonb_build_object('session_id', '$id'::uuid)")"
      apply_intent "$OWNER" "$request" >/dev/null
    fi
  done <<< "$sessions"
  movements="$(psql_local -Atqc "SELECT m.id FROM public.stock_movements m JOIN public.stock_opname_items i ON i.id = m.opname_item_id JOIN public.stock_opname_sessions s ON s.id = i.session_id WHERE s.note LIKE '$prefix%' AND m.reverses_movement_id IS NULL ORDER BY m.created_at DESC, m.id DESC")"
  while IFS= read -r movement; do
    [[ -n "$movement" ]] || continue
    existing="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM public.stock_movements r WHERE r.reverses_movement_id = '$movement'::uuid)")"
    if [[ "$existing" != t ]]; then
      request="$(new_request_for_reverse "$OWNER" "$movement" "CC cleanup $RUN_ID")"
      apply_intent "$OWNER" "$request" >/dev/null
    fi
  done <<< "$movements"
  while IFS= read -r movement; do
    [[ -n "$movement" ]] || continue
    existing="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM public.stock_movement_source_reconciliations WHERE reconciliation_group_id = '$movement'::uuid)")"
    if [[ "$existing" != t ]]; then
      source="$(psql_local -Atqc "SELECT baseline_source_import_row_id FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")"
      request="$(new_request_for_reconcile "$OWNER" "$movement" "$source" "CC cleanup $RUN_ID")"
      apply_intent "$OWNER" "$request" >/dev/null
    fi
  done <<< "$movements"
}

# Recover an interrupted earlier run by cancelling only its tagged drafts and
# reversing/reconciling only its own posted opname movements. Immutable audit
# rows remain by design; their net stock effect is neutralized.
cleanup_tagged_data 'CC:%'
if [[ "$(psql_local -Atqc "SELECT unreconciled_movement_delta = 0 FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")" != t ]]; then
  printf 'REFUSED: synthetic concurrency stock projection is not neutral after prior-run recovery\n' >&2
  exit 54
fi

BASELINE_SOURCE="$(psql_local -Atqc "SELECT baseline_source_import_row_id FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")"
BASELINE_QUANTITY="$(psql_local -Atqc "SELECT baseline_quantity FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")"
if [[ "$BASELINE_QUANTITY" != 20 ]]; then printf 'REFUSED: STG-CONCURRENT baseline must be 20, got %s\n' "$BASELINE_QUANTITY" >&2; exit 55; fi
printf 'Concurrency run=%s uses synthetic product STG-CONCURRENT; immutable test audit rows will be retained and stock effect restored.\n' "$RUN_ID"

# A. Two actors bind the same observed revision. The second waits on the
# session lock (the RPC locks session before item), then checks item revision.
CURRENT_SCENARIO='A competing RECORD_COUNT'
CURRENT_SESSION="$(new_session "$OWNER" "$PRODUCT" "${RUN_ID}:A-count")"
REVISION="$(psql_local -Atqc "SELECT revision_no FROM public.stock_opname_items WHERE session_id = '$CURRENT_SESSION'::uuid AND product_id = '$PRODUCT'::uuid")"
[[ "$REVISION" == 0 ]] || fail "fresh item started at revision $REVISION instead of 0"
REQ_A="$(issue_intent "$OWNER" RECORD_COUNT "jsonb_build_object('session_id', '$CURRENT_SESSION'::uuid, 'product_id', '$PRODUCT'::uuid, 'physical_quantity', 19, 'expected_revision', $REVISION, 'barcode_id', null)")"
REQ_B="$(issue_intent "$ADMIN" RECORD_COUNT "jsonb_build_object('session_id', '$CURRENT_SESSION'::uuid, 'product_id', '$PRODUCT'::uuid, 'physical_quantity', 18, 'expected_revision', $REVISION, 'barcode_id', null)")"
run_race 'A-record-count' "$OWNER" "$REQ_A" "$ADMIN" "$REQ_B" stale-json 'ITEM_REVISION_MISMATCH'
[[ "$(psql_local -Atqc "SELECT physical_quantity = 19 AND revision_no = 1 FROM public.stock_opname_items WHERE session_id = '$CURRENT_SESSION'::uuid AND product_id = '$PRODUCT'::uuid")" == t ]] || fail 'A stale client overwrote the winning physical count/revision'
[[ "$(psql_local -Atqc "SELECT count(*) FROM public.stock_opname_count_events WHERE request_id = '$REQ_B'::uuid")" == 0 ]] || fail 'stale client request wrote a count event'
REPLAY="$(apply_intent "$ADMIN" "$REQ_B")"
[[ "$REPLAY" == *'ITEM_REVISION_MISMATCH'* && "$REPLAY" == *'"currentRevision": 1'* ]] || fail 'stale request replay changed result'
REQ_REFRESH="$(issue_intent "$ADMIN" RECORD_COUNT "jsonb_build_object('session_id', '$CURRENT_SESSION'::uuid, 'product_id', '$PRODUCT'::uuid, 'physical_quantity', 18, 'expected_revision', 1, 'barcode_id', null)")"
REFRESH_RESULT="$(apply_intent "$ADMIN" "$REQ_REFRESH")"
[[ "$REFRESH_RESULT" == *'"revision": 2'* ]] || fail 'refreshed expected_revision did not succeed'
cancel_session "$CURRENT_SESSION"
printf 'PASS: A — expected_revision=N wins once; stale N replays without count/event/revision mutation; N+1 succeeds\n'
[[ "$(psql_local -Atqc "SELECT status = 'CANCELLED' FROM public.stock_opname_sessions WHERE id = '$CURRENT_SESSION'::uuid")" == t ]] || fail 'Scenario A cleanup did not cancel its own session'
[[ "$(psql_local -Atqc "SELECT count(*) FROM public.stock_movements m JOIN public.stock_opname_items i ON i.id = m.opname_item_id WHERE i.session_id = '$CURRENT_SESSION'::uuid")" == 0 ]] || fail 'Scenario A unexpectedly created a movement that could affect Scenario B'

# B. Two distinct authorized actors race to post one reviewed session.
CURRENT_SCENARIO='B competing POST_SESSION'
B_VERSION_BEFORE="$(psql_local -Atqc "SELECT balance_version FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")"
[[ "$(psql_local -Atqc "SELECT baseline_quantity = 20 AND unreconciled_movement_delta = 0 AND effective_quantity = 20 FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")" == t ]] || fail 'Scenario B expected clean baseline/effective quantity 20 before preparing its session'
CURRENT_SESSION="$(prepare_reviewed_session "$OWNER" -1 "${RUN_ID}:B-post-race")"
[[ "$(psql_local -Atqc "SELECT status = 'REVIEW' FROM public.stock_opname_sessions WHERE id = '$CURRENT_SESSION'::uuid")" == t ]] || fail 'Scenario B target session is not in REVIEW before the race'
[[ "$(psql_local -Atqc "SELECT count(*) FROM public.stock_movements m JOIN public.stock_opname_items i ON i.id = m.opname_item_id WHERE i.session_id = '$CURRENT_SESSION'::uuid AND m.movement_type = 'OPNAME_ADJUSTMENT'")" == 0 ]] || fail 'Scenario B target session already has an OPNAME_ADJUSTMENT before the race'
[[ "$(psql_local -Atqc "SELECT i.baseline_quantity = 20 AND i.physical_quantity = 19 AND p.effective_quantity = 20 AND p.balance_version = '$B_VERSION_BEFORE'::bigint FROM public.stock_opname_items i JOIN public.stock_balance_projection p ON p.product_id = i.product_id AND p.outlet_id = i.outlet_id WHERE i.session_id = '$CURRENT_SESSION'::uuid AND i.product_id = '$PRODUCT'::uuid")" == t ]] || fail 'Scenario B count or projection precondition is not the expected 20-to-19 adjustment on unchanged projection version'
REQ_A="$(new_request_for_post "$OWNER" "$CURRENT_SESSION")"
REQ_B="$(new_request_for_post "$ADMIN" "$CURRENT_SESSION")"
[[ "$(psql_local -Atqc "SELECT count(*) = 2 AND bool_and(q.state = 'PENDING' AND q.operation_key = 'POST_SESSION' AND q.target_key = '$CURRENT_SESSION' AND q.request_payload->>'session_id' = '$CURRENT_SESSION') FROM public.stock_operation_requests q WHERE q.request_id IN ('$REQ_A'::uuid, '$REQ_B'::uuid)")" == t ]] || fail 'Scenario B post requests are missing, already completed, or bound to another session before the race'
[[ "$(psql_local -Atqc "SELECT count(*) = 0 FROM public.stock_operation_requests q WHERE q.request_id IN ('$REQ_A'::uuid, '$REQ_B'::uuid) AND q.state = 'COMPLETED'")" == t ]] || fail 'Scenario B current POST_SESSION request was already completed before the race'
run_race 'B-post-session' "$OWNER" "$REQ_A" "$ADMIN" "$REQ_B" sql-error 'Session is not ready to post'
MOVEMENT="$(psql_local -Atqc "SELECT m.id FROM public.stock_movements m JOIN public.stock_opname_items i ON i.id = m.opname_item_id WHERE i.session_id = '$CURRENT_SESSION'::uuid AND m.movement_type = 'OPNAME_ADJUSTMENT'")"
[[ -n "$MOVEMENT" ]] || fail 'winning race did not create its expected OPNAME_ADJUSTMENT'
[[ "$(psql_local -Atqc "SELECT count(*) FROM public.stock_movements WHERE opname_item_id IN (SELECT id FROM public.stock_opname_items WHERE session_id = '$CURRENT_SESSION'::uuid)")" == 1 ]] || fail 'competing post created duplicate movements'
[[ "$(psql_local -Atqc "SELECT status = 'POSTED' FROM public.stock_opname_sessions WHERE id = '$CURRENT_SESSION'::uuid")" == t ]] || fail 'winning post did not leave one POSTED session'
[[ "$(psql_local -Atqc "SELECT balance_version = '$B_VERSION_BEFORE'::bigint + 1 FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")" == t ]] || fail 'competing post changed projection version more than once'
POST_REPLAY="$(apply_intent "$OWNER" "$REQ_A")"
[[ "$POST_REPLAY" == *'"status": "POSTED"'* ]] || fail 'exact successful posting retry did not replay its committed result'
[[ "$(psql_local -Atqc "SELECT count(*) FROM public.stock_movements WHERE opname_item_id IN (SELECT id FROM public.stock_opname_items WHERE session_id = '$CURRENT_SESSION'::uuid)")" == 1 ]] || fail 'exact posting retry created a duplicate movement'
[[ "$(psql_local -Atqc "SELECT balance_version = '$B_VERSION_BEFORE'::bigint + 1 FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")" == t ]] || fail 'exact posting retry applied a second projection delta'
printf 'PASS: B — one post/movement; losing request receives deterministic state rejection\n'

# E. Competing reversals of the same finalized movement; one wins.
CURRENT_SCENARIO='E competing reversal'
REQ_A="$(new_request_for_reverse "$OWNER" "$MOVEMENT" "CC $RUN_ID reversal owner")"
REQ_B="$(new_request_for_reverse "$ADMIN" "$MOVEMENT" "CC $RUN_ID reversal admin")"
E_VERSION_BEFORE="$(psql_local -Atqc "SELECT balance_version FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")"
run_race 'E-reversal' "$OWNER" "$REQ_A" "$ADMIN" "$REQ_B" sql-error 'Movement has already been reversed'
REVERSAL_ID="$(psql_local -Atqc "SELECT id FROM public.stock_movements WHERE reverses_movement_id = '$MOVEMENT'::uuid")"
[[ "$REVERSAL_ID" =~ ^[0-9a-f-]{36}$ ]] || fail 'original movement has no unique reversal'
E_VERSION_AFTER_RACE="$(psql_local -Atqc "SELECT balance_version FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")"
E_QUANTITY_AFTER_RACE="$(psql_local -Atqc "SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")"
REVERSAL_REPLAY="$(apply_intent "$OWNER" "$REQ_A")"
REVERSAL_REPLAY_MATCH="$(psql_local -Atq \
  -v replay_result="$REVERSAL_REPLAY" \
  -v request_id="$REQ_A" \
  -v original_movement_id="$MOVEMENT" <<'SQL'
SELECT :'replay_result'::jsonb = q.result
   AND (:'replay_result'::jsonb->>'reversesMovementId') = :'original_movement_id'
FROM public.stock_operation_requests AS q
WHERE q.request_id = :'request_id'::uuid;
SQL
)"
[[ "$REVERSAL_REPLAY_MATCH" == t ]] || fail 'same winning request UUID did not replay its stored reversal result semantically'
[[ "$(psql_local -Atqc "SELECT count(*) FROM public.stock_movements WHERE reverses_movement_id = '$MOVEMENT'::uuid")" == 1 ]] || fail 'duplicate reversal exists'
[[ "$(psql_local -Atqc "SELECT balance_version = '$E_VERSION_AFTER_RACE'::bigint AND effective_quantity = '$E_QUANTITY_AFTER_RACE'::numeric FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")" == t ]] || fail 'exact reversal retry changed projection quantity or version'
[[ "$(psql_local -Atqc "SELECT '$E_VERSION_AFTER_RACE'::bigint = '$E_VERSION_BEFORE'::bigint + 1 AND '$E_QUANTITY_AFTER_RACE'::numeric = (SELECT baseline_quantity FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid)")" == t ]] || fail 'reversal race applied projection change more than once or lost the reversal'
printf 'PASS: E — one reversal wins; original remains and exact retry replays\n'

# F. Reconcile the original/reversal pair concurrently as one group.
CURRENT_SCENARIO='F competing reconciliation'
SOURCE="$(psql_local -Atqc "SELECT baseline_source_import_row_id FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")"
BALANCE_BEFORE="$(psql_local -Atqc "SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")"
DELTA_BEFORE="$(psql_local -Atqc "SELECT unreconciled_movement_delta FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")"
REQ_A="$(new_request_for_reconcile "$OWNER" "$MOVEMENT" "$SOURCE" "CC $RUN_ID reconcile owner")"
REQ_B="$(new_request_for_reconcile "$ADMIN" "$MOVEMENT" "$SOURCE" "CC $RUN_ID reconcile admin")"
F_VERSION_BEFORE="$(psql_local -Atqc "SELECT balance_version FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")"
run_race 'F-reconciliation' "$OWNER" "$REQ_A" "$ADMIN" "$REQ_B" sql-error 'Movement group is already or partially reconciled'
[[ "$(apply_intent "$OWNER" "$REQ_A")" == *'"movementCount": 2'* ]] || fail 'exact group reconciliation retry did not replay two-member result'
[[ "$(psql_local -Atqc "SELECT count(*) FROM public.stock_movement_source_reconciliations WHERE reconciliation_group_id = '$MOVEMENT'::uuid")" == 2 ]] || fail 'reconciliation did not atomically record both members'
[[ "$(psql_local -Atqc "SELECT effective_quantity = '$BALANCE_BEFORE'::numeric AND unreconciled_movement_delta = '$DELTA_BEFORE'::numeric FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")" == t ]] || fail 'zero-net group reconciliation changed effective stock/overlay'
[[ "$(psql_local -Atqc "SELECT balance_version = '$F_VERSION_BEFORE'::bigint + 1 FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")" == t ]] || fail 'concurrent reconciliation advanced projection more than once'
printf 'PASS: F — original/reversal group reconciles atomically once with unchanged effective quantity\n'

# D. Supported reverse-operation race: two +2 movements exist while current
# stock is 3; either reversal alone is legal, both together would produce -1.
CURRENT_SCENARIO='D negative stock reversal race'
M1_SETUP="$(post_delta "$OWNER" "-$BASELINE_QUANTITY" "${RUN_ID}:D-base-to-zero")"; M1_SESSION="${M1_SETUP%%|*}"; M1="$(printf '%s' "$M1_SETUP" | cut -d'|' -f2)"
M2_SETUP="$(post_delta "$OWNER" 2 "${RUN_ID}:D-in-1")"; M2="$(printf '%s' "$M2_SETUP" | cut -d'|' -f2)"
M3_SETUP="$(post_delta "$OWNER" 2 "${RUN_ID}:D-in-2")"; M3="$(printf '%s' "$M3_SETUP" | cut -d'|' -f2)"
M4_SETUP="$(post_delta "$OWNER" -1 "${RUN_ID}:D-spend")"; M4="$(printf '%s' "$M4_SETUP" | cut -d'|' -f2)"
[[ "$(psql_local -Atqc "SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")" == 3 ]] || fail 'negative-stock race precondition is not exactly 3'
REQ_A="$(new_request_for_reverse "$OWNER" "$M2" "CC $RUN_ID negative race A")"
REQ_B="$(new_request_for_reverse "$ADMIN" "$M3" "CC $RUN_ID negative race B")"
run_race 'D-negative-stock' "$OWNER" "$REQ_A" "$ADMIN" "$REQ_B" sql-error 'Stock movement would make effective stock negative'
[[ "$(psql_local -Atqc "SELECT effective_quantity >= 0 FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")" == t ]] || fail 'negative stock race produced negative effective stock'
[[ "$(psql_local -Atqc "SELECT count(*) FROM public.stock_movements WHERE reverses_movement_id IN ('$M2'::uuid, '$M3'::uuid)")" == 1 ]] || fail 'negative race created zero or two reversals'
printf 'PASS: D — serialized reversals reject the decrement that would make effective stock negative\n'

# G. Use the real request/claim/raw-row/complete/commit importer lifecycle.
# Hold its commit after the inventory trigger locked projection, then race a
# legitimate reversal against that exact projection row.
CURRENT_SCENARIO='G import observation versus stock reversal'
G_SETUP="$(post_delta "$OWNER" 1 "${RUN_ID}:G-stock-movement")"
G_SESSION="${G_SETUP%%|*}"; G_MOVEMENT="$(printf '%s' "$G_SETUP" | cut -d'|' -f2)"
G_BASELINE="$(psql_local -Atqc "SELECT baseline_quantity FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")"
G_SOURCE="$(psql_local -Atqc "SELECT baseline_source_import_row_id FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")"
G_PRE_OVERLAY="$(psql_local -Atqc "SELECT unreconciled_movement_delta - 1 FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")"
STORAGE_ID="$(psql_local -Atqc 'SELECT gen_random_uuid()')"
OBJECT_NAME="incoming/$OWNER/$STORAGE_ID.xlsx"
psql_local -v storage_id="$STORAGE_ID" -v object_name="$OBJECT_NAME" \
  -f "$SCRIPT_DIR/prepare-stock-concurrency-import.sql" \
  >"$WORK_DIR/G-import-prepare.log" 2>&1 || fail 'could not prepare synthetic completed iPos import through worker lifecycle'
IMPORT_REQUEST="$(psql_local -Atqc "SELECT id FROM public.ipos_import_requests WHERE storage_path = '$OBJECT_NAME'")"
[[ "$IMPORT_REQUEST" =~ ^[0-9a-f-]{36}$ ]] || fail 'prepared iPos request not found'
IMPORT_BATCH="$(psql_local -Atqc "SELECT id FROM public.ipos_import_batches WHERE request_id = '$IMPORT_REQUEST'::uuid")"
IMPORT_ROW="$(psql_local -Atqc "SELECT id FROM public.ipos_import_rows WHERE batch_id = '$IMPORT_BATCH'::uuid")"
NORMALIZED="$(psql_local -Atqc "SELECT cr.normalized_data || jsonb_build_object('quantity', (pi.quantity + 4)::text) FROM public.product_inventory pi JOIN public.ipos_normalization_commit_rows cr ON cr.source_row_id = pi.source_import_row_id AND cr.product_id = pi.product_id WHERE pi.product_id = '$PRODUCT'::uuid AND pi.outlet_id = '$OUTLET'::uuid ORDER BY cr.created_at DESC, cr.commit_id DESC, cr.source_row_number DESC LIMIT 1")"
APP_G="cc_${RUN_ID}_g"
rm -f "$RELEASE_FILE" "$STOCK_BARRIER_COMMIT"
PGAPPNAME="$APP_G" STOCK_BARRIER_RELEASE="$RELEASE_FILE" psql_local \
  -v batch_id="$IMPORT_BATCH" -v outlet_id="$OUTLET" -v sku='STG-CONCURRENT' \
  -v barcode='STG-CONCURRENT-BC' -v product_id="$PRODUCT" -v source_row_id="$IMPORT_ROW" \
  -v normalized_data="$NORMALIZED" -f "$SCRIPT_DIR/stock-concurrency-import-holder.sql" \
  >"$WORK_DIR/G-import-a.log" 2>&1 &
PID_A=$!
ACTIVE_PIDS=("$PID_A")
if ! wait_for_text "$WORK_DIR/G-import-a.log" CONCURRENCY_IMPORT_APPLIED; then touch "$RELEASE_FILE"; wait "$PID_A" || true; ACTIVE_PIDS=(); fail 'import transaction did not reach projection-lock barrier'; fi
REQ_B="$(new_request_for_reverse "$ADMIN" "$G_MOVEMENT" "CC $RUN_ID observation race reverse")"
PGAPPNAME="cc_${RUN_ID}_g_b" psql_local -v actor_id="$ADMIN" -v request_id="$REQ_B" \
  -f "$SCRIPT_DIR/stock-concurrency-waiter.sql" >"$WORK_DIR/G-stock-b.log" 2>&1 &
PID_B=$!
ACTIVE_PIDS+=("$PID_B")
if ! wait_for_lock "cc_${RUN_ID}_g_b" "$APP_G"; then touch "$RELEASE_FILE"; wait "$PID_A" || true; wait "$PID_B" || true; ACTIVE_PIDS=(); fail 'stock operation did not overlap/wait on importer projection lock'; fi
( sleep 40; touch "$RELEASE_FILE"; kill -TERM "$PID_A" "$PID_B" 2>/dev/null || true ) & WATCHDOG_PID=$!
touch "$STOCK_BARRIER_COMMIT"
touch "$RELEASE_FILE"
set +e; wait "$PID_A"; RC_A=$?; wait "$PID_B"; RC_B=$?; set -e
ACTIVE_PIDS=()
kill "$WATCHDOG_PID" 2>/dev/null || true; wait "$WATCHDOG_PID" 2>/dev/null || true; WATCHDOG_PID=''
[[ $RC_A -eq 0 && $RC_B -eq 0 ]] || fail "import/stock race process failed (A=$RC_A B=$RC_B)"
[[ "$(psql_local -Atqc "SELECT last_observation_source_import_row_id = '$IMPORT_ROW'::uuid AND last_observation_status = 'SOURCE_CHRONOLOGY_UNVERIFIED' FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")" == t ]] || fail 'projection did not record the real iPos observation status/source'
[[ "$(psql_local -Atqc "SELECT baseline_quantity = '$G_BASELINE'::numeric AND baseline_source_import_row_id = '$G_SOURCE'::uuid AND unreconciled_movement_delta = '$G_PRE_OVERLAY'::numeric FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")" == t ]] || fail 'import observation advanced baseline or lost the Quena reversal result'
[[ "$(psql_local -Atqc "SELECT pi.source_import_row_id = '$IMPORT_ROW'::uuid AND pi.quantity = (SELECT (r.raw_data->>'STOK')::numeric FROM public.ipos_import_rows r WHERE r.id = '$IMPORT_ROW'::uuid) FROM public.product_inventory pi WHERE pi.product_id = '$PRODUCT'::uuid AND pi.outlet_id = '$OUTLET'::uuid")" == t ]] || fail 'actual normalization commit did not advance product_inventory source observation'
printf 'PASS: G — Phase 2B commit/trigger observation overlaps a stock reversal; accepted baseline stays fixed\n'

# Cleanup all tagged open sessions and neutralize only this harness's movement
# groups. Append-only audit rows cannot be deleted without violating 180000.
cleanup_tagged_data "CC:$RUN_ID:%"
[[ "$(psql_local -Atqc "SELECT unreconciled_movement_delta = 0 AND effective_quantity = baseline_quantity FROM public.stock_balance_projection WHERE product_id = '$PRODUCT'::uuid AND outlet_id = '$OUTLET'::uuid")" == t ]] || fail 'cleanup did not restore the synthetic product effective balance to its accepted baseline'
[[ "$(psql_local -Atqc "SELECT count(*) FROM public.stock_opname_sessions WHERE note LIKE 'CC:$RUN_ID:%' AND status IN ('COUNTING', 'REVIEW')")" == 0 ]] || fail 'cleanup left an active session from this concurrency run'

printf '\nDEFERRED C: no generic manual movement/SALE RPC is exposed by 180000.\n'
printf 'DEFERRED H: public multi-product stock paths internally sort product IDs; there is no caller-controlled reverse lock order.\n'
printf 'PASS: concurrency assertions completed; stock effects neutralized. Append-only tagged audit records are retained.\n'
printf 'NOTE: this runner performs real, committed local-staging mutations. It does not run inside a rollback transaction.\n'
