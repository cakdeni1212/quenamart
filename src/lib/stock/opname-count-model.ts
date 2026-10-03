export const STOCK_OPNAME_COUNT_PAGE_SIZE = 40;

export const STOCK_OPNAME_COUNT_FILTERS = ["ALL", "UNCOUNTED", "COUNTED", "RECOUNT"] as const;
export type StockOpnameCountFilter = (typeof STOCK_OPNAME_COUNT_FILTERS)[number];

export type StockOpnameCountQuery = {
  page: number;
  filter: StockOpnameCountFilter;
  q: string;
};

type SearchParams = Record<string, string | string[] | undefined>;

function first(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

export function parseStockOpnameCountQuery(params: SearchParams): StockOpnameCountQuery {
  const requestedPage = Number.parseInt(first(params.page) ?? "1", 10);
  const requestedFilter = (first(params.filter) ?? "ALL").toUpperCase();
  const filter = STOCK_OPNAME_COUNT_FILTERS.includes(requestedFilter as StockOpnameCountFilter)
    ? requestedFilter as StockOpnameCountFilter
    : "ALL";

  return {
    page: Number.isFinite(requestedPage) ? Math.max(1, Math.min(requestedPage, 1_000_000)) : 1,
    filter,
    q: (first(params.q) ?? "").trim().slice(0, 100),
  };
}

export function escapePostgrestContains(value: string): string {
  const escaped = value.replaceAll("\\", "\\\\").replaceAll("%", "\\%").replaceAll("_", "\\_").replaceAll('"', '\\"');
  return `"%${escaped}%"`;
}

export function countInputError(raw: string): string | null {
  if (raw.trim() === "") return "Masukkan jumlah fisik. Nilai kosong bukan nol.";
  if (!/^(?:0|[1-9]\d*)(?:[.,]\d{1,3})?$/.test(raw)) {
    return "Gunakan angka nonnegatif dengan maksimal tiga angka desimal.";
  }
  const value = Number(raw.replace(",", "."));
  if (!Number.isFinite(value) || value >= 100_000_000_000) {
    return "Jumlah berada di luar batas yang didukung.";
  }
  return null;
}

export function opnameCountResultMessage(result: {
  ok?: boolean;
  code?: string;
  reason?: string;
}): string {
  if (result.ok) return "Hitungan berhasil disimpan.";
  if (result.code === "STALE_BASELINE" && result.reason === "ITEM_REVISION_MISMATCH") {
    return "Hitungan lain mengubah item ini. Hitungan Anda tidak menggantikan data tersebut; muat ulang dan periksa kembali sebelum menghitung.";
  }
  if (result.code === "STALE_BASELINE" && result.reason === "PROJECTION_BASELINE_CHANGED") {
    return "Saldo stok berubah sejak opname dimulai. Item ini memerlukan pembaruan baseline dan hitung ulang sebelum dapat disimpan.";
  }
  return "Hitungan belum dapat disimpan. Muat ulang item dan coba kembali.";
}
