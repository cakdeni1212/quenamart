import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (path) => readFileSync(new URL(path, import.meta.url), 'utf8');
const listPage = read('../app/(workspace)/pembelian/barang-masuk/page.tsx');
const reader = read('../src/lib/purchasing/receipt-read.ts');
const listReader = reader.slice(reader.indexOf('export async function readReceiptList'), reader.indexOf('export async function readReceiptDetail'));
const editor = read('../src/components/purchasing/purchase-receipt-editor.tsx');
const supplier = read('../src/components/purchasing/supplier-management.tsx');
const styles = read('../app/globals.css');
const model = read('../src/lib/purchasing/receipt-model.ts');

test('receipt list preserves bounded reads and applies filters in the database', () => {
  assert.match(reader, /\.range\(\(page - 1\) \* RECEIPT_PAGE_SIZE, page \* RECEIPT_PAGE_SIZE - 1\)/);
  assert.match(reader, /\.ilike\("receipt_reference"/);
  assert.match(reader, /\.ilike\("display_name"/);
  assert.match(reader, /\.gte\("received_at"/);
  assert.doesNotMatch(listReader, /purchase_receipt_items/);
  assert.match(listReader, /\.range\(\(page - 1\) \* RECEIPT_PAGE_SIZE, page \* RECEIPT_PAGE_SIZE - 1\)/);
  assert.match(listPage, /name="status"/);
  assert.match(listPage, /name="from"/);
  assert.match(listPage, /name="to"/);
  assert.match(listReader, /purchase_receipt_list_details/);
  assert.match(listPage, /row\.stock_added/);
  assert.doesNotMatch(listReader, /\.from\("purchase_receipt_items"\)/);
});

test('successful posting returns to the list with a server-verified success summary', () => {
  assert.match(editor, /router\.replace\(`\/pembelian\/barang-masuk\?posted=/);
  assert.match(editor, /POST_SUCCESS:\$\{receipt\.id\}/);
  assert.match(listPage, /row\.id === postedId && row\.status === "POSTED"/);
  assert.match(listPage, /<ReceiptPostSuccess/);
  assert.match(editor, /itemCount: items\.length, stockAdded: totalStock/);
  assert.match(read('../src/components/purchasing/receipt-post-success.tsx'), /Barang masuk \{reference\} berhasil diposting/);
  const banner = read('../src/components/purchasing/receipt-post-success.tsx');
  assert.match(banner, /stok bertambah \$\{formatReceiptQuantity\(value\.stockAdded\)\}/);
  assert.match(banner, /Lihat detail/);
  assert.match(banner, /Barang masuk baru/);
});

test('receipt editor preserves exact barcode behavior and adds explicit scan/search and review stages', () => {
  assert.match(editor, /resolveReceiptBarcode\(barcode\)/);
  assert.match(editor, /BARCODE_NOT_FOUND/);
  assert.match(editor, /BARCODE_AMBIGUOUS/);
  assert.match(editor, /sudah ada pada draf/);
  assert.match(editor, /280\)/);
  assert.match(editor, /Scan Barcode/);
  assert.match(editor, /Cari Produk/);
  assert.match(editor, /Review Barang Masuk/);
  assert.match(editor, /PERIKSA SEBELUM POSTING/);
  assert.match(editor, /Posting Barang Masuk/);
  assert.match(editor, /issueReceiptPost\(receipt\.id\)/);
  assert.match(editor, /applyReceiptPost\(requestId\)/);
});

test('posted receipt is a text-only result with item stock summary and secondary timeline', () => {
  const resultBranch = editor.slice(editor.indexOf('if (readOnly) return'), editor.indexOf('return <section className="purchase-receipt-editor'));
  assert.match(resultBranch, /Waktu diposting/);
  assert.match(resultBranch, /Barang yang diterima/);
  assert.match(resultBranch, /purchase-posted-table/);
  assert.match(resultBranch, /Total stok bertambah/);
  assert.doesNotMatch(resultBranch, /<input/);
  assert.match(editor, /Riwayat barang masuk/);
});

test('desktop tables and responsive phone cards are provided for receipts and suppliers', () => {
  assert.match(listPage, /purchase-receipt-table/);
  assert.match(listPage, /purchase-receipt-mobile-list/);
  assert.match(supplier, /purchase-supplier-table/);
  assert.match(supplier, /purchase-supplier-mobile-list/);
  assert.match(styles, /@media\(max-width:760px\).*purchase-receipt-mobile-list/s);
  assert.match(styles, /purchase-draft-actions/);
  assert.match(styles, /purchase-posted-mobile-list/);
});

test('GUDANG receipt presentation stays operational only while manager financial columns remain role-gated', () => {
  assert.match(model, /acceptedQty \+ bonusQty/);
  assert.doesNotMatch(editor, /purchase_price|unit_cost|\bhpp\b|invoice_total/i);
  assert.match(listPage, /isManager && <>[\s\S]*Total Nota[\s\S]*Pembayaran/);
  assert.match(reader, /if \(!canAccessSection\(profile\.role, "pembelian"\)\)/);
});
