import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { businessDayLabel, salesComparisonLabel, sumRupiahAmounts, trendBarHeight } from '../src/lib/dashboard/model.ts';
import { canAccessSection, landingPathForRole } from '../src/lib/auth/roles.ts';

const migration = await readFile(new URL('../supabase/migrations/20260929410000_owner_dashboard_read_v1.sql', import.meta.url), 'utf8');
const page = await readFile(new URL('../app/(workspace)/dashboard/page.tsx', import.meta.url), 'utf8');
const reader = await readFile(new URL('../src/lib/dashboard/read.ts', import.meta.url), 'utf8');
const css = await readFile(new URL('../src/components/dashboard/dashboard.module.css', import.meta.url), 'utf8');

test('dashboard access keeps Owner and Admin while cashier and warehouse keep their role homes', () => {
  assert.equal(canAccessSection('OWNER', 'dashboard'), true);
  assert.equal(canAccessSection('ADMIN', 'dashboard'), true);
  assert.equal(canAccessSection('KASIR', 'dashboard'), false);
  assert.equal(canAccessSection('GUDANG', 'dashboard'), false);
  assert.equal(landingPathForRole('KASIR'), '/kasir');
  assert.equal(landingPathForRole('GUDANG'), '/produk');
});

test('sales comparisons handle increase, decrease, new sales and a neutral zero day', () => {
  assert.equal(salesComparisonLabel('CHANGE', '12.4'), '↑ 12,4% dari kemarin');
  assert.equal(salesComparisonLabel('CHANGE', '-8.2'), '↓ 8,2% dari kemarin');
  assert.equal(salesComparisonLabel('NEW', null), 'Ada penjualan baru dibanding kemarin');
  assert.equal(salesComparisonLabel('NO_SALES', null), 'Belum ada transaksi hari ini maupun kemarin');
});

test('trend chart retains zero days and computes bounded visible bar heights', () => {
  assert.equal(trendBarHeight('0.00', '150000'), 0);
  assert.equal(trendBarHeight('75000', '150000'), 50);
  assert.equal(trendBarHeight('200000', '150000'), 100);
  assert.equal(trendBarHeight('1', '150000'), 3);
  assert.match(businessDayLabel('2026-10-12'), /12/);
  assert.equal(sumRupiahAmounts(['120000.10', '0.20', '0']), '120000.30');
});

test('read RPC is bounded, read-only, Jakarta scoped, and aggregates payments separately', () => {
  assert.match(migration, /CREATE FUNCTION public\.owner_dashboard_read\(p_trend_days integer DEFAULT 7\)/);
  assert.match(migration, /SECURITY DEFINER[\s\S]*SET search_path = pg_catalog/);
  assert.match(migration, /v_role NOT IN \([\s\S]*'OWNER'[\s\S]*'ADMIN'/);
  assert.match(migration, /timezone\('Asia\/Jakarta', now\(\)\)::date/);
  assert.match(migration, /generate_series\(v_today - \(v_days - 1\), v_today/);
  assert.match(migration, /count\(DISTINCT sp\.sale_id\)/);
  assert.match(migration, /stock_balance_projection/);
  assert.match(migration, /missing_projection_count/);
  assert.match(migration, /i\.status = 'FINALIZED' AND i\.payment_type = 'TEMPO'/);
  assert.match(migration, /e\.status = 'RESOLVED'[\s\S]*e\.resolved_cogs_amount IS NOT NULL/);
  assert.match(migration, /REVOKE ALL[\s\S]*FROM PUBLIC, anon, service_role/);
  assert.match(migration, /GRANT EXECUTE[\s\S]*TO authenticated/);
  assert.doesNotMatch(migration, /\b(INSERT|UPDATE|DELETE|TRUNCATE|ALTER TABLE|DROP TABLE)\b/i);
});

test('dashboard renders real data states and navigation without mutation controls', () => {
  assert.match(page, /readOwnerDashboard\(profile, trendDays\)/);
  assert.match(page, /Belum tersedia/);
  assert.match(page, /Belum lengkap/);
  assert.match(page, /Persiapan Go-Live/);
  assert.match(page, /href="\/transaksi"/);
  assert.match(page, /href="\/stok"/);
  assert.match(page, /href="\/tempo-supplier"/);
  assert.match(page, /href="\/stok\/opname"/);
  assert.match(page, /salesMoney\(/);
  assert.doesNotMatch(page, /<form|<button/);
  assert.match(reader, /owner_dashboard_read/);
  assert.match(reader, /Ringkasan toko belum dapat dimuat/);
  assert.match(css, /@media \(max-width:760px\)/);
});

test('RPC returns no HPP, WAC, source-layer or raw COGS payload', () => {
  const responseShape = migration.slice(migration.indexOf("SELECT jsonb_build_object("), migration.indexOf('ALTER FUNCTION public.owner_dashboard_read'));
  assert.doesNotMatch(responseShape, /'wac'|'current_wac'|'hpp'|'source_layer'|'resolved_cogs'|'inventory_value'/i);
  assert.match(responseShape, /'gross_profit'/);
  assert.match(responseShape, /'gross_profit'[\s\S]*ps\.incomplete_sales = 0/);
});
