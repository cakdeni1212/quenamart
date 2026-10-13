import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { canAccessSection } from '../src/lib/auth/roles.ts';
import { addDays, isValidReportRange, jakartaToday, percentChange, reportPeriod } from '../src/lib/reports/model.ts';
import { formatReportMoney } from '../src/lib/reports/model.ts';
import { formatRupiah } from '../src/lib/money.ts';

const migration = await readFile(new URL('../supabase/migrations/20260929460000_owner_reports_read_v1.sql', import.meta.url), 'utf8');
const page = await readFile(new URL('../app/(workspace)/laporan/page.tsx', import.meta.url), 'utf8');
const reader = await readFile(new URL('../src/lib/reports/read.ts', import.meta.url), 'utf8');
const css = await readFile(new URL('../src/components/reports/reports.module.css', import.meta.url), 'utf8');
const docs = await readFile(new URL('../docs/REPORTING.md', import.meta.url), 'utf8');

test('report authorization exposes the workspace only to Owner and Admin', () => {
  assert.equal(canAccessSection('OWNER', 'laporan'), true);
  assert.equal(canAccessSection('ADMIN', 'laporan'), true);
  assert.equal(canAccessSection('KASIR', 'laporan'), false);
  assert.equal(canAccessSection('GUDANG', 'laporan'), false);
  assert.match(migration, /v_role NOT IN \('OWNER'::public\.user_role,'ADMIN'::public\.user_role\)/);
  assert.match(migration, /REVOKE ALL ON FUNCTION public\.owner_reports_read\(date,date,date,date\) FROM PUBLIC,anon,service_role/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.owner_reports_read\(date,date,date,date\) TO authenticated/);
});

test('Jakarta dates, custom bounds, comparisons and month presets are deterministic', () => {
  assert.equal(jakartaToday(new Date('2026-10-12T17:30:00Z')), '2026-10-13');
  assert.equal(addDays('2026-10-01', -1), '2026-09-30');
  assert.deepEqual(reportPeriod('hari-ini', '2026-10-13'), {
    from: '2026-10-13', to: '2026-10-13', compareFrom: '2026-10-12', compareTo: '2026-10-12',
  });
  assert.deepEqual(reportPeriod('7-hari', '2026-10-13'), {
    from: '2026-10-07', to: '2026-10-13', compareFrom: '2026-09-30', compareTo: '2026-10-06',
  });
  assert.deepEqual(reportPeriod('bulan-ini', '2026-10-13'), {
    from: '2026-10-01', to: '2026-10-13', compareFrom: '2026-09-01', compareTo: '2026-09-13',
  });
  assert.deepEqual(reportPeriod('bulan-lalu', '2026-10-13'), {
    from: '2026-09-01', to: '2026-09-30', compareFrom: '2026-08-01', compareTo: '2026-08-31',
  });
  assert.equal(reportPeriod('custom', '2026-10-13', '2026-10-04', '2026-10-05').compareFrom, '2026-10-02');
  assert.equal(reportPeriod('custom', '2026-10-13', 'bogus', '2026-10-05').from, '2026-10-01');
  assert.equal(isValidReportRange('2026-01-01', '2026-12-31'), true);
  assert.equal(isValidReportRange('2025-01-01', '2026-01-02'), false);
  assert.equal(isValidReportRange('2026-02-30', '2026-03-01'), false);
});

test('comparison change handles increase, decrease, equality and zero without NaN or infinity', () => {
  assert.equal(percentChange('120', '100'), '20.0');
  assert.equal(percentChange('80', '100'), '-20.0');
  assert.equal(percentChange('100', '100'), '0.0');
  assert.equal(percentChange('100', '0'), null);
  assert.equal(percentChange('0', '0'), null);
  assert.equal(percentChange('0', '100'), '-100.0');
});

test('negative report amounts retain sign and canonical Rupiah grouping', () => {
  assert.equal(formatReportMoney('-2000000', formatRupiah), '-Rp 2.000.000');
  assert.equal(formatReportMoney('2000000', formatRupiah), 'Rp 2.000.000');
});

test('read model uses completed sale snapshots, sale-time COGS, posted expenses and split payment rows separately', () => {
  assert.match(migration, /CREATE FUNCTION public\.owner_reports_read\(p_from date, p_to date, p_compare_from date, p_compare_to date\)/);
  assert.match(migration, /SECURITY DEFINER[\s\S]*SET search_path = pg_catalog/);
  assert.match(migration, /s\.status='COMPLETED'::public\.pos_sale_status/);
  assert.match(migration, /s\.source_system::text/);
  assert.match(migration, /sale_item_cost_evidence/);
  assert.match(migration, /e\.status='RESOLVED'[\s\S]*e\.resolved_cogs_amount IS NOT NULL/);
  assert.match(migration, /e\.status='POSTED'/);
  assert.match(migration, /FROM public\.sale_payments sp JOIN period_sales ps/);
  assert.match(migration, /payment_reconciliation/);
  assert.match(migration, /product_name_snapshot[\s\S]*sku_snapshot[\s\S]*line_subtotal/);
  assert.match(migration, /'top_categories',NULL/);
  assert.match(migration, /timezone\('Asia\/Jakarta',s\.completed_at\)::date/);
  assert.match(migration, /generate_series\(p_from::timestamp,p_to::timestamp,interval '1 day'\)/);
  assert.match(migration, /CASE WHEN v_days<=60 THEN 'DAY' ELSE 'WEEK' END/);
  assert.match(migration, /i\.status='FINALIZED' AND i\.payment_type='TEMPO'/);
  assert.match(migration, /stock_balance_projection/);
  assert.match(migration, /quantity_mismatch=0/);
  assert.doesNotMatch(migration, /\b(INSERT INTO|UPDATE public\.|DELETE FROM|TRUNCATE|DROP TABLE)\b/i);
});

test('profit and inventory values remain unavailable when evidence is incomplete', () => {
  assert.match(migration, /'gross_profit',[\s\S]*SELECT incomplete FROM cogs_state\)=0/);
  assert.match(migration, /'gross_margin',[\s\S]*SELECT incomplete FROM cogs_state\)=0/);
  assert.match(migration, /'operating_profit',[\s\S]*SELECT incomplete FROM cogs_state\)=0/);
  assert.match(migration, /AND \(SELECT unvalued FROM source_summary\)=0 AND \(SELECT provisional FROM source_summary\)=0 THEN/);
  assert.match(docs, /No current HPP\/WAC is used/);
  assert.match(docs, /\*\*current\*\* snapshots/);
});

test('page renders bounded period filters, financial states, current snapshots and responsive sections', () => {
  assert.match(page, /readReports\(profile, period\)/);
  assert.match(page, /Belum tersedia/);
  assert.match(page, /Metode Pembayaran/);
  assert.match(page, /Pengeluaran per Kategori/);
  assert.match(page, /Produk Terlaris/);
  assert.match(page, /Kondisi Persediaan Saat Ini/);
  assert.match(page, /Tempo Supplier Saat Ini/);
  assert.match(page, /salesMoney\(/);
  assert.match(reader, /p_compare_from/);
  assert.match(reader, /OWNER.*ADMIN/);
  assert.match(css, /@media \(max-width:760px\)/);
  assert.match(css, /grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/);
});
