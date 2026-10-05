import "server-only";
import { canAccessSection, type Profile } from "@/lib/auth/roles";
import { createClient } from "@/lib/supabase/server";
import {
  escapePostgrestContains,
  parseStockOpnameCountQuery,
  STOCK_OPNAME_COUNT_PAGE_SIZE,
  type StockOpnameCountQuery,
} from "@/lib/stock/opname-count-model";

type SessionRow = {
  id: string;
  outlet_id: string;
  scope_type: "FULL" | "PARTIAL";
  status: "COUNTING" | "REVIEW" | "POSTED" | "CANCELLED";
  created_at: string;
  outlets: { name: string } | null;
};

type ItemRow = {
  id: string;
  product_id: string;
  outlet_id: string;
  baseline_quantity: number | string | null;
  physical_quantity: number | string | null;
  quantity_variance: number | string | null;
  revision_no: number;
  requires_recount: boolean;
  exception_reason: string | null;
  exception_reviewed_by: string | null;
  exception_reviewed_at: string | null;
  products: { name: string; sku: string };
};

type StockOpnameProgress = {
  total: number;
  counted: number;
  exception: number;
  accounted: number;
  remaining: number;
  recountRequired: number;
};

export type StockOpnameCountItem = {
  id: string;
  productId: string;
  name: string;
  sku: string;
  barcode: string | null;
  rack: string | null;
  baselineQuantity: number | string | null;
  physicalQuantity: number | string | null;
  variance: number | string | null;
  revision: number;
  requiresRecount: boolean;
  exceptionReason: string | null;
  exceptionReviewed: boolean;
};

export type StockOpnameCountData = {
  session: {
    id: string;
    outletId: string;
    outletName: string;
    scope: "FULL" | "PARTIAL";
    status: SessionRow["status"];
    createdAt: string;
  } | null;
  query: StockOpnameCountQuery;
  items: StockOpnameCountItem[];
  progress: StockOpnameProgress | null;
  progressError: string | null;
  filteredTotal: number;
  pageCount: number;
  error: string | null;
};

function empty(query: StockOpnameCountQuery, error: string | null): StockOpnameCountData {
  return {
    session: null,
    query,
    items: [],
    progress: null,
    progressError: null,
    filteredTotal: 0,
    pageCount: 0,
    error,
  };
}

function logFailure(operation: string, error: { code?: string | null; message?: string | null; details?: string | null }) {
  console.error("[stock-opname-count] read failed", {
    operation,
    code: error.code?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 80),
    message: error.message?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240),
    details: error.details?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 160),
  });
}

