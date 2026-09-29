import assert from "node:assert/strict";
import test from "node:test";
import { IPOS_HEADERS } from "../src/lib/ipos/xlsx-parser.ts";
import { analyzeIposPreflight } from "../src/lib/ipos/preflight-engine.ts";
import { normalizeProductNameKey, normalizeRawIposRow, parseIposNumber } from "../src/lib/ipos/normalize.ts";
import { buildIposCommitPayload } from "../src/lib/ipos/commit-payload.ts";

function rawRow(overrides = {}) {
  return { ...Object.fromEntries(IPOS_HEADERS.map((header) => [header, null])), ...overrides };
}

function sourceRow(rowNumber, values) {
  return {
    id: `row-${rowNumber}`,
    batch_id: "batch-1",
    outlet_id: "outlet-1",
    source_row_number: rowNumber,
    raw_data: rawRow(values),
    status: "RAW_ONLY",
    product_id: null,
  };
}

function analyze(rows, options = {}) {
  return analyzeIposPreflight({
    batchId: "batch-1",
    outletId: "outlet-1",
    rows,
    existingProducts: [],
    existingBarcodes: [],
    activeOverrides: [],
    ...options,
  });
}

test("trims SKU without folding case and preserves leading zero barcode", () => {
  const normalized = normalizeRawIposRow(rawRow({ KODEITEM: "  AbC001  ", KODEBARCODE: "001234" }));
  assert.equal(normalized.sku, "AbC001");
  assert.equal(normalized.barcode, "001234");
  assert.equal(normalizeRawIposRow(rawRow({ KODEITEM: "\tAbC001" })).sku, null);
});

test("blank barcode maps to null and malformed control-character barcode is rejected", () => {
  assert.equal(normalizeRawIposRow(rawRow({ KODEITEM: "A", KODEBARCODE: "   " })).barcodeState, "BLANK");
  const malformed = normalizeRawIposRow(rawRow({ KODEITEM: "A", KODEBARCODE: "12\u0001" }));
  assert.equal(malformed.barcodeState, "MALFORMED");
  assert.equal(malformed.barcode, null);
  assert.equal(normalizeRawIposRow(rawRow({ KODEITEM: "A", KODEBARCODE: "12\t" })).barcodeState, "MALFORMED");
});

test("parses Indonesian textual numbers exactly and rejects ambiguity or excess scale", () => {
  assert.equal(parseIposNumber("1.234,50", "HARGAPOKOK").value.canonical, "1234.5");
  assert.equal(parseIposNumber("1.234", "STOK").value.canonical, "1234");
  assert.equal(parseIposNumber(1234.5, "HARGAPOKOK").value.canonical, "1234.5");
  assert.equal(parseIposNumber(1.234, "HARGAPOKOK").error, "EXCESS_PRECISION");
  assert.equal(parseIposNumber("1,234", "HARGAPOKOK").error, "EXCESS_PRECISION");
  assert.equal(parseIposNumber("12.34", "HARGAPOKOK").error, "AMBIGUOUS_OR_INVALID_NUMBER");
  assert.equal(parseIposNumber("bukan angka", "STOK").state, "invalid");
});

test("zero HPP and below-HPP values create the documented finding codes", () => {
  const report = analyze([
    sourceRow(3, { KODEITEM: "A", NAMAITEM: "Alpha", HARGAPOKOK: 0, HARGAJUAL: 10 }),
    sourceRow(4, { KODEITEM: "B", NAMAITEM: "Beta", HARGAPOKOK: 20, HARGAJUAL: 19 }),
  ]);
  assert.equal(report.hppZeroOrMissing, 1);
  assert.equal(report.sellingBelowHpp, 1);
  assert.equal(report.auditFindingCountByType.ZERO_OR_MISSING_HPP, 1);
  assert.equal(report.auditFindingCountByType.SELLING_PRICE_BELOW_HPP, 1);
});

test("equal selling price to HPP is counted separately and does not create below-HPP", () => {
  const report = analyze([sourceRow(3, { KODEITEM: "A", NAMAITEM: "Alpha", HARGAPOKOK: 100, HARGAJUAL: 100 })]);
  assert.equal(report.sellingEqualHpp, 1);
  assert.equal(report.sellingBelowHpp, 0);
});

test("reorder requires positive minimum and stock at or below minimum", () => {
  const report = analyze([
    sourceRow(3, { KODEITEM: "A", NAMAITEM: "A", STOK: 5, STOKMIN: 5 }),
    sourceRow(4, { KODEITEM: "B", NAMAITEM: "B", STOK: 4, STOKMIN: 5 }),
    sourceRow(5, { KODEITEM: "C", NAMAITEM: "C", STOK: 0, STOKMIN: 0 }),
  ]);
  assert.equal(report.reorderCount, 2);
  assert.equal(report.zeroStock, 1);
  assert.equal(report.auditFindingCountByType.STOCK_AT_OR_BELOW_MINIMUM, 2);
});

