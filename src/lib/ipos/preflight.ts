import "server-only";
import { createAdminClient } from "@/lib/supabase/admin";
import {
  analyzeIposPreflight,
  type ActiveOverride,
  type ExistingBarcode,
  type ExistingProduct,
  type PreflightRawRow,
} from "./preflight-engine";
import { normalizeRawIposRow } from "./normalize";

const PAGE_SIZE = 1000;
const FILTER_CHUNK_SIZE = 100;

async function readPages<T>(makeQuery: (from: number, to: number) => PromiseLike<{
  data: T[] | null;
  error: { message: string } | null;
}>): Promise<T[]> {
  const all: T[] = [];
  for (let offset = 0; ; offset += PAGE_SIZE) {
    const { data, error } = await makeQuery(offset, offset + PAGE_SIZE - 1);
    if (error) throw new Error(`Read-only preflight query failed: ${error.message}`);
    const page = data ?? [];
    all.push(...page);
    if (page.length < PAGE_SIZE) return all;
  }
}

async function readByIds<T>(
  ids: string[],
  makeQuery: (chunk: string[], from: number, to: number) => PromiseLike<{
    data: T[] | null;
    error: { message: string } | null;
  }>,
): Promise<T[]> {
  const all: T[] = [];
  for (let offset = 0; offset < ids.length; offset += FILTER_CHUNK_SIZE) {
    const chunk = ids.slice(offset, offset + FILTER_CHUNK_SIZE);
    all.push(...await readPages((from, to) => makeQuery(chunk, from, to)));
  }
  return all;
}

export async function prepareIposPreflight(batchId: string) {
  const supabase = createAdminClient();
  const { data: batch, error: batchError } = await supabase
    .from("ipos_import_batches")
    .select("id, outlet_id, status, expected_data_row_count, actual_data_row_count")
    .eq("id", batchId)
    .maybeSingle();
  if (batchError) throw new Error(`Could not read import batch: ${batchError.message}`);
  if (!batch) throw new Error("Import batch was not found.");
  if (batch.status !== "COMPLETED") throw new Error("Preflight requires a COMPLETED raw snapshot.");

  const rows = await readPages<PreflightRawRow>((from, to) => supabase
    .from("ipos_import_rows")
    .select("id, batch_id, outlet_id, source_row_number, raw_data, status, product_id")
    .eq("batch_id", batchId)
    .order("source_row_number", { ascending: true })
    .range(from, to));
  if (rows.length !== batch.actual_data_row_count
    || rows.length !== batch.expected_data_row_count
    || rows.some((row, index) => row.batch_id !== batchId
      || row.outlet_id !== batch.outlet_id
      || row.status !== "RAW_ONLY"
      || row.product_id !== null
      || row.source_row_number !== index + 3)) {
    throw new Error("The raw snapshot does not match its completed Phase 2A invariants; preflight stopped without writes.");
  }

  const existingProducts = await readPages<ExistingProduct>((from, to) => supabase
    .from("products")
    .select("id, sku, name")
    .order("sku", { ascending: true })
    .range(from, to));
  const rowsBySku = new Set<string>();
  for (const row of rows) {
    const sku = normalizeRawIposRow(row.raw_data).sku;
    if (sku) rowsBySku.add(sku);
  }
  const matchingProductIds = existingProducts
    .filter((product) => rowsBySku.has(product.sku))
    .map((product) => product.id);
  const activeOverrides = await readByIds<ActiveOverride>(matchingProductIds, (ids, from, to) => supabase
    .from("product_field_overrides")
    .select("id, product_id, barcode_id, outlet_id, field_key, corrected_value")
    .in("product_id", ids)
    .eq("is_active", true)
    .order("product_id", { ascending: true })
    .range(from, to));

  const matchingBarcodeValues = new Set<string>();
  for (const row of rows) {
    const value = row.raw_data.KODEBARCODE;
    if (typeof value === "string") {
      const barcode = value.trim();
      if (barcode && !/[\u0000-\u001f\u007f-\u009f]/u.test(barcode)) matchingBarcodeValues.add(barcode);
    }
  }
  const activeBarcodesForCandidateProducts = await readByIds<ExistingBarcode>(matchingProductIds, (ids, from, to) => supabase
    .from("product_barcodes")
    .select("id, product_id, barcode, source_import_row_id")
    .in("product_id", ids)
    .eq("is_active", true)
    .order("product_id", { ascending: true })
    .range(from, to));
  const barcodesMatchingCandidateValues = await readByIds<ExistingBarcode>([...matchingBarcodeValues], (values, from, to) => supabase
    .from("product_barcodes")
    .select("id, product_id, barcode, source_import_row_id")
    .in("barcode", values)
    .eq("is_active", true)
    .order("barcode", { ascending: true })
    .range(from, to));
  const barcodeById = new Map<string, ExistingBarcode>();
  for (const barcode of [...activeBarcodesForCandidateProducts, ...barcodesMatchingCandidateValues]) {
    barcodeById.set(barcode.id, barcode);
  }

  const report = analyzeIposPreflight({
    batchId,
    outletId: batch.outlet_id,
    rows,
    existingProducts,
    existingBarcodes: [...barcodeById.values()],
    activeOverrides,
  });

  // Sent only to the transactional commit RPC, never returned by the preflight
  // HTTP route. The database compares this exact reference state under locks.
  const expectedState = {
    products: existingProducts.map(({ id, sku, name }) => ({ id, sku, name }))
      .sort((left, right) => left.id.localeCompare(right.id)),
    barcodes: [...barcodeById.values()].map(({ id, product_id, barcode, source_import_row_id }) => ({
      id, product_id, barcode, source_import_row_id,
    })).sort((left, right) => left.id.localeCompare(right.id)),
    overrides: activeOverrides.map(({ id, product_id, barcode_id, outlet_id, field_key, corrected_value }) => ({
      id, product_id, barcode_id, outlet_id, field_key, corrected_value,
    })).sort((left, right) => left.id.localeCompare(right.id)),
  };

  return { report, expectedState };
}

export async function runIposPreflight(batchId: string) {
  return (await prepareIposPreflight(batchId)).report;
}
