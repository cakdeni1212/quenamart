import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { canAccessSection } from '../src/lib/auth/roles.ts';
import {
  canRetryStockOpnamePost,
  canRolePostStockOpname,
  isStockOpnamePostAdvisoryEligible,
  stockOpnamePostOutcomeFromDatabase,
  stockOpnamePostRequestKey,
  stockOpnamePostStateKey,
} from '../src/lib/stock/opname-post-model.ts';

const action = readFileSync(new URL('../src/lib/stock/opname-post-action.ts', import.meta.url), 'utf8');
const component = readFileSync(new URL('../src/components/stock/stock-opname-counting.tsx', import.meta.url), 'utf8');
const page = readFileSync(new URL('../app/(workspace)/stok/opname/[id]/page.tsx', import.meta.url), 'utf8');
const reader = readFileSync(new URL('../src/lib/stock/opname-count-read.ts', import.meta.url), 'utf8');
const migration = readFileSync(new URL('../supabase/migrations/20260929180000_stock_foundation_v1.sql', import.meta.url), 'utf8');
const guardMigration = readFileSync(new URL('../supabase/migrations/20260929200000_stock_opname_revision_guard_v1.sql', import.meta.url), 'utf8');
const runtimeSql = readFileSync(new URL('./staging/runtime-stock-opname-post.sql', import.meta.url), 'utf8');

test('OWNER and ADMIN may post while GUDANG and KASIR are denied by server-side role policy', () => {
  for (const role of ['OWNER', 'ADMIN']) {
    assert.equal(canRolePostStockOpname(role), true);
    assert.equal(canAccessSection(role, 'stok'), true);
  }
  for (const role of ['GUDANG', 'KASIR']) assert.equal(canRolePostStockOpname(role), false);
  assert.equal(canAccessSection('KASIR', 'stok'), false);
  assert.match(action, /getProfile\(\)[\s\S]*profile\?\.is_active && canRolePostStockOpname\(profile\.role\)/);
  assert.match(page, /profile\.role === "OWNER" \|\| profile\.role === "ADMIN"/);
  assert.match(migration, /p_operation_key = 'POST_SESSION' and v_role = 'GUDANG'[\s\S]*Stock approval permission denied/);
  assert.match(migration, /v_role not in \('OWNER'::public\.user_role, 'ADMIN'::public\.user_role\)[\s\S]*Stock approval permission denied/);
});

test('POST_SESSION intent sends exactly session_id and leaves content hash canonicalization to PostgreSQL', () => {
  assert.match(action, /p_operation_key: "POST_SESSION",\s*p_payload: \{ session_id: input\.sessionId \}/);
  assert.doesNotMatch(action, /content_hash|contentHash|stock_opname_items|stock_movement_batches|stock_movements|stock_balance_projection/);
  assert.match(migration, /v_payload := jsonb_build_object\('session_id', v_session,[\s\S]*'content_hash', public\.stock_opname_content_hash\(v_session\)\)/);
});

