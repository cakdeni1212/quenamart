import "server-only";
import type { Profile } from "@/lib/auth/roles";
import { createClient } from "@/lib/supabase/server";
import type { TrendRow } from "@/lib/dashboard/model";

export type DashboardData = {
  business_date: string;
  sales: {
    today_total: string;
    today_count: number;
    average_basket: string;
    yesterday_total: string;
    yesterday_count: number;
    comparison: "NO_SALES" | "NEW" | "CHANGE";
    change_percent: string | null;
  };
  trend_days: 7 | 30;
  trend: TrendRow[];
  payments: Array<{ method: "CASH" | "QRIS" | "CARD" | "E_WALLET"; total: string; sale_count: number }>;
  profit: { status: "COSTING_INACTIVE" | "INCOMPLETE" | "RESOLVED"; gross_profit: string | null; incomplete_sales: number };
  expenses: { expenses_today: string; gross_profit_status: "COSTING_INACTIVE" | "INCOMPLETE" | "RESOLVED"; operating_profit: string | null };
  stock: { low_stock_count: number; missing_projection_count: number; items: Array<{ product_id: string; name: string; effective_quantity: number; minimum_quantity: number | null; rack: string | null }> };
  tempo: { outstanding_total: string; due_soon_total: string; overdue_total: string; due_soon_count: number; overdue_count: number; urgent: Array<{ id: string; supplier_name: string; invoice_number: string | null; due_date: string; outstanding: string; days_overdue: number }> };
  attention: { costing_active: boolean; low_stock_count: number; missing_stock_projection_count: number; due_soon_count: number; overdue_count: number; open_opname_count: number; incomplete_profit_sales: number };
};

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function readOwnerDashboard(profile: Profile, trendDays: 7 | 30) {
  if (!profile.is_active || !["OWNER", "ADMIN"].includes(profile.role)) {
    return { data: null, error: "Anda tidak memiliki akses ke dashboard Owner." };
  }
  const supabase = await createClient();
  const [{ data, error }, { data: expenseData, error: expenseError }] = await Promise.all([
    supabase.rpc("owner_dashboard_read", { p_trend_days: trendDays }),
    supabase.rpc("owner_dashboard_operating_expense_read"),
  ]);
  if (error || !isObject(data) || !isObject(data.sales) || !Array.isArray(data.trend)
    || !isObject(data.profit) || !isObject(data.stock) || !isObject(data.tempo)
    || !isObject(data.attention) || !Array.isArray(data.payments) || expenseError || !isObject(expenseData)
    || typeof expenseData.expenses_today !== "string"
    || !["COSTING_INACTIVE", "INCOMPLETE", "RESOLVED"].includes(String(expenseData.gross_profit_status))
    || !(expenseData.operating_profit === null || typeof expenseData.operating_profit === "string")) {
    return { data: null, error: "Ringkasan toko belum dapat dimuat. Coba muat ulang halaman." };
  }
  return { data: { ...data, expenses: expenseData } as unknown as DashboardData, error: null };
}
