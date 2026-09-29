import { canAccessSection, type UserRole } from "../auth/roles.ts";
import { isUuid } from "./context.ts";

export const CORRECTION_FIELDS = ["barcode", "rack_label", "hpp", "selling_price"] as const;
export type CorrectionField = (typeof CORRECTION_FIELDS)[number];
export type BarcodeOperation = "ADD_ALIAS" | "REPLACE_SOURCE";

export type CorrectionIntentInput = {
  productId: string;
  outletId: string | null;
  fieldKey: CorrectionField;
  sourceImportRowId: string;
  correctedValue: string | number;
  reason: string;
  barcodeOperation: BarcodeOperation | null;
};

export type CorrectionIntentSummary = {
  requestId: string;
  productId: string;
  outletId: string | null;
  fieldKey: CorrectionField;
  sourceImportRowId: string;
  barcodeOperation: BarcodeOperation | null;
  completed: boolean;
};

export type CorrectionIntentActionResult =
  | { ok: true; requestId: string }
  | { ok: false; code: "VALIDATION" | "DENIED" | "STALE" | "UNAVAILABLE"; message: string };

export type ApplyCorrectionIntentActionResult =
  | { ok: true; outcome: "APPLIED" | "BARCODE_CONFLICT"; sourceSynchronized: boolean | null }
  | { ok: false; code: "VALIDATION" | "DENIED" | "UNAVAILABLE"; message: string };

export function parseCorrectionIntentRequestId(value: unknown): string | null {
  return typeof value === "string" && isUuid(value) ? value : null;
}

export function parseApplyCorrectionIntentResult(value: unknown): ApplyCorrectionIntentActionResult | null {
  if (!value || typeof value !== "object") return null;
  const result = value as Record<string, unknown>;
  if (result.ok === false && result.code === "BARCODE_CONFLICT") {
    return { ok: true, outcome: "BARCODE_CONFLICT", sourceSynchronized: null };
  }
  if (result.ok !== true || typeof result.sourceSynchronized !== "boolean") return null;
  return { ok: true, outcome: "APPLIED", sourceSynchronized: result.sourceSynchronized };
}

export function canIssueCorrectionIntent(role: UserRole, field: CorrectionField) {
  return canAccessSection(role, "audit-produk")
    && role !== "KASIR"
    && (role !== "GUDANG" || field === "barcode" || field === "rack_label");
}

export function parseCorrectionIntentInput(formData: FormData): CorrectionIntentInput | null {
  const productId = formData.get("productId");
  const outletValue = formData.get("outletId");
  const fieldValue = formData.get("fieldKey");
  const sourceImportRowId = formData.get("sourceImportRowId");
  const rawValue = formData.get("correctedValue");
  const rawReason = formData.get("reason");
  const operationValue = formData.get("barcodeOperation");

  if (typeof productId !== "string" || !isUuid(productId)
    || typeof sourceImportRowId !== "string" || !isUuid(sourceImportRowId)
    || (outletValue !== "" && (typeof outletValue !== "string" || !isUuid(outletValue)))
    || typeof fieldValue !== "string" || !CORRECTION_FIELDS.includes(fieldValue as CorrectionField)
    || typeof rawValue !== "string" || typeof rawReason !== "string") return null;

  const fieldKey = fieldValue as CorrectionField;
  const outletId = outletValue === "" ? null : outletValue as string;
  if ((fieldKey === "barcode" && outletId !== null)
    || (fieldKey !== "barcode" && outletId === null)) return null;

  let barcodeOperation: BarcodeOperation | null = null;
  if (fieldKey === "barcode") {
    if (operationValue !== "ADD_ALIAS" && operationValue !== "REPLACE_SOURCE") return null;
    barcodeOperation = operationValue;
  } else if (operationValue !== "") {
    return null;
  }

  const reason = rawReason.replace(/^[\s]+|[\s]+$/g, "");
  if (!reason) return null;

  let correctedValue: string | number;
  if (fieldKey === "barcode" || fieldKey === "rack_label") {
    correctedValue = rawValue;
    if (!rawValue.replace(/^[\s]+|[\s]+$/g, "") || /[\u0000-\u001f\u007f-\u009f]/u.test(rawValue)) return null;
    if (fieldKey === "barcode" && rawValue.replace(/^[\s]+|[\s]+$/g, "").length > 256) return null;
  } else {
    // Accept plain decimal input here. A currency-formatted UI can normalize
    // Indonesian separators before this server action is called.
    if (!/^\d+(?:\.\d{1,2})?$/.test(rawValue.trim())) return null;
    correctedValue = Number(rawValue.trim());
    if (!Number.isFinite(correctedValue) || correctedValue >= 1_000_000_000_000) return null;
  }

  return { productId, outletId, fieldKey, sourceImportRowId, correctedValue, reason, barcodeOperation };
}

export function parseCorrectionIntentSummary(requestId: string, value: unknown): CorrectionIntentSummary | null {
  if (!value || typeof value !== "object") return null;
  const row = value as Record<string, unknown>;
  const field = row.field_key;
  const operation = row.barcode_operation;
  if (row.request_id !== requestId || typeof row.product_id !== "string" || !isUuid(row.product_id)
    || !(row.outlet_id === null || (typeof row.outlet_id === "string" && isUuid(row.outlet_id)))
    || typeof field !== "string" || !CORRECTION_FIELDS.includes(field as CorrectionField)
    || typeof row.source_import_row_id !== "string" || !isUuid(row.source_import_row_id)
    || !(operation === null || operation === "ADD_ALIAS" || operation === "REPLACE_SOURCE")
    || typeof row.completed !== "boolean") return null;
  if ((field === "barcode" && (row.outlet_id !== null || operation === null))
    || (field !== "barcode" && (row.outlet_id === null || operation !== null))) return null;
  return {
    requestId,
    productId: row.product_id,
    outletId: row.outlet_id,
    fieldKey: field as CorrectionField,
    sourceImportRowId: row.source_import_row_id,
    barcodeOperation: operation as BarcodeOperation | null,
    completed: row.completed,
  };
}
