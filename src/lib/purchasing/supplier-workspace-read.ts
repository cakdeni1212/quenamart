import "server-only";
import type { Profile } from "@/lib/auth/roles";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/purchasing/receipt-model";

export type SupplierWorkspaceRow = {
  id: string; supplier_code: string; display_name: string; contact_name: string | null;
  phone: string | null; address: string | null; is_active: boolean;
  open_count?: number; outstanding?: string; nearest_due?: string | null; last_purchase?: string | null;
};

export async function readSupplierWorkspace(profile: Profile, query: { search?: string; status?: string; tempo?: string; page?: number }) {
  const allowed = profile.is_active && ["OWNER", "ADMIN", "GUDANG"].includes(profile.role);
  if (!allowed) return { rows: [] as SupplierWorkspaceRow[], total: 0, page: 1, pages: 0, summary: null, error: "Anda tidak memiliki akses ke supplier." };
  const supabase = await createClient();
  const requestedPage = typeof query.page === "number" && Number.isSafeInteger(query.page) ? query.page : 1;
  const { data, error } = await supabase.rpc("supplier_workspace_page", {
    p_search: (query.search ?? "").trim().slice(0, 80),
    p_status: profile.role === "GUDANG" ? "ACTIVE" : ["ACTIVE", "INACTIVE"].includes(query.status ?? "") ? query.status : "",
    p_tempo: profile.role === "GUDANG" ? "" : ["HAS_TEMPO", "NO_TEMPO"].includes(query.tempo ?? "") ? query.tempo : "",
    p_page: Math.max(1, Math.min(100000, requestedPage)), p_page_size: 20,
  });
  if (error || !data || typeof data !== "object") return { rows: [] as SupplierWorkspaceRow[], total: 0, page: 1, pages: 0, summary: null, error: "Daftar supplier belum dapat dimuat." };
  const result = data as { rows?: unknown; total?: unknown; page?: unknown; pageSize?: unknown; summary?: unknown };
  if (!Array.isArray(result.rows)) return { rows: [] as SupplierWorkspaceRow[], total: 0, page: 1, pages: 0, summary: null, error: "Daftar supplier belum dapat dimuat." };
  const total = typeof result.total === "number" ? result.total : 0;
  const page = typeof result.page === "number" ? result.page : 1;
  const pageSize = typeof result.pageSize === "number" ? result.pageSize : 20;
  return { rows: result.rows as SupplierWorkspaceRow[], total, page, pages: Math.ceil(total / pageSize), summary: result.summary as { activeSuppliers: number; tempoCount: number; outstanding: string; nearestDue: string | null } | null, error: null };
}

export async function readSupplierDetail(profile: Profile, id: string, page = 1) {
  if (!profile.is_active || !["OWNER", "ADMIN"].includes(profile.role) || !isUuid(id)) return null;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("supplier_workspace_detail", { p_supplier_id: id, p_page: Math.max(1, page), p_page_size: 20 });
  if (error || !data || typeof data !== "object" || !(data as { supplier?: unknown }).supplier) return null;
  return data as {
    supplier: { id: string; supplier_code: string; display_name: string; legal_name: string | null; contact_name: string | null; phone: string | null; address: string | null; notes: string | null; is_active: boolean };
    purchases: Array<{ id: string; invoice_reference: string; invoice_number: string | null; invoice_date: string | null; due_date: string | null; total: string; paid: string; outstanding: string; payment_type: string; finalized_at: string; receipts: Array<{ id: string; reference: string; receivedAt: string }> }>;
    purchaseCount: number; page: number; pageSize: number;
    products: Array<{ id: string; name: string; sku: string; last_purchase: string; last_received_quantity: number }>;
    summary: { totalPurchases: string; outstanding: string; openInvoices: number; lastPurchase: string | null };
  };
}
