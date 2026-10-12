import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { jakartaDateString, salesPresetRange, isSalesDate } from '../src/lib/sales/history-date.ts';

const read = (path) => readFile(new URL(path, import.meta.url), 'utf8');
const [migration, page, detail, reprint, loading, reader, receipt, formatter, css, roles, changelog, todo, posDocs] = await Promise.all([
  read('../supabase/migrations/20260929400000_pos_sales_history_read_v1.sql'),
  read('../app/(workspace)/transaksi/page.tsx'),
  read('../app/(workspace)/transaksi/[id]/page.tsx'),
  read('../src/components/sales/receipt-reprint.tsx'),
  read('../app/(workspace)/transaksi/loading.tsx'),
  read('../src/lib/sales/history-read.ts'),
  read('../src/components/pos/pos-receipt.tsx'),
  read('../src/lib/sales/presentation.ts'),
  read('../src/components/sales/sales-history.module.css'),
  read('../src/lib/auth/roles.ts'),
  read('../docs/CHANGELOG.md'),
  read('../docs/TODO.md'),
  read('../docs/POS.md'),
]);

test('history contract is authenticated, outlet-scoped, role-aware, read-only, and bounded', () => {
  assert.match(migration, /CREATE FUNCTION public\.pos_sales_history_read/);
  assert.match(migration, /SECURITY DEFINER[\s\S]*SET search_path=pg_catalog/);
  assert.match(migration, /auth\.uid\(\)/);
  assert.match(migration, /current_active_user_role\(\)/);
  assert.match(migration, /v_actor IS NULL OR v_role IS NULL OR v_role NOT IN/);
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.pos_sale_receipt_read[\s\S]*v_role IS NULL/);
  assert.match(migration, /'OWNER'[\s\S]*?'ADMIN'[\s\S]*?'KASIR'/);
  assert.match(migration, /s\.outlet_id=v_outlet/);
  assert.match(migration, /v_role<>'KASIR'[\s\S]*s\.cashier_id=v_actor/);
  assert.match(migration, /LIMIT 20 OFFSET/);
  assert.match(migration, /s\.source_system='QUENA_POS'[\s\S]*s\.status='COMPLETED'/);
  assert.match(migration, /completed_at DESC,id DESC/);
  assert.match(migration, /REVOKE ALL ON FUNCTION public\.pos_sales_history_read[\s\S]*FROM PUBLIC,anon,service_role/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.pos_sales_history_read[\s\S]*TO authenticated/);
  assert.doesNotMatch(migration, /\b(?:INSERT|UPDATE|DELETE|TRUNCATE)\b/i);
  assert.doesNotMatch(migration, /COGS|WAC|hpp|inventory_cost/i);
});

