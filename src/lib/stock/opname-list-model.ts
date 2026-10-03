export const STOCK_OPNAME_LIST_PAGE_SIZE = 20;

export const STOCK_OPNAME_LIST_STATUSES = [
  "ALL",
  "COUNTING",
  "REVIEW",
  "POSTED",
  "CANCELLED",
] as const;

export type StockOpnameListStatus = (typeof STOCK_OPNAME_LIST_STATUSES)[number];

export type StockOpnameListQuery = {
  page: number;
  status: StockOpnameListStatus;
};

type SearchParams = Record<string, string | string[] | undefined>;

function first(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

export function parseStockOpnameListQuery(params: SearchParams): StockOpnameListQuery {
  const pageValue = Number.parseInt(first(params.page) ?? "1", 10);
  const requestedStatus = (first(params.status) ?? "ALL").toUpperCase();
  const status = STOCK_OPNAME_LIST_STATUSES.includes(requestedStatus as StockOpnameListStatus)
    ? requestedStatus as StockOpnameListStatus
    : "ALL";

  return {
    page: Number.isFinite(pageValue) ? Math.max(1, Math.min(pageValue, 1_000_000)) : 1,
    status,
  };
}
