import "server-only";
import { createClient } from "@/lib/supabase/server";

export type ManagedAccount = {
  id: string;
  full_name: string | null;
  email: string;
  role: "OWNER" | "ADMIN" | "KASIR" | "GUDANG";
  is_active: boolean;
  last_sign_in_at: string | null;
};

export type AccountDirectoryResult = {
  rows: ManagedAccount[];
  total: number;
  error: boolean;
};

export async function readAccountDirectory(filters: {
  search?: string;
  role?: string;
  status?: string;
  page?: number;
}): Promise<AccountDirectoryResult> {
  const supabase = await createClient();
  const page = Math.max(1, Math.min(1001, Number.isInteger(filters.page) ? Number(filters.page) : 1));
  const role = ["OWNER", "ADMIN", "KASIR", "GUDANG"].includes(filters.role ?? "") ? filters.role! : null;
  const status = ["ACTIVE", "INACTIVE"].includes(filters.status ?? "") ? filters.status! : null;
  const search = (filters.search ?? "").trim().slice(0, 100) || null;
  const { data, error } = await supabase.rpc("account_management_list", {
    p_search: search,
    p_role: role,
    p_status: status,
    p_limit: 25,
    p_offset: (page - 1) * 25,
  });
  if (error || !data || typeof data !== "object") return { rows: [], total: 0, error: true };
  const result = data as { rows?: unknown; total?: unknown };
  const rows = Array.isArray(result.rows) ? result.rows.filter((row): row is ManagedAccount => {
    if (!row || typeof row !== "object") return false;
    const item = row as Record<string, unknown>;
    return typeof item.id === "string" && typeof item.email === "string" &&
      ["OWNER", "ADMIN", "KASIR", "GUDANG"].includes(String(item.role)) && typeof item.is_active === "boolean";
  }) : [];
  const total = typeof result.total === "number" ? result.total : Number(result.total ?? 0);
  return { rows, total: Number.isFinite(total) ? total : 0, error: false };
}
