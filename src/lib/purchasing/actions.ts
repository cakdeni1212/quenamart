"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { canAccessSection } from "@/lib/auth/roles";
import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { getActiveStockOutletId } from "@/lib/stock/opname-create-read";
import { isUuid, normalizeReceiptDraftItems } from "@/lib/purchasing/receipt-model";

export type ActionState = { error: string | null; success?: string | null };

function safeMessage(error: { code?: string | null; message?: string | null }) {
  console.error("[purchasing] action failed", { code: error.code, message: error.message?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 160) });
  if (error.code === "42501") return "Anda tidak memiliki izin untuk tindakan ini.";
  if (error.code === "55000") return "Barang masuk sudah diposting atau tidak lagi dapat diubah. Muat ulang halaman.";
  return "Tindakan belum dapat diselesaikan. Periksa data dan coba lagi.";
}

async function authorized(managerOnly = false) {
  const profile = await getProfile();
  if (!profile || !canAccessSection(profile.role, "pembelian")
      || (managerOnly && profile.role !== "OWNER" && profile.role !== "ADMIN")) return null;
  return profile;
}

export async function saveSupplier(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const profile = await authorized(true);
  if (!profile) return { error: "Hanya OWNER atau ADMIN yang dapat mengelola supplier." };
  const supplierIdValue = formData.get("supplier_id");
  const supplierId = typeof supplierIdValue === "string" && supplierIdValue ? supplierIdValue : null;
  if (supplierId && !isUuid(supplierId)) return { error: "Data supplier tidak valid." };
  const displayName = formData.get("display_name");
  if (typeof displayName !== "string" || !displayName.trim()) return { error: "Nama supplier wajib diisi." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("purchase_supplier_upsert", {
    p_supplier_id: supplierId,
    p_display_name: displayName.trim(),
    p_legal_name: optionalText(formData.get("legal_name")),
    p_phone: optionalText(formData.get("phone")),
    p_contact_name: optionalText(formData.get("contact_name")),
    p_is_active: formData.getAll("is_active").includes("true"),
  });
  if (error) return { error: safeMessage(error) };
  revalidatePath("/pembelian/supplier");
  revalidatePath("/pembelian/barang-masuk");
  return { error: null, success: "Data supplier tersimpan." };
}

function optionalText(value: FormDataEntryValue | null) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

export async function createReceiptDraft(formData: FormData): Promise<never> {
  const profile = await authorized();
  if (!profile) redirect("/dashboard");
  const supplier = formData.get("supplier_id");
  const receivedAt = formData.get("received_at");
  const note = formData.get("operational_note");
  if (typeof supplier !== "string" || !isUuid(supplier) || typeof receivedAt !== "string" || !receivedAt) redirect("/pembelian/barang-masuk/baru?error=invalid");
  const receivedDate = new Date(receivedAt);
  if (!Number.isFinite(receivedDate.getTime())) redirect("/pembelian/barang-masuk/baru?error=invalid");
  const outletId = await getActiveStockOutletId();
  if (!outletId) redirect("/pembelian/barang-masuk/baru?error=outlet");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("purchase_receipt_create_draft", {
    p_outlet_id: outletId, p_supplier_id: supplier, p_received_at: receivedDate.toISOString(),
    p_note: typeof note === "string" && note.trim() ? note.trim() : null,
  });
  if (error || typeof data !== "string" || !isUuid(data)) {
    if (error) safeMessage(error);
    redirect("/pembelian/barang-masuk/baru?error=create");
  }
  redirect(`/pembelian/barang-masuk/${data}`);
}

export async function saveReceiptDraft(receiptId: string, expectedRevision: number, formData: FormData): Promise<ActionState> {
  const profile = await authorized();
  if (!profile || !isUuid(receiptId)) return { error: "Anda tidak memiliki akses untuk mengubah barang masuk." };
  const receivedAtValue = formData.get("received_at");
  const noteValue = formData.get("operational_note");
  const itemsValue = formData.get("items");
  if (typeof receivedAtValue !== "string" || typeof itemsValue !== "string") return { error: "Data barang masuk belum lengkap." };
  let parsed: unknown;
  try { parsed = JSON.parse(itemsValue); } catch { return { error: "Daftar barang tidak valid." }; }
  const items = normalizeReceiptDraftItems(parsed);
  if (!items) return { error: "Periksa produk dan kuantitas. Produk hanya boleh dicatat satu kali." };
  const receivedAt = new Date(receivedAtValue);
  if (!Number.isFinite(receivedAt.getTime()) || !Number.isSafeInteger(expectedRevision)) return { error: "Tanggal atau revisi barang masuk tidak valid." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("purchase_receipt_save_draft", {
    p_receipt_id: receiptId, p_expected_revision: expectedRevision, p_received_at: receivedAt.toISOString(),
    p_note: typeof noteValue === "string" && noteValue.trim() ? noteValue.trim() : null, p_items: items,
  });
  if (error) return { error: safeMessage(error) };
  const result = data as { ok?: boolean; code?: string } | null;
  if (!result?.ok) return { error: result?.code === "DRAFT_CHANGED" ? "Barang masuk berubah di sesi lain. Muat ulang sebelum melanjutkan." : "Draf belum tersimpan." };
  revalidatePath(`/pembelian/barang-masuk/${receiptId}`);
  revalidatePath("/pembelian/barang-masuk");
  return { error: null, success: "Draf barang masuk tersimpan." };
}

export async function issueReceiptPost(receiptId: string): Promise<{ requestId: string | null; error: string | null }> {
  const profile = await authorized();
  if (!profile || !isUuid(receiptId)) return { requestId: null, error: "Anda tidak memiliki akses untuk memposting barang masuk." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("issue_purchase_receipt_post_intent", { p_receipt_id: receiptId });
  if (error || typeof data !== "string" || !isUuid(data)) return { requestId: null, error: error ? safeMessage(error) : "Permintaan posting belum dapat disiapkan." };
  return { requestId: data, error: null };
}

export async function searchReceiptProducts(search: string): Promise<{ rows: Array<{ id: string; name: string; sku: string; barcode: string | null }>; error: string | null }> {
  const profile = await authorized();
  if (!profile) return { rows: [], error: "Anda tidak memiliki akses ke pencarian produk." };
  if (typeof search !== "string" || search.trim().length < 2) return { rows: [], error: null };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("purchase_receipt_product_search", { p_search: search.trim().slice(0, 100), p_page: 1 });
  if (error || !data || typeof data !== "object" || !Array.isArray((data as { rows?: unknown }).rows)) return { rows: [], error: "Pencarian produk belum dapat digunakan." };
  return { rows: (data as { rows: Array<{ id: string; name: string; sku: string; barcode: string | null }> }).rows, error: null };
}

export async function resolveReceiptBarcode(barcode: string): Promise<{ product: { id: string; name: string; sku: string; barcode: string | null } | null; code: string }> {
  const profile = await authorized();
  if (!profile) return { product: null, code: "FORBIDDEN" };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("purchase_receipt_resolve_barcode", { p_barcode: barcode.trim().slice(0, 160) });
  if (error || !data || typeof data !== "object") return { product: null, code: "LOOKUP_FAILED" };
  const result = data as { code?: unknown; product?: unknown };
  if (result.code !== "BARCODE_MATCH" || !result.product || typeof result.product !== "object") return { product: null, code: typeof result.code === "string" ? result.code : "LOOKUP_FAILED" };
  return { product: result.product as { id: string; name: string; sku: string; barcode: string | null }, code: "BARCODE_MATCH" };
}

export async function applyReceiptPost(requestId: string): Promise<{ result: { ok: boolean; code: string; movementCount?: number; movementBatchId?: string } | null; error: string | null; terminal: boolean }> {
  const profile = await authorized();
  if (!profile || !isUuid(requestId)) return { result: null, error: "Anda tidak memiliki akses untuk memposting barang masuk.", terminal: true };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("apply_purchase_receipt_post_intent", { p_request_id: requestId });
  if (error) return { result: null, error: safeMessage(error), terminal: ["42501", "22023", "55000", "P0002"].includes(error.code ?? "") };
  const result = data as { ok?: unknown; code?: unknown; movementCount?: unknown; movementBatchId?: unknown } | null;
  if (!result || typeof result.ok !== "boolean" || typeof result.code !== "string") return { result: null, error: null, terminal: false };
  revalidatePath("/pembelian/barang-masuk");
  return { result: { ok: result.ok, code: result.code,
    movementCount: typeof result.movementCount === "number" ? result.movementCount : undefined,
    movementBatchId: typeof result.movementBatchId === "string" ? result.movementBatchId : undefined }, error: null, terminal: true };
}

export async function createPurchaseInvoiceDraft(supplierId: string, requestId: string) {
  const profile = await authorized(true);
  if (!profile || !isUuid(supplierId) || !isUuid(requestId)) return { id: null, error: "Akses atau data nota tidak valid." };
  const outletId = await getActiveStockOutletId();
  if (!outletId) return { id: null, error: "Outlet aktif belum tersedia." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("purchase_invoice_create_draft", { p_outlet_id: outletId, p_supplier_id: supplierId, p_request_id: requestId });
  if (error || typeof data !== "string" || !isUuid(data)) return { id: null, error: error ? safeMessage(error) : "Nota belum dapat dibuat." };
  revalidatePath("/pembelian/nota");
  return { id: data, error: null };
}

export async function savePurchaseInvoiceDraft(invoiceId: string, revision: number, input: {
  invoiceNumber: string; invoiceDate: string; dueDate: string | null; paymentType: "CASH" | "TEMPO";
  supplierTotal: number; items: Array<{ product_id: string; invoice_quantity: number; purchase_unit_price: number }>;
}) {
  const profile = await authorized(true);
  if (!profile || !isUuid(invoiceId) || !Number.isSafeInteger(revision) || !input || !Array.isArray(input.items) || input.items.length > 500) return { error: "Data nota tidak valid." };
  if (typeof input.invoiceNumber !== "string" || input.invoiceNumber.trim().length > 120
    || !/^\d{4}-\d{2}-\d{2}$/.test(input.invoiceDate) || (input.dueDate !== null && !/^\d{4}-\d{2}-\d{2}$/.test(input.dueDate))
    || !["CASH", "TEMPO"].includes(input.paymentType) || !Number.isFinite(input.supplierTotal) || input.supplierTotal < 0
    || (input.paymentType === "TEMPO" && !input.dueDate)) return { error: "Tanggal, pembayaran, atau total nota belum valid." };
  if (!input.items.every((item) => isUuid(item.product_id) && Number.isFinite(item.invoice_quantity) && item.invoice_quantity > 0 && Number.isFinite(item.purchase_unit_price) && item.purchase_unit_price >= 0)) return { error: "Periksa kuantitas dan harga setiap barang." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("purchase_invoice_save_draft", {
    p_invoice_id: invoiceId, p_expected_revision: revision, p_invoice_number: input.invoiceNumber.trim(), p_invoice_date: input.invoiceDate,
    p_due_date: input.dueDate, p_payment_type: input.paymentType, p_supplier_total: input.supplierTotal,
    p_items: input.items,
  });
  if (error) return { error: safeMessage(error) };
  const result = data as { ok?: boolean; code?: string } | null;
  if (!result?.ok) return { error: result?.code === "INVOICE_CHANGED" ? "Nota berubah di sesi lain. Muat ulang sebelum melanjutkan." : "Nota belum tersimpan." };
  revalidatePath(`/pembelian/nota/${invoiceId}`); revalidatePath("/pembelian/nota"); revalidatePath("/tempo-supplier");
  return { error: null };
}

export async function linkPurchaseReceipt(invoiceId: string, receiptId: string, link = true) {
  const profile = await authorized(true);
  if (!profile || !isUuid(invoiceId) || !isUuid(receiptId)) return { error: "Akses atau data penerimaan tidak valid." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("purchase_invoice_link_receipt", { p_invoice_id: invoiceId, p_receipt_id: receiptId, p_link: link });
  if (error) return { error: safeMessage(error) };
  revalidatePath(`/pembelian/nota/${invoiceId}`); revalidatePath(`/pembelian/barang-masuk/${receiptId}`);
  return { error: null };
}

export async function finalizePurchaseInvoice(invoiceId: string, requestId: string, revision: number, input: { initialPaid: number; paymentMethod: string | null; paymentDate: string | null; paymentNote: string | null }) {
  const profile = await authorized(true);
  if (!profile || !isUuid(invoiceId) || !isUuid(requestId) || !Number.isSafeInteger(revision) || !input || !Number.isFinite(input.initialPaid) || input.initialPaid < 0
    || (input.paymentMethod !== null && !["CASH", "TRANSFER", "OTHER"].includes(input.paymentMethod))
    || (input.paymentDate !== null && !/^\d{4}-\d{2}-\d{2}$/.test(input.paymentDate))
    || (input.paymentNote !== null && (typeof input.paymentNote !== "string" || input.paymentNote.trim().length > 300))) return { result: null, error: "Akses atau data finalisasi tidak valid.", terminal: true };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("purchase_invoice_finalize", { p_invoice_id: invoiceId, p_request_id: requestId, p_expected_revision: revision,
    p_initial_paid: input.initialPaid, p_payment_method: input.paymentMethod, p_payment_date: input.paymentDate, p_payment_note: input.paymentNote });
  if (error) return { result: null, error: safeMessage(error), terminal: ["42501", "22023", "55000", "P0002"].includes(error.code ?? "") };
  revalidatePath(`/pembelian/nota/${invoiceId}`); revalidatePath("/pembelian/nota"); revalidatePath("/tempo-supplier"); revalidatePath("/pembelian/barang-masuk");
  return { result: data as { ok: boolean; code: string; invoiceId?: string; payableId?: string; systemTotal?: number; invoiceTotal?: number; paid?: number } | null, error: null, terminal: true };
}

export async function recordSupplierPayment(requestId: string, supplierId: string, outletId: string, paymentDate: string, amount: number,
  method: "CASH" | "TRANSFER" | "OTHER", reference: string | null, allocations: Array<{ payable_id: string; amount: number }>) {
  const profile = await authorized(true);
  if (!profile || !isUuid(requestId) || !isUuid(supplierId) || !isUuid(outletId) || !Array.isArray(allocations) || allocations.length < 1 || allocations.length > 100) return { result: null, error: "Akses atau data pembayaran tidak valid.", terminal: true };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("purchase_record_supplier_payment", { p_request_id: requestId, p_supplier_id: supplierId, p_outlet_id: outletId,
    p_payment_date: paymentDate, p_amount: amount, p_payment_method: method, p_reference_note: reference, p_allocations: allocations });
  if (error) return { result: null, error: safeMessage(error), terminal: ["42501", "22023", "55000", "P0002"].includes(error.code ?? "") };
  revalidatePath("/tempo-supplier"); revalidatePath("/pembelian/nota");
  return { result: data as { ok: boolean; code: string; paymentId?: string } | null, error: null, terminal: true };
}

export async function attachPurchaseInvoiceDocument(invoiceId: string, path: string) {
  const profile = await authorized(true);
  if (!profile || !isUuid(invoiceId) || typeof path !== "string" || path.length > 300
    || !new RegExp(`^invoices/${invoiceId}/[0-9a-fA-F-]{36}\\.(jpg|jpeg|png|webp|pdf)$`).test(path)) return { error: "Akses atau dokumen tidak valid." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("purchase_invoice_attach_document", { p_invoice_id: invoiceId, p_storage_path: path });
  if (error) return { error: safeMessage(error) };
  revalidatePath(`/pembelian/nota/${invoiceId}`);
  return { error: null };
}

export async function signPurchaseInvoiceDocument(path: string) {
  const profile = await authorized(true);
  if (!profile || typeof path !== "string" || path.length > 300 || !path.startsWith("invoices/")) return { url: null };
  const supabase = await createClient();
  const { data, error } = await supabase.storage.from("quena-purchasing-invoices").createSignedUrl(path, 60);
  return { url: error ? null : data.signedUrl };
}
