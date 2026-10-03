import "server-only";
import { canAccessSection, type Profile } from "@/lib/auth/roles";
import { createClient } from "@/lib/supabase/server";
import {
  classifyStockStatus,
  paginateStockRows,
  parseStockWorkspaceQuery,
  STOCK_PAGE_SIZE,
  summarizeStockRows,
  type StockWorkspaceQuery,
  type StockWorkspaceRow,
} from "@/lib/stock/workspace";

type ProductDetailRow = {
  product_id: string;
  sku: string;
  name: string;
  category_label: string | null;
  barcode: string | null;
  minimum_quantity: number | string | null;
  rack_label: string | null;
};

type BarcodeResolution = {
  resolution: "BARCODE_NOT_FOUND" | "BARCODE_MATCH" | "BARCODE_AMBIGUOUS";
  product_id: string | null;
  product_name: string | null;
  system_quantity: number | string | null;
};

type StockPageRow = {
  product_id: string;
  name: string;
  sku: string;
  barcode: string | null;
  category: string | null;
  rack: string | null;
  effective_quantity: number | string;
  minimum_stock: number | string | null;
  stock_status: "HABIS" | "MENIPIS" | "AMAN";
};

type StockPageResponse = {
  rows: StockPageRow[];
  summary: { total: number; empty: number; low: number; safe: number };
  pagination: { page: number; page_size: number; filtered_total: number; page_count: number };
  integrity: { missing_projection_count: number };
};

type ReadErrorDetails = {
  code?: string | null;
  message?: string | null;
  details?: string | null;
  hint?: string | null;
};

export type StockScanNotice = {
  kind: "found" | "not-found" | "ambiguous" | "error";
  message: string;
};

export type StockWorkspaceData = {
  query: StockWorkspaceQuery;
  rows: StockWorkspaceRow[];
  summary: { total: number; habis: number; menipis: number; aman: number } | null;
  total: number;
  page: number;
  pages: number;
  start: number;
  end: number;
  outletName: string | null;
  missingProjectionCount: number;
  scanNotice: StockScanNotice | null;
  scannedProductId: string | null;
  error: string | null;
};

function numeric(value: number | string | null | undefined): number | null {
  if (value == null) return null;
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function safeDiagnosticText(value: string | null | undefined): string | undefined {
  if (!value) return undefined;
  return value.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240);
}

function logStockReadFailure(
  operation: string,
  error: ReadErrorDetails,
  context: Record<string, number | string> = {},
) {
  console.error("[stock-read] query failed", {
    operation,
    ...context,
    code: safeDiagnosticText(error.code),
    message: safeDiagnosticText(error.message),
    details: safeDiagnosticText(error.details),
    hint: safeDiagnosticText(error.hint),
  });
}

function toSafeRow(product: ProductDetailRow, effectiveQuantity: number | null): StockWorkspaceRow {
  const minimumQuantity = numeric(product.minimum_quantity);
  return {
    productId: product.product_id,
    name: product.name,
    sku: product.sku,
    barcode: product.barcode,
    category: product.category_label,
    rack: product.rack_label,
    effectiveQuantity,
    minimumQuantity,
    status: classifyStockStatus(effectiveQuantity, minimumQuantity),
  };
}

function emptyData(query: StockWorkspaceQuery, error: string): StockWorkspaceData {
  return {
    query, rows: [], summary: null, total: 0, page: 1, pages: 0, start: 0, end: 0,
    outletName: null, missingProjectionCount: 0,
    scanNotice: null, scannedProductId: null, error,
  };
}

async function fetchCurrentAuthority(supabase: Awaited<ReturnType<typeof createClient>>) {
  const { data: periods, error } = await supabase
    .from("stock_authority_periods")
    .select("outlet_id, outlets(name, is_active)")
    .is("ended_at", null);
  if (error) {
    logStockReadFailure("stock_authority_periods", error);
    throw new Error("Saldo stok belum dapat dibaca. Coba muat ulang halaman.");
  }
  if (!periods?.length) throw new Error("Periode sumber stok aktif belum tersedia.");
  if (periods.length !== 1) throw new Error("Terdapat beberapa outlet aktif. Pemilihan outlet belum tersedia di ruang kerja stok.");

  const period = periods[0] as unknown as {
    outlet_id: string;
    outlets: { name: string; is_active: boolean } | null;
  };
  if (!period.outlets?.is_active) throw new Error("Outlet stok aktif belum tersedia.");
  return { outletId: period.outlet_id, outletName: period.outlets.name };
}

function mapPageRow(row: StockPageRow): StockWorkspaceRow {
  return {
    productId: row.product_id,
    name: row.name,
    sku: row.sku,
    barcode: row.barcode,
    category: row.category,
    rack: row.rack,
    effectiveQuantity: numeric(row.effective_quantity),
    minimumQuantity: numeric(row.minimum_stock),
    status: row.stock_status,
  };
}

