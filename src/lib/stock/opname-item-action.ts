"use server";

import { canAccessSection } from "@/lib/auth/roles";
import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { normalizeExceptionReason } from "@/lib/stock/opname-count-model";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type OpnameItemOperation = "REBASE_ITEM" | "REVIEW_EXCEPTION";
export type OpnameItemActionResult = {
  kind: "issued" | "success" | "stale-item" | "stale-baseline" | "error";
  requestId?: string;
  message?: string;
};

export type OpnameItemActionInput = {
  operation: OpnameItemOperation;
  sessionId: string;
  productId: string;
  expectedRevision: number;
  reason?: string;
};

function safeText(value: string | null | undefined) {
  return value?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 160) ?? "";
}

function invalid(message: string): OpnameItemActionResult {
  return { kind: "error", message };
}

async function authorized() {
  const profile = await getProfile();
  return profile && canAccessSection(profile.role, "stok") ? profile : null;
}

export async function issueOpnameItemIntent(input: OpnameItemActionInput): Promise<OpnameItemActionResult> {
  const profile = await authorized();
  if (!profile) return invalid("Anda tidak memiliki akses untuk mengubah item opname.");
  if (!input || (input.operation !== "REBASE_ITEM" && input.operation !== "REVIEW_EXCEPTION")
      || typeof input.sessionId !== "string" || !UUID_PATTERN.test(input.sessionId)
      || typeof input.productId !== "string" || !UUID_PATTERN.test(input.productId)
      || !Number.isInteger(input.expectedRevision) || input.expectedRevision < 0 || input.expectedRevision > 2_147_483_647) {
    return invalid("Data item atau revisi tidak valid. Muat ulang sesi opname.");
  }
  if (input.operation === "REVIEW_EXCEPTION" && typeof input.reason !== "string") {
    return invalid("Tuliskan alasan pengecualian terlebih dahulu.");
  }

  const reason = input.operation === "REVIEW_EXCEPTION" ? normalizeExceptionReason(input.reason ?? "") : undefined;
  if (input.operation === "REVIEW_EXCEPTION" && !reason) {
    return invalid("Tuliskan alasan pengecualian terlebih dahulu.");
  }

  const payload: Record<string, string | number> = {
    session_id: input.sessionId,
    product_id: input.productId,
    expected_revision: input.expectedRevision,
  };
  if (input.operation === "REVIEW_EXCEPTION") payload.reason = reason!;

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("issue_stock_operation_intent", {
    p_operation_key: input.operation,
    p_payload: payload,
  });
  if (error || typeof data !== "string" || !UUID_PATTERN.test(data)) {
    if (error) console.error("[stock-opname-item] intent issuance failed", {
      operation: input.operation,
      code: safeText(error.code),
      message: safeText(error.message),
    });
    return invalid(error?.code === "42501"
      ? "Akun ini tidak diizinkan menjalankan tindakan pada item opname."
      : input.operation === "REVIEW_EXCEPTION" && error?.code === "22023"
        ? "Alasan pengecualian belum valid. Periksa alasan dan coba lagi."
        : "Permintaan belum dapat disiapkan. Muat ulang item dan coba lagi.");
  }
  return { kind: "issued", requestId: data };
}

export async function applyOpnameItemIntent(
  requestId: string,
  operation: OpnameItemOperation,
): Promise<OpnameItemActionResult> {
  const profile = await authorized();
  if (!profile) return invalid("Anda tidak memiliki akses untuk mengubah item opname.");
  if (typeof requestId !== "string" || !UUID_PATTERN.test(requestId)
      || (operation !== "REBASE_ITEM" && operation !== "REVIEW_EXCEPTION")) {
    return invalid("Permintaan opname tidak valid.");
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("apply_stock_operation_intent", { p_request_id: requestId });
  if (error) {
    console.error("[stock-opname-item] intent application failed", {
      operation,
      code: safeText(error.code),
      message: safeText(error.message),
    });
    return { kind: "error", requestId, message: error.code === "42501"
      ? "Permintaan ini tidak dapat diakses oleh akun Anda."
      : "Hasil belum terkonfirmasi. Ulangi permintaan tersimpan dengan tombol yang sama." };
  }

  const result = data as { ok?: boolean; code?: string; reason?: string; recountRequired?: boolean } | null;
  if (result?.ok) {
    return { kind: "success", requestId, message: operation === "REBASE_ITEM"
      ? "Baseline diperbarui. Masukkan hitungan fisik baru; hitungan dan pengecualian lama tidak digunakan."
      : "Pengecualian dicatat. Item tetap tanpa hitungan fisik dan tidak mengubah saldo stok." };
  }
  if (result?.code === "STALE_BASELINE" && result.reason === "ITEM_REVISION_MISMATCH") {
    return { kind: "stale-item", requestId,
      message: "Item berubah sejak dibuka. Tindakan Anda tidak diterapkan; data terbaru dimuat untuk ditinjau kembali." };
  }
  if (result?.code === "STALE_BASELINE" && result.recountRequired === true) {
    return { kind: "stale-baseline", requestId,
      message: "Saldo proyeksi berubah sejak sesi dimulai. Item memerlukan baseline terbaru dan hitungan ulang sebelum pengecualian dapat dicatat." };
  }
  if (result?.reason === "EXPECTED_REVISION_REQUIRED") {
    return { kind: "stale-item", requestId,
      message: "Permintaan lama tidak memuat revisi item. Data terbaru dimuat; kirim tindakan baru setelah diperiksa." };
  }
  return { kind: "error", requestId, message: "Tindakan belum dapat diterapkan. Muat ulang item dan coba kembali." };
}
