import "server-only";
import type { Profile } from "@/lib/auth/roles";
import { createClient } from "@/lib/supabase/server";

export type ReportsData = {
  period: { from: string; to: string; days: number; comparison_from: string; comparison_to: string };
  kpis: { revenue: string; transactions: number; average_basket: string; comparison_revenue: string; comparison_transactions: number; change_percent: string | null; comparison_available: boolean; expenses: string; expense_count: number; profit_status: "COSTING_INACTIVE" | "INCOMPLETE" | "RESOLVED"; gross_profit: string | null; gross_margin: string | null; operating_profit: string | null; incomplete_sales: number; cogs: string };
  sales_trend: Array<{ date: string; revenue: string; transactions: number }>;
  profit_trend: Array<{ date: string; revenue: string; gross_profit: string; operating_profit: string }> | null;
  profit_unavailable_reason: string | null;
  expenses_by_category: Array<{ category: string; amount: string; count: number; percent: string }>;
  payments: Array<{ method: string; amount: string; transactions: number }>;
  payment_reconciliation: { sales_revenue: string; payment_total: string; difference: string; matches: boolean };
  sales_sources: Array<{ source: string; revenue: string; transactions: number }>;
  top_products: Array<{ name: string; sku: string; quantity: string; revenue: string; contribution: string }>;
  top_categories: null;
  current_inventory: { as_of: string; sku_count: number; out_of_stock: number; at_minimum: number; missing_stock: number; physical_quantity: string; valued_quantity: string; provisional_quantity: string; unvalued_quantity: string; inventory_value: string | null; valuation_status: string };
  current_tempo: { as_of: string; outstanding: string; unpaid_invoices: number; due_soon: string; due_soon_count: number; overdue: string; overdue_count: number };
  ipos_estimated_profit: {
    revenue: string; transactions: number; totalLines: number; coveredLines: number; uncoveredLines: number;
    totalQuantity: string; coveredQuantity: string; uncoveredQuantity: string; coveredRevenue: string;
    uncoveredRevenue: string; estimatedCost: string | null; estimatedProfit: string | null; estimatedMargin: string | null;
    revenueCoverage: string; totalSku: number; coveredSku: number; uncoveredSku: number; wacSkuCount: number;
    referenceHppSkuCount: number; unavailableSkuCount: number; calculatedAt: string | null;
    uncovered: Array<{ sku: string; name: string; quantity: string; revenue: string; reason: string }>;
  };
};

function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }

export async function readReports(profile: Profile, period: { from: string; to: string; compareFrom: string; compareTo: string }) {
  if (!profile.is_active || !["OWNER", "ADMIN"].includes(profile.role)) return { data: null, error: "Anda tidak memiliki akses ke Laporan." };
  const supabase = await createClient();
  const [reportResult, estimateResult] = await Promise.all([
    supabase.rpc("owner_reports_read", {
      p_from: period.from, p_to: period.to, p_compare_from: period.compareFrom, p_compare_to: period.compareTo,
    }),
    supabase.rpc("ipos_estimated_profit_read", { p_from: period.from, p_to: period.to }),
  ]);
  const { data, error } = reportResult;
  const estimate = estimateResult.data;
  if (error || !isRecord(data) || !isRecord(data.period) || !isRecord(data.kpis)
      || !Array.isArray(data.sales_trend) || !Array.isArray(data.expenses_by_category)
      || !Array.isArray(data.payments) || !Array.isArray(data.top_products)
      || !isRecord(data.current_inventory) || !isRecord(data.current_tempo)
      || !isRecord(data.payment_reconciliation) || estimateResult.error || !isRecord(estimate)
      || !Array.isArray(estimate.uncovered)) {
    return { data: null, error: "Laporan belum dapat dimuat. Periksa koneksi, lalu coba lagi." };
  }
  return { data: { ...data, ipos_estimated_profit: estimate } as unknown as ReportsData, error: null };
}
