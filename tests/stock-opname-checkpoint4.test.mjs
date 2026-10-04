import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { canAccessSection } from '../src/lib/auth/roles.ts';
import { normalizeExceptionReason, transitionItemEditorAfterApply } from '../src/lib/stock/opname-count-model.ts';

const action = readFileSync(new URL('../src/lib/stock/opname-item-action.ts', import.meta.url), 'utf8');
const countAction = readFileSync(new URL('../src/lib/stock/opname-count-action.ts', import.meta.url), 'utf8');
const reader = readFileSync(new URL('../src/lib/stock/opname-count-read.ts', import.meta.url), 'utf8');
const workspace = readFileSync(new URL('../src/components/stock/stock-opname-counting.tsx', import.meta.url), 'utf8');
const migration = readFileSync(new URL('../supabase/migrations/20260929200000_stock_opname_revision_guard_v1.sql', import.meta.url), 'utf8');

test('OWNER, ADMIN, and GUDANG can use opname item actions; KASIR is denied by action-side profile checks', () => {
  for (const role of ['OWNER', 'ADMIN', 'GUDANG']) assert.equal(canAccessSection(role, 'stok'), true);
  assert.equal(canAccessSection('KASIR', 'stok'), false);
  assert.match(action, /getProfile\(\)[\s\S]*canAccessSection\(profile\.role, "stok"\)/);
  assert.match(action, /if \(!profile\) return invalid\("Anda tidak memiliki akses/);
});

test('REBASE_ITEM and REVIEW_EXCEPTION send exact existing payloads then apply the same actor-bound request UUID', () => {
  assert.match(action, /p_operation_key: input\.operation/);
  assert.match(action, /session_id: input\.sessionId,[\s\S]*product_id: input\.productId,[\s\S]*expected_revision: input\.expectedRevision/);
  assert.match(action, /payload\.reason = reason!/);
  assert.match(action, /rpc\("apply_stock_operation_intent", \{ p_request_id: requestId \}\)/);
  assert.match(workspace, /savePendingValue\(pendingKey\(data\.session\.id, item\.productId\), JSON\.stringify\(pending\)\)/);
  assert.match(workspace, /finishApply\(item\.productId, pending\)/);
  assert.match(workspace, /pending\.operation === "RECORD_COUNT"[\s\S]*applyRecordCountIntent[\s\S]*applyOpnameItemIntent/);
  assert.match(migration, /v_req\.state in \('COMPLETED'::public\.stock_request_state, 'STALE'::public\.stock_request_state/);
});

test('exception reason is trimmed and whitespace-only values are rejected before issuing', () => {
  assert.equal(normalizeExceptionReason('  Barang belum dapat dipastikan  '), 'Barang belum dapat dipastikan');
  assert.equal(normalizeExceptionReason('   \n '), null);
  assert.match(action, /normalizeExceptionReason\(input\.reason \?\? ""\)/);
  assert.match(action, /if \(input\.operation === "REVIEW_EXCEPTION" && !reason\)/);
  assert.match(workspace, /disabled=\{!itemEditor\.exceptionReasonDraft\.trim\(\)/);
  assert.match(workspace, /Alasan pengecualian \(wajib\)/);
});

test('revision mismatch and projection staleness remain distinct; revision conflict does not mark recount', () => {
  assert.match(action, /result\.reason === "ITEM_REVISION_MISMATCH"/);
  assert.match(action, /kind: "stale-item"/);
  assert.match(action, /result\.recountRequired === true/);
  assert.match(action, /kind: "stale-baseline"/);
  const mismatch = action.slice(action.indexOf('result.reason === "ITEM_REVISION_MISMATCH"'), action.indexOf('result.recountRequired === true'));
  assert.doesNotMatch(mismatch, /recountRequired\s*:/);
  assert.match(migration, /'reason', 'ITEM_REVISION_MISMATCH',[\s\S]*'refreshRequired', true/);
  assert.match(migration, /if v_item\.revision_no <> v_expected_revision then/);
  assert.match(migration, /update public\.stock_operation_requests[\s\S]*return v_result;/);
});

test('stale items require explicit rebase before counting; successful rebase clears old count and exception fields', () => {
  assert.match(workspace, /item\.requiresRecount && operation === "REVIEW_EXCEPTION"/);
  assert.match(workspace, /item\.requiresRecount \? "Perlu hitung ulang"/);
  assert.match(workspace, /Perbarui baseline & hitung ulang/);
  assert.match(workspace, /const editable = canCount && !item\.requiresRecount/);
  assert.match(migration, /baseline_quantity = v_projection\.effective_quantity,[\s\S]*physical_quantity = null,[\s\S]*requires_recount = false,[\s\S]*exception_reason = null/);
  assert.match(migration, /'BASELINE_REFRESHED'/);
  assert.match(action, /Baseline diperbarui\. Masukkan hitungan fisik baru/);
  assert.match(countAction, /p_operation_key: "RECORD_COUNT"/);
});

test('successful rebase clears a barcode-focused stale count draft and requires a fresh explicit count', () => {
  const barcodeFocusedStaleItem = {
    editingProduct: 'product-a',
    quantityDraft: '12.375',
    exceptionProduct: 'product-a',
    exceptionReasonDraft: 'old exception reason',
  };
  const afterRebase = transitionItemEditorAfterApply(barcodeFocusedStaleItem, 'product-a', 'REBASE_ITEM', true);
  assert.deepEqual(afterRebase, {
    editingProduct: null,
    quantityDraft: '',
    exceptionProduct: null,
    exceptionReasonDraft: '',
  });
  assert.match(workspace, /setItemEditor\(\(current\) => transitionItemEditorAfterApply\([\s\S]*result\.kind === "success"/);
  assert.match(workspace, /item.requiresRecount && operation === "REVIEW_EXCEPTION"/);
});

test('successful exception review clears the old physical count editor and reason input draft', () => {
  const beforeReview = {
    editingProduct: 'product-b',
    quantityDraft: '0.5',
    exceptionProduct: 'product-b',
    exceptionReasonDraft: 'replacement reason',
  };
  assert.deepEqual(transitionItemEditorAfterApply(beforeReview, 'product-b', 'REVIEW_EXCEPTION', true), {
    editingProduct: null,
    quantityDraft: '',
    exceptionProduct: null,
    exceptionReasonDraft: '',
  });
  assert.match(workspace, /Alasan pengecualian: \$\{item\.exceptionReason\}/);
});

test('failed, uncertain, stale, unrelated, and count results preserve item editor drafts', () => {
  const draft = {
    editingProduct: 'product-a',
    quantityDraft: '7.125',
    exceptionProduct: 'product-a',
    exceptionReasonDraft: 'keep this draft',
  };
  for (const operation of ['REBASE_ITEM', 'REVIEW_EXCEPTION']) {
    assert.deepEqual(transitionItemEditorAfterApply(draft, 'product-a', operation, false), draft);
  }
  assert.deepEqual(transitionItemEditorAfterApply(draft, 'product-a', 'RECORD_COUNT', true), draft);
  const otherItemDraft = { ...draft, editingProduct: 'product-b', exceptionProduct: 'product-b' };
  assert.deepEqual(transitionItemEditorAfterApply(otherItemDraft, 'product-a', 'REBASE_ITEM', true), otherItemDraft);
});

test('REVIEW_EXCEPTION is explicit, never quantity zero, and does not invoke movement or projection actions', () => {
  assert.match(workspace, /Tandai pengecualian/);
  assert.match(workspace, /Simpan pengecualian/);
  assert.match(workspace, /Pengecualian bukan hitungan nol/);
  assert.match(action, /Pengecualian dicatat\. Item tetap tanpa hitungan fisik/);
  assert.match(migration, /'EXCEPTION_REVIEWED'/);
  assert.match(migration, /exception_reason = v_payload->>'reason'[\s\S]*physical_quantity = null/);
  assert.doesNotMatch(action + countAction, /RECONCILE_MOVEMENT|REVERSE_MOVEMENT|POST_SESSION|stock_balance_projection|stock_movements/);
  assert.doesNotMatch(action, /\.from\("stock_opname_items"\)\s*\.(insert|update|upsert|delete)/i);
});

test('progress comes only from the aggregate RPC and presents all locked counts, including recount-required', () => {
  assert.match(reader, /rpc\("stock_opname_progress_counts", \{ p_session_id: session\.id \}\)/);
  for (const key of ['total', 'counted', 'exception', 'accounted', 'remaining', 'recount_required']) {
    assert.match(reader, new RegExp(`readCount\\("${key}"\\)`));
  }
  assert.match(workspace, /data\.progress\.total/);
  assert.match(workspace, /data\.progress\.counted/);
  assert.match(workspace, /data\.progress\.exception/);
  assert.match(workspace, /data\.progress\.accounted/);
  assert.match(workspace, /data\.progress\.remaining/);
  assert.match(workspace, /data\.progress\.recountRequired/);
  assert.match(migration, /physical_quantity is not null and not i\.requires_recount/);
  assert.match(migration, /exception_reviewed_at is not null[\s\S]*not i\.requires_recount/);
  assert.doesNotMatch(reader, /const count = \(\)|countedResult|recountResult/);
  assert.match(reader, /progressError = "Ringkasan progress/);
});

test('read path remains bounded and batched, without HPP or financial fields', () => {
  assert.match(reader, /STOCK_OPNAME_COUNT_PAGE_SIZE/);
  assert.match(reader, /\.range\(\(query\.page - 1\) \* STOCK_OPNAME_COUNT_PAGE_SIZE/);
  assert.match(reader, /\.in\("product_id", productIds\)/);
  assert.doesNotMatch(reader, /for\s*\([^)]*productIds|Promise\.all\([^)]*map\(/);
  assert.doesNotMatch(reader + action + workspace, /\bhpp\b|product_costs|profit|service_role|cost_price/i);
});

test('barcode scanning still focuses the included item and never changes its quantity', () => {
  assert.match(workspace, /rpc\("resolve_stock_barcode"/);
  assert.match(workspace, /BARCODE_NOT_FOUND/);
  assert.match(workspace, /BARCODE_AMBIGUOUS/);
  assert.match(workspace, /Produk ini tidak termasuk dalam sesi opname/);
  assert.match(workspace, /setFocusedProduct\(match\.product_id\)/);
  assert.match(workspace, /Pemindaian hanya memilih item; jumlah tidak berubah/);
  assert.doesNotMatch(workspace, /physicalQuantity\s*\+\s*1|setQuantity\([^)]*\+\s*1/);
});

test('item action remains limited to Checkpoint 4 operations while later lifecycle/post controls live elsewhere', () => {
  assert.match(action, /"REBASE_ITEM" \| "REVIEW_EXCEPTION"/);
  assert.doesNotMatch(action, /SUBMIT_REVIEW|RETURN_TO_COUNTING|CANCEL_SESSION|POST_SESSION|RECONCILE_MOVEMENT|REVERSE_MOVEMENT/);
  assert.match(workspace, /POST_SESSION/);
  assert.doesNotMatch(workspace, /RECONCILE_MOVEMENT|REVERSE_MOVEMENT/);
  assert.doesNotMatch(action + workspace, /service_role|SUPABASE_SERVICE_ROLE_KEY/);
});
