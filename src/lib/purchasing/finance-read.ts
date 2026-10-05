import "server-only";
import type { Profile } from "@/lib/auth/roles";
import { createClient } from "@/lib/supabase/server";
import { getActiveStockOutletId } from "@/lib/stock/opname-create-read";
import { isUuid } from "@/lib/purchasing/receipt-model";

export type InvoiceSummary = { id: string; invoice_reference: string; invoice_number: string | null; invoice_date: string | null; due_date: string | null; payment_type: "CASH" | "TEMPO" | null; supplier_invoice_total: number | null; status: "DRAFT" | "FINALIZED"; supplier_name: string; paid: number; payment_status: string };
export type InvoiceDetailData = {
  header: { id: string; invoice_reference: string; outlet_id: string; supplier_id: string; invoice_number: string | null; invoice_date: string | null; due_date: string | null; payment_type: "CASH" | "TEMPO" | null; supplier_invoice_total: number | null; status: "DRAFT" | "FINALIZED"; created_by: string; created_at: string; updated_by: string; finalized_by: string | null; finalized_at: string | null; draft_revision: number; supplier: { id: string; name: string }; outlet: string; createdByName: string; updatedByName: string; finalizedByName: string };
  items: Array<{ id: string; productId: string; name: string; sku: string; quantity: number; unitPrice: number; subtotal: number }>;
  receipts: Array<{ id: string; reference: string; status: "DRAFT" | "POSTED"; receivedAt: string }>;
  payable: null | { id: string; amount: number; paid: number; outstanding: number; status: string };
  payments: Array<{ id: string; date: string; amount: number; method: string; reference: string | null; recordedByName: string; recordedAt: string }>;
  documents: Array<{ id: string; path: string; uploadedAt: string; uploadedByName: string }>;
  events: Array<{ type: string; at: string; actorName: string; note: string | null }>;
};

function canSeeFinancials(profile: Profile) { return profile.is_active && (profile.role === "OWNER" || profile.role === "ADMIN"); }
function normalizePage(value: number) { return Number.isSafeInteger(value) && value > 0 ? Math.min(value, 100000) : 1; }

export async function readInvoiceList(profile: Profile, search = "", status = "", pageValue = 1) {
  if (!canSeeFinancials(profile)) return { rows: [] as InvoiceSummary[], total: 0, page: 1, pages: 0, error: "Anda tidak memiliki akses ke data nota." };
  const supabase = await createClient();
  const allowed = ["", "DRAFT", "BELUM_DIBAYAR", "SEBAGIAN", "LUNAS", "JATUH_TEMPO_SEGERA", "TERLAMBAT"];
  const { data, error } = await supabase.rpc("purchase_invoices_page", { p_search: search.trim().slice(0, 80), p_status: allowed.includes(status) ? status : "", p_page: normalizePage(pageValue), p_page_size: 25 });
  if (error || !data || typeof data !== "object") return { rows: [] as InvoiceSummary[], total: 0, page: 1, pages: 0, error: "Daftar nota belum dapat dimuat." };
  const result = data as { rows?: unknown; total?: unknown; page?: unknown; pageSize?: unknown };
  if (!Array.isArray(result.rows)) return { rows: [] as InvoiceSummary[], total: 0, page: 1, pages: 0, error: "Daftar nota belum dapat dimuat." };
  const total = typeof result.total === "number" ? result.total : 0;
  const page = typeof result.page === "number" ? result.page : 1;
  const pageSize = typeof result.pageSize === "number" ? result.pageSize : 25;
  return { rows: result.rows as InvoiceSummary[], total, page, pages: Math.ceil(total / pageSize), error: null };
}

export async function readInvoiceDetail(profile: Profile, invoiceId: string): Promise<InvoiceDetailData | null> {
  if (!canSeeFinancials(profile) || !isUuid(invoiceId)) return null;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("purchase_invoice_financial_detail", { p_invoice_id: invoiceId });
  if (error || !data || typeof data !== "object" || !(data as { header?: unknown }).header) return null;
  return data as InvoiceDetailData;
}