test('date, search, and tender filters produce sale-level aggregates without join multiplication', () => {
  assert.match(migration, /p_from::timestamp AT TIME ZONE 'Asia\/Jakarta'/);
  assert.match(migration, /\(p_to\+1\)::timestamp AT TIME ZONE 'Asia\/Jakarta'/);
  assert.match(migration, /position\(lower\(v_search\) in lower\(s\.sale_number\)\)>0/);
  assert.match(migration, /EXISTS\([\s\S]*FROM public\.sale_payments sp[\s\S]*sp\.method::text=p_method/);
  assert.match(migration, /sum\(grand_total\)/);
  assert.match(migration, /count\(\*\)::integer FROM public\.sale_items/);
  assert.match(migration, /FROM public\.sale_payments sp WHERE sp\.sale_id=s\.id/);
  assert.match(migration, /WHEN count\(\*\)>1 THEN 'MIXED'/);
  assert.match(migration, /p_to-p_from>365/);
});

test('history page provides Jakarta presets, custom dates, summaries, filters, bounded pagination, and responsive rows', () => {
  for (const label of ['Hari ini', 'Kemarin', '7 hari', '30 hari', 'Semua', 'Tunai', 'QRIS', 'Kartu', 'E-Wallet']) assert.ok(page.includes(label));
  assert.match(page, /Total Penjualan/);
  assert.match(page, /Jumlah Transaksi/);
  assert.match(page, /Rata-rata Transaksi/);
  assert.match(page, /pageHref\(Math\.max\(1, data\.page - 1\)\)/);
  assert.match(page, /pageHref\(Math\.min\(data\.total_pages, data\.page \+ 1\)\)/);
  assert.match(page, /href="\/kasir">\+ Transaksi Baru/);
  assert.match(page, /href="\/kasir">Buka Kasir/);
  assert.match(loading, /aria-busy="true"/);
  assert.match(loading, /Memuat riwayat transaksi/);
  assert.match(page, /item_count} item/);
  assert.match(css, /\.tableWrap\{overflow:auto/);
  assert.match(css, /\.mobileList\{display:none\}/);
  assert.match(css, /@media\(max-width:760px\)[\s\S]*\.tableWrap\{display:none\}[\s\S]*\.mobileList\{display:grid/);
});

test('detail and reprint use immutable receipt RPC and support split tenders without cost fields', () => {
  assert.match(detail, /readPosSaleReceipt\(id\)/);
  assert.match(detail, /receipt\.items\.map/);
  assert.match(detail, /receipt\.payments\.map/);
  assert.match(reprint, /Cetak Ulang Struk/);
  assert.match(reprint, /window\.print\(\)/);
  assert.match(reprint, /value="58"/);
  assert.match(reprint, /value="80"/);
  assert.match(detail, /salesMoney\(item\.unit_selling_price\)/);
  assert.match(detail, /salesMoney\(item\.line_subtotal\)/);
  assert.match(detail, /salesMoney\(receipt\.grand_total\)/);
  assert.match(receipt, /receipt\.payments\.map/);
  assert.match(receipt, /size: "58" \| "80"/);
  assert.match(receipt, /data-print-receipt/);
  assert.match(receipt, /salesDateTime\(receipt\.completed_at\)/);
  assert.doesNotMatch(reader, /hpp|wac|cogs|profit|source.layer/i);
  assert.doesNotMatch(detail, /hpp|wac|cogs|profit|source.layer/i);
});

test('read wrapper delegates authorization to the bounded RPC and returns only commercial fields', () => {
  assert.match(reader, /canAccessSection\(profile\.role, "transaksi"\)/);
  assert.match(reader, /pos_sales_history_read/);
  assert.match(reader, /p_from: filters\.from/);
  assert.match(reader, /p_page: filters\.page/);
  assert.match(roles, /transaksi: \["OWNER", "ADMIN", "KASIR"\]/);
  assert.match(formatter, /formatRupiah/);
  assert.match(formatter, /timeZone: "Asia\/Jakarta"/);
  assert.match(formatter, /maximumFractionDigits: 3/);
  assert.match(changelog, /sales transaction history/i);
  assert.match(todo, /native sales history/i);
  assert.match(posDocs, /\/transaksi/);
});

test('Jakarta business dates and inclusive preset ranges are deterministic', () => {
  assert.equal(jakartaDateString(new Date('2026-10-11T18:00:00.000Z')), '2026-10-12');
  assert.deepEqual(salesPresetRange('today', '2026-10-12'), { from: '2026-10-12', to: '2026-10-12' });
  assert.deepEqual(salesPresetRange('yesterday', '2026-10-12'), { from: '2026-10-11', to: '2026-10-11' });
  assert.deepEqual(salesPresetRange('7d', '2026-10-12'), { from: '2026-10-06', to: '2026-10-12' });
  assert.deepEqual(salesPresetRange('30d', '2026-10-12'), { from: '2026-09-13', to: '2026-10-12' });
  assert.equal(isSalesDate('2026-02-29'), false);
  assert.equal(isSalesDate('2026-10-12'), true);
});