test("duplicate product names use exact NFC/case/whitespace normalization only", () => {
  assert.equal(normalizeProductNameKey(" Cafe\u0301   Susu "), normalizeProductNameKey("Café Susu"));
  const report = analyze([
    sourceRow(3, { KODEITEM: "A", NAMAITEM: "Cafe\u0301   Susu" }),
    sourceRow(4, { KODEITEM: "B", NAMAITEM: "Café Susu" }),
    sourceRow(5, { KODEITEM: "C", NAMAITEM: "Cafe Susu 2" }),
  ]);
  assert.equal(report.duplicateNameGroups, 1);
  assert.equal(report.duplicateNameRows, 2);
});

test("duplicate barcode across distinct SKUs is reported without invalidating candidates", () => {
  const report = analyze([
    sourceRow(3, { KODEITEM: "A", NAMAITEM: "Alpha", KODEBARCODE: "00001" }),
    sourceRow(4, { KODEITEM: "B", NAMAITEM: "Beta", KODEBARCODE: "00001" }),
  ]);
  assert.equal(report.validNormalizedProductCandidates, 2);
  assert.equal(report.duplicateBarcodeGroups, 1);
  assert.equal(report.duplicateBarcodeRows, 2);
});

test("multiple audit candidates can coexist for one product; blank supplier adds none", () => {
  const report = analyze([sourceRow(3, {
    KODEITEM: "A", NAMAITEM: "Alpha", KODEBARCODE: "", HARGAPOKOK: 0, STOK: 0,
    RAK: " ", SUPPLIER1: null,
  })]);
  assert.equal(report.auditFindingCountByType.MISSING_BARCODE, 1);
  assert.equal(report.auditFindingCountByType.ZERO_OR_MISSING_HPP, 1);
  assert.equal(report.auditFindingCountByType.ZERO_STOCK, 1);
  assert.equal(report.auditFindingCountByType.MISSING_RACK, 1);
  assert.equal(report.preflightDiagnosticCountByType.MISSING_SUPPLIER, undefined);
  assert.equal(report.plannedProductActions[0].action, "CREATE");
});

test("invalid numeric cells are validation diagnostics and never become zero", () => {
  const report = analyze([sourceRow(3, {
    KODEITEM: "A", NAMAITEM: "Alpha", HARGAPOKOK: "oops", HARGAJUAL: 5, STOK: -1, STOKMIN: "1.2,34",
  })]);
  assert.equal(report.numericParseErrors, 3);
  assert.equal(report.hppZeroOrMissing, 0);
  assert.equal(report.negativeStock, 1);
  assert.equal(report.preflightDiagnosticCountByType.INVALID_NUMERIC_VALUE, 3);
});

test("blank barcode and blank rack counts are independent of supplier values", () => {
  const report = analyze([sourceRow(3, {
    KODEITEM: "A", NAMAITEM: "Alpha", KODEBARCODE: "", RAK: "", SUPPLIER1: "",
  })]);
  assert.equal(report.blankBarcodeCount, 1);
  assert.equal(report.blankRack, 1);
  assert.equal(report.candidateBarcodeCount, 0);
});

test("exact SKU match plans UPDATE and active overrides become explicit conflicts", () => {
  const report = analyze([
    sourceRow(3, { KODEITEM: "SKU-1", NAMAITEM: "Alpha", HARGAPOKOK: 1200 }),
  ], {
    existingProducts: [{ id: "p-1", sku: "SKU-1", name: "Alpha" }],
    activeOverrides: [{
      id: "o-1", product_id: "p-1", barcode_id: null, outlet_id: "outlet-1",
      field_key: "hpp", corrected_value: 1500,
    }],
  });
  assert.equal(report.existingProductsMatchedByExactSku, 1);
  assert.equal(report.plannedProductActions[0].action, "UPDATE");
  assert.equal(report.overrideConflictCount, 1);
  assert.equal(report.exceptionSamples.OVERRIDE_CONFLICT[0].field, "hpp");
});

test("barcode override conflicts only protect imported associations, not manual barcodes", () => {
  const inputRow = sourceRow(3, { KODEITEM: "SKU-1", NAMAITEM: "Alpha", KODEBARCODE: "NEW" });
  const report = analyze([inputRow], {
    existingProducts: [{ id: "p-1", sku: "SKU-1", name: "Alpha" }],
    existingBarcodes: [
      { id: "b-imported", product_id: "p-1", barcode: "OLD", source_import_row_id: "row-old" },
      { id: "b-manual", product_id: "p-1", barcode: "MANUAL", source_import_row_id: null },
    ],
    activeOverrides: [
      { id: "o-imported", product_id: "p-1", barcode_id: "b-imported", outlet_id: null, field_key: "barcode", corrected_value: "CORRECTED" },
      { id: "o-manual", product_id: "p-1", barcode_id: "b-manual", outlet_id: null, field_key: "barcode", corrected_value: "MANUAL" },
    ],
  });
  assert.equal(report.overrideConflictCount, 1);
  assert.deepEqual(report.plannedProductActions[0].blockedOverrideFields, ["barcode"]);
});

