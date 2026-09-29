"use server";

import { getProfile } from "@/lib/auth/session";
import { isUuid } from "@/lib/product-audit/context";
import {
  canIssueCorrectionIntent,
  parseApplyCorrectionIntentResult,
  parseCorrectionIntentInput,
  parseCorrectionIntentRequestId,
  parseCorrectionIntentSummary,
  type ApplyCorrectionIntentActionResult,
  type CorrectionField,
  type CorrectionIntentActionResult,
  type CorrectionIntentSummary,
} from "@/lib/product-audit/correction-intent-core";
import { readProductFieldAudit } from "@/lib/product-audit/read";
import { createClient } from "@/lib/supabase/server";

export async function issueProductFieldCorrectionIntentAction(
  formData: FormData,
): Promise<CorrectionIntentActionResult> {
  try {
    const input = parseCorrectionIntentInput(formData);
    if (!input) {
      return { ok: false, code: "VALIDATION", message: "Data koreksi tidak valid. Periksa kembali nilai dan alasannya." };
    }
    const profile = await getProfile();
    if (!profile || !canIssueCorrectionIntent(profile.role, input.fieldKey)) {
      return { ok: false, code: "DENIED", message: "Akun ini tidak memiliki akses untuk menyiapkan koreksi bidang tersebut." };
    }

    const current = await readProductFieldAudit(input.productId);
    if (current.kind !== "ok") {
      return { ok: false, code: "UNAVAILABLE", message: "Data audit belum dapat diperiksa. Muat ulang halaman lalu coba lagi." };
    }
    const field = current.data.fields[input.fieldKey];
    if (!field || field.sourceRowId !== input.sourceImportRowId
      || field.outletId !== input.outletId
      || (input.fieldKey !== "barcode" && current.data.outletId !== input.outletId)
      || field.review?.status !== "SEDANG_DICEK") {
      return { ok: false, code: "STALE", message: "Sumber atau status pemeriksaan sudah berubah. Muat ulang dan mulai pemeriksaan terbaru." };
    }

    const supabase = await createClient();
    const { data, error } = await supabase.rpc("issue_product_field_correction_intent", {
      p_product_id: input.productId,
      p_outlet_id: input.outletId,
      p_field_key: input.fieldKey,
      p_source_import_row_id: input.sourceImportRowId,
      p_corrected_value: input.correctedValue,
      p_reason: input.reason,
      p_barcode_operation: input.barcodeOperation,
    });
    if (error) {
      if (error.code === "40001" || /source changed/i.test(error.message)) {
        return { ok: false, code: "STALE", message: "Sumber iPos berubah saat permintaan disiapkan. Muat ulang halaman." };
      }
      logCorrectionIntentFailure("issue_rpc", error);
      return { ok: false, code: "UNAVAILABLE", message: "Permintaan koreksi belum dapat disiapkan. Coba lagi." };
    }
    if (typeof data !== "string" || !isUuid(data)) {
      return { ok: false, code: "UNAVAILABLE", message: "Permintaan koreksi belum dapat disiapkan. Coba lagi." };
    }
    return { ok: true, requestId: data };
  } catch (error) {
    logCorrectionIntentFailure("issue_action", error);
    return { ok: false, code: "UNAVAILABLE", message: "Terjadi kendala saat menyiapkan koreksi. Coba lagi." };
  }
}

export async function readProductFieldCorrectionIntentAction(
  requestId: string,
): Promise<CorrectionIntentSummary | null> {
  try {
    if (!isUuid(requestId)) return null;
    const profile = await getProfile();
    if (!profile || profile.role === "KASIR") return null;
    const supabase = await createClient();
    const { data, error } = await supabase.rpc("read_product_field_correction_intent", {
      p_request_id: requestId,
    });
    if (error) {
      logCorrectionIntentFailure("read_rpc", error);
      return null;
    }
    const summary = parseCorrectionIntentSummary(requestId, data);
    if (!summary || (profile.role === "GUDANG" && summary.fieldKey !== "barcode" && summary.fieldKey !== "rack_label")) {
      return null;
    }
    return summary;
  } catch (error) {
    logCorrectionIntentFailure("read_action", error);
    return null;
  }
}

/** Applies only the database-stored payload. The browser submits an opaque UUID. */
export async function applyProductFieldCorrectionIntentAction(
  requestIdValue: string,
): Promise<ApplyCorrectionIntentActionResult> {
  try {
    const requestId = parseCorrectionIntentRequestId(requestIdValue);
    if (!requestId) {
      return { ok: false, code: "VALIDATION", message: "Permintaan koreksi tidak valid." };
    }
    const profile = await getProfile();
    if (!profile || profile.role === "KASIR") {
      return { ok: false, code: "DENIED", message: "Akun ini tidak memiliki akses koreksi." };
    }
    const supabase = await createClient();
    const { data, error } = await supabase.rpc("apply_product_field_correction_intent", {
      p_request_id: requestId,
    });
    if (error) {
      if (error.code === "42501") {
        return { ok: false, code: "DENIED", message: "Akun ini tidak memiliki akses koreksi." };
      }
      logCorrectionIntentFailure("apply_rpc", error);
      return { ok: false, code: "UNAVAILABLE", message: "Koreksi belum dapat diproses. Periksa status audit lalu coba lagi." };
    }
    const result = parseApplyCorrectionIntentResult(data);
    if (!result || !result.ok) {
      return { ok: false, code: "UNAVAILABLE", message: "Koreksi belum dapat diproses. Periksa status audit lalu coba lagi." };
    }
    return result;
  } catch (error) {
    logCorrectionIntentFailure("apply_action", error);
    return { ok: false, code: "UNAVAILABLE", message: "Terjadi kendala saat memproses koreksi. Coba lagi." };
  }
}

function logCorrectionIntentFailure(phase: string, error: unknown) {
  const record = error as { code?: unknown; name?: unknown } | null;
  const code = typeof record?.code === "string" && /^[A-Z0-9_]{3,24}$/.test(record.code)
    ? record.code
    : undefined;
  const errorName = typeof record?.name === "string" ? record.name : "UnknownError";
  console.error("Product correction intent failed", { phase, code, errorName });
}

// Keep this compile-time role/field mapping local to the server boundary.
export type ProductCorrectionField = CorrectionField;
