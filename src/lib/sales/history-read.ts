import { canAccessSection, type UserRole } from "@/lib/auth/roles";
import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";

export type SalesHistoryRow = {
  id: string;
  sale_number: string;
  completed_at: string;
  cashier_label: string;
  item_count: number;
  grand_total: string;
  payment_method: string | null;
};

export type SalesHistoryResult = {
  rows: SalesHistoryRow[];
  page: number;
  page_size: number;
  total_count: number;
  total_pages: number;
  summary: { total_sales: string; transaction_count: number; average_transaction: string };
};

export type SalesHistoryFilters = {
  from: string;
  to: string;
  search: string | null;
  method: string | null;
  page: number;
};

export async function readSalesHistory(filters: SalesHistoryFilters): Promise<{
  data: SalesHistoryResult | null;
  role: UserRole | null;
  error: string | null;
}> {
  const profile = await getProfile();
  if (!profile || !canAccessSection(profile.role, "transaksi")) {
    return { data: null, role: profile?.role ?? null, error: "Anda tidak memiliki akses ke riwayat transaksi." };
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("pos_sales_history_read", {
    p_from: filters.from,
    p_to: filters.to,
    p_search: filters.search,
    p_method: filters.method,
    p_page: filters.page,
  });
  if (error || !data || typeof data !== "object" || Array.isArray(data)) {
    return { data: null, role: profile.role, error: "Riwayat transaksi belum dapat dimuat. Coba muat ulang halaman." };
  }
  const result = data as Record<string, unknown>;
  const summary = result.summary;
  if (!Array.isArray(result.rows) || !summary || typeof summary !== "object" || Array.isArray(summary)) {
    return { data: null, role: profile.role, error: "Data riwayat transaksi belum dapat dibaca." };
  }
  const summaryRecord = summary as Record<string, unknown>;
  const rows = result.rows.filter((row): row is Record<string, unknown> => typeof row === "object" && row !== null && !Array.isArray(row))
    .map((row) => ({
      id: String(row.id ?? ""),
      sale_number: String(row.sale_number ?? ""),
      completed_at: String(row.completed_at ?? ""),
      cashier_label: String(row.cashier_label ?? "Kasir"),
      item_count: Number(row.item_count) || 0,
      grand_total: String(row.grand_total ?? "0"),
      payment_method: row.payment_method === null ? null : String(row.payment_method ?? ""),
    }));
  return {
    role: profile.role,
    error: null,
    data: {
      rows,
      page: Number(result.page) || filters.page,
      page_size: Number(result.page_size) || 20,
      total_count: Number(result.total_count) || 0,
      total_pages: Number(result.total_pages) || 1,
      summary: {
        total_sales: String(summaryRecord.total_sales ?? "0"),
        transaction_count: Number(summaryRecord.transaction_count) || 0,
        average_transaction: String(summaryRecord.average_transaction ?? "0"),
      },
    },
  };
}
