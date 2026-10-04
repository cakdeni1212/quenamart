import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { canAccessSection } from '../src/lib/auth/roles.ts';
import { parseStockOpnameListQuery, STOCK_OPNAME_LIST_PAGE_SIZE } from '../src/lib/stock/opname-list-model.ts';

const model = readFileSync(new URL('../src/lib/stock/opname-list-model.ts', import.meta.url), 'utf8');
const reader = readFileSync(new URL('../src/lib/stock/opname-list-read.ts', import.meta.url), 'utf8');
const page = readFileSync(new URL('../app/(workspace)/stok/opname/page.tsx', import.meta.url), 'utf8');
const list = readFileSync(new URL('../src/components/stock/stock-opname-list.tsx', import.meta.url), 'utf8');
const stockPage = readFileSync(new URL('../app/(workspace)/stok/page.tsx', import.meta.url), 'utf8');

test('Stock Opname list is accessible to OWNER, ADMIN, and GUDANG but not KASIR', () => {
  assert.equal(canAccessSection('OWNER', 'stok'), true);
  assert.equal(canAccessSection('ADMIN', 'stok'), true);
  assert.equal(canAccessSection('GUDANG', 'stok'), true);
  assert.equal(canAccessSection('KASIR', 'stok'), false);
  assert.match(page, /requireProfile\(\)/);
  assert.match(page, /canAccessSection\(profile\.role, "stok"\)/);
});

test('list URL filters accept only foundation statuses and bound pagination', () => {
  assert.deepEqual(parseStockOpnameListQuery({ page: '3', status: 'review' }), { page: 3, status: 'REVIEW' });
  assert.deepEqual(parseStockOpnameListQuery({ page: '-2', status: 'NOT_A_STATUS' }), { page: 1, status: 'ALL' });
  assert.equal(STOCK_OPNAME_LIST_PAGE_SIZE, 20);
  assert.match(model, /COUNTING[\s\S]*REVIEW[\s\S]*POSTED[\s\S]*CANCELLED/);
});

test('session list uses one bounded RLS-protected page query with deterministic ordering', () => {
  assert.match(reader, /\.from\("stock_opname_sessions"\)/);
  assert.match(reader, /\.select\("id, outlet_id, scope_type, status, created_at, outlets\(name\)", \{ count: "exact" \}\)/);
  assert.match(reader, /\.range\(from, from \+ STOCK_OPNAME_LIST_PAGE_SIZE - 1\)/);
  assert.match(reader, /\.order\("created_at", \{ ascending: false \}\)[\s\S]*?\.order\("id", \{ ascending: false \}\)/);
  assert.match(reader, /\.eq\("status", query\.status\)/);
  assert.doesNotMatch(reader, /\.from\("stock_opname_items"\)|\.from\("stock_opname_count_events"\)|service_role|product_costs|\bhpp\b/i);
});

test('read-only list omits unsafe actor lookups and renders responsive non-financial fields', () => {
  assert.match(reader, /reference: row\.id\.slice/);
  assert.match(list, /Outlet/);
  assert.match(list, /Ruang lingkup/);
  assert.match(list, /Dibuat/);
  assert.match(list, /data\.rows\.map/);
  assert.match(list, /hrefFor\(data\.query\.status, data\.page \+ 1\)/);
  assert.doesNotMatch(list, /product_inventory|minimum_quantity|hpp|cost|profit|stock_operation_intent/i);
  assert.match(stockPage, /href="\/stok\/opname"/);
});

test('every session card is a keyboard-accessible link to its detail route with status-specific navigation cue', () => {
  assert.match(list, /<li className="surface-card stock-opname-card"[\s\S]*?<Link className="stock-opname-card-link" href=\{`\/stok\/opname\/\$\{row\.id\}`\}/);
  assert.match(list, /COUNTING: "Lanjutkan opname"/);
  assert.match(list, /REVIEW: "Buka review"/);
  assert.match(list, /POSTED: "Lihat hasil"/);
  assert.match(list, /CANCELLED: "Lihat detail"/);
  assert.match(list, /<span className="stock-opname-card-action">\{OPEN_ACTION\[row\.status\]\}/);
});

test('list copy no longer presents the Stock Opname module as globally read-only', () => {
  assert.doesNotMatch(page, /Tindakan opname belum tersedia|Baca saja|BACA SAJA/);
  assert.match(page, /Kelola sesi stock opname, lanjutkan penghitungan, review, dan posting hasil/);
  assert.match(page, /Kelola sesi stock opname, lanjutkan penghitungan dan review hasil/);
  assert.doesNotMatch(list, /Daftar sesi · baca saja/);
});
