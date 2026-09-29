"use server";

import { revalidatePath } from "next/cache";
import {
  executeProductFieldReview,
  issueProductFieldReviewIntent,
  type CanonicalReviewIntent,
  type ProductFieldReviewActionState,
  type ReviewRpcPayload,
  type StoredReviewIntent,
} from "@/lib/product-audit/review-action-core";
import { getProfile } from "@/lib/auth/session";
import { readProductFieldAudit } from "@/lib/product-audit/read";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/product-audit/context";

export type { ProductFieldReviewActionState } from "@/lib/product-audit/review-action-core";

function canonicalFromRow(requestId: string, value: unknown): StoredReviewIntent | null {
  if (!value || typeof value !== "object") return null;
  const row = value as Record<string, unknown>;
  const payload = row.payload as Record<string, unknown> | undefined;
  if (!payload || row.request_id !== requestId
    || typeof payload.product_id !== "string"
    || !(payload.outlet_id === null || typeof payload.outlet_id === "string")
    || typeof payload.field_key !== "string"
    || (payload.status !== "SEDANG_DICEK" && payload.status !== "SUDAH_DIVERIFIKASI")
    || typeof payload.source_import_row_id !== "string"
    || !(payload.evidence_notes === null || typeof payload.evidence_notes === "string")
    || typeof row.completed !== "boolean") return null;
  const field = payload.field_key as CanonicalReviewIntent["p_field_key"];
  if (!["barcode", "rack_label", "hpp", "selling_price", "quantity", "minimum_quantity"].includes(field)) return null;
  return {
    requestId,
    completed: row.completed,
    payload: {
      p_product_id: payload.product_id,
      p_outlet_id: payload.outlet_id,
      p_field_key: field,
      p_status: payload.status,
      p_source_import_row_id: payload.source_import_row_id,
      p_evidence_notes: payload.evidence_notes,
    },
  };
}

export async function ensureProductFieldReviewIntentAction(formData: FormData) {
  return issueProductFieldReviewIntent(formData, {
    getProfile,
    async readCurrent(productId) {
      const result = await readProductFieldAudit(productId);
      if (result.kind !== "ok") return result;
      return {
        kind: "ok",
        outletId: result.data.outletId,
        fields: Object.fromEntries(Object.entries(result.data.fields).map(([field, record]) => [field, record && {
          outletId: record.outletId,
          sourceRowId: record.sourceRowId,
        }])),
      };
    },
    async issueIntent(payload: CanonicalReviewIntent) {
      const supabase = await createClient();
      const { data, error } = await supabase.rpc("issue_product_field_review_intent", {
        p_product_id: payload.p_product_id,
        p_outlet_id: payload.p_outlet_id,
        p_field_key: payload.p_field_key,
        p_status: payload.p_status,
        p_source_import_row_id: payload.p_source_import_row_id,
        p_evidence_notes: payload.p_evidence_notes,
      });
      return { requestId: typeof data === "string" ? data : null, error };
    },
    logFailure(phase, error) {
      console.error("Product field review intent failed", {
        phase,
        errorName: error instanceof Error ? error.name : "UnknownError",
      });
    },
  });
}

export async function readProductFieldReviewIntentAction(requestId: string): Promise<StoredReviewIntent | null> {
  if (!isUuid(requestId)) return null;
  const profile = await getProfile();
  if (!profile || profile.role === "KASIR") return null;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("read_product_field_review_intent", { p_request_id: requestId });
  if (error) throw new Error("Review intent lookup failed", { cause: { code: error.code } });
  const intent = canonicalFromRow(requestId, data);
  if (intent && profile.role === "GUDANG" && !["barcode", "rack_label", "quantity", "minimum_quantity"].includes(intent.payload.p_field_key)) {
    return null;
  }
  return intent;
}

export async function recordProductFieldReviewAction(
  requestId: string,
  _previousState: ProductFieldReviewActionState,
  formData: FormData,
): Promise<ProductFieldReviewActionState> {
  return executeProductFieldReview(requestId, formData, {
    getProfile,
    readIntent: (requestId) => readProductFieldReviewIntentAction(requestId),
    async callRpc(payload: ReviewRpcPayload) {
      const supabase = await createClient();
      const { error } = await supabase.rpc("record_product_field_review", payload);
      return { error };
    },
    revalidate(paths) {
      for (const path of paths) revalidatePath(path);
    },
    logFailure(phase, error) {
      const errorCode = typeof error === "object" && error !== null && "code" in error
        && typeof error.code === "string" && /^[A-Z0-9_]{3,24}$/.test(error.code)
        ? error.code
        : undefined;
      console.error("Product field review action failed", {
        phase,
        errorName: error instanceof Error ? error.name : "UnknownError",
        errorCode,
      });
    },
  });
}
