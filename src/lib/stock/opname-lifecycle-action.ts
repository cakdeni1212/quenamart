"use server";

import { canAccessSection } from "@/lib/auth/roles";
import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { STOCK_OPNAME_LIFECYCLE_OPERATIONS, type StockOpnameLifecycleOperation } from "@/lib/stock/opname-lifecycle-model";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type StockOpnameLifecycleActionResult = {
  kind: "issued" | "success" | "rejected" | "error";
  requestId?: string;
  message: string;
};

function safeText(value: string | null | undefined) {
  return value?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 180) ?? "";
}

async function hasStockAccess() {
  const profile = await getProfile();
  return Boolean(profile && canAccessSection(profile.role, "stok"));
}

function operationMessage(operation: StockOpnameLifecycleOperation) {
  switch (operation) {
    case "SUBMIT_REVIEW": return "Kelengkapan berubah atau sesi tidak lagi dalam tahap penghitungan. Muat ulang data sesi.";
    case "RETURN_TO_COUNTING": return "Sesi tidak lagi berada dalam tahap review. Muat ulang data sesi.";
    case "CANCEL_SESSION": return "Sesi tidak lagi dapat dibatalkan. Muat ulang data sesi.";
  }
}

export async function issueStockOpnameLifecycleIntent(input: {
  operation: StockOpnameLifecycleOperation;
  sessionId: string;
}): Promise<StockOpnameLifecycleActionResult> {
  if (!(await hasStockAccess())) return { kind: "rejected", message: "Anda tidak memiliki akses ke tindakan opname ini." };
  if (!input || !STOCK_OPNAME_LIFECYCLE_OPERATIONS.includes(input.operation)
      || typeof input.sessionId !== "string" || !UUID_PATTERN.test(input.sessionId)) {
    return { kind: "rejected", message: "Sesi opname tidak valid. Muat ulang halaman." };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("issue_stock_operation_intent", {
    p_operation_key: input.operation,
    p_payload: { session_id: input.sessionId },
  });
  if (error || typeof data !== "string" || !UUID_PATTERN.test(data)) {
    if (error) console.error("[stock-opname-lifecycle] intent issuance failed", {
      operation: input.operation,
      code: safeText(error.code),
      message: safeText(error.message),
    });
    return { kind: "rejected", message: error?.code === "42501"
      ? "Akun ini tidak diizinkan melakukan tindakan opname."
      : "Permintaan belum dapat disiapkan. Muat ulang sesi dan coba lagi." };
  }
  return { kind: "issued", requestId: data, message: "Permintaan siap diterapkan." };
}

export async function applyStockOpnameLifecycleIntent(input: {
  operation: StockOpnameLifecycleOperation;
  requestId: string;
}): Promise<StockOpnameLifecycleActionResult> {
  if (!(await hasStockAccess())) return { kind: "rejected", requestId: input?.requestId, message: "Akun ini tidak diizinkan melakukan tindakan opname." };
  if (!input || !STOCK_OPNAME_LIFECYCLE_OPERATIONS.includes(input.operation)
      || typeof input.requestId !== "string" || !UUID_PATTERN.test(input.requestId)) {
    return { kind: "rejected", message: "Permintaan opname tidak valid." };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("apply_stock_operation_intent", {
    p_request_id: input.requestId,
  });
  if (error) {
    console.error("[stock-opname-lifecycle] intent application failed", {
      operation: input.operation,
      code: safeText(error.code),
      message: safeText(error.message),
    });
    if (error.code === "22023" || error.code === "42501") {
      return { kind: "rejected", requestId: input.requestId, message: error.code === "42501"
        ? "Akun ini tidak diizinkan melakukan tindakan opname."
        : operationMessage(input.operation) };
    }
    return { kind: "error", requestId: input.requestId, message: "Hasil belum terkonfirmasi. Ulangi tindakan tersimpan dengan tombol retry." };
  }

  const result = data as { ok?: boolean; status?: string } | null;
  if (result?.ok === true) {
    const message = input.operation === "SUBMIT_REVIEW"
      ? "Opname diajukan untuk review. Item tetap tersimpan tanpa perubahan."
      : input.operation === "RETURN_TO_COUNTING"
        ? "Sesi kembali ke penghitungan. Hitungan dan pengecualian tetap tersimpan."
        : "Sesi dibatalkan. Riwayat tetap tersimpan dan tidak ada penyesuaian stok yang diposting.";
    return { kind: "success", requestId: input.requestId, message };
  }
  return { kind: "rejected", requestId: input.requestId, message: operationMessage(input.operation) };
}