export async function readStockOpnameCounting(
  profile: Profile,
  sessionId: string,
  params: Record<string, string | string[] | undefined>,
): Promise<StockOpnameCountData> {
  const query = parseStockOpnameCountQuery(params);
  if (!canAccessSection(profile.role, "stok")) return empty(query, "Anda tidak memiliki akses ke opname stok.");

  const supabase = await createClient();
  const { data: rawSession, error: sessionError } = await supabase
    .from("stock_opname_sessions")
    .select("id, outlet_id, scope_type, status, created_at, outlets(name)")
    .eq("id", sessionId)
    .maybeSingle();
  if (sessionError) {
    logFailure("stock_opname_session", sessionError);
    return empty(query, "Informasi sesi opname belum dapat dimuat.");
  }
  if (!rawSession) return empty(query, "Sesi opname tidak ditemukan atau tidak dapat diakses.");
  const session = rawSession as unknown as SessionRow;

  // POSTED results are read through the dedicated bounded results RPC. Avoid
  // fetching counting rows, current barcodes/racks, or progress for that view.
  if (session.status === "POSTED") {
    return {
      ...empty(query, null),
      session: {
        id: session.id,
        outletId: session.outlet_id,
        outletName: session.outlets?.name ?? "Outlet",
        scope: session.scope_type,
        status: session.status,
        createdAt: session.created_at,
      },
    };
  }

  let itemRequest = supabase
    .from("stock_opname_items")
    .select("id, product_id, outlet_id, baseline_quantity, physical_quantity, quantity_variance, revision_no, requires_recount, exception_reason, exception_reviewed_by, exception_reviewed_at, products!inner(name, sku)", { count: "exact" })
    .eq("session_id", session.id);
  if (query.filter === "UNCOUNTED") itemRequest = itemRequest.is("physical_quantity", null);
  if (query.filter === "COUNTED") itemRequest = itemRequest.not("physical_quantity", "is", null).eq("requires_recount", false);
  if (query.filter === "RECOUNT") itemRequest = itemRequest.eq("requires_recount", true);
  if (query.q) {
    const pattern = escapePostgrestContains(query.q);
    itemRequest = itemRequest.or(`name.ilike.${pattern},sku.ilike.${pattern}`, { referencedTable: "products" });
  }

  const [itemResult, progressResult] = await Promise.all([
    itemRequest
      .order("name", { referencedTable: "products", ascending: true })
      .order("sku", { referencedTable: "products", ascending: true })
      .order("product_id", { ascending: true })
      .range((query.page - 1) * STOCK_OPNAME_COUNT_PAGE_SIZE, query.page * STOCK_OPNAME_COUNT_PAGE_SIZE - 1),
    supabase.rpc("stock_opname_progress_counts", { p_session_id: session.id }),
  ]);
  if (itemResult.error) {
    logFailure("stock_opname_items_page", itemResult.error);
    return { ...empty(query, "Daftar item opname belum dapat dimuat."), session: {
      id: session.id,
      outletId: session.outlet_id,
      outletName: session.outlets?.name ?? "Outlet",
      scope: session.scope_type,
      status: session.status,
      createdAt: session.created_at,
    } };
  }

  const pages = Math.ceil((itemResult.count ?? 0) / STOCK_OPNAME_COUNT_PAGE_SIZE);
  const page = pages === 0 ? 1 : Math.min(query.page, pages);
  if (page !== query.page) {
    return readStockOpnameCounting(profile, sessionId, { ...params, page: String(page) });
  }

  const rawItems = (itemResult.data ?? []) as unknown as ItemRow[];
  const productIds = rawItems.map((item) => item.product_id);
  let racks = new Map<string, string | null>();
  const barcodes = new Map<string, string>();
  if (productIds.length) {
    const [settingsResult, barcodeResult] = await Promise.all([
      supabase.from("product_outlet_settings").select("product_id, rack_label")
        .eq("outlet_id", session.outlet_id).in("product_id", productIds),
      supabase.from("product_barcodes").select("product_id, barcode, created_at, id")
        .eq("is_active", true).in("product_id", productIds)
        .order("created_at", { ascending: true }).order("id", { ascending: true }),
    ]);
    if (settingsResult.error) logFailure("product_outlet_settings_page", settingsResult.error);
    else racks = new Map((settingsResult.data ?? []).map((row) => [row.product_id, row.rack_label]));
    if (barcodeResult.error) logFailure("product_barcodes_page", barcodeResult.error);
    else {
      for (const row of barcodeResult.data ?? []) {
        if (!barcodes.has(row.product_id)) barcodes.set(row.product_id, row.barcode);
      }
    }
  }

  const items = rawItems.map((item) => ({
    id: item.id,
    productId: item.product_id,
    name: item.products.name,
    sku: item.products.sku,
    barcode: barcodes.get(item.product_id) ?? null,
    rack: racks.get(item.product_id) ?? null,
    baselineQuantity: item.baseline_quantity,
    physicalQuantity: item.physical_quantity,
    variance: item.quantity_variance,
    revision: item.revision_no,
    requiresRecount: item.requires_recount,
    exceptionReason: item.exception_reason,
    exceptionReviewed: Boolean(item.exception_reason?.trim()
      && item.exception_reviewed_by && item.exception_reviewed_at),
  }));
  const filteredTotal = itemResult.count ?? 0;
  let progress: StockOpnameProgress | null = null;
  let progressError: string | null = null;
  if (progressResult.error) {
    logFailure("stock_opname_progress_counts", progressResult.error);
    progressError = "Ringkasan progress belum dapat dimuat.";
  } else if (progressResult.data && typeof progressResult.data === "object") {
    const row = progressResult.data as Record<string, unknown>;
    const readCount = (key: string) => {
      const value = row[key];
      const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : NaN;
      return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : null;
    };
    const total = readCount("total");
    const counted = readCount("counted");
    const exception = readCount("exception");
    const accounted = readCount("accounted");
    const remaining = readCount("remaining");
    const recountRequired = readCount("recount_required");
    if (total !== null && counted !== null && exception !== null && accounted !== null
        && remaining !== null && recountRequired !== null
        && accounted === counted + exception && remaining === total - accounted) {
      progress = { total, counted, exception, accounted, remaining, recountRequired };
    } else {
      progressError = "Ringkasan progress menerima data yang tidak lengkap.";
      console.error("[stock-opname-count] read failed", { operation: "stock_opname_progress_shape" });
    }
  } else {
    progressError = "Ringkasan progress belum tersedia.";
  }

  return {
    session: {
      id: session.id,
      outletId: session.outlet_id,
      outletName: session.outlets?.name ?? "Outlet",
      scope: session.scope_type,
      status: session.status,
      createdAt: session.created_at,
    },
    query: { ...query, page },
    items,
    progress,
    progressError,
    filteredTotal,
    pageCount: pages,
    error: null,
  };
}
