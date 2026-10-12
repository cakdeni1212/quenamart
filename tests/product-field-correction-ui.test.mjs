import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import {
  canIssueCorrectionIntent,
  correctionReviewEligible,
  forgetCorrectionRequestId,
  formatIndonesianMoney,
  formatIndonesianMoneyInput,
  parseCorrectionIntentInput,
  parseIndonesianMoney,
  readStoredCorrectionRequestId,
  storeCorrectionRequestId,
} from '../src/lib/product-audit/correction-intent-core.ts';

const page = readFileSync(new URL('../app/(workspace)/audit-produk/[productId]/page.tsx', import.meta.url), 'utf8');
const component = readFileSync(new URL('../src/components/product-audit/field-correction-controls.tsx', import.meta.url), 'utf8');
const actions = readFileSync(new URL('../src/app/actions/product-field-correction-intents.ts', import.meta.url), 'utf8');
const readModel = readFileSync(new URL('../src/lib/product-audit/read.ts', import.meta.url), 'utf8');

const ids = {
  product: '2fdb6fbb-e383-4bed-9eb7-7a55627eb995',
  source: 'c14f4afa-c114-4d5e-acae-c232a82016d5',
  outlet: '52ea55dd-5608-4066-9e17-91666de1d78d',
  request: 'f52a0ad4-2ae6-4ae7-8ef5-49e5fc7d7c09',
};

function memoryStorage() {
  const values = new Map();
  return {
    values,
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: (key) => values.delete(key),
  };
}

test('correction controls require the exact in-progress review and a source row', () => {
  assert.equal(correctionReviewEligible('SEDANG_DICEK', ids.source), true);
  assert.equal(correctionReviewEligible('BELUM_DICEK', ids.source), false);
  assert.equal(correctionReviewEligible('SUDAH_DIVERIFIKASI', ids.source), false);
  assert.equal(correctionReviewEligible('SEDANG_DICEK', null), false);
  assert.match(component, /correctionReviewEligible\(reviewStatus, sourceRowId\)/);
  assert.match(page, /FieldCorrectionControls/);
});

test('correction role matrix keeps GUDANG nonfinancial and KASIR denied', () => {
  for (const field of ['barcode', 'rack_label']) assert.equal(canIssueCorrectionIntent('GUDANG', field), true);
  assert.equal(canIssueCorrectionIntent('GUDANG', 'hpp'), false);
  assert.equal(canIssueCorrectionIntent('GUDANG', 'selling_price'), false);
  for (const field of ['barcode', 'rack_label', 'hpp', 'selling_price']) assert.equal(canIssueCorrectionIntent('KASIR', field), false);
  assert.match(page, /const fieldOrder = manager[\s\S]*\["barcode", "rack_label"\]/);
  assert.match(readModel, /const allowedFields: FieldKey\[\] = manager/);
  assert.match(readModel, /: \["barcode", "rack_label", "quantity", "minimum_quantity"\]/);
});

test('stock and minimum stock remain informational and are never correction fields', () => {
  assert.match(page, /Nilai ini merupakan catatan snapshot iPos\. Perubahan stok belum tersedia/);
  assert.doesNotMatch(component, /quantity|minimum_quantity/);
});

test('barcode choices are explicit and text inputs preserve leading zeros', () => {
  assert.match(component, /Tambah barcode lain/);
  assert.match(component, /Perbaiki barcode iPos/);
  assert.match(component, /ADD_ALIAS/);
  assert.match(component, /REPLACE_SOURCE/);
  assert.match(component, /moneyField \? <RupiahInput id=\{inputId\} name="correctedValue"/);
  assert.match(component, /<input id=\{inputId\} name="correctedValue" type="text"/);
  assert.match(component, /Barcode ini sudah digunakan produk lain\./);
  assert.doesNotMatch(component, /barcode utama|primary barcode/i);
  assert.match(page, /sourceDisplay=\{sourceDisplay\(record\)\}/);
});

