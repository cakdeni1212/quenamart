import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { canAccessSection } from '../src/lib/auth/roles.ts';
import {
  formatReceiptQuantity,
  isUuid,
  normalizeReceiptDraftItems,
  parseReceiptPage,
  parseReceiptQuantity,
  receiptPostRetryKey,
  receiptStockQuantity,
} from '../src/lib/purchasing/receipt-model.ts';

const migration = readFileSync(new URL('../supabase/migrations/20260929220000_purchasing_receipts_v1.sql', import.meta.url), 'utf8');
const actions = readFileSync(new URL('../src/lib/purchasing/actions.ts', import.meta.url), 'utf8');
const reader = readFileSync(new URL('../src/lib/purchasing/receipt-read.ts', import.meta.url), 'utf8');
const editor = readFileSync(new URL('../src/components/purchasing/purchase-receipt-editor.tsx', import.meta.url), 'utf8');

test('purchasing workspace role matrix allows OWNER ADMIN GUDANG and denies KASIR', () => {
  for (const role of ['OWNER', 'ADMIN', 'GUDANG']) assert.equal(canAccessSection(role, 'pembelian'), true);
  assert.equal(canAccessSection('KASIR', 'pembelian'), false);
  assert.match(migration, /current_active_user_role\(\) IS NULL[\s\S]*current_active_user_role\(\) NOT IN \('OWNER'::public\.user_role, 'ADMIN'::public\.user_role\)/);
  assert.match(migration, /v_role IS NULL OR v_role NOT IN \('OWNER'::public\.user_role, 'ADMIN'::public\.user_role, 'GUDANG'::public\.user_role\)/);
});

test('receipt quantities use 3 decimals and only accepted plus bonus enter stock', () => {
  assert.equal(parseReceiptQuantity('1.125'), 1.125);
  assert.equal(parseReceiptQuantity('1.001'), 1.001);
  assert.equal(parseReceiptQuantity('1.0010'), 1.001);
  assert.equal(parseReceiptQuantity('1.1234'), null);
  assert.equal(parseReceiptQuantity('-0.001'), null);
  assert.equal(parseReceiptQuantity('0'), 0);
  assert.equal(receiptStockQuantity('95', '2'), 97);
  assert.equal(formatReceiptQuantity('2.500'), '2,5');
  assert.match(migration, /accepted_quantity \+ bonus_quantity/);
  assert.doesNotMatch(migration, /rejected_quantity\s*\+\s*short_quantity/);
});

test('draft payload is bounded, UUID validated, unique by product, and requires a positive physical quantity field', () => {
  const id = 'c0000000-0000-4000-8000-000000000001';
  assert.equal(isUuid(id), true);
  assert.equal(isUuid('not-a-uuid'), false);
  const valid = normalizeReceiptDraftItems([{ product_id: id, accepted_quantity: '0', bonus_quantity: '2', rejected_quantity: '1', short_quantity: null }]);
  assert.equal(valid?.[0].bonus_quantity, '2');
  assert.equal(normalizeReceiptDraftItems([
    { product_id: id, accepted_quantity: '1', bonus_quantity: '0', rejected_quantity: '0', short_quantity: null },
    { product_id: id, accepted_quantity: '1', bonus_quantity: '0', rejected_quantity: '0', short_quantity: null },
  ]), null);
  assert.equal(normalizeReceiptDraftItems([{ product_id: id, accepted_quantity: '0', bonus_quantity: '0', rejected_quantity: '0', short_quantity: null }]), null);
  assert.equal(parseReceiptPage('0'), 1);
  assert.equal(parseReceiptPage('8'), 8);
});

test('retry UUID scope includes receipt and POST_PURCHASE_RECEIPT; uncertain apply retry is separated from issue', () => {
  const key = receiptPostRetryKey('c0000000-0000-4000-8000-000000000001');
  assert.equal(key, 'quena:purchasing:POST_PURCHASE_RECEIPT:c0000000-0000-4000-8000-000000000001');
  assert.match(editor, /sessionStorage\.setItem\(retryKey, issued\.requestId\)/);
  assert.match(editor, /sessionStorage\.getItem\(retryKey\)/);
  assert.match(editor, /if \(retryRequest\).*applyRequest\(retryRequest\)/s);
  assert.match(editor, /applyReceiptPost\(requestId\)/);
  assert.match(editor, /applyRequest\(pendingRequest\)/);
  assert.match(editor, /Ulangi posting dengan permintaan yang sama/);
  assert.match(editor, /router\.replace\(`\/pembelian\/barang-masuk\?posted=/);
  assert.match(actions, /apply_purchase_receipt_post_intent/);
  assert.match(actions, /issue_purchase_receipt_post_intent/);
});

test('purchasing API avoids direct stock DML and costs, and stock writes share the transaction ledger', () => {
  assert.match(migration, /CREATE FUNCTION public\.apply_purchase_receipt_post_intent/);
  assert.match(migration, /stock_movement_batches/);
  assert.match(migration, /stock_movements/);
  assert.match(migration, /stock_apply_balance_delta/);
  assert.match(migration, /stock_balance_projection_events/);
  assert.match(migration, /purchase_receipt_item_id/);
  assert.match(migration, /BEGIN;/);
  assert.match(migration, /COMMIT;/);
  assert.doesNotMatch(migration, /UPDATE public\.product_inventory/i);
  assert.doesNotMatch(migration, /purchase_price|unit_cost|hpp|invoice_total/i);
  assert.match(migration, /REVOKE ALL ON public\.suppliers, public\.purchase_receipts, public\.purchase_receipt_items/);
  assert.match(migration, /current_active_user_role\(\) <> 'GUDANG'::public\.user_role OR is_active\s+OR EXISTS \(SELECT 1 FROM public\.purchase_receipts/);
  assert.match(migration, /REVOKE ALL ON FUNCTION public\.apply_purchase_receipt_post_intent/);
  assert.match(reader, /\.range\(\(page - 1\) \* RECEIPT_PAGE_SIZE, page \* RECEIPT_PAGE_SIZE - 1\)/);
});

test('draft is editable only before post; posted detail is rendered as a read-only result and posting requires confirmation', () => {
  assert.match(migration, /Posted purchase receipts are immutable/);
  assert.match(migration, /Receipt items are editable only while draft/);
  assert.match(editor, /const readOnly = receipt\.status === "POSTED"/);
  assert.match(editor, /if \(readOnly\) return <section className="purchase-receipt-result surface-card">/);
  assert.doesNotMatch(editor, /disabled=\{readOnly\}/);
  assert.match(editor, /window\.confirm\("Posting akan menambah stok efektif/);
  assert.match(editor, /accepted_quantity.*bonus_quantity/);
});

test('posting is actor-bound, checks a draft content snapshot, locks outlet projections in product order, and writes one batch', () => {
  assert.match(migration, /actor_id=v_actor FOR UPDATE/);
  assert.match(migration, /operation_key <> 'POST_PURCHASE_RECEIPT'/);
  assert.match(migration, /ORDER BY i\.product_id LOOP/);
  assert.match(migration, /content_hash/);
  assert.match(migration, /operation_request_id,created_by\)\s*VALUES\(v_period\.id,v_receipt\.outlet_id,'PURCHASING',v_req\.request_id,v_actor\)/);
  assert.match(migration, /'RECEIPT_CHANGED'/);
  assert.match(migration, /state='COMPLETED'/);
});
