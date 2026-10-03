export type StockStatus = "HABIS" | "MENIPIS" | "AMAN" | "DATA_BELUM_TERSEDIA";
export type StockFilter = "SEMUA" | "HABIS" | "MENIPIS" | "AMAN";

export type StockWorkspaceQuery = {
  q: string;
  category: string;
  status: StockFilter;
  emptyRack: boolean;
  page: number;
  scan: string | null;
};

export type StockWorkspaceRow = {
  productId: string;
  name: string;
  sku: string;
  barcode: string | null;
  category: string | null;
  rack: string | null;
  effectiveQuantity: number | null;
  minimumQuantity: number | null;
  status: StockStatus;
};

export type StockSummary = {
  total: number;
  habis: number;
  menipis: number;
  aman: number;
};

export const STOCK_PAGE_SIZE = 50;

export function parseStockWorkspaceQuery(
  raw: Record<string, string | string[] | undefined>,
): StockWorkspaceQuery {
  const first = (value: string | string[] | undefined) => Array.isArray(value) ? value[0] : value;
  const statusValue = first(raw.status);
  const status: StockFilter = statusValue === "HABIS" || statusValue === "MENIPIS" || statusValue === "AMAN"
    ? statusValue
    : "SEMUA";
  const pageValue = Number(first(raw.page));

  return {
    q: (first(raw.q) ?? "").trim().slice(0, 120),
    category: (first(raw.category) ?? "").trim().slice(0, 120),
    status,
    emptyRack: first(raw.rak) === "kosong",
    page: Number.isSafeInteger(pageValue) && pageValue > 0 ? pageValue : 1,
    scan: first(raw.scan) ?? null,
  };
}

export function classifyStockStatus(
  effectiveQuantity: number | null,
  minimumQuantity: number | null,
): StockStatus {
  if (effectiveQuantity === null || !Number.isFinite(effectiveQuantity)) return "DATA_BELUM_TERSEDIA";
  if (effectiveQuantity === 0) return "HABIS";
  if ((minimumQuantity ?? 0) > 0 && effectiveQuantity <= (minimumQuantity ?? 0)) return "MENIPIS";
  return "AMAN";
}

export function filterStockRows(
  rows: StockWorkspaceRow[],
  status: StockFilter,
  emptyRack: boolean,
): StockWorkspaceRow[] {
  return rows.filter((row) =>
    (status === "SEMUA" || row.status === status)
    && (!emptyRack || !row.rack?.trim()),
  );
}

export function summarizeStockRows(rows: StockWorkspaceRow[]): StockSummary {
  return rows.reduce<StockSummary>((summary, row) => {
    summary.total += 1;
    if (row.status === "HABIS") summary.habis += 1;
    if (row.status === "MENIPIS") summary.menipis += 1;
    if (row.status === "AMAN") summary.aman += 1;
    return summary;
  }, { total: 0, habis: 0, menipis: 0, aman: 0 });
}

export function paginateStockRows<T>(rows: T[], requestedPage: number) {
  const pages = Math.max(1, Math.ceil(rows.length / STOCK_PAGE_SIZE));
  const page = Math.min(Math.max(1, requestedPage), pages);
  const start = (page - 1) * STOCK_PAGE_SIZE;
  return {
    rows: rows.slice(start, start + STOCK_PAGE_SIZE),
    page,
    pages,
    total: rows.length,
    start: rows.length ? start + 1 : 0,
    end: Math.min(start + STOCK_PAGE_SIZE, rows.length),
  };
}