test("missing SKU, missing name, and duplicate source SKU rows are invalid without name matching", () => {
  const report = analyze([
    sourceRow(3, { KODEITEM: "", NAMAITEM: "Name" }),
    sourceRow(4, { KODEITEM: "DUP", NAMAITEM: "One" }),
    sourceRow(5, { KODEITEM: "DUP", NAMAITEM: "Two" }),
    sourceRow(6, { KODEITEM: "NO-NAME", NAMAITEM: " " }),
  ]);
  assert.equal(report.invalidProductRows, 4);
  assert.equal(report.validNormalizedProductCandidates, 0);
  assert.equal(report.preflightDiagnosticCountByType.DUPLICATE_SKU_IN_BATCH, 2);
  assert.equal(report.preflightDiagnosticCountByType.MISSING_PRODUCT_NAME, 1);
});

test("SKU matching is exact and case-sensitive; missing later rows do not imply deletion", () => {
  const report = analyze([sourceRow(3, { KODEITEM: "sku-1", NAMAITEM: "New" })], {
    existingProducts: [
      { id: "p-upper", sku: "SKU-1", name: "Upper" },
      { id: "p-absent", sku: "ABSENT", name: "Keep me" },
    ],
  });
  assert.equal(report.newProducts, 1);
  assert.equal(report.existingProductsMatchedByExactSku, 0);
  assert.equal(report.plannedProductActions[0].action, "CREATE");
  assert.equal(report.plannedProductActions.some((action) => action.productId === "p-absent"), false);
});

test("multiple barcode associations retain manual barcodes and replace imported source barcode", () => {
  const report = analyze([sourceRow(3, { KODEITEM: "SKU-1", NAMAITEM: "Alpha", KODEBARCODE: "00022" })], {
    existingProducts: [{ id: "p-1", sku: "SKU-1", name: "Alpha" }],
    existingBarcodes: [
      { id: "b-manual", product_id: "p-1", barcode: "MANUAL", source_import_row_id: null },
      { id: "b-old", product_id: "p-1", barcode: "00011", source_import_row_id: "old-row" },
    ],
  });
  assert.equal(report.plannedProductActions[0].sourceNormalizedProposal.barcode, "00022");
  assert.equal(report.plannedProductActions[0].sourceNormalizedProposal.barcodeState, "VALID");
  assert.equal(report.duplicateBarcodeRows, 0);
});

test("malformed incoming barcode does not project an imported association deletion", () => {
  const report = analyze([sourceRow(3, { KODEITEM: "SKU-1", NAMAITEM: "Alpha", KODEBARCODE: "bad\u0001" })], {
    existingProducts: [
      { id: "p-1", sku: "SKU-1", name: "Alpha" },
      { id: "p-2", sku: "SKU-2", name: "Beta" },
    ],
    existingBarcodes: [
      { id: "b-old", product_id: "p-1", barcode: "00011", source_import_row_id: "old-row" },
      { id: "b-other", product_id: "p-2", barcode: "00011", source_import_row_id: "other-row" },
    ],
  });
  assert.equal(report.malformedBarcodeCount, 1);
  assert.equal(report.plannedProductActions[0].sourceNormalizedProposal.barcode, null);
  assert.equal(report.plannedProductActions[0].auditFindings.includes("MALFORMED_BARCODE"), true);
  assert.equal(report.plannedProductActions[0].auditFindings.includes("DUPLICATE_BARCODE"), true);
});

test("commit payload carries the verified findings and raw-row link identity", () => {
  const report = analyze([sourceRow(3, {
    KODEITEM: "SKU-1", NAMAITEM: "Alpha", KODEBARCODE: "bad\u0001", HARGAPOKOK: 0,
  })]);
  const payload = buildIposCommitPayload("batch-1", report, { products: [], barcodes: [], overrides: [] });
  assert.equal(payload.normalizationVersion, report.normalizationVersion);
  assert.equal(payload.rows[0].source_row_id, "row-3");
  assert.deepEqual(payload.rows[0].audit_findings, ["MALFORMED_BARCODE", "MISSING_RACK", "ZERO_OR_MISSING_HPP"]);
  assert.equal(payload.rows[0].normalized_data.barcode, null);
  assert.equal(payload.rows[0].normalized_data.hpp, "0");
});
