import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import test from 'node:test';

const migration = readFileSync(new URL('../supabase/migrations/20260929240000_purchasing_receipt_draft_cancellation_v1.sql', import.meta.url), 'utf8');
const actions = readFileSync(new URL('../src/lib/purchasing/actions.ts', import.meta.url), 'utf8');
const listPage = readFileSync(new URL('../app/(workspace)/pembelian/barang-masuk/page.tsx', import.meta.url), 'utf8');
const actionComponent = readFileSync(new URL('../src/components/purchasing/receipt-list-actions.tsx', import.meta.url), 'utf8');
const editor = readFileSync(new URL('../src/components/purchasing/purchase-receipt-editor.tsx', import.meta.url), 'utf8');
const reader = readFileSync(new URL('../src/lib/purchasing/receipt-read.ts', import.meta.url), 'utf8');

test('cancellation is a terminal audited state; no physical delete path is introduced', () => {
  assert.match(migration, /CHECK \(status IN \('DRAFT','POSTED','CANCELLED'\)\)/);
  assert.match(migration, /CREATE FUNCTION public\.purchase_receipt_cancel_draft/);
  assert.match(migration, /status='CANCELLED',cancelled_by=v_actor,cancelled_at=now\(\)/);
  assert.match(migration, /INSERT INTO public\.purchase_receipt_events\(receipt_id,event_type,actor_id,note\)\s+VALUES\(p_receipt_id,'CANCELLED',v_actor/);
  assert.match(migration, /Purchase receipt history cannot be deleted/);
  assert.match(migration, /status IN \('POSTED','CANCELLED'\)/);
  assert.doesNotMatch(migration, /DELETE\s+FROM\s+public\.purchase_receipts/i);
  assert.doesNotMatch(actions, /\.from\("purchase_receipts"\)\.delete\(/);
});

test('database cancellation is manager-only and rejects posted, movement-backed, and finalized financial state', () => {
  assert.match(migration, /v_role NOT IN \('OWNER'::public\.user_role,'ADMIN'::public\.user_role\)/);
  assert.match(migration, /v_receipt\.status='POSTED'[\s\S]*Posted purchase receipt cannot be cancelled/);
  assert.match(migration, /stock_movements m JOIN public\.purchase_receipt_items ri/);
  assert.match(migration, /i\.status='DRAFT'/);
  assert.match(migration, /supplier_payables p WHERE p\.invoice_id=v_invoice_id/);
  assert.match(migration, /supplier_payments p JOIN public\.supplier_payment_allocations/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.purchase_receipt_cancel_draft\(uuid\) TO authenticated/);
  assert.match(actions, /authorized\(true\)/);
});

test('linked draft invoices are cancelled without deleting audit rows and document cleanup is private, bounded, and retryable', () => {
  assert.match(migration, /UPDATE public\.purchase_invoices SET status='CANCELLED'/);
  assert.match(migration, /INSERT INTO public\.purchase_invoice_events\(invoice_id,event_type,actor_id,note\)[\s\S]*'CANCELLED'/);
  assert.match(migration, /cleanup_status='CLEANUP_PENDING'/);
  assert.match(migration, /purchase_invoice_document_cleanup_mark/);
  assert.match(migration, /request\.jwt\.claim\.role[\s\S]*'service_role'/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.purchase_invoice_document_cleanup_mark\(uuid,boolean\) TO service_role/);
  assert.match(actions, /createAdminClient\(\)\.storage\.from\("quena-purchasing-invoices"\)\.remove\(\[storagePath\]\)/);
  assert.match(actions, /purchase_invoice_document_cleanup_mark/);
  assert.match(actions, /cleanupCancelledInvoiceDocuments/);
});

test('private document cleanup succeeds, remains pending on failure, retries, and rejects arbitrary paths', () => {
  const moduleUrl = new URL('../src/lib/purchasing/document-cleanup.ts', import.meta.url).href;
  const source = `
    import assert from 'node:assert/strict';
    import { cleanupCancelledInvoiceDocuments } from ${JSON.stringify(moduleUrl)};
    const invoice = '11111111-1111-4111-8111-111111111111';
    const document = { documentId: '22222222-2222-4222-8222-222222222222', storagePath: 'invoices/' + invoice + '/33333333-3333-4333-8333-333333333333.jpg' };
    let removeOk = true;
    let marks = [];
    const remove = async (path) => { assert.equal(path, document.storagePath); return removeOk; };
    const mark = async (_id, deleted) => { marks.push(deleted); return true; };
    assert.equal(await cleanupCancelledInvoiceDocuments(invoice, [document], remove, mark), false);
    removeOk = false;
    assert.equal(await cleanupCancelledInvoiceDocuments(invoice, [document], remove, mark), true);
    removeOk = true;
    assert.equal(await cleanupCancelledInvoiceDocuments(invoice, [document], remove, mark), false);
    assert.equal(marks.join(','), 'true,false,true');
    let removed = false;
    const pending = await cleanupCancelledInvoiceDocuments(invoice, [{ ...document, storagePath: 'invoices/other/path.jpg' }], async () => { removed = true; return true; }, async () => true);
    assert.equal(pending, true);
    assert.equal(removed, false);
  `;
  execFileSync(process.execPath, ['--disable-warning=ExperimentalWarning', '--experimental-strip-types', '--input-type=module', '-e', source], { stdio: 'pipe' });
});

test('cancelled receipts are hidden by default, manager-filterable, and read-only in detail', () => {
  assert.match(reader, /query\.neq\("status", "CANCELLED"\)/);
  assert.match(reader, /filters\.status === "CANCELLED" && manager/);
  assert.match(listPage, /<option value="CANCELLED">Dibatalkan<\/option>/);
  assert.match(listPage, /canCancel=\{isManager && row\.status === "DRAFT"\}/);
  assert.match(actionComponent, /Batalkan draf pembelian ini\?/);
  assert.match(actionComponent, /Draf tidak akan memengaruhi stok dan akan dipindahkan ke riwayat pembatalan\./);
  assert.match(actionComponent, /Ya, Batalkan Draf/);
  assert.match(editor, /cancelled && manager && receipt\.document_cleanup_pending/);
  assert.match(editor, /Dibatalkan oleh/);
  assert.match(editor, /Draf dibatalkan/);
});
