import "server-only";
import type { Profile } from "@/lib/auth/roles";
import { createClient } from "@/lib/supabase/server";
import type { ExpenseCategory, ExpenseMethod, ExpenseStatus } from "@/lib/expenses/model";

export type ExpenseRow = {
  id: string; expense_number: string; expense_date: string; category: ExpenseCategory; description: string;
  amount: string; payment_method: ExpenseMethod; reference_note: string | null; status: ExpenseStatus;
  draft_revision: number; created_at: string; posted_at: string | null; cancelled_at: string | null;
};
export type ExpenseFilter = { from: string; to: string; search?: string; category?: string; method?: string; status?: string; page?: number };

const permitted = (profile: Profile) => profile.is_active && (profile.role === "OWNER" || profile.role === "ADMIN");

export async function readExpenses(profile: Profile, filter: ExpenseFilter) {
  if (!permitted(profile)) return { rows: [] as ExpenseRow[], total: 0, page: 1, pages: 0, summary: null, error: "Anda tidak memiliki akses ke pengeluaran." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("operational_expenses_page", {
    p_date_from: filter.from, p_date_to: filter.to, p_search: (filter.search ?? "").trim().slice(0, 100),
    p_category: filter.category ?? "", p_method: filter.method ?? "", p_status: filter.status ?? "",
    p_page: Number.isSafeInteger(filter.page) ? Math.max(1, filter.page ?? 1) : 1, p_page_size: 20,
  });
  if (error || !data || typeof data !== "object" || !Array.isArray((data as { rows?: unknown }).rows)) {
    return { rows: [] as ExpenseRow[], total: 0, page: 1, pages: 0, summary: null, error: "Daftar pengeluaran belum dapat dimuat." };
  }
  const result = data as { rows: ExpenseRow[]; total: number; page: number; pageSize: number; summary: { total: string; count: number; average: string; largestCategory: string | null; largestCategoryAmount: string | null } };
  return { rows: result.rows, total: result.total, page: result.page, pages: Math.ceil(result.total / result.pageSize), summary: result.summary, error: null };
}

export type ExpenseDetail = ExpenseRow & {
  outlet_id: string; created_by: string; created_at: string; posted_by: string | null; posted_at: string | null;
  cancelled_by: string | null; cancelled_at: string | null; cancellation_reason: string | null;
  events: Array<{ type: string; actor: string; at: string; note: string | null }>;
};

export async function readExpenseDetail(profile: Profile, id: string): Promise<ExpenseDetail | null> {
  if (!permitted(profile) || !/^[0-9a-f-]{36}$/i.test(id)) return null;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("operational_expense_detail", { p_expense_id: id });
  return error || !data || typeof data !== "object" ? null : data as ExpenseDetail;
}