test('post controls are REVIEW-only, OWNER/ADMIN-only and require explicit confirmation plus advisory complete progress', () => {
  for (const status of ['COUNTING', 'REVIEW', 'CANCELLED', 'POSTED']) {
    assert.equal(canRetryStockOpnamePost(status), status === 'REVIEW');
  }
  assert.equal(isStockOpnamePostAdvisoryEligible({ remaining: 0, recountRequired: 0 }), true);
  assert.equal(isStockOpnamePostAdvisoryEligible({ remaining: 1, recountRequired: 0 }), false);
  assert.equal(isStockOpnamePostAdvisoryEligible({ remaining: 0, recountRequired: 1 }), false);
  assert.equal(isStockOpnamePostAdvisoryEligible(null), false);
  assert.match(component, /canPost && !currentPendingPost && <button[\s\S]*startPostSession/);
  assert.match(component, /session\.status !== "REVIEW"/);
  assert.match(component, /window\.confirm\([\s\S]*Posting akan menyesuaikan stok sistem[\s\S]*final untuk sesi ini/);
  assert.match(component, /isStockOpnamePostAdvisoryEligible\(data\.progress\)/);
  assert.match(component, /baseline masih terbaru; database memeriksa perubahan stok saat posting/);
});

test('request and in-memory keys are session scoped and operation specific', () => {
  assert.notEqual(stockOpnamePostRequestKey('session-a'), stockOpnamePostRequestKey('session-b'));
  assert.notEqual(stockOpnamePostRequestKey('session-a'), 'quena-opname-lifecycle:session-a:CANCEL_SESSION');
  assert.equal(stockOpnamePostStateKey('session-a'), 'session-a:POST_SESSION');
  assert.notEqual(stockOpnamePostStateKey('session-a'), stockOpnamePostStateKey('session-b'));
  assert.match(component, /pendingPostByKey\.has\(stateKey\)/);
  assert.match(component, /setPostFeedbackBySession\(\(current\) => new Map\(current\)\.set\(sessionId/);
  assert.match(component, /currentSessionIdRef\.current === pending\.sessionId/);
});

test('uncertain retry applies the stored UUID directly; terminal success and stale results clear it', () => {
  const retry = component.slice(component.indexOf('async function retryPostRequest'), component.indexOf('async function saveCount'));
  assert.match(retry, /applyPostRequest\(pending\)/);
  assert.doesNotMatch(retry, /issueStockOpnamePostIntent/);
  assert.match(component, /savePendingValue\(stockOpnamePostRequestKey\(sessionId\), JSON\.stringify\(pending\)\)/);
  assert.match(component, /result\.kind === "success-posted" \|\| result\.kind === "stale-session-changed" \|\| result\.kind === "stale-baseline"/);
  assert.match(component, /if \(postSessionStatus === "POSTED"\)[\s\S]*removePendingValue\(storageKey\)/);
  assert.match(action, /read_stock_operation_intent/);
});

test('runtime matrix snapshots posting effects before exact UUID replay and compares them afterward', () => {
  const replay = runtimeSql.slice(runtimeSql.indexOf('-- Snapshot the complete stock effect before replay'), runtimeSql.indexOf("v_other_request := public.issue_stock_operation_intent('POST_SESSION'"));
  const apply = replay.indexOf('v_replay := public.apply_stock_operation_intent(v_request)');
  assert.ok(apply > 0);
  for (const marker of [
    'v_replay_batch_count_before',
    'v_replay_movement_count_before',
    'v_replay_balance_event_count_before',
    'v_replay_projection_before',
    'v_replay_session_status_before',
    'v_replay_posted_event_count_before',
  ]) assert.ok(replay.indexOf(marker) >= 0 && replay.indexOf(marker) < apply, `${marker} must be captured before replay`);
  for (const marker of [
    'v_replay_batch_count_after',
    'v_replay_movement_count_after',
    'v_replay_balance_event_count_after',
    'v_replay_projection_after',
    'v_replay_session_status_after',
    'v_replay_posted_event_count_after',
  ]) assert.ok(replay.indexOf(marker, apply) > apply, `${marker} must be checked after replay`);
  assert.match(replay, /v_replay IS DISTINCT FROM v_result/);
  assert.match(replay, /v_replay_session_status_after IS DISTINCT FROM 'POSTED'/);
});

test('runtime harness verifies installed issue/apply authorization guards before mutations', () => {
  const guardStart = runtimeSql.indexOf('DO $function_guard$');
  const guardEnd = runtimeSql.indexOf('$function_guard$;', guardStart) + '$function_guard$;'.length;
  const preflight = runtimeSql.slice(guardStart, guardEnd);
  assert.match(preflight, /to_regprocedure\('public\.issue_stock_operation_intent\(text,jsonb\)'\)/);
  assert.match(preflight, /to_regprocedure\('public\.apply_stock_operation_intent\(uuid\)'\)/);
  assert.match(preflight, /v_issue_access_pos[\s\S]*v_issue_gudang_pos[\s\S]*v_issue_insert_pos/);
  assert.match(preflight, /v_apply_access_pos[\s\S]*v_apply_actor_pos[\s\S]*v_apply_gudang_pos/);
  assert.match(preflight, /v_apply_post_branch_pos[\s\S]*v_apply_owner_admin_pos[\s\S]*v_apply_reconcile_branch_pos/);
  assert.match(preflight, /FUNCTION_DEFINITION_MISMATCH/);
});

test('runtime role tests assert effective synthetic actor and role immediately after switches', () => {
  for (const [actor, role] of [['v_owner', 'OWNER'], ['v_admin', 'ADMIN'], ['v_gudang', 'GUDANG'], ['v_kasir', 'KASIR']]) {
    const switchPattern = new RegExp(`PERFORM set_config\\('request\\.jwt\\.claim\\.sub', ${actor}::text, true\\);\\s*IF auth\\.uid\\(\\) IS DISTINCT FROM ${actor}[\\s\\S]*?IF public\\.current_active_user_role\\(\\) IS DISTINCT FROM '${role}'`);
    assert.match(runtimeSql, switchPattern, `${actor} must resolve to ${role} immediately after switching`);
  }
  assert.match(runtimeSql, /IDENTITY_MISMATCH expected_actor=% actual_actor=%/);
  assert.match(runtimeSql, /ROLE_MISMATCH expected_role=OWNER actual_role=%/);
});

test('GUDANG and KASIR issue denials are independently diagnosed and effects are checked as OWNER', () => {
  for (const [role, start, end] of [
    ['GUDANG', '-- GUDANG issue denial', '-- Repeat the same independent checks for KASIR'],
    ['KASIR', '-- Repeat the same independent checks for KASIR', '-- SESSION_CHANGED:'],
  ]) {
    const block = runtimeSql.slice(runtimeSql.indexOf(start), runtimeSql.indexOf(end, runtimeSql.indexOf(start) + start.length));
    assert.match(block, new RegExp(`expected_role=${role}`));
    assert.match(block, new RegExp(`ISSUE_AUTHORIZATION_FAILURE role=${role} expected_sqlstate=42501 actual_sqlstate=%`));
    assert.match(block, new RegExp(`UNEXPECTED_REQUEST_CREATED role=${role}`));
    assert.match(block, /v_denied_request := public\.issue_stock_operation_intent\('POST_SESSION'/);
    assert.match(block, /set_config\('request\.jwt\.claim\.sub', v_owner::text, true\)/);
    assert.match(block, new RegExp(`UNEXPECTED_SESSION_CHANGE role=${role}`));
    assert.match(block, /stock_movement_batches[\s\S]*stock_movements[\s\S]*stock_balance_projection_events[\s\S]*v_guard_projection/);
    assert.doesNotMatch(block, /apply_stock_operation_intent\(v_denied_request\)/);
  }
});

test('database post outcomes distinguish success, changed session, stale baseline, rejection, and uncertainty', () => {
  assert.equal(stockOpnamePostOutcomeFromDatabase({ ok: true, status: 'POSTED', movementCount: 2 }, 'r').kind, 'success-posted');
  assert.equal(stockOpnamePostOutcomeFromDatabase({ ok: false, code: 'SESSION_CHANGED' }, 'r').kind, 'stale-session-changed');
  assert.equal(stockOpnamePostOutcomeFromDatabase({ ok: false, code: 'STALE_BASELINE', staleItemCount: 1 }, 'r').kind, 'stale-baseline');
  assert.equal(stockOpnamePostOutcomeFromDatabase({ ok: false, code: 'OTHER' }, 'r').kind, 'known-rejection');
  assert.equal(stockOpnamePostOutcomeFromDatabase(null, 'r').kind, 'uncertain-failure');
  assert.match(component, /currentPostFeedback\.kind === "success-posted"/);
  assert.match(component, /currentPostFeedback\.kind === "stale-baseline"/);
});

test('stale outcomes are not presented as partial posting, and POSTED is action-free', () => {
  for (const result of [
    stockOpnamePostOutcomeFromDatabase({ ok: false, code: 'SESSION_CHANGED' }, 'r'),
    stockOpnamePostOutcomeFromDatabase({ ok: false, code: 'STALE_BASELINE' }, 'r'),
  ]) {
    assert.match(result.message, /Tidak ada penyesuaian stok|Tidak ada item yang diposting/);
  }
  const postedNote = component.slice(component.indexOf('{data.session.status === "POSTED"'), component.indexOf('{currentLifecycleRequests.map'));
  assert.match(postedNote, /hanya dapat dilihat/);
  assert.doesNotMatch(postedNote, /<button/);
  assert.match(component, /canCount = data\.session\?\.status === "COUNTING"/);
  assert.match(component, /data\.session\.status === "POSTED"[\s\S]*hanya dapat dilihat/);
});

test('posting does not calculate deltas in the app, expand bounded reads, expose costs, or add a migration', () => {
  assert.doesNotMatch(action + component, /physicalQuantity\s*-\s*baselineQuantity|stock_movements|stock_movement_batches|stock_balance_projection|product_costs|\bhpp\b|profit/i);
  assert.match(reader, /\.range\(\(query\.page - 1\) \* STOCK_OPNAME_COUNT_PAGE_SIZE/);
  assert.match(reader, /rpc\("stock_opname_progress_counts"/);
  assert.doesNotMatch(reader, /fetchAll|for\s*\([^)]*items/);
  assert.match(component, /data\.items\.map/);
  assert.doesNotMatch(component, /POST_SESSION[\s\S]{0,100}(SUBMIT_REVIEW|RETURN_TO_COUNTING|CANCEL_SESSION)/);
});

test('immutable database contract confirms stale baseline returns before movement creation', () => {
  const post = guardMigration.slice(guardMigration.indexOf("elsif v_req.operation_key = 'POST_SESSION' then"), guardMigration.indexOf("elsif v_req.operation_key = 'RECONCILE_MOVEMENT' then"));
  assert.ok(post.indexOf("if v_stale_count > 0 then") < post.indexOf("insert into public.stock_movement_batches"));
  assert.match(post, /'STALE_BASELINE'[\s\S]*'recountRequired', true[\s\S]*'staleItemCount'/);
  assert.match(post, /v_delta := v_row\.physical_quantity - v_row\.baseline_quantity/);
});
