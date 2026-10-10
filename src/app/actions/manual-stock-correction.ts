"use server";

import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";

type CorrectionLineInput = { productId: string; quantityDelta: number; note?: string | null };
type ActionResult = { ok: true; value: Record<string, unknown> } | { ok: false; message: string };
const denied = (): ActionResult => ({ ok: false, message: "Koreksi stok hanya dapat dikelola OWNER atau ADMIN." });

async function managerClient() {
  const profile = await getProfile();
  if (!profile || !["OWNER", "ADMIN"].includes(profile.role)) return null;
  return createClient();
}

export async function searchManualCorrectionProducts(query: string): Promise<ActionResult> {
  const supabase = await managerClient();
  if (!supabase) return denied();
  const term = query.trim().slice(0, 100);
  if (term.length < 2) return { ok: true, value: { rows: [] } };
  const { data: periods, error: periodError } = await supabase.from("stock_authority_periods")
    .select("outlet_id, outlets(is_active)").is("ended_at", null);
  const period = periods?.length === 1 ? periods[0] as unknown as { outlet_id: string; outlets: { is_active: boolean } | null } : null;
  if (periodError || !period?.outlets?.is_active) return { ok: false, message: "Outlet stok aktif belum tersedia." };
  const { data, error } = await supabase.rpc("stock_workspace_read_page", {
    p_outlet_id: period.outlet_id, p_q: term, p_stock_status: "ALL", p_rack_empty: false,
    p_category: null, p_page: 1, p_page_size: 25,
  });
  if (error) {
    console.error("[stock-correction] product search failed", { code: error.code, message: error.message?.slice(0, 180) });
    return { ok: false, message: "Pencarian produk belum dapat diproses." };
  }
  const response = data as { rows?: Array<Record<string, unknown>> } | null;
  return { ok: true, value: { rows: response?.rows ?? [] } };
}

export async function resolveManualCorrectionBarcode(barcode: string): Promise<ActionResult> {
  const supabase = await managerClient();
  if (!supabase) return denied();
  const { data: periods, error: periodError } = await supabase.from("stock_authority_periods")
    .select("outlet_id, outlets(is_active)").is("ended_at", null);
  const period = periods?.length === 1 ? periods[0] as unknown as { outlet_id: string; outlets: { is_active: boolean } | null } : null;
  if (periodError || !period?.outlets?.is_active) return { ok: false, message: "Outlet stok aktif belum tersedia." };
  const { data, error } = await supabase.rpc("resolve_stock_barcode", { p_outlet_id: period.outlet_id, p_barcode: barcode.trim() });
  if (error) return { ok: false, message: "Pemindaian barcode belum dapat diproses." };
  const row = (data ?? [])[0] as Record<string, unknown> | undefined;
  if (!row || row.resolution === "BARCODE_NOT_FOUND") return { ok: false, message: "Barcode belum terdaftar." };
  if (row.resolution === "BARCODE_AMBIGUOUS") return { ok: false, message: "Barcode terhubung ke lebih dari satu produk. Periksa melalui Audit Produk." };
  const detail = await supabase.rpc("product_workspace_detail", { p_product_id: row.product_id });
  const product = (detail.data ?? [])[0] as Record<string, unknown> | undefined;
  if (detail.error || !product || row.system_quantity == null) return { ok: false, message: "Saldo produk belum tersedia." };
  return { ok: true, value: { productId: row.product_id, name: product.name, sku: product.sku,
    barcode: product.barcode, stock: row.system_quantity } };
}

export async function createManualCorrection(input: {
  outletId: string; reasonCategory: string; reason: string; lines: CorrectionLineInput[];
}): Promise<ActionResult> {
  const supabase = await managerClient();
  if (!supabase) return denied();
  const { data, error } = await supabase.rpc("create_manual_stock_correction", {
    p_outlet_id: input.outletId, p_reason_category: input.reasonCategory, p_reason: input.reason,
    p_lines: input.lines.map((line) => ({ product_id: line.productId, quantity_delta: line.quantityDelta, note: line.note ?? null })),
  });
  if (error) {
    console.error("[stock-correction] create failed", { code: error.code, message: error.message?.slice(0, 180) });
    return { ok: false, message: "Draft koreksi belum dapat disimpan. Periksa alasan dan jumlah barang." };
  }
  return { ok: true, value: data as Record<string, unknown> };
}

export async function updateManualCorrection(input: {
  id: string; expectedRevision: number; reasonCategory: string; reason: string; lines: CorrectionLineInput[];
}): Promise<ActionResult> {
  const supabase = await managerClient();
  if (!supabase) return denied();
  const { data, error } = await supabase.rpc("update_manual_stock_correction", {
    p_id: input.id, p_expected_revision: input.expectedRevision, p_reason_category: input.reasonCategory,
    p_reason: input.reason, p_lines: input.lines.map((line) => ({ product_id: line.productId,
      quantity_delta: line.quantityDelta, note: line.note ?? null })),
  });
  if (error) return { ok: false, message: "Perubahan draft tidak tersimpan. Muat ulang lalu periksa koreksi." };
  return { ok: true, value: data as Record<string, unknown> };
}

export async function cancelManualCorrection(id: string, reason: string): Promise<ActionResult> {
  const supabase = await managerClient();
  if (!supabase) return denied();
  const { data, error } = await supabase.rpc("cancel_manual_stock_correction", { p_id: id, p_reason: reason });
  if (error) return { ok: false, message: "Draft koreksi belum dapat dibatalkan." };
  return { ok: true, value: data as Record<string, unknown> };
}

export async function postManualCorrection(id: string, requestId: string): Promise<ActionResult> {
  const supabase = await managerClient();
  if (!supabase) return denied();
  const { data, error } = await supabase.rpc("post_manual_stock_correction", { p_id: id, p_request_id: requestId });
  if (error) {
    console.error("[stock-correction] post failed", { operation: "post_manual_stock_correction", requestId,
      code: error.code, message: error.message?.slice(0, 180) });
    return { ok: false, message: error.code === "55000" ? (error.message ?? "Koreksi belum dapat diposting.") : "Koreksi belum dapat diposting. Periksa kembali saldo dan coba lagi." };
  }
  return { ok: true, value: data as Record<string, unknown> };
}
