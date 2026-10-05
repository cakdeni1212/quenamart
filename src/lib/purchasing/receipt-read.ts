import "server-only";
import type { Profile } from "@/lib/auth/roles";
import { canAccessSection } from "@/lib/auth/roles";
import { createClient } from "@/lib/supabase/server";
import { getActiveStockOutletId } from "@/lib/stock/opname-create-read";
import { parseReceiptPage, RECEIPT_PAGE_SIZE } from "@/lib/purchasing/receipt-model";

export type Supplier = { id: string; supplier_code: string; display_name: string; legal_name: string | null; phone: string | null; contact_name: string | null; is_active: boolean };
export type ReceiptListRow = { id: string; receipt_reference: string; received_at: string; status: "DRAFT" | "POSTED"; created_at: string; supplier: { display_name: string } | null; item_count?: number };
export type ReceiptDetail = {
  id: string; receipt_reference: string; outlet_id: string; supplier_id: string; received_at: string; status: "DRAFT" | "POSTED";
  operational_note: string | null; draft_revision: number; created_at: string; posted_at: string | null; posted_by: string | null;
  created_by: string; outlet: { name: string } | null; supplier: Supplier | null;
  items: Array<{ id: string; product_id: string; accepted_quantity: number | string; bonus_quantity: number | string;
    rejected_quantity: number | string; short_quantity: number | string | null; operational_note: string | null;
    product: { name: string; sku: string; unit_label: string | null } | null }>;
  events: Array<{ event_type: string; actor_id: string; created_at: string; note: string | null }>;
};

export async function readSuppliers(profile: Profile, includeInactive: boolean, search = ""): Promise<Supplier[]> {
  if (!canAccessSection(profile.role, "pembelian")) return [];
  const supabase = await createClient();
  let query = supabase.from("suppliers").select("id,supplier_code,display_name,legal_name,phone,contact_name,is_active")
    .order("display_name").order("id").limit(100);
  if (profile.role === "GUDANG" || !includeInactive) query = query.eq("is_active", true);
  if (search.trim()) query = query.ilike("display_name", `%${search.trim().slice(0, 80)}%`);
  const { data, error } = await query;
  if (error) {
    console.error("[purchasing] suppliers read failed", { code: error.code });
    return [];
  }
  return (data ?? []) as Supplier[];
}

export async function readReceiptList(profile: Profile, pageValue: unknown): Promise<{ rows: ReceiptListRow[]; page: number; pages: number; total: number; outletName: string | null; error: string | null }> {
  const page = parseReceiptPage(pageValue);
  if (!canAccessSection(profile.role, "pembelian")) return { rows: [], page: 1, pages: 0, total: 0, outletName: null, error: "Anda tidak memiliki akses ke barang masuk." };
  const supabase = await createClient();
  const outletId = await getActiveStockOutletId();
  if (!outletId) return { rows: [], page: 1, pages: 0, total: 0, outletName: null, error: "Outlet aktif belum tersedia." };
  const [{ data: outlet }, result] = await Promise.all([
    supabase.from("outlets").select("name").eq("id", outletId).maybeSingle(),
    supabase.from("purchase_receipts").select("id,receipt_reference,received_at,status,created_at,supplier:suppliers(display_name)", { count: "exact" })
      .eq("outlet_id", outletId).order("created_at", { ascending: false }).order("id", { ascending: false })
      .range((page - 1) * RECEIPT_PAGE_SIZE, page * RECEIPT_PAGE_SIZE - 1),
  ]);
  if (result.error) {
    console.error("[purchasing] receipts read failed", { code: result.error.code });
    return { rows: [], page: 1, pages: 0, total: 0, outletName: outlet?.name ?? null, error: "Daftar barang masuk belum dapat dimuat." };
  }
  const total = result.count ?? 0;
  const pages = Math.ceil(total / RECEIPT_PAGE_SIZE);
  const normalizedPage = pages ? Math.min(page, pages) : 1;
  if (normalizedPage !== page) return readReceiptList(profile, normalizedPage);
  return { rows: (result.data ?? []) as unknown as ReceiptListRow[], page: normalizedPage, pages, total, outletName: outlet?.name ?? null, error: null };
}

export async function readReceiptDetail(profile: Profile, receiptId: string): Promise<ReceiptDetail | null> {
  if (!canAccessSection(profile.role, "pembelian")) return null;
  const supabase = await createClient();
  const { data, error } = await supabase.from("purchase_receipts")
    .select("id,receipt_reference,outlet_id,supplier_id,received_at,status,operational_note,draft_revision,created_at,posted_at,posted_by,created_by,outlet:outlets(name),supplier:suppliers(id,supplier_code,display_name,legal_name,phone,contact_name,is_active),items:purchase_receipt_items(id,product_id,accepted_quantity,bonus_quantity,rejected_quantity,short_quantity,operational_note,product:products(name,sku,unit_label)),events:purchase_receipt_events(event_type,actor_id,created_at,note)")
    .eq("id", receiptId).maybeSingle();
  if (error) {
    console.error("[purchasing] receipt detail read failed", { code: error.code });
    return null;
  }
  return data as unknown as ReceiptDetail | null;
}

export async function readProductSearch(search: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("purchase_receipt_product_search", { p_search: search.trim().slice(0, 100), p_page: 1 });
  if (error || !data || typeof data !== "object" || !Array.isArray((data as { rows?: unknown }).rows)) {
    return { rows: [], error: "Pencarian produk belum dapat digunakan." };
  }
  return { rows: (data as { rows: Array<{ id: string; name: string; sku: string; barcode: string | null }> }).rows, error: null };
}