export async function readPayables(profile: Profile, search = "", status = "", pageValue = 1) {
  if (!canSeeFinancials(profile)) return { rows: [], total: 0, page: 1, pages: 0, summary: null, error: "Anda tidak memiliki akses ke tempo supplier." };
  const supabase = await createClient();
  const allowed = ["", "BELUM_DIBAYAR", "SEBAGIAN", "LUNAS", "JATUH_TEMPO_SEGERA", "TERLAMBAT"];
  const { data, error } = await supabase.rpc("purchase_payables_page", { p_search: search.trim().slice(0, 80), p_status: allowed.includes(status) ? status : "", p_page: normalizePage(pageValue), p_page_size: 25 });
  if (error || !data || typeof data !== "object") return { rows: [], total: 0, page: 1, pages: 0, summary: null, error: "Data tempo supplier belum dapat dimuat." };
  const result = data as { rows?: unknown; total?: unknown; page?: unknown; pageSize?: unknown; summary?: unknown };
  if (!Array.isArray(result.rows)) return { rows: [], total: 0, page: 1, pages: 0, summary: null, error: "Data tempo supplier belum dapat dimuat." };
  const total = typeof result.total === "number" ? result.total : 0;
  const page = typeof result.page === "number" ? result.page : 1;
  const pageSize = typeof result.pageSize === "number" ? result.pageSize : 25;
  return { rows: result.rows as Array<Record<string, unknown>>, total, page, pages: Math.ceil(total / pageSize), summary: result.summary as { totalOutstanding: number; dueSoon: number; overdue: number } | null, error: null };
}

export async function readInvoiceCreateOptions(profile: Profile, receiptId?: string) {
  if (!canSeeFinancials(profile)) return { suppliers: [], outletId: null };
  const supabase = await createClient();
  const [suppliers, outletId, receipt] = await Promise.all([
    supabase.from("suppliers").select("id,display_name,supplier_code").eq("is_active", true).order("display_name").limit(100),
    getActiveStockOutletId(),
    receiptId && isUuid(receiptId) ? supabase.from("purchase_receipts").select("id,supplier_id,outlet_id,receipt_reference").eq("id", receiptId).maybeSingle() : Promise.resolve({ data: null, error: null }),
  ]);
  const validReceipt = receipt.data && !receipt.error && receipt.data.outlet_id === outletId ? receipt.data : null;
  return { suppliers: suppliers.error ? [] : suppliers.data ?? [], outletId, receipt: validReceipt };
}

export async function readLinkableReceipts(profile: Profile, invoice: InvoiceDetailData) {
  if (!canSeeFinancials(profile)) return [];
  const supabase = await createClient();
  const { data, error } = await supabase.from("purchase_receipts").select("id,receipt_reference,status,received_at,supplier_id,outlet_id,invoiceLink:purchase_invoice_receipts(receipt_id)")
    .eq("supplier_id", invoice.header.supplier_id).eq("outlet_id", invoice.header.outlet_id).order("created_at", { ascending: false }).limit(50);
  if (error) return [];
  return (data ?? []).filter((row) => {
    const links = row.invoiceLink as unknown as Array<{ receipt_id: string }> | null;
    return !links?.length || links[0]?.receipt_id === row.id;
  }).map((row) => ({ id: row.id, reference: row.receipt_reference, status: row.status as "DRAFT" | "POSTED", receivedAt: row.received_at }));
}

export async function readReceiptInvoiceId(profile: Profile, receiptId: string): Promise<string | null> {
  if (!canSeeFinancials(profile) || !isUuid(receiptId)) return null;
  const supabase = await createClient();
  const { data, error } = await supabase.from("purchase_invoice_receipts").select("invoice_id").eq("receipt_id", receiptId).maybeSingle();
  return error || !data ? null : data.invoice_id;
}
