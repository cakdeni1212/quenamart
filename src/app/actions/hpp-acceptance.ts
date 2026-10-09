"use server";

import { revalidatePath } from "next/cache";
import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";

type ActionResult = { ok: boolean; code: string; message: string };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

async function authorizedProfile(ownerOnly = false) {
  const profile = await getProfile();
  if (!profile || (profile.role !== "OWNER" && profile.role !== "ADMIN") || (ownerOnly && profile.role !== "OWNER")) return null;
  return profile;
}

function response(data: unknown): ActionResult {
  if (!data || typeof data !== "object" || Array.isArray(data)) return { ok: false, code: "INVALID_RESPONSE", message: "Respons belum dapat dipastikan. Coba lagi dengan permintaan yang sama." };
  const value = data as Record<string, unknown>;
  if (value.ok === true) return { ok: true, code: String(value.code ?? "OK"), message: "Perubahan berhasil disimpan." };
  const code = typeof value.code === "string" ? value.code : "FAILED";
  if (code === "STALE_BATCH") return { ok: false, code, message: "Data HPP berubah. Perbarui persiapan sebelum melanjutkan." };
  return { ok: false, code, message: "Tindakan belum dapat dilakukan. Muat ulang data dan coba kembali." };
}

function failed(error: { code?: string | null }): ActionResult {
  console.error("[hpp-awal] action failed", { code: error.code ?? "UNKNOWN" });
  return { ok: false, code: error.code ?? "UNKNOWN", message: "Tindakan belum dapat diselesaikan. Jika belum pasti, coba lagi dengan tombol yang sama." };
}

export async function prepareInitialHppAcceptance(outletId: string, requestId: string): Promise<ActionResult> {
  if (!(await authorizedProfile()) || !UUID.test(outletId) || !UUID.test(requestId)) {
    return { ok: false, code: "FORBIDDEN", message: "Anda tidak memiliki akses untuk menyiapkan HPP awal." };
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("prepare_initial_hpp_acceptance", {
    p_outlet_id: outletId,
    p_request_id: requestId,
  });
  if (error) return failed(error);
  const result = response(data);
  if (result.ok) revalidatePath("/hpp-awal");
  return result;
}

export async function resolveInitialHppAcceptanceException(input: {
  batchId: string;
  productId: string;
  disposition: "ACCEPT_CURRENT_HPP" | "OPENING_HPP_OVERRIDE" | "LEAVE_UNVALUED" | "AUTHORITATIVE_ZERO";
  openingHpp: string | null;
  reason: string;
  requestId: string;
}): Promise<ActionResult> {
  if (!(await authorizedProfile()) || !UUID.test(input.batchId) || !UUID.test(input.productId) || !UUID.test(input.requestId)) {
    return { ok: false, code: "FORBIDDEN", message: "Anda tidak memiliki akses untuk menyimpan keputusan." };
  }
  const reason = input.reason.trim();
  if (!reason) return { ok: false, code: "REASON_REQUIRED", message: "Isi alasan keputusan terlebih dahulu." };
  let openingHpp: string | null = null;
  if (input.disposition === "OPENING_HPP_OVERRIDE") {
    const value = input.openingHpp?.trim() ?? "";
    if (!/^\d{1,12}(\.\d{1,2})?$/.test(value) || /^0+(\.0+)?$/.test(value)) {
      return { ok: false, code: "INVALID_HPP", message: "Masukkan HPP awal lebih dari Rp0 dengan maksimal 2 angka desimal." };
    }
    openingHpp = value;
  } else if (input.openingHpp !== null) {
    return { ok: false, code: "INVALID_HPP", message: "Nilai HPP awal hanya digunakan untuk pilihan Masukkan HPP Awal." };
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("resolve_initial_hpp_acceptance_exception", {
    p_batch_id: input.batchId,
    p_product_id: input.productId,
    p_disposition: input.disposition,
    p_opening_hpp: openingHpp,
    p_reason: reason,
    p_request_id: input.requestId,
  });
  if (error) return failed(error);
  const result = response(data);
  if (result.ok || result.code === "STALE_BATCH") revalidatePath("/hpp-awal");
  return result;
}

export async function approveInitialHppAcceptance(batchId: string, requestId: string): Promise<ActionResult> {
  if (!(await authorizedProfile(true)) || !UUID.test(batchId) || !UUID.test(requestId)) {
    return { ok: false, code: "FORBIDDEN", message: "Persetujuan akhir hanya dapat dilakukan oleh Owner." };
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("approve_initial_hpp_acceptance", {
    p_batch_id: batchId,
    p_request_id: requestId,
  });
  if (error) return failed(error);
  const result = response(data);
  if (result.ok || result.code === "STALE_BATCH") revalidatePath("/hpp-awal");
  return result;
}
