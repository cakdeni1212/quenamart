import type { IposRawRow } from "./xlsx-parser.ts";
import { IPOS_NORMALIZATION_VERSION, normalizeProductNameKey, normalizeRawIposRow, parseIposNumber, type NormalizedIposRow } from "./normalize.ts";

export type PreflightRawRow = {
  id: string;
  batch_id: string;
  outlet_id: string;
  source_row_number: number;
  raw_data: IposRawRow;
  status: string;
  product_id: string | null;
};

export type ExistingProduct = { id: string; sku: string; name: string };
export type ExistingBarcode = {
  id: string;
  product_id: string;
  barcode: string;
  source_import_row_id: string | null;
};
export type ActiveOverride = {
  id: string;
  product_id: string;
  barcode_id: string | null;
  outlet_id: string | null;
  field_key: string;
  corrected_value: unknown;
};

export type IposPreflightInput = {
  batchId: string;
  outletId: string;
  rows: PreflightRawRow[];
  existingProducts: ExistingProduct[];
  existingBarcodes: ExistingBarcode[];
  activeOverrides: ActiveOverride[];
  sampleLimit?: number;
};

type RowState = {
  source: PreflightRawRow;
  normalized: NormalizedIposRow;
  invalid: boolean;
  action: "CREATE" | "UPDATE" | "INVALID";
  productId: string | null;
};

type Sample = { sku: string | null; sourceSku?: string | number | boolean | null; sourceRow: number; field?: string; code?: string };

const DEPLOYED_FINDINGS = [
  "MISSING_BARCODE",
  "MALFORMED_BARCODE",
  "DUPLICATE_BARCODE",
  "ZERO_OR_MISSING_HPP",
  "SELLING_PRICE_BELOW_HPP",
  "ZERO_STOCK",
  "STOCK_AT_OR_BELOW_MINIMUM",
  "MISSING_RACK",
  "DUPLICATE_PRODUCT_NAME",
] as const;

function sampleSku(row: RowState): string | null {
  return row.normalized.sku ?? (typeof row.source.raw_data.KODEITEM === "string" ? row.source.raw_data.KODEITEM : null);
}

function rowSample(row: RowState, field?: string, code?: string): Sample {
  return {
    sku: sampleSku(row),
    sourceSku: row.source.raw_data.KODEITEM,
    sourceRow: row.source.source_row_number,
    ...(field ? { field } : {}),
    ...(code ? { code } : {}),
  };
}

function isValidNumber(value: NormalizedIposRow["hpp"]): value is Extract<typeof value, { state: "valid" }> {
  return value.state === "valid";
}

function numericEqual(left: unknown, field: "HARGAPOKOK" | "HARGAJUAL" | "STOK" | "STOKMIN", right: NormalizedIposRow["hpp"]): boolean {
  if (right.state === "invalid") return true; // invalid source values are not applied by the documented import contract
  if (right.state === "blank") return left === null;
  const parsedLeft = parseIposNumber(left, field);
  return parsedLeft.state === "valid" && parsedLeft.value.units === right.value.units;
}

function sourceValueForOverride(row: RowState, override: ActiveOverride): unknown | { skip: true } {
  const normalized = row.normalized;
  switch (override.field_key) {
    case "name": return normalized.name;
    case "category_label": return normalized.categoryLabel;
    case "brand_label": return normalized.brandLabel;
    case "unit_label": return normalized.unitLabel;
    case "department_label": return normalized.departmentLabel;
    case "source_description": return normalized.sourceDescription;
    case "source_reference_code": return normalized.sourceReferenceCode;
    case "rack_label": return normalized.rackLabel;
    case "barcode": {
      const raw = row.source.raw_data.KODEBARCODE;
      return typeof raw === "string" && raw.trim() !== "" ? raw.trim() : normalized.barcode;
    }
    case "quantity": return normalized.quantity.state === "invalid" ? { skip: true } : normalized.quantity;
    case "minimum_quantity": return normalized.minimumQuantity.state === "invalid" ? { skip: true } : normalized.minimumQuantity;
    case "selling_price": return normalized.sellingPrice.state === "invalid" ? { skip: true } : normalized.sellingPrice;
    case "hpp": return normalized.hpp.state === "invalid" ? { skip: true } : normalized.hpp;
    default: return { skip: true };
  }
}

