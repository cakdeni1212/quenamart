import "server-only";

import { redirect } from "next/navigation";
import { canAccessSection, type UserRole } from "@/lib/auth/roles";
import { requireProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "./context";

type FindingCode = string;
type FieldKey = "barcode" | "rack_label" | "hpp" | "selling_price" | "quantity" | "minimum_quantity";

type ProductDetailRow = {
  product_id: string;
  sku: string;
  name: string;
  category_label: string | null;
  barcode: string | null;
  selling_price: number | string | null;
  hpp: number | string | null;
  quantity: number | string | null;
  minimum_quantity: number | string | null;
  rack_label: string | null;
  finding_codes: FindingCode[];
};

type ReadValue = string | number | null;

export type FieldAuditRecord = {
  field: FieldKey;
  outletId: string | null;
  sourceRowId: string | null;
  batchId: string | null;
  sourceValue: ReadValue;
  currentValue: ReadValue;
  override: {
    value: string | number | null;
    reason: string;
    correctedAt: string;
    correctedBy: string;
  } | null;
  review: {
    status: string;
    reviewedAt: string;
  } | null;
  reconciliation: {
    eventType: string;
    sourceRowId: string;
    createdAt: string;
    sourceValue: string | number | null;
    effectiveValue: string | number | null;
  } | null;
};

export type ProductFieldAuditReadModel = {
  role: UserRole;
  product: {
    id: string;
    sku: string;
    name: string;
    category: string | null;
    findingCodes: FindingCode[];
  };
  outletId: string;
  stock: {
    quantity: ReadValue;
    minimumQuantity: ReadValue;
    sourceRowId: string | null;
  };
  activeBarcodes: Array<{ value: string; sourceRowId: string | null }>;
  fields: Partial<Record<FieldKey, FieldAuditRecord>>;
  financial?: {
    hpp: ReadValue;
    sellingPrice: ReadValue;
  };
};

export type ProductFieldAuditResult =
  | { kind: "not-found" }
  | { kind: "error" }
  | { kind: "ok"; data: ProductFieldAuditReadModel };

type DbRow = Record<string, unknown>;

function displayScalar(value: unknown): string | number | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "string" || typeof value === "number") return value;
  return JSON.stringify(value);
}

function reviewFor(rows: DbRow[], field: FieldKey, outletId: string | null, sourceRowId: string | null) {
  if (!sourceRowId) return null;
  const row = rows.find((item) => item.field_key === field
    && item.outlet_id === outletId
    && item.source_import_row_id === sourceRowId);
  return row ? { status: String(row.status), reviewedAt: String(row.reviewed_at) } : null;
}

function overrideFor(rows: DbRow[], field: FieldKey, outletId: string | null, barcodeId?: string) {
  const row = rows.find((item) => item.field_key === field
    && item.outlet_id === outletId
    && (field !== "barcode" || item.barcode_id === barcodeId));
  if (!row) return null;
  return {
    value: displayScalar(row.corrected_value),
    reason: String(row.reason),
    correctedAt: String(row.corrected_at),
    correctedBy: String(row.corrected_by),
  };
}

function reconciliationFor(rows: DbRow[], field: FieldKey, outletId: string | null, overrideId?: string | null) {
  const row = rows.find((item) => item.field_key === field
    && item.outlet_id === outletId
    && (!overrideId || item.override_id === overrideId));
  if (!row) return null;
  return {
    eventType: String(row.event_type),
    sourceRowId: String(row.source_import_row_id),
    createdAt: String(row.created_at),
    sourceValue: displayScalar(row.source_value),
    effectiveValue: displayScalar(row.effective_value),
  };
}

