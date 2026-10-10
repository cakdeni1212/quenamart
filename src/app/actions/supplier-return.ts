"use server";

import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";

type LineInput = { productId: string; quantity: number; sourceReceiptId?: string | null; sourceReceiptItemId?: string | null; note?: string | null };
type Result = { ok: true; value: Record<string, unknown> } | { ok: false; message: string };
const denied = (): Result => ({ ok: false, message: "Retur supplier hanya dapat dikelola OWNER, ADMIN, atau GUDANG." });
async function editorClient() {
  const profile = await getProfile();
  if (!profile || !["OWNER", "ADMIN", "GUDANG"].includes(profile.role)) return null;
  return { profile, supabase: await createClient() };
}
function dbLines(lines: LineInput[]) {
  return lines.map((line) => ({ product_id: line.productId, quantity: line.quantity,
    source_receipt_id: line.sourceReceiptId ?? null, source_receipt_item_id: line.sourceReceiptItemId ?? null, note: line.note ?? null }));
}

export async function searchSupplierReturnProducts(query: string): Promise<Result> {
  const context = await editorClient(); if (!context) return denied();
  const term = query.trim().slice(0, 100); if (term.length < 2) return { ok: true, value: { rows: [] } };
  const { data: periods, error: periodError } = await context.supabase.from("stock_authority_periods").select("outlet_id,outlets(is_active)").is("ended_at", null);
  const period = periods?.length === 1 ? periods[0] as unknown as { outlet_id: string; outlets: { is_active: boolean } | null } : null;
  if (periodError || !period?.outlets?.is_active) return { ok: false, message: "Outlet stok aktif belum tersedia." };
  const { data, error } = await context.supabase.rpc("stock_workspace_read_page", { p_outlet_id: period.outlet_id,
    p_q: term, p_stock_status: "ALL", p_rack_empty: false, p_category: null, p_page: 1, p_page_size: 25 });
  if (error) return { ok: false, message: "Pencarian produk belum dapat diproses." };
  return { ok: true, value: { rows: (data as { rows?: unknown[] } | null)?.rows ?? [] } };
}
export async function resolveSupplierReturnBarcode(barcode: string): Promise<Result> {
  const context = await editorClient(); if (!context) return denied();
  const { data, error } = await context.supabase.rpc("supplier_return_resolve_barcode", { p_barcode: barcode.trim() });
  const product = (data ?? [])[0] as Record<string, unknown> | undefined;
  if (error || !product) return { ok: false, message: "Barcode belum terdaftar, ambigu, atau saldo belum tersedia." };
  return { ok: true, value: product };
}
export async function supplierReturnReceiptCandidates(supplierId: string, productId: string, query: string): Promise<Result> {
  const context = await editorClient(); if (!context) return denied();
  const { data, error } = await context.supabase.rpc("supplier_return_receipt_candidates", {
    p_supplier: supplierId, p_product: productId, p_q: query.trim().slice(0, 80) || null, p_limit: 20,
  });
  if (error) return { ok: false, message: "Riwayat penerimaan sumber belum dapat dimuat." };
  return { ok: true, value: { rows: data ?? [] } };
}
export async function createSupplierReturn(input: { outletId: string; supplierId: string; reasonCategory: string; reason: string; note: string; lines: LineInput[] }): Promise<Result> {
  const context = await editorClient(); if (!context) return denied();
  const { data, error } = await context.supabase.rpc("create_supplier_return", { p_outlet_id: input.outletId, p_supplier_id: input.supplierId,
    p_reason_category: input.reasonCategory, p_reason: input.reason, p_note: input.note || null, p_lines: dbLines(input.lines) });
  return error ? { ok: false, message: "Draft retur belum dapat disimpan. Periksa supplier, alasan, dan jumlah." } : { ok: true, value: data as Record<string, unknown> };
}
export async function updateSupplierReturn(input: { id: string; expectedRevision: number; reasonCategory: string; reason: string; note: string; lines: LineInput[] }): Promise<Result> {
  const context = await editorClient(); if (!context) return denied();
  const { data, error } = await context.supabase.rpc("update_supplier_return", { p_id: input.id, p_expected_revision: input.expectedRevision,
    p_reason_category: input.reasonCategory, p_reason: input.reason, p_note: input.note || null, p_lines: dbLines(input.lines) });
  return error ? { ok: false, message: "Draft retur tidak tersimpan. Muat ulang lalu coba lagi." } : { ok: true, value: data as Record<string, unknown> };
}
export async function cancelSupplierReturn(id: string, reason: string): Promise<Result> {
  const context = await editorClient(); if (!context) return denied();
  const { data, error } = await context.supabase.rpc("cancel_supplier_return", { p_id: id, p_reason: reason });
  return error ? { ok: false, message: "Draft retur belum dapat dibatalkan." } : { ok: true, value: data as Record<string, unknown> };
}
export async function postSupplierReturn(id: string, requestId: string): Promise<Result> {
  const profile = await getProfile(); if (!profile || !["OWNER", "ADMIN"].includes(profile.role)) return denied();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("post_supplier_return", { p_id: id, p_request_id: requestId });
  if (error) return { ok: false, message: error.code === "55000" || error.code === "23514" ? (error.message ?? "Retur belum dapat diposting.") : "Retur belum dapat diposting. Periksa saldo stok dan coba lagi." };
  return { ok: true, value: data as Record<string, unknown> };
}