function overrideDiffers(override: ActiveOverride, incoming: unknown | { skip: true }): boolean {
  if (incoming && typeof incoming === "object" && "skip" in incoming) return false;
  if (["quantity", "minimum_quantity", "selling_price", "hpp"].includes(override.field_key)) {
    const numericField = override.field_key === "quantity" ? "STOK"
      : override.field_key === "minimum_quantity" ? "STOKMIN"
      : override.field_key === "selling_price" ? "HARGAJUAL" : "HARGAPOKOK";
    const result = incoming as NormalizedIposRow["hpp"];
    return !numericEqual(override.corrected_value, numericField, result);
  }
  return incoming !== override.corrected_value;
}

function addSample(samples: Record<string, Sample[]>, key: string, sample: Sample, limit: number) {
  const group = samples[key] ?? (samples[key] = []);
  if (group.length < limit) group.push(sample);
}

function exactGroups<T>(items: T[], keyOf: (item: T) => string | null): Map<string, T[]> {
  const result = new Map<string, T[]>();
  for (const item of items) {
    const key = keyOf(item);
    if (key === null || key === "") continue;
    const group = result.get(key) ?? [];
    group.push(item);
    result.set(key, group);
  }
  return result;
}

export function analyzeIposPreflight(input: IposPreflightInput) {
  const sampleLimit = input.sampleLimit ?? 30;
  const productsBySku = new Map(input.existingProducts.map((product) => [product.sku, product]));
  const rowStates: RowState[] = input.rows.map((source) => {
    const normalized = normalizeRawIposRow(source.raw_data);
    return { source, normalized, invalid: false, action: "INVALID", productId: null };
  });

  const skuGroups = exactGroups(rowStates.filter((row) => row.normalized.sku), (row) => row.normalized.sku);
  const duplicateSkuRows = new Set<RowState>();
  const duplicateSkuGroups = [...skuGroups.values()].filter((group) => group.length > 1).length;
  for (const group of skuGroups.values()) {
    if (group.length > 1) for (const row of group) duplicateSkuRows.add(row);
  }

  const diagnosticCounts: Record<string, number> = {
    INVALID_OR_MISSING_SKU: 0,
    MISSING_PRODUCT_NAME: 0,
    DUPLICATE_SKU_IN_BATCH: 0,
    INVALID_NUMERIC_VALUE: 0,
    INVALID_TEXT_TYPE: 0,
    INVALID_BARCODE_TYPE: 0,
  };
  const findingCounts: Record<(typeof DEPLOYED_FINDINGS)[number], number> = Object.fromEntries(
    DEPLOYED_FINDINGS.map((code) => [code, 0]),
  ) as Record<(typeof DEPLOYED_FINDINGS)[number], number>;
  const exceptionSamples: Record<string, Sample[]> = {};
  const auditCodesBySourceRow = new Map<number, string[]>();
  const recordFinding = (row: RowState, code: (typeof DEPLOYED_FINDINGS)[number]) => {
    const codes = auditCodesBySourceRow.get(row.source.source_row_number) ?? [];
    if (codes.includes(code)) return;
    codes.push(code);
    auditCodesBySourceRow.set(row.source.source_row_number, codes);
    findingCounts[code] += 1;
    addSample(exceptionSamples, code, rowSample(row), sampleLimit);
  };

  for (const row of rowStates) {
    for (const issue of row.normalized.issues) {
      diagnosticCounts[issue.code] = (diagnosticCounts[issue.code] ?? 0) + 1;
      addSample(exceptionSamples, issue.code, rowSample(row, issue.field, issue.code), sampleLimit);
    }
    if (duplicateSkuRows.has(row)) {
      row.invalid = true;
      diagnosticCounts.DUPLICATE_SKU_IN_BATCH += 1;
      addSample(exceptionSamples, "DUPLICATE_SKU_IN_BATCH", rowSample(row, "KODEITEM"), sampleLimit);
    }
    if (!row.normalized.sku || !row.normalized.name || duplicateSkuRows.has(row)) row.invalid = true;
    if (!row.invalid) {
      const existing = productsBySku.get(row.normalized.sku!);
      row.productId = existing?.id ?? null;
      row.action = existing ? "UPDATE" : "CREATE";
    }
  }

  const candidates = rowStates.filter((row) => !row.invalid);
  const candidateByExistingId = new Map(candidates.filter((row) => row.productId).map((row) => [row.productId!, row]));
  const activeOverridesByProduct = new Map<string, ActiveOverride[]>();
  for (const override of input.activeOverrides) {
    if (!override.product_id || (override.outlet_id !== null && override.outlet_id !== input.outletId)) continue;
    const list = activeOverridesByProduct.get(override.product_id) ?? [];
    list.push(override);
    activeOverridesByProduct.set(override.product_id, list);
  }

  const activeBarcodesById = new Map(input.existingBarcodes.map((barcode) => [barcode.id, barcode]));
  const overrideConflicts: Array<{ sku: string; sourceRow: number; field: string }> = [];
  for (const row of candidates) {
    if (!row.productId) continue;
    const rowOverrides = activeOverridesByProduct.get(row.productId) ?? [];
    for (const override of rowOverrides) {
      if (override.field_key === "barcode") {
        const current = override.barcode_id ? activeBarcodesById.get(override.barcode_id) : undefined;
        if (!current || current.source_import_row_id === null) continue;
      }
      const incoming = sourceValueForOverride(row, override);
      if (overrideDiffers(override, incoming)) {
        overrideConflicts.push({ sku: row.normalized.sku!, sourceRow: row.source.source_row_number, field: override.field_key });
        addSample(exceptionSamples, "OVERRIDE_CONFLICT", rowSample(row, override.field_key), sampleLimit);
      }
    }
  }

  // Project exact-name collisions against the product master. Existing products
  // omitted from this snapshot remain present, per the approved import contract.
  const projectedNames = new Map<string, { nameKey: string; candidate: RowState | null }>();
  for (const product of input.existingProducts) {
    projectedNames.set(product.id, { nameKey: normalizeProductNameKey(product.name), candidate: null });
  }
  for (const row of candidates) {
    const identity = row.productId ?? `new:${row.normalized.sku}`;
    const nameOverride = row.productId
      ? (activeOverridesByProduct.get(row.productId) ?? []).find((item) => item.field_key === "name")
      : undefined;
    const nameKey = nameOverride && overrideDiffers(nameOverride, sourceValueForOverride(row, nameOverride))
      ? normalizeProductNameKey(String(nameOverride.corrected_value))
      : row.normalized.nameKey!;
    projectedNames.set(identity, { nameKey, candidate: row });
  }
  const nameGroups = exactGroups([...projectedNames.entries()], ([, value]) => value.nameKey);
  const duplicateNameRows = new Set<RowState>();
  let duplicateNameGroupCount = 0;
  for (const [nameKey, group] of nameGroups) {
    if (group.length < 2) continue;
    const candidateRows = group.map(([, item]) => item.candidate).filter((row): row is RowState => row !== null);
    if (candidateRows.length === 0) continue;
    duplicateNameGroupCount += 1;
    for (const row of candidateRows) {
      duplicateNameRows.add(row);
    }
    for (const row of candidateRows) recordFinding(row, "DUPLICATE_PRODUCT_NAME");
    void nameKey;
  }

  // Compute the prospective active barcode owners: keep manual associations,
  // replace imported associations for candidate products, then add valid iPos
  // candidates unless an active barcode override blocks that value.
  const projectedBarcodeOwners = new Map<string, Set<string>>();
  const candidateRowsByOwner = new Map<string, RowState>();
  const candidateOwner = (row: RowState) => row.productId ?? `new:${row.normalized.sku}`;
  const hasBarcodeOverride = (row: RowState) => row.productId
    ? (activeOverridesByProduct.get(row.productId) ?? []).some((override) => {
      if (override.field_key !== "barcode" || !override.barcode_id) return false;
      const current = activeBarcodesById.get(override.barcode_id);
      return current !== undefined && current.source_import_row_id !== null;
    })
    : false;
  for (const barcode of input.existingBarcodes) {
    const candidate = candidateByExistingId.get(barcode.product_id);
    if (candidate && barcode.source_import_row_id !== null) {
      const keptByOverride = (activeOverridesByProduct.get(barcode.product_id) ?? [])
        .some((override) => override.field_key === "barcode" && override.barcode_id === barcode.id);
      const incomingState = candidate.normalized.barcodeState;
      const incomingBarcode = candidate.normalized.barcode;
      const keepExistingForInvalidSource = incomingState === "MALFORMED" || incomingState === "INVALID_TYPE";
      const keepExistingForSameValue = incomingState === "VALID" && incomingBarcode === barcode.barcode;
      if (!keptByOverride && !keepExistingForInvalidSource && !keepExistingForSameValue) continue;
    }
    const owners = projectedBarcodeOwners.get(barcode.barcode) ?? new Set<string>();
    owners.add(barcode.product_id);
    projectedBarcodeOwners.set(barcode.barcode, owners);
  }
  for (const row of candidates) {
    const owner = candidateOwner(row);
    candidateRowsByOwner.set(owner, row);
    if (row.normalized.barcodeState !== "VALID" || !row.normalized.barcode || hasBarcodeOverride(row)) continue;
    const owners = projectedBarcodeOwners.get(row.normalized.barcode) ?? new Set<string>();
    owners.add(owner);
    projectedBarcodeOwners.set(row.normalized.barcode, owners);
  }
  const duplicateBarcodeRows = new Set<RowState>();
  let duplicateBarcodeGroupCount = 0;
  for (const [barcode, owners] of projectedBarcodeOwners) {
    if (owners.size < 2) continue;
    const candidateRowsInGroup = [...owners].map((owner) => candidateRowsByOwner.get(owner)).filter((row): row is RowState => row !== undefined);
    if (candidateRowsInGroup.length === 0) continue;
    duplicateBarcodeGroupCount += 1;
    for (const row of candidateRowsInGroup) {
      duplicateBarcodeRows.add(row);
    }
    for (const row of candidateRowsInGroup) recordFinding(row, "DUPLICATE_BARCODE");
    void barcode;
  }

  for (const row of candidates) {
    const n = row.normalized;
    if (n.barcodeState === "BLANK") {
      recordFinding(row, "MISSING_BARCODE");
    }
    if (n.barcodeState === "MALFORMED") {
      recordFinding(row, "MALFORMED_BARCODE");
    }
    if (n.hpp.state === "blank" || (isValidNumber(n.hpp) && n.hpp.value.units === BigInt(0))) {
      recordFinding(row, "ZERO_OR_MISSING_HPP");
    }
    if (isValidNumber(n.hpp) && isValidNumber(n.sellingPrice) && n.sellingPrice.value.units < n.hpp.value.units) {
      recordFinding(row, "SELLING_PRICE_BELOW_HPP");
    }
    if (isValidNumber(n.quantity) && n.quantity.value.units === BigInt(0)) {
      recordFinding(row, "ZERO_STOCK");
    }
    if (isValidNumber(n.quantity) && isValidNumber(n.minimumQuantity)
      && n.minimumQuantity.value.units > BigInt(0) && n.quantity.value.units <= n.minimumQuantity.value.units) {
      recordFinding(row, "STOCK_AT_OR_BELOW_MINIMUM");
    }
    if (!n.rackLabel && !n.issues.some((issue) => issue.code === "INVALID_TEXT_TYPE" && issue.field === "RAK")) {
      recordFinding(row, "MISSING_RACK");
    }
  }

  let numericParseErrors = 0;
  for (const row of rowStates) {
    const values = [row.normalized.hpp, row.normalized.sellingPrice, row.normalized.quantity, row.normalized.minimumQuantity];
    numericParseErrors += values.filter((value) => value.state === "invalid").length;
  }

  const duplicateBarcodeCount = duplicateBarcodeRows.size;
  const duplicateNameCount = duplicateNameRows.size;
  const blankBarcodeCount = rowStates.filter((row) => row.normalized.barcodeState === "BLANK").length;
  const malformedBarcodeCount = rowStates.filter((row) => row.normalized.barcodeState === "MALFORMED").length;
  const negativeStockCount = rowStates.filter((row) => row.normalized.quantity.value !== null && row.normalized.quantity.value.units < BigInt(0)).length;
  const blankRackCount = rowStates.filter((row) => !row.normalized.rackLabel
    && !row.normalized.issues.some((issue) => issue.code === "INVALID_TEXT_TYPE" && issue.field === "RAK")).length;
  const blankRackWithPositiveStockCount = rowStates.filter((row) => !row.normalized.rackLabel
    && row.normalized.quantity.state === "valid" && row.normalized.quantity.value.units > BigInt(0)).length;
  const hppZeroOrMissingCount = findingCounts.ZERO_OR_MISSING_HPP;
  const sellingBelowHppCount = findingCounts.SELLING_PRICE_BELOW_HPP;
  const sellingEqualHppCount = candidates.filter((row) => isValidNumber(row.normalized.hpp)
    && isValidNumber(row.normalized.sellingPrice)
    && row.normalized.hpp.value.units === row.normalized.sellingPrice.value.units).length;
  const zeroStockCount = findingCounts.ZERO_STOCK;
  const reorderCount = findingCounts.STOCK_AT_OR_BELOW_MINIMUM;

  const missingSkuCount = rowStates.filter((row) => !row.normalized.sku).length;
  const missingNameCount = rowStates.filter((row) => !row.normalized.name).length;
  const duplicateSkuCount = duplicateSkuRows.size;
  diagnosticCounts.INVALID_OR_MISSING_SKU = missingSkuCount;
  diagnosticCounts.MISSING_PRODUCT_NAME = missingNameCount;
  diagnosticCounts.DUPLICATE_SKU_IN_BATCH = duplicateSkuCount;
  for (const row of rowStates) {
    if (!row.normalized.sku) addSample(exceptionSamples, "INVALID_OR_MISSING_SKU", rowSample(row, "KODEITEM"), sampleLimit);
    if (!row.normalized.name) addSample(exceptionSamples, "MISSING_PRODUCT_NAME", rowSample(row, "NAMAITEM"), sampleLimit);
  }

  for (const samples of Object.values(exceptionSamples)) {
    samples.sort((left, right) => left.sourceRow - right.sourceRow
      || (left.field ?? "").localeCompare(right.field ?? "")
      || (left.sku ?? "").localeCompare(right.sku ?? ""));
  }
  overrideConflicts.sort((left, right) => left.sourceRow - right.sourceRow || left.field.localeCompare(right.field));

  const conflictsBySourceRow = new Map<number, string[]>();
  for (const conflict of overrideConflicts) {
    const fields = conflictsBySourceRow.get(conflict.sourceRow) ?? [];
    fields.push(conflict.field);
    conflictsBySourceRow.set(conflict.sourceRow, fields);
  }

  return {
    batchId: input.batchId,
    outletId: input.outletId,
    rawRowsExamined: rowStates.length,
    validNormalizedProductCandidates: candidates.length,
    invalidProductRows: rowStates.length - candidates.length,
    newProducts: candidates.filter((row) => row.action === "CREATE").length,
    existingProductsMatchedByExactSku: candidates.filter((row) => row.action === "UPDATE").length,
    candidateBarcodeCount: candidates.filter((row) => row.normalized.barcodeState === "VALID").length,
    blankBarcodeCount,
    malformedBarcodeCount,
    duplicateBarcodeGroups: duplicateBarcodeGroupCount,
    duplicateBarcodeRows: duplicateBarcodeCount,
    duplicateSkuGroups,
    duplicateSkuRows: duplicateSkuCount,
    duplicateNonblankBarcodeGroups: duplicateBarcodeGroupCount,
    duplicateNonblankBarcodeRows: duplicateBarcodeCount,
    hppZeroOrMissing: hppZeroOrMissingCount,
    hppNonpositiveOrMissing: rowStates.filter((row) => row.normalized.hpp.state === "blank"
      || (row.normalized.hpp.value !== null && row.normalized.hpp.value.units <= BigInt(0))).length,
    sellingBelowHpp: sellingBelowHppCount,
    sellingEqualHpp: sellingEqualHppCount,
    sellingPriceNonpositiveOrMissing: rowStates.filter((row) => row.normalized.sellingPrice.state === "blank"
      || (row.normalized.sellingPrice.value !== null && row.normalized.sellingPrice.value.units <= BigInt(0))).length,
    zeroStock: zeroStockCount,
    negativeStock: negativeStockCount,
    reorderCount,
    blankRack: blankRackCount,
    blankRackWithPositiveStock: blankRackWithPositiveStockCount,
    blankCategory: rowStates.filter((row) => !row.normalized.categoryLabel).length,
    blankBrand: rowStates.filter((row) => !row.normalized.brandLabel).length,
    blankSupplierRawOnly: rowStates.filter((row) => row.source.raw_data.SUPPLIER1 === null
      || (typeof row.source.raw_data.SUPPLIER1 === "string" && row.source.raw_data.SUPPLIER1.trim() === "")).length,
    minimumStockZeroOrBlank: rowStates.filter((row) => row.normalized.minimumQuantity.state === "blank"
      || (row.normalized.minimumQuantity.value !== null && row.normalized.minimumQuantity.value.units === BigInt(0))).length,
    duplicateNameGroups: duplicateNameGroupCount,
    duplicateNameRows: duplicateNameCount,
    numericParseErrors,
    overrideConflictCount: overrideConflicts.length,
    auditFindingCountByType: findingCounts,
    preflightDiagnosticCountByType: diagnosticCounts,
    preflightDiagnosticCount: Object.values(diagnosticCounts).reduce((sum, count) => sum + count, 0),
    plannedProductActions: rowStates.map((row) => ({
      sourceRowId: row.source.id,
      sourceRow: row.source.source_row_number,
      sku: row.normalized.sku ?? sampleSku(row),
      action: row.action,
      productId: row.productId,
      blockedOverrideFields: [...new Set(conflictsBySourceRow.get(row.source.source_row_number) ?? [])].sort(),
      sourceNormalizedProposal: {
        sku: row.normalized.sku,
        name: row.normalized.name,
        barcode: row.normalized.barcode,
        barcodeState: row.normalized.barcodeState,
        categoryLabel: row.normalized.categoryLabel,
        brandLabel: row.normalized.brandLabel,
        unitLabel: row.normalized.unitLabel,
        departmentLabel: row.normalized.departmentLabel,
        sourceDescription: row.normalized.sourceDescription,
        sourceReferenceCode: row.normalized.sourceReferenceCode,
        rackLabel: row.normalized.rackLabel,
        hpp: row.normalized.hpp.state === "valid" ? row.normalized.hpp.value.canonical : null,
        sellingPrice: row.normalized.sellingPrice.state === "valid" ? row.normalized.sellingPrice.value.canonical : null,
        quantity: row.normalized.quantity.state === "valid" ? row.normalized.quantity.value.canonical : null,
        minimumQuantity: row.normalized.minimumQuantity.state === "valid" ? row.normalized.minimumQuantity.value.canonical : null,
      },
      issues: [
        ...row.normalized.issues.map((issue) => ({ code: issue.code, field: issue.field })),
        ...(duplicateSkuRows.has(row) ? [{ code: "DUPLICATE_SKU_IN_BATCH", field: "KODEITEM" }] : []),
      ],
      auditFindings: [...new Set(auditCodesBySourceRow.get(row.source.source_row_number) ?? [])].sort(),
    })),
    exceptionSamples,
    sampleLimit,
    samplesTruncated: Object.fromEntries(Object.entries(exceptionSamples).map(([code, samples]) => {
      const totals: Record<string, number> = {
        INVALID_NUMERIC_VALUE: numericParseErrors,
        INVALID_OR_MISSING_SKU: missingSkuCount,
        MISSING_PRODUCT_NAME: missingNameCount,
        DUPLICATE_SKU_IN_BATCH: duplicateSkuCount,
        INVALID_TEXT_TYPE: diagnosticCounts.INVALID_TEXT_TYPE,
        INVALID_BARCODE_TYPE: diagnosticCounts.INVALID_BARCODE_TYPE,
        OVERRIDE_CONFLICT: overrideConflicts.length,
        DUPLICATE_BARCODE: duplicateBarcodeCount,
        DUPLICATE_PRODUCT_NAME: duplicateNameCount,
        MISSING_BARCODE: findingCounts.MISSING_BARCODE,
        MALFORMED_BARCODE: findingCounts.MALFORMED_BARCODE,
        ZERO_OR_MISSING_HPP: findingCounts.ZERO_OR_MISSING_HPP,
        SELLING_PRICE_BELOW_HPP: findingCounts.SELLING_PRICE_BELOW_HPP,
        ZERO_STOCK: findingCounts.ZERO_STOCK,
        STOCK_AT_OR_BELOW_MINIMUM: findingCounts.STOCK_AT_OR_BELOW_MINIMUM,
        MISSING_RACK: findingCounts.MISSING_RACK,
      };
      return [code, Math.max(0, (totals[code] ?? samples.length) - samples.length)];
    })),
    normalizationVersion: IPOS_NORMALIZATION_VERSION,
  };
}
