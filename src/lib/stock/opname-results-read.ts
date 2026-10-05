import "server-only";
import { canAccessSection, type Profile } from "@/lib/auth/roles";
import { createClient } from "@/lib/supabase/server";
import {
  parseStockOpnameResultsQuery,
  STOCK_OPNAME_RESULTS_PAGE_SIZE,
  type StockOpnameResultsQuery,
} from "@/lib/stock/opname-results-model";

type Provenance = "POST_SNAPSHOT" | "CURRENT_FALLBACK" | "LEGACY_UNAVAILABLE";
type Quantity = number | string | null;

export type StockOpnamePostedResultRow = {
  itemId: string;
  productId: string;
  productName: string | null;
  sku: string | null;
  rack: string | null;
  unit: string | null;
  displayBarcode: string | null;
  metadataProvenance: Provenance;
  baselineQuantity: Quantity;
  physicalQuantity: Quantity;
  difference: Quantity;
  historicalAfterQuantity: Quantity;
  historicalAfterState: "RESULTING_STOCK" | "NOT_CHANGED_BY_OPNAME" | "UNAVAILABLE";
  exceptionState: boolean;
  exceptionReason: string | null;
};

export type StockOpnamePostedResultsData = {
  query: StockOpnameResultsQuery;
  header: {
    sessionId: string;
    reference: string;
    status: "POSTED";
    scope: "FULL" | "PARTIAL";
    outletId: string;
    outletName: string | null;
    outletMetadataProvenance: Provenance;
    createdAt: string;
    submittedAt: string | null;
    postedAt: string | null;
    createdBy: string | null;
    submittedBy: string | null;
    postedBy: string | null;
  };
  summary: {
    totalItems: number;
    counted: number;
    exceptions: number;
    difference: number;
    match: number;
    increased: number;
    decreased: number;
  };
  page: { totalMatching: number; page: number; pageSize: number };
  rows: StockOpnamePostedResultRow[];
  timeline: Array<{
    eventId: string;
    eventType: string;
    previousStatus: string | null;
    nextStatus: string | null;
    actorId: string | null;
    createdAt: string;
  }>;
  error: string | null;
};

export type StockOpnamePostedResultsReadData = Omit<StockOpnamePostedResultsData, "header" | "summary" | "page"> & {
  header: StockOpnamePostedResultsData["header"] | null;
  summary: StockOpnamePostedResultsData["summary"] | null;
  page: StockOpnamePostedResultsData["page"] | null;
};

type JsonObject = Record<string, unknown>;

const PROVENANCE = ["POST_SNAPSHOT", "CURRENT_FALLBACK", "LEGACY_UNAVAILABLE"] as const;

function isObject(value: unknown): value is JsonObject {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function text(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function quantity(value: unknown): Quantity | undefined {
  if (value === null) return null;
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) return value;
  return undefined;
}

function provenance(value: unknown): Provenance | null {
  return PROVENANCE.includes(value as Provenance) ? value as Provenance : null;
}

function safeError(message: string): StockOpnamePostedResultsReadData {
  return {
    query: parseStockOpnameResultsQuery({}),
    header: null,
    summary: null,
    page: null,
    rows: [],
    timeline: [],
    error: message,
  };
}

function logFailure(error: { code?: string | null; message?: string | null }) {
  console.error("[stock-opname-results] read failed", {
    code: error.code?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 80),
    message: error.message?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 200),
  });
}

