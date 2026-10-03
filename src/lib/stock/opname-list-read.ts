import "server-only";
import { canAccessSection, type Profile } from "@/lib/auth/roles";
import { createClient } from "@/lib/supabase/server";
import {
  parseStockOpnameListQuery,
  STOCK_OPNAME_LIST_PAGE_SIZE,
  type StockOpnameListQuery,
  type StockOpnameListStatus,
} from "@/lib/stock/opname-list-model";

type OpnameSessionRow = {
  id: string;
  outlet_id: string;
  scope_type: "FULL" | "PARTIAL";
  status: Exclude<StockOpnameListStatus, "ALL">;
  created_at: string;
  outlets: { name: string } | null;
};

export type StockOpnameListRow = {
  id: string;
  reference: string;
  outletName: string;
  scope: "FULL" | "PARTIAL";
  status: Exclude<StockOpnameListStatus, "ALL">;
  createdAt: string;
};

export type StockOpnameListData = {
  query: StockOpnameListQuery;
  rows: StockOpnameListRow[];
  total: number;
  page: number;
  pages: number;
  start: number;
  end: number;
  error: string | null;
};

function mapRows(rows: OpnameSessionRow[]): StockOpnameListRow[] {
  return rows.map((row) => ({
    id: row.id,
    reference: row.id.slice(0, 8).toUpperCase(),
    outletName: row.outlets?.name ?? "Outlet tidak tersedia",
    scope: row.scope_type,
    status: row.status,
    createdAt: row.created_at,
  }));
}

function failed(query: StockOpnameListQuery): StockOpnameListData {
  return { query, rows: [], total: 0, page: 1, pages: 0, start: 0, end: 0,
    error: "Daftar opname belum dapat dimuat. Coba muat ulang halaman." };
}

async function fetchPage(
  supabase: Awaited<ReturnType<typeof createClient>>,
  query: StockOpnameListQuery,
  page: number,
) {
  const from = (page - 1) * STOCK_OPNAME_LIST_PAGE_SIZE;
  let request = supabase
    .from("stock_opname_sessions")
    .select("id, outlet_id, scope_type, status, created_at, outlets(name)", { count: "exact" });

  if (query.status !== "ALL") request = request.eq("status", query.status);

  return request
    .order("created_at", { ascending: false })
    .order("id", { ascending: false })
    .range(from, from + STOCK_OPNAME_LIST_PAGE_SIZE - 1);
}

export async function readStockOpnameList(profile: Profile, params: Record<string, string | string[] | undefined>): Promise<StockOpnameListData> {
  const query = parseStockOpnameListQuery(params);
  if (!canAccessSection(profile.role, "stok")) {
    return { ...failed(query), error: "Anda tidak memiliki akses ke daftar opname stok." };
  }

  const supabase = await createClient();
  let result = await fetchPage(supabase, query, query.page);
  if (result.error) {
    console.error("[stock-opname-list] query failed", {
      operation: "stock_opname_sessions_page",
      code: result.error.code,
      message: result.error.message.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240),
      details: result.error.details?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240),
      hint: result.error.hint?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240),
    });
    return failed(query);
  }

  const total = result.count ?? 0;
  const pages = Math.ceil(total / STOCK_OPNAME_LIST_PAGE_SIZE);
  const page = pages === 0 ? 1 : Math.min(query.page, pages);
  if (page !== query.page) {
    result = await fetchPage(supabase, query, page);
    if (result.error) {
      console.error("[stock-opname-list] query failed", {
        operation: "stock_opname_sessions_last_page",
        code: result.error.code,
        message: result.error.message.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240),
      });
      return failed(query);
    }
  }

  const rows = mapRows((result.data ?? []) as unknown as OpnameSessionRow[]);
  const start = total === 0 ? 0 : (page - 1) * STOCK_OPNAME_LIST_PAGE_SIZE + 1;
  return {
    query,
    rows,
    total,
    page,
    pages,
    start,
    end: start === 0 ? 0 : start + rows.length - 1,
    error: null,
  };
}
