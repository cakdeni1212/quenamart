export const STOCK_OPNAME_RESULTS_FILTERS = [
  "ALL",
  "DIFFERENCE",
  "MATCH",
  "INCREASE",
  "DECREASE",
  "EXCEPTION",
] as const;

export type StockOpnameResultsFilter = (typeof STOCK_OPNAME_RESULTS_FILTERS)[number];

export const STOCK_OPNAME_RESULTS_PAGE_SIZE = 40;

export type StockOpnameResultsQuery = {
  search: string;
  filter: StockOpnameResultsFilter;
  page: number;
};

type SearchParams = Record<string, string | string[] | undefined>;

function first(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

export function parseStockOpnameResultsQuery(params: SearchParams): StockOpnameResultsQuery {
  const requestedPage = Number.parseInt(first(params.page) ?? "1", 10);
  const requestedFilter = (first(params.filter) ?? "ALL").toUpperCase();
  return {
    search: (first(params.q) ?? "").trim().slice(0, 120),
    filter: STOCK_OPNAME_RESULTS_FILTERS.includes(requestedFilter as StockOpnameResultsFilter)
      ? requestedFilter as StockOpnameResultsFilter
      : "ALL",
    page: Number.isFinite(requestedPage) ? Math.max(1, Math.min(requestedPage, 1_000_000)) : 1,
  };
}

export function stockOpnameResultsHref(
  pathname: string,
  query: StockOpnameResultsQuery,
  overrides: Partial<StockOpnameResultsQuery> = {},
): string {
  const next = { ...query, ...overrides };
  const params = new URLSearchParams();
  if (next.search) params.set("q", next.search);
  if (next.filter !== "ALL") params.set("filter", next.filter);
  if (next.page > 1) params.set("page", String(next.page));
  const suffix = params.toString();
  return suffix ? `${pathname}?${suffix}` : pathname;
}

export function formatStockOpnameResultQuantity(value: number | string | null): string {
  if (value === null) return "—";
  const number = Number(value);
  if (!Number.isFinite(number)) return "—";
  return new Intl.NumberFormat("id-ID", { maximumFractionDigits: 3 }).format(number);
}

export function formatStockOpnameResultDifference(value: number | string | null): string {
  if (value === null) return "—";
  const number = Number(value);
  if (!Number.isFinite(number)) return "—";
  const formatted = formatStockOpnameResultQuantity(number);
  return number > 0 ? `+${formatted}` : formatted;
}

export function stockOpnameResultEventLabel(eventType: string): string {
  switch (eventType) {
    case "CREATED": return "Dibuat";
    case "SUBMITTED_FOR_REVIEW": return "Dikirim untuk review";
    case "RETURNED_TO_COUNTING": return "Dikembalikan ke penghitungan";
    case "BASELINE_STALE": return "Baseline berubah; perlu hitung ulang";
    case "POSTED": return "Selesai";
    case "CANCELLED": return "Dibatalkan";
    default: return "Pembaruan sesi opname";
  }
}

export function hasCurrentMetadataFallback(
  outletProvenance: string,
  rowProvenances: readonly string[],
): boolean {
  return outletProvenance === "CURRENT_FALLBACK" || rowProvenances.includes("CURRENT_FALLBACK");
}

export function stockOpnameMetadataLabel(
  value: string | null,
  provenance: string,
): string {
  if (provenance === "LEGACY_UNAVAILABLE") return "Tidak tersedia";
  return value?.trim() || "—";
}

export function stockOpnameResultValues(input: {
  exception: boolean;
  baseline: number | string | null;
  physical: number | string | null;
  difference: number | string | null;
  after: number | string | null;
}) {
  if (input.exception) {
    return {
      before: formatStockOpnameResultQuantity(input.baseline),
      physical: "Tidak dihitung",
      difference: "—",
      after: "Tidak diubah oleh opname",
      adjustment: "Tidak dilakukan",
    };
  }
  return {
    before: formatStockOpnameResultQuantity(input.baseline),
    physical: formatStockOpnameResultQuantity(input.physical),
    difference: formatStockOpnameResultDifference(input.difference),
    after: input.after === null ? "Tidak tersedia" : formatStockOpnameResultQuantity(input.after),
    adjustment: null,
  };
}