export async function readStockOpnamePostedResults(
  profile: Profile,
  sessionId: string,
  params: Record<string, string | string[] | undefined>,
): Promise<StockOpnamePostedResultsReadData> {
  const query = parseStockOpnameResultsQuery(params);
  if (!canAccessSection(profile.role, "stok")) return { ...safeError("Anda tidak memiliki akses ke hasil opname."), query };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("stock_opname_posted_results_page", {
    p_session_id: sessionId,
    p_search: query.search || null,
    p_result_filter: query.filter,
    p_page: query.page,
    p_page_size: STOCK_OPNAME_RESULTS_PAGE_SIZE,
  });
  if (error) {
    logFailure(error);
    return { ...safeError("Hasil opname belum dapat dimuat. Coba muat ulang halaman."), query };
  }
  if (!isObject(data) || data.ok !== true) {
    const code = isObject(data) ? data.code : null;
    const message = code === "FORBIDDEN"
      ? "Anda tidak memiliki akses ke hasil opname."
      : code === "NOT_FOUND"
        ? "Sesi opname tidak ditemukan atau tidak dapat diakses."
        : code === "SESSION_NOT_POSTED"
          ? "Sesi ini belum selesai diposting. Muat ulang halaman untuk melihat status terbaru."
          : "Hasil opname belum dapat dimuat. Coba muat ulang halaman.";
    return { ...safeError(message), query };
  }

  const header = data.header;
  const summary = data.summary;
  const page = data.page;
  if (!isObject(header) || !isObject(summary) || !isObject(page) || !Array.isArray(data.rows)
      || !Array.isArray(data.timeline)) {
    return { ...safeError("Data hasil opname belum lengkap. Coba muat ulang halaman."), query };
  }

  const outletProvenance = provenance(header.outlet_metadata_provenance);
  const headerSessionId = text(header.session_id);
  const headerReference = text(header.reference);
  const headerScope = header.scope;
  const headerOutletId = text(header.outlet_id);
  const headerCreatedAt = text(header.created_at);
  const counts = ["total_items", "counted", "exceptions", "difference", "match", "increased", "decreased"]
    .map((key) => summary[key]);
  const parsedCounts = counts.map((value) => typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : null);
  const matchingTotal = page.total_matching;
  const currentPage = page.page;
  const pageSize = page.page_size;
  if (header.status !== "POSTED" || !headerSessionId || !headerReference
      || (headerScope !== "FULL" && headerScope !== "PARTIAL")
      || !headerOutletId || !outletProvenance || !headerCreatedAt
      || parsedCounts.some((value) => value === null)
      || typeof matchingTotal !== "number" || !Number.isSafeInteger(matchingTotal) || matchingTotal < 0
      || typeof currentPage !== "number" || !Number.isSafeInteger(currentPage) || currentPage < 1
      || typeof pageSize !== "number" || !Number.isSafeInteger(pageSize) || pageSize < 1 || pageSize > 100) {
    return { ...safeError("Data hasil opname belum lengkap. Coba muat ulang halaman."), query };
  }

  const rows: StockOpnamePostedResultRow[] = [];
  for (const candidate of data.rows) {
    if (!isObject(candidate)) return { ...safeError("Data hasil opname belum lengkap. Coba muat ulang halaman."), query };
    const itemId = text(candidate.item_id);
    const productId = text(candidate.product_id);
    const rowProvenance = provenance(candidate.metadata_provenance);
    const baseline = quantity(candidate.baseline_quantity);
    const physical = quantity(candidate.physical_quantity);
    const difference = quantity(candidate.difference);
    const after = quantity(candidate.historical_after_quantity);
    if (!itemId || !productId || !rowProvenance
        || baseline === undefined || physical === undefined || difference === undefined || after === undefined
        || typeof candidate.exception_state !== "boolean"
        || !["RESULTING_STOCK", "NOT_CHANGED_BY_OPNAME", "UNAVAILABLE"].includes(String(candidate.historical_after_state))) {
      return { ...safeError("Data hasil opname belum lengkap. Coba muat ulang halaman."), query };
    }
    rows.push({
      itemId,
      productId,
      productName: text(candidate.product_name),
      sku: text(candidate.sku),
      rack: text(candidate.rack),
      unit: text(candidate.unit),
      displayBarcode: text(candidate.display_barcode),
      metadataProvenance: rowProvenance,
      baselineQuantity: baseline,
      physicalQuantity: physical,
      difference,
      historicalAfterQuantity: after,
      historicalAfterState: candidate.historical_after_state as StockOpnamePostedResultRow["historicalAfterState"],
      exceptionState: candidate.exception_state,
      exceptionReason: text(candidate.exception_reason),
    });
  }

  const timeline: StockOpnamePostedResultsData["timeline"] = [];
  for (const candidate of data.timeline) {
    if (!isObject(candidate) || !text(candidate.event_id) || !text(candidate.event_type) || !text(candidate.created_at)) {
      return { ...safeError("Riwayat sesi belum dapat dimuat. Coba muat ulang halaman."), query };
    }
    const eventId = text(candidate.event_id);
    const eventType = text(candidate.event_type);
    const createdAt = text(candidate.created_at);
    if (!eventId || !eventType || !createdAt) return { ...safeError("Riwayat sesi belum dapat dimuat. Coba muat ulang halaman."), query };
    timeline.push({
      eventId,
      eventType,
      previousStatus: text(candidate.previous_status),
      nextStatus: text(candidate.next_status),
      actorId: text(candidate.actor_id),
      createdAt,
    });
  }

  return {
    query,
    header: {
      sessionId: headerSessionId,
      reference: headerReference,
      status: "POSTED",
      scope: headerScope,
      outletId: headerOutletId,
      outletName: text(header.outlet_name),
      outletMetadataProvenance: outletProvenance,
      createdAt: headerCreatedAt,
      submittedAt: text(header.submitted_at),
      postedAt: text(header.posted_at),
      createdBy: text(header.created_by),
      submittedBy: text(header.submitted_by),
      postedBy: text(header.posted_by),
    },
    summary: {
      totalItems: parsedCounts[0]!,
      counted: parsedCounts[1]!,
      exceptions: parsedCounts[2]!,
      difference: parsedCounts[3]!,
      match: parsedCounts[4]!,
      increased: parsedCounts[5]!,
      decreased: parsedCounts[6]!,
    },
    page: { totalMatching: matchingTotal, page: currentPage, pageSize },
    rows,
    timeline,
    error: null,
  };
}
