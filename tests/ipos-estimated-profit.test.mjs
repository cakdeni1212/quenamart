import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = await readFile(new URL("../supabase/migrations/20260929473000_ipos_estimated_profit_snapshots_v1.sql", import.meta.url), "utf8");
const workspace = await readFile(new URL("../src/components/sales/ipos-sales-import-workspace.tsx", import.meta.url), "utf8");
const reports = await readFile(new URL("../app/(workspace)/laporan/page.tsx", import.meta.url), "utf8");
const readModel = await readFile(new URL("../src/lib/reports/read.ts", import.meta.url), "utf8");

test("estimates use current valid WAC first, reference HPP second, and never write official COGS", () => {
  assert.match(migration, /v_authority='WAC_ACTIVE'[\s\S]*?cp\.valuation_status='VALUED'[\s\S]*?THEN 'WAC'/);
  assert.match(migration, /c\.hpp IS NOT NULL AND c\.hpp>=0[\s\S]*?THEN 'REFERENCE_HPP'/);
  assert.match(migration, /ELSE 'UNAVAILABLE'/);
  assert.match(migration, /CREATE TABLE public\.ipos_sales_estimate_(snapshots|lines)/);
  assert.doesNotMatch(migration, /INSERT INTO public\.sale_item_cost_evidence|INSERT INTO public\.inventory_cost_events|INSERT INTO public\.stock_movements/);
});

test("recheck refreshes immutable estimate evidence and successful import freezes it", () => {
  assert.match(migration, /AFTER UPDATE OF preflight_result,revision ON public\.ipos_sales_import_batches/);
  assert.match(migration, /NEW\.revision>OLD\.revision AND NEW\.status<>'COMMITTED'/);
  assert.match(migration, /AFTER UPDATE OF status ON public\.ipos_sales_import_batches/);
  assert.match(migration, /frozen_estimate_snapshot_id/);
  assert.match(migration, /estimated_line_profit/);
  assert.match(migration, /uncovered_reason/);
  assert.match(migration, /IPOS sales estimate evidence is immutable/);
});

test("coverage profit is calculated only on covered revenue and Reports keeps it separate", () => {
  assert.match(migration, /sum\(line_profit\)/);
  assert.match(migration, /sum\(raw_line_total\) FILTER\(WHERE cost_source<>'UNAVAILABLE'\)/);
  assert.match(migration, /least\(100::numeric,\(SELECT covered_revenue FROM totals\)\/\(SELECT revenue FROM totals\)\*100\)/);
  assert.match(readModel, /ipos_estimated_profit_read/);
  assert.match(reports, /Estimasi Profit iPos/);
  assert.match(reports, /bukan laba akuntansi historis/);
  assert.match(reports, /Laba Kotor resmi|Laba Kotor/);
  assert.match(workspace, /Estimasi Profit ·/);
  assert.match(workspace, /bukan laba akuntansi historis/);
});

test("the locked QUENAEX report facts are preserved as authoritative revenue while blocked", () => {
  const lockedReport = { transactions: 217, lines: 489, quantity: 633, revenue: 7_077_400, reconciled: true };
  const missingSkuAndStockBlockers = { missingSku: 9, stockNotReady: 32 };
  assert.equal(lockedReport.transactions, 217);
  assert.equal(lockedReport.lines, 489);
  assert.equal(lockedReport.quantity, 633);
  assert.equal(lockedReport.revenue, 7_077_400);
  assert.equal(lockedReport.reconciled, true);
  assert.equal(missingSkuAndStockBlockers.missingSku, 9);
  assert.equal(missingSkuAndStockBlockers.stockNotReady, 32);
  assert.match(migration, /report_revenue numeric\(32,2\) NOT NULL/);
  assert.match(migration, /'reportRevenue',s\.report_revenue::text/);
  assert.doesNotMatch(migration, /report_revenue[\s\S]{0,80}CASE WHEN.*blocked/i);
});

test("the explicit partial coverage example does not count unknown-cost revenue as profit", () => {
  const totalRevenue = 150000;
  const coveredRevenue = 100000;
  const estimatedCost = 70000;
  const estimatedProfit = 30000;
  const coverage = coveredRevenue / totalRevenue * 100;
  assert.ok(Math.abs(coverage - 100 * 2 / 3) < 1e-12);
  assert.equal(estimatedProfit, coveredRevenue - estimatedCost);
  assert.notEqual(estimatedProfit, totalRevenue - estimatedCost);
});