async function fetchWorkspacePage(
  supabase: Awaited<ReturnType<typeof createClient>>,
  outletId: string,
  query: StockWorkspaceQuery,
): Promise<StockWorkspaceData> {
  const { data, error } = await supabase.rpc("stock_workspace_read_page", {
    p_outlet_id: outletId,
    p_q: query.q || null,
    p_stock_status: query.status === "SEMUA" ? "ALL" : query.status,
    p_rack_empty: query.emptyRack,
    p_category: query.category || null,
    p_page: query.page,
    p_page_size: STOCK_PAGE_SIZE,
  });
  if (error) {
    logStockReadFailure("stock_workspace_read_page", error, { page: query.page });
    throw new Error("Data stok belum dapat dimuat. Coba muat ulang halaman.");
  }

  const result = data as unknown as StockPageResponse;
  const rows = (result.rows ?? []).map(mapPageRow);
  const total = Number(result.pagination.filtered_total ?? 0);
  const page = Number(result.pagination.page ?? 1);
  const pageSize = Number(result.pagination.page_size ?? STOCK_PAGE_SIZE);
  return {
    query,
    rows,
    summary: {
      total: Number(result.summary.total ?? 0),
      habis: Number(result.summary.empty ?? 0),
      menipis: Number(result.summary.low ?? 0),
      aman: Number(result.summary.safe ?? 0),
    },
    total,
    page,
    pages: Number(result.pagination.page_count ?? 0),
    start: total ? (page - 1) * pageSize + 1 : 0,
    end: total ? Math.min(page * pageSize, total) : 0,
    outletName: null,
    missingProjectionCount: Number(result.integrity.missing_projection_count ?? 0),
    scanNotice: null,
    scannedProductId: null,
    error: null,
  };
}

async function fetchBarcodeProduct(
  supabase: Awaited<ReturnType<typeof createClient>>,
  outletId: string,
  barcode: string,
): Promise<{ notice: StockScanNotice; row: StockWorkspaceRow | null; productId: string | null }> {
  const { data, error } = await supabase.rpc("resolve_stock_barcode", {
    p_outlet_id: outletId,
    p_barcode: barcode,
  });
  if (error) {
    logStockReadFailure("resolve_stock_barcode", error);
    return { notice: { kind: "error", message: "Pemindaian barcode belum dapat diproses. Coba lagi." }, row: null, productId: null };
  }
  const resolution = ((data ?? []) as BarcodeResolution[])[0];
  if (!resolution || resolution.resolution === "BARCODE_NOT_FOUND") {
    return { notice: { kind: "not-found", message: "Barcode belum terdaftar" }, row: null, productId: null };
  }
  if (resolution.resolution === "BARCODE_AMBIGUOUS") {
    return { notice: { kind: "ambiguous", message: "Barcode terhubung ke lebih dari satu produk. Periksa melalui Audit Produk." }, row: null, productId: null };
  }
  if (!resolution.product_id || resolution.system_quantity == null) {
    return { notice: { kind: "error", message: "Saldo efektif produk belum tersedia." }, row: null, productId: null };
  }

  const { data: detail, error: detailError } = await supabase
    .rpc("product_workspace_detail", { p_product_id: resolution.product_id });
  if (detailError) {
    logStockReadFailure("product_workspace_detail", detailError);
    return { notice: { kind: "error", message: "Data produk hasil pindai belum dapat dibuka." }, row: null, productId: null };
  }
  const product = ((detail ?? []) as ProductDetailRow[])[0];
  if (!product) return { notice: { kind: "error", message: "Produk hasil pindai tidak tersedia di outlet aktif." }, row: null, productId: null };
  const row = toSafeRow(product, numeric(resolution.system_quantity));
  return {
    notice: { kind: "found", message: `Produk ditemukan: ${product.name}` },
    row,
    productId: product.product_id,
  };
}

export async function readStockWorkspace(
  profile: Profile,
  rawQuery: Record<string, string | string[] | undefined>,
): Promise<StockWorkspaceData> {
  const query = parseStockWorkspaceQuery(rawQuery);
  if (!canAccessSection(profile.role, "stok")) return emptyData(query, "Anda tidak memiliki akses ke ruang kerja stok.");

  const supabase = await createClient();
  try {
    const authority = await fetchCurrentAuthority(supabase);
    if (query.scan !== null) {
      const scan = await fetchBarcodeProduct(supabase, authority.outletId, query.scan);
      const scanQuery = { ...query, q: "", status: "SEMUA" as const, emptyRack: false, page: 1 };
      if (scan.row) {
        const summary = summarizeStockRows([scan.row]);
        const page = paginateStockRows([scan.row], 1);
        return {
          query: scanQuery, ...page, summary, outletName: authority.outletName,
          missingProjectionCount: 0, scanNotice: scan.notice, scannedProductId: scan.productId, error: null,
        };
      }
      const failedScan = emptyData(scanQuery, scan.notice.kind === "error" ? scan.notice.message : "");
      return {
        ...failedScan,
        summary: summarizeStockRows([]),
        outletName: authority.outletName,
        scanNotice: scan.notice,
        error: scan.notice.kind === "error" ? scan.notice.message : null,
      };
    }

    const page = await fetchWorkspacePage(supabase, authority.outletId, query);
    return { ...page, outletName: authority.outletName };
  } catch (error) {
    return emptyData(query, error instanceof Error ? error.message : "Data stok belum dapat dimuat.");
  }
}
