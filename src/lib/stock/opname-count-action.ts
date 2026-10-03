"use server";

import { canAccessSection } from "@/lib/auth/roles";
import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { countInputError } from "@/lib/stock/opname-count-model";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type RecordCountInput = {
  sessionId: string;
  productId: string;
  physicalQuantity: string;
  expectedRevision: number;
  barcodeId: string | null;
};

export type RecordCountActionResult = {
  kind: "issued" | "success" | "stale-item" | "stale-baseline" | "error";
  requestId?: string;
  itemId?: string;
  revision?: number;
  message?: string;
};

function safeText(value: string | null | undefined) {
  return value?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 160) ?? "";
}

function denied(): RecordCountActionResult {
  return { kind: "error", message: "Anda tidak memiliki akses untuk menghitung stok." };
}

async function authorizedProfile() {
  const profile = await getProfile();
  return profile && canAccessSection(profile.role, "stok") ? profile : null;
}

export async function issueRecordCountIntent(input: RecordCountInput): Promise<RecordCountActionResult> {
  const profile = await authorizedProfile();
  if (!profile) return denied();
  if (!input || typeof input !== "object"
      || typeof input.sessionId !== "string" || !UUID_PATTERN.test(input.sessionId)
      || typeof input.productId !== "string" || !UUID_PATTERN.test(input.productId)
      || typeof input.physicalQuantity !== "string"
      || (input.barcodeId !== null && (typeof input.barcodeId !== "string" || !UUID_PATTERN.test(input.barcodeId)))) {
    return { kind: "error", message: "Data item tidak valid. Muat ulang sesi opname." };
  }
  const quantityError = countInputError(input.physicalQuantity);
  if (quantityError) return { kind: "error", message: quantityError };
  if (!Number.isInteger(input.expectedRevision) || input.expectedRevision < 0) {
    return { kind: "error", message: "Revisi item tidak valid. Muat ulang sesi opname." };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("issue_stock_operation_intent", {
    p_operation_key: "RECORD_COUNT",
    p_payload: {
      session_id: input.sessionId,
      product_id: input.productId,
      physical_quantity: Number(input.physicalQuantity.replace(",", ".")),
      expected_revision: input.expectedRevision,
      barcode_id: input.barcodeId,
    },
  });
  if (error || typeof data !== "string" || !UUID_PATTERN.test(data)) {
    if (error) console.error("[stock-opname-count] intent issuance failed", {
      operation: "RECORD_COUNT",
      code: safeText(error.code),
      message: safeText(error.message),
    });
    return { kind: "error", message: error?.code === "42501"
      ? "Anda tidak memiliki izin untuk menghitung item ini."
      : "Permintaan hitung belum dapat disiapkan. Periksa sesi dan coba lagi." };
  }
  return { kind: "issued", requestId: data };
}

export async function applyRecordCountIntent(requestId: string): Promise<RecordCountActionResult> {
  const profile = await authorizedProfile();
  if (!profile) return denied();
  if (typeof requestId !== "string" || !UUID_PATTERN.test(requestId)) return { kind: "error", message: "Permintaan hitung tidak valid." };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("apply_stock_operation_intent", { p_request_id: requestId });
  if (error) {
    console.error("[stock-opname-count] intent application failed", {
      operation: "RECORD_COUNT",
      code: safeText(error.code),
      message: safeText(error.message),
    });
    return { kind: "error", message: error.code === "42501"
      ? "Permintaan ini tidak dapat diakses oleh akun Anda."
      : "Hitungan belum dapat dikonfirmasi. Permintaan tersimpan; coba ulangi dengan tombol yang sama." };
  }

  const result = data as {
    ok?: boolean;
    code?: string;
    reason?: string;
    itemId?: string;
    revision?: number;
  } | null;
  if (result?.ok) {
    return { kind: "success", requestId, itemId: result.itemId, revision: result.revision,
      message: "Hitungan berhasil disimpan." };
  }
  if (result?.code === "STALE_BASELINE" && result.reason === "ITEM_REVISION_MISMATCH") {
    return { kind: "stale-item", requestId,
      message: "Hitungan lain mengubah item ini. Hitungan Anda tidak menggantikan data tersebut; muat ulang dan periksa kembali." };
  }
  if (result?.code === "STALE_BASELINE" && result.reason === "PROJECTION_BASELINE_CHANGED") {
    return { kind: "stale-baseline", requestId,
      message: "Saldo stok berubah sejak opname dimulai. Item ini memerlukan pembaruan baseline dan hitung ulang sebelum dapat disimpan." };
  }
  return { kind: "error", requestId, message: "Hitungan belum dapat disimpan. Muat ulang item dan coba kembali." };
}
