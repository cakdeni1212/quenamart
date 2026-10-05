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
