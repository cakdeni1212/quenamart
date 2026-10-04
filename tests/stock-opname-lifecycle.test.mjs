import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { canAccessSection } from '../src/lib/auth/roles.ts';
import {
  canRetryStockOpnameLifecycle,
  hasSessionLifecycleInFlight,
  isSubmitReviewAdvisoryEligible,
  lifecycleOperationLabel,
  removeSessionEntries,
  removeSessionOperationEntry,
  stockOpnameLifecycleRequestKey,
  stockOpnameLifecycleStateKey,
} from '../src/lib/stock/opname-lifecycle-model.ts';

const action = readFileSync(new URL('../src/lib/stock/opname-lifecycle-action.ts', import.meta.url), 'utf8');
const component = readFileSync(new URL('../src/components/stock/stock-opname-counting.tsx', import.meta.url), 'utf8');
const reader = readFileSync(new URL('../src/lib/stock/opname-count-read.ts', import.meta.url), 'utf8');
const migration = readFileSync(new URL('../supabase/migrations/20260929180000_stock_foundation_v1.sql', import.meta.url), 'utf8');
const progressMigration = readFileSync(new URL('../supabase/migrations/20260929200000_stock_opname_revision_guard_v1.sql', import.meta.url), 'utf8');

test('OWNER, ADMIN, and GUDANG lifecycle actions are server-authorized; KASIR is denied', () => {
  for (const role of ['OWNER', 'ADMIN', 'GUDANG']) assert.equal(canAccessSection(role, 'stok'), true);
  assert.equal(canAccessSection('KASIR', 'stok'), false);
  assert.match(action, /getProfile\(\)[\s\S]*canAccessSection\(profile\.role, "stok"\)/);
});