test('Indonesian money parser handles exact grouping and decimal examples without float parsing', () => {
  assert.deepEqual(parseIndonesianMoney('15000'), { value: 15000, canonical: '15000.00' });
  assert.deepEqual(parseIndonesianMoney('15.000'), { value: 15000, canonical: '15000.00' });
  assert.deepEqual(parseIndonesianMoney('15.000,50'), { value: 15000.5, canonical: '15000.50' });
  assert.deepEqual(parseIndonesianMoney('010000.50'), { value: 10000.5, canonical: '10000.50' });
  assert.equal(parseIndonesianMoney('15,000.50'), null);
  assert.equal(parseIndonesianMoney('-100'), null);
  assert.equal(formatIndonesianMoney('15000.50'), 'Rp 15.000,5');
  assert.equal(formatIndonesianMoney('15.000'), 'Rp 15');
  assert.equal(formatIndonesianMoneyInput('15.000'), 'Rp 15.000');
});

test('correction parser requires nonblank reason and preserves barcode strings', () => {
  const form = new FormData();
  form.set('productId', ids.product);
  form.set('outletId', '');
  form.set('fieldKey', 'barcode');
  form.set('sourceImportRowId', ids.source);
  form.set('correctedValue', '000012345');
  form.set('reason', '  Barcode pada kemasan  ');
  form.set('barcodeOperation', 'ADD_ALIAS');
  const parsed = parseCorrectionIntentInput(form);
  assert.equal(parsed.correctedValue, '000012345');
  assert.equal(parsed.reason, 'Barcode pada kemasan');
  form.set('reason', '   ');
  assert.equal(parseCorrectionIntentInput(form), null);
});

test('opaque request ID survives reload and is consumed only after confirmed completion/conflict', () => {
  const storage = memoryStorage();
  storeCorrectionRequestId(storage, ids.product, 'hpp', ids.request);
  // A remounted component reads the same device storage and recovers only the UUID.
  assert.equal(readStoredCorrectionRequestId(storage, ids.product, 'hpp'), ids.request);
  assert.equal(storage.values.size, 1);
  assert.equal([...storage.values.values()][0], ids.request);
  forgetCorrectionRequestId(storage, ids.product, 'hpp');
  assert.equal(readStoredCorrectionRequestId(storage, ids.product, 'hpp'), null);
  storeCorrectionRequestId(storage, ids.product, 'rack_label', ids.request);
  assert.equal(readStoredCorrectionRequestId(storage, ids.product, 'hpp'), null);
});

test('recovered UUID is applied only after actor-scoped metadata matches its product and field', () => {
  assert.match(component, /summary && summary\.requestId === restoredId && summary\.productId === productId && summary\.fieldKey === fieldKey/);
  assert.match(component, /setRecoveryBlocked\(true\)/);
  assert.match(component, /Permintaan tersimpan belum dapat diverifikasi/);
});

test('component applies by UUID only, preserves the token on unknown result, and blocks duplicate submits', () => {
  assert.match(component, /applyProductFieldCorrectionIntentAction\(issued\.requestId\)/);
  assert.match(component, /applyProductFieldCorrectionIntentAction\(requestId\)/);
  assert.match(component, /busy\.current/);
  assert.match(component, /Hasil koreksi belum dapat dipastikan/);
  assert.match(component, /storeCorrectionRequestId\(window\.localStorage, productId, fieldKey, issued\.requestId\)/);
  assert.doesNotMatch(component, /localStorage\.(setItem|set)\([^\n]*(value|reason|HPP|corrected)/i);
  assert.doesNotMatch(component, /sessionStorage|document\.cookie/);
});

test('stale source is not retargeted and uses the requested refresh message', () => {
  assert.match(actions, /Data sumber berubah\. Muat ulang pemeriksaan sebelum melanjutkan\./);
  assert.match(component, /Data sumber berubah\. Muat ulang pemeriksaan sebelum melanjutkan\./);
  assert.match(component, /router\.refresh\(\)/);
  assert.match(actions, /field\.sourceRowId !== input\.sourceImportRowId/);
});

test('findings stay separate from review and correction success language', () => {
  assert.match(page, /Temuan sumber tidak berubah karena pemeriksaan manual/);
  assert.match(page, /Cek petugas tidak menghapus temuan iPos/);
  assert.match(component, /status pemeriksaan diperbarui/);
  assert.doesNotMatch(component, /finding.*resolved|temuan.*selesai/i);
});

test('actions use the session Supabase client and never a service-role client', () => {
  assert.match(actions, /createClient\(\)/);
  assert.doesNotMatch(actions, /supabase\/admin|service_role|SUPABASE_SERVICE_ROLE/i);
  assert.match(actions, /getProfile\(\)/);
});
