"use server";

import { redirect } from "next/navigation";
import { canAccessSection } from "@/lib/auth/roles";
import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { getActiveStockOutletId } from "@/lib/stock/opname-create-read";

export type CreateStockOpnameState = { error: string | null };

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function safeErrorText(value: string | null | undefined) {
  return value?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240) ?? "";
}

function errorMessage(error: { code?: string | null; message?: string | null }) {
  const message = safeErrorText(error.message).toLowerCase();
  if (message.includes("stock_opname_no_active_overlap")) {
    return "Satu atau beberapa produk sudah tercakup dalam sesi opname aktif. Selesaikan atau batalkan sesi tersebut terlebih dahulu.";
  }
  if (message.includes("full opname requires") || message.includes("partial scope contains")) {
    return "Sebagian saldo belum memiliki baseline yang dapat digunakan. Muat ulang informasi stok sebelum membuat opname.";
  }
  if (error.code === "42501") return "Anda tidak memiliki izin untuk membuat sesi opname.";
  return "Sesi opname belum dapat dibuat. Periksa kembali pilihan dan coba lagi.";
}

function failed(error: string): CreateStockOpnameState {
  return { error };
}

export async function createStockOpname(
  _previous: CreateStockOpnameState,
  formData: FormData,
): Promise<CreateStockOpnameState> {
  const profile = await getProfile();
  if (!profile || !canAccessSection(profile.role, "stok")) {
    return failed("Anda tidak memiliki akses untuk membuat opname stok.");
  }

  const scope = formData.get("scope_type");
  if (scope !== "FULL" && scope !== "PARTIAL") return failed("Pilih jenis opname terlebih dahulu.");
  if (formData.get("confirm") !== "yes") return failed("Konfirmasikan pembuatan sesi opname terlebih dahulu.");

  const selected = formData.getAll("product_id");
  const productIds = [...new Set(selected.filter((value): value is string => typeof value === "string"))];
  if (scope === "FULL" && productIds.length > 0) return failed("Pilihan produk hanya digunakan untuk opname sebagian.");
  if (scope === "PARTIAL" && productIds.length === 0) return failed("Pilih minimal satu produk untuk opname sebagian.");
  if (productIds.some((id) => !UUID_PATTERN.test(id))) return failed("Daftar produk tidak valid. Muat ulang pencarian dan coba lagi.");

  const outletId = await getActiveStockOutletId();
  if (!outletId) return failed("Outlet dengan periode saldo stok aktif belum tersedia.");

  const supabase = await createClient();
  const payload = {
    outlet_id: outletId,
    scope_type: scope,
    product_ids: scope === "FULL" ? [] : productIds,
  };
  const { data: requestId, error: issueError } = await supabase.rpc("issue_stock_operation_intent", {
    p_operation_key: "CREATE_SESSION",
    p_payload: payload,
  });
  if (issueError || typeof requestId !== "string" || !UUID_PATTERN.test(requestId)) {
    if (issueError) console.error("[stock-opname-create] intent issuance failed", {
      operation: "CREATE_SESSION",
      code: safeErrorText(issueError.code),
      message: safeErrorText(issueError.message),
    });
    return failed(issueError ? errorMessage(issueError) : "Permintaan pembuatan sesi tidak dapat disiapkan.");
  }

  const { data: result, error: applyError } = await supabase.rpc("apply_stock_operation_intent", {
    p_request_id: requestId,
  });
  if (applyError) {
    console.error("[stock-opname-create] intent application failed", {
      operation: "CREATE_SESSION",
      code: safeErrorText(applyError.code),
      message: safeErrorText(applyError.message),
    });
    return failed(errorMessage(applyError));
  }

  const applied = result as { ok?: boolean; code?: string; sessionId?: string } | null;
  if (!applied?.ok || !applied.sessionId || !UUID_PATTERN.test(applied.sessionId)) {
    if (applied?.code === "INTENT_SUPERSEDED" || applied?.code === "STALE_BASELINE") {
      return failed("Permintaan opname sudah berubah. Muat ulang halaman sebelum mencoba lagi.");
    }
    return failed("Sesi opname belum dapat dibuat. Muat ulang informasi dan coba lagi.");
  }

  redirect(`/stok/opname/${applied.sessionId}`);
}