test('all three operations issue only the canonical session_id payload then apply the returned UUID', () => {
  assert.match(action, /p_operation_key: input\.operation,[\s\S]*p_payload: \{ session_id: input\.sessionId \}/);
  assert.match(action, /rpc\("apply_stock_operation_intent", \{\s*p_request_id: input\.requestId/);
  assert.doesNotMatch(action, /expected_revision|reason:|product_id|progress/i);
  for (const op of ['SUBMIT_REVIEW', 'RETURN_TO_COUNTING', 'CANCEL_SESSION']) assert.ok(action.includes(op));
  assert.doesNotMatch(action, /stock_opname_(sessions|items|session_events)|stock_movements|stock_balance_projection/);
});

test('review submit advisory eligibility requires a valid aggregate with zero remaining and recount-required', () => {
  assert.equal(isSubmitReviewAdvisoryEligible({ remaining: 0, recountRequired: 0 }), true);
  assert.equal(isSubmitReviewAdvisoryEligible({ remaining: 1, recountRequired: 0 }), false);
  assert.equal(isSubmitReviewAdvisoryEligible({ remaining: 0, recountRequired: 1 }), false);
  assert.equal(isSubmitReviewAdvisoryEligible(null), false);
  assert.match(component, /isSubmitReviewAdvisoryEligible\(data\.progress\)/);
  assert.match(component, /Database memeriksa ulang kelengkapan saat dikirim/);
  assert.match(component, /tidak memeriksa perubahan stok sejak hitungan/);
});

test('database completeness remains authoritative and handles zero counts, reviewed exceptions, and recount-required items', () => {
  const submit = migration.slice(migration.indexOf("elsif v_req.operation_key = 'SUBMIT_REVIEW' then"), migration.indexOf("elsif v_req.operation_key = 'RETURN_TO_COUNTING' then"));
  assert.match(submit, /i\.requires_recount or \(i\.physical_quantity is null and i\.exception_reviewed_at is null\)/);
  assert.match(submit, /Every item needs a count or reviewed exception/);
  assert.doesNotMatch(submit, /stock_balance_projection|baseline_balance_version/);
  assert.match(progressMigration, /physical_quantity is not null and not i\.requires_recount/);
  assert.match(progressMigration, /exception_reviewed_at is not null[\s\S]*not i\.requires_recount/);
});

test('review return is status-only and cancellation preserves history while releasing active scope', () => {
  const returning = migration.slice(migration.indexOf("elsif v_req.operation_key = 'RETURN_TO_COUNTING' then"), migration.indexOf("elsif v_req.operation_key = 'CANCEL_SESSION' then"));
  assert.match(returning, /v_session\.status <> 'REVIEW'/);
  assert.match(returning, /set status = 'COUNTING', submitted_by = null,[\s\S]*submitted_at = null/);
  assert.match(returning, /'RETURNED_TO_COUNTING', 'REVIEW', 'COUNTING'/);
  assert.doesNotMatch(returning, /stock_opname_items|revision_no|physical_quantity|exception_reason/);

  const cancel = migration.slice(migration.indexOf("elsif v_req.operation_key = 'CANCEL_SESSION' then"), migration.indexOf("elsif v_req.operation_key = 'POST_SESSION' then"));
  assert.match(cancel, /v_session\.status not in \('COUNTING'::public\.stock_opname_status,[\s\S]*'REVIEW'::public\.stock_opname_status/);
  assert.match(cancel, /set active_scope = false[\s\S]*where session_id = v_session_id/);
  assert.match(cancel, /set status = 'CANCELLED', cancelled_by = v_actor,[\s\S]*cancelled_at = now\(\)/);
  assert.match(cancel, /'CANCELLED', v_session\.status, 'CANCELLED'/);
  assert.doesNotMatch(cancel, /reason|stock_movements|stock_movement_batches|stock_balance_projection/);
});

test('lifecycle retry keys are isolated by both session and operation', () => {
  const sessionA = 'session-a';
  const sessionB = 'session-b';
  assert.notEqual(stockOpnameLifecycleRequestKey(sessionA, 'SUBMIT_REVIEW'), stockOpnameLifecycleRequestKey(sessionA, 'CANCEL_SESSION'));
  assert.notEqual(stockOpnameLifecycleRequestKey(sessionA, 'SUBMIT_REVIEW'), stockOpnameLifecycleRequestKey(sessionB, 'SUBMIT_REVIEW'));
  assert.notEqual(stockOpnameLifecycleStateKey(sessionA, 'SUBMIT_REVIEW'), stockOpnameLifecycleStateKey(sessionA, 'CANCEL_SESSION'));
  assert.notEqual(stockOpnameLifecycleStateKey(sessionA, 'SUBMIT_REVIEW'), stockOpnameLifecycleStateKey(sessionB, 'SUBMIT_REVIEW'));
  const inFlight = new Set([stockOpnameLifecycleStateKey(sessionA, 'SUBMIT_REVIEW')]);
  assert.equal(hasSessionLifecycleInFlight(inFlight, sessionA), true);
  assert.equal(hasSessionLifecycleInFlight(inFlight, sessionB), false);
  assert.match(component, /stockOpnameLifecycleRequestKey\(sessionId, operation\)/);
  assert.match(component, /pending\.sessionId === data\.session!\.id/);
  assert.match(component, /pending\.operation, requestId: pending\.requestId/);
  assert.match(component, /hasSessionLifecycleInFlight\(lifecycleInFlight\.current, session\.id\)/);
  assert.match(component, /lifecycleBusy\.entries\(\)\]\.find\(\(\[key\]\) => key\.startsWith/);
});

test('completing session A lifecycle state preserves session B same-operation pending and feedback entries', () => {
  const operation = 'SUBMIT_REVIEW';
  const pendingA = { sessionId: 'session-a', operation, requestId: 'request-a' };
  const pendingB = { sessionId: 'session-b', operation, requestId: 'request-b' };
  const pending = new Map([
    [stockOpnameLifecycleStateKey(pendingA.sessionId, operation), pendingA],
    [stockOpnameLifecycleStateKey(pendingB.sessionId, operation), pendingB],
  ]);
  const afterA = removeSessionOperationEntry(pending, pendingA.sessionId, operation);
  assert.equal(afterA.has(stockOpnameLifecycleStateKey('session-a', operation)), false);
  assert.deepEqual(afterA.get(stockOpnameLifecycleStateKey('session-b', operation)), pendingB);

  const feedback = new Map([
    [stockOpnameLifecycleStateKey('session-a', operation), { ...pendingA, result: { kind: 'success' } }],
    [stockOpnameLifecycleStateKey('session-b', operation), { ...pendingB, result: { kind: 'error' } }],
  ]);
  const afterStartingAOperation = removeSessionEntries(feedback, 'session-a');
  assert.equal(afterStartingAOperation.has(stockOpnameLifecycleStateKey('session-a', operation)), false);
  assert.deepEqual(afterStartingAOperation.get(stockOpnameLifecycleStateKey('session-b', operation)), {
    ...pendingB,
    result: { kind: 'error' },
  });
  assert.match(component, /currentSessionIdRef\.current === pending\.sessionId/);
  assert.match(component, /lifecycleFeedback\.values\(\)\]\.filter\(\(feedback\) => feedback\.sessionId === data\.session!\.id/);
  assert.match(component, /pendingLifecycle\.values\(\)\]\.filter\(\(pending\) => pending\.sessionId === data\.session!\.id/);
});

test('uncertain apply retains exact UUID; confirmed success or known rejection clears it and refreshes', () => {
  assert.match(component, /kind === "success" \|\| result\.kind === "rejected"/);
  assert.match(component, /removePendingValue\(stockOpnameLifecycleRequestKey\(pending\.sessionId, pending\.operation\)\)/);
  assert.match(component, /kind: "error", requestId: pending\.requestId/);
  assert.match(component, /await applyLifecycleRequest\(pending\)/);
  assert.match(component, /lifecycleInFlight\.current/);
  assert.match(component, /router\.refresh\(\)/);
  assert.match(action, /error\.code === "22023" \|\| error\.code === "42501"/);
  const retry = component.slice(component.indexOf('async function retryLifecycleRequest'), component.indexOf('async function saveCount'));
  assert.match(retry, /await applyLifecycleRequest\(pending\)/);
  assert.doesNotMatch(retry, /issueStockOpnameLifecycleIntent/);
  assert.match(component, /result\.kind === "success" \|\| result\.kind === "rejected"/);
});

test('lifecycle retries are enabled only in the operation-compatible current status', () => {
  for (const status of ['COUNTING', 'REVIEW', 'CANCELLED', 'POSTED']) {
    assert.equal(canRetryStockOpnameLifecycle('SUBMIT_REVIEW', status), status === 'COUNTING');
    assert.equal(canRetryStockOpnameLifecycle('RETURN_TO_COUNTING', status), status === 'REVIEW');
    assert.equal(canRetryStockOpnameLifecycle('CANCEL_SESSION', status), status === 'COUNTING' || status === 'REVIEW');
  }
  assert.match(component, /canRetryStockOpnameLifecycle\(pending\.operation, data\.session\.status\)/);
  assert.match(component, /Permintaan tetap tersimpan; retry tidak tersedia pada status sesi saat ini/);
  assert.match(component, /removePendingValue\(stockOpnameLifecycleRequestKey\(pending\.sessionId, pending\.operation\)\)/);
  assert.match(component, /currentLifecycleRequests\.filter\(\(pending\) => canRetryStockOpnameLifecycle/);
  assert.match(component, /result\.kind === "success" \|\| result\.kind === "rejected"\) \{/);
  assert.match(component, /setPendingLifecycle\(\(current\) => removeSessionOperationEntry\(current, pending\.sessionId, pending\.operation\)\)/);
});

test('cancel requires explicit confirmation and no cancellation reason is sent', () => {
  assert.match(component, /operation === "CANCEL_SESSION" && !window\.confirm\(/);
  assert.match(component, /Riwayat tetap tersimpan dan tidak ada penyesuaian stok yang diposting/);
  assert.match(action, /p_payload: \{ session_id: input\.sessionId \}/);
  assert.doesNotMatch(action, /cancel_reason|cancellation_reason|reason:/i);
});

test('lifecycle controls are limited to COUNTING and REVIEW; cancelled is read-only and posting stays out of scope', () => {
  assert.match(component, /data\.session\?\.status === "COUNTING"/);
  assert.match(component, /data\.session\?\.status === "REVIEW"/);
  assert.match(component, /data\.session\.status === "CANCELLED"[\s\S]*dibatalkan dan sekarang baca-saja/);
  assert.match(component, /data\.session\.status === "POSTED"[\s\S]*hanya dapat dilihat/);
  assert.match(component, /"Sedang direview"/);
  assert.doesNotMatch(action + component, /POST_SESSION|approved|APPROVED|RECONCILE_MOVEMENT|REVERSE_MOVEMENT|stock_movements/);
  assert.match(reader, /rpc\("stock_opname_progress_counts", \{ p_session_id: session\.id \}\)/);
  assert.match(component, /data\.items\.map/);
  assert.doesNotMatch(reader, /fetchAll|for\s*\([^)]*items/);
  const itemRetry = component.slice(component.indexOf('{pending && <div className="stock-opname-pending-request"'), component.indexOf('{canCount && !pending && !isEditing'));
  assert.match(itemRetry, /canCount \? <button/);
  assert.match(itemRetry, /Retry hitungan hanya tersedia saat sesi berada dalam tahap penghitungan/);
});

test('lifecycle result messages distinguish the operation without claiming projection freshness', () => {
  assert.equal(lifecycleOperationLabel('SUBMIT_REVIEW'), 'Ajukan review');
  assert.equal(lifecycleOperationLabel('RETURN_TO_COUNTING'), 'Kembali ke penghitungan');
  assert.equal(lifecycleOperationLabel('CANCEL_SESSION'), 'Batalkan sesi');
  assert.match(action, /Kelengkapan berubah atau sesi tidak lagi dalam tahap penghitungan/);
  assert.match(action, /Sesi tidak lagi berada dalam tahap review/);
  assert.match(action, /Sesi tidak lagi dapat dibatalkan/);
});