export async function readProductFieldAudit(productId: string): Promise<ProductFieldAuditResult> {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "audit-produk")) redirect("/dashboard");
  if (!isUuid(productId)) return { kind: "not-found" };

  const manager = profile.role === "OWNER" || profile.role === "ADMIN";
  const allowedFields: FieldKey[] = manager
    ? ["barcode", "rack_label", "hpp", "selling_price", "quantity", "minimum_quantity"]
    : ["barcode", "rack_label", "quantity", "minimum_quantity"];
  const supabase = await createClient();

  const [detailResult, snapshotResult] = await Promise.all([
    supabase.rpc("product_workspace_detail", { p_product_id: productId }),
    supabase.rpc("product_workspace_latest_snapshot"),
  ]);
  if (detailResult.error || snapshotResult.error) return { kind: "error" };
  const detail = ((detailResult.data ?? []) as ProductDetailRow[])[0];
  const snapshot = ((snapshotResult.data ?? []) as Array<{ batch_id: string; outlet_id: string }>)[0];
  if (!detail || !snapshot) return { kind: "not-found" };

  const safeReviewFields = manager
    ? allowedFields
    : ["barcode", "rack_label", "quantity", "minimum_quantity"] as FieldKey[];
  const safeEventFields = manager ? allowedFields.slice(0, 4) : ["barcode", "rack_label"] as FieldKey[];
  const [sourceResult, financialSourceResult, barcodeResult, inventoryResult, overrideResult, reviewResult, eventResult] = await Promise.all([
    supabase.rpc("read_product_field_source", { p_product_id: productId, p_outlet_id: snapshot.outlet_id }),
    manager
      ? supabase.rpc("read_product_financial_field_source", { p_product_id: productId, p_outlet_id: snapshot.outlet_id })
      : Promise.resolve({ data: null, error: null }),
    supabase.from("product_barcodes").select("id, barcode, source_import_row_id")
      .eq("product_id", productId).eq("is_active", true).order("created_at", { ascending: true }),
    supabase.from("product_inventory").select("quantity, minimum_quantity, source_import_row_id")
      .eq("product_id", productId).eq("outlet_id", snapshot.outlet_id).maybeSingle(),
    supabase.from("product_field_overrides")
      .select("id, field_key, outlet_id, barcode_id, corrected_value, reason, source_import_row_id, corrected_by, corrected_at")
      .eq("product_id", productId).eq("is_active", true).in("field_key", allowedFields),
    supabase.from("product_field_audit_reviews")
      .select("field_key, outlet_id, status, source_import_row_id, reviewer_id, reviewed_at, barcode_id")
      .eq("product_id", productId).in("field_key", safeReviewFields)
      .order("reviewed_at", { ascending: false }),
    supabase.from("product_field_reconciliation_events")
      .select("field_key, outlet_id, override_id, event_type, source_import_row_id, source_value, effective_value, created_at")
      .eq("product_id", productId).eq("outlet_id", snapshot.outlet_id).in("field_key", safeEventFields)
      .order("created_at", { ascending: false }),
  ]);

  if (sourceResult.error || financialSourceResult.error || barcodeResult.error || inventoryResult.error
    || overrideResult.error || reviewResult.error || eventResult.error) return { kind: "error" };

  const source = ((sourceResult.data ?? []) as DbRow[])[0] ?? {};
  const financialSource = ((financialSourceResult.data ?? []) as DbRow[])[0] ?? {};
  const barcodes = (barcodeResult.data ?? []) as DbRow[];
  const inventory = (inventoryResult.data ?? {}) as DbRow;
  const overrides = (overrideResult.data ?? []) as DbRow[];
  const reviews = (reviewResult.data ?? []) as DbRow[];
  const events = (eventResult.data ?? []) as DbRow[];

  const specs: Array<{
    field: FieldKey;
    outletId: string | null;
    sourceRowId: string | null;
    batchId: string | null;
    sourceValue: unknown;
    currentValue: unknown;
    barcodeId?: string;
  }> = [
    {
      field: "barcode", outletId: null,
      sourceRowId: typeof source.barcode_source_import_row_id === "string" ? source.barcode_source_import_row_id : null,
      batchId: typeof source.barcode_batch_id === "string" ? source.barcode_batch_id : null,
      sourceValue: source.barcode_source,
      currentValue: barcodes.map((row) => row.barcode),
    },
    {
      field: "rack_label", outletId: snapshot.outlet_id,
      sourceRowId: typeof source.rack_source_import_row_id === "string" ? source.rack_source_import_row_id : null,
      batchId: typeof source.rack_batch_id === "string" ? source.rack_batch_id : null,
      sourceValue: source.rack_source,
      currentValue: detail.rack_label,
    },
    {
      field: "quantity", outletId: snapshot.outlet_id,
      sourceRowId: typeof inventory.source_import_row_id === "string" ? inventory.source_import_row_id : null,
      batchId: null, sourceValue: null, currentValue: detail.quantity,
    },
    {
      field: "minimum_quantity", outletId: snapshot.outlet_id,
      sourceRowId: typeof inventory.source_import_row_id === "string" ? inventory.source_import_row_id : null,
      batchId: null, sourceValue: null, currentValue: detail.minimum_quantity,
    },
  ];

  if (manager) {
    specs.push(
      {
        field: "hpp", outletId: snapshot.outlet_id,
        sourceRowId: typeof financialSource.hpp_source_import_row_id === "string" ? financialSource.hpp_source_import_row_id : null,
        batchId: typeof financialSource.hpp_batch_id === "string" ? financialSource.hpp_batch_id : null,
        sourceValue: financialSource.hpp_source, currentValue: detail.hpp,
      },
      {
        field: "selling_price", outletId: snapshot.outlet_id,
        sourceRowId: typeof financialSource.selling_price_source_import_row_id === "string" ? financialSource.selling_price_source_import_row_id : null,
        batchId: typeof financialSource.selling_price_batch_id === "string" ? financialSource.selling_price_batch_id : null,
        sourceValue: financialSource.selling_price_source, currentValue: detail.selling_price,
      },
    );
  }

  const fields: ProductFieldAuditReadModel["fields"] = {};
  for (const spec of specs) {
    const activeBarcodeOverride = overrides.find((row) => row.field_key === spec.field
      && row.outlet_id === spec.outletId && (!spec.barcodeId || row.barcode_id === spec.barcodeId));
    const matchingEvents = events.filter((row) => row.field_key === spec.field
      && row.outlet_id === spec.outletId
      && (!activeBarcodeOverride || row.override_id === activeBarcodeOverride.id));
    fields[spec.field] = {
      field: spec.field,
      outletId: spec.outletId,
      sourceRowId: spec.sourceRowId,
      batchId: spec.batchId,
      sourceValue: displayScalar(spec.sourceValue),
      currentValue: displayScalar(spec.currentValue),
      override: overrideFor(overrides, spec.field, spec.outletId, spec.barcodeId),
      review: reviewFor(reviews, spec.field, spec.outletId, spec.sourceRowId),
      reconciliation: activeBarcodeOverride
        ? reconciliationFor(matchingEvents, spec.field, spec.outletId,
          typeof activeBarcodeOverride.id === "string" ? activeBarcodeOverride.id : null)
        : null,
    };
  }

  return {
    kind: "ok",
    data: {
      role: profile.role,
      product: {
        id: detail.product_id,
        sku: detail.sku,
        name: detail.name,
        category: detail.category_label,
        findingCodes: detail.finding_codes ?? [],
      },
      outletId: snapshot.outlet_id,
      stock: {
        quantity: displayScalar(detail.quantity),
        minimumQuantity: displayScalar(detail.minimum_quantity),
        sourceRowId: typeof inventory.source_import_row_id === "string" ? inventory.source_import_row_id : null,
      },
      activeBarcodes: barcodes.map((row) => ({
        value: String(row.barcode),
        sourceRowId: typeof row.source_import_row_id === "string" ? row.source_import_row_id : null,
      })),
      fields,
      ...(manager ? { financial: {
        hpp: displayScalar(detail.hpp),
        sellingPrice: displayScalar(detail.selling_price),
      } } : {}),
    },
  };
}
