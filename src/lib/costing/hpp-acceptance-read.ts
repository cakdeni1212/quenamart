import "server-only";
import { performance } from "node:perf_hooks";

import { createClient } from "@/lib/supabase/server";
import { readAllPreparedValuationItems, summarizePreparedOpeningValue } from "@/lib/costing/hpp-acceptance-valuation";

export type HppAcceptanceView = "EXCEPTIONS" | "CANDIDATES" | "WARNINGS";
export type HppAcceptanceRow = {
  productId: string;
  sku: string;
  name: string;
  stock: string | number | null;
  currentHpp: string | number | null;
  sellingPrice: string | number | null;
  blockers: string[];
  warnings: string[];
  reviewStatus: string | null;
  disposition: string | null;
  acceptedHpp: string | number | null;
  reason: string | null;
  resolved: boolean;
  preparedEvidence: boolean;
};

export type HppAcceptanceWorkspaceData = {
  outletId: string | null;
  batch: {
    id: string;
    status: "PREPARED" | "APPROVED" | "INVALIDATED" | "CONSUMED";
    candidates: number;
    exceptions: number;
    warningProducts: number;
    candidateValue: string | number | null;
    approvedValue: string | number | null;
    unresolved: number;
  } | null;
  summary: {
    positiveStock: number;
    candidates: number;
    exceptions: number;
    warningProducts: number;
    openingValue: string | number;
    valuationState: "CANDIDATE_ESTIMATE" | "PREPARED_PROPOSAL" | "APPROVED_VALUE";
    unvaluedProducts: number | null;
  } | null;
  rows: HppAcceptanceRow[];
  total: number;
  page: number;
  pageSize: number;
  view: HppAcceptanceView;
  search: string;
  error: string | null;
};

type Json = Record<string, unknown>;
const PAGE_SIZE = 20;
const SUMMARY_READ_PAGE_SIZE = 1000;
const VIEWS: HppAcceptanceView[] = ["EXCEPTIONS", "CANDIDATES", "WARNINGS"];

function isObject(value: unknown): value is Json {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function integer(value: unknown) {
  const n = typeof value === "number" ? value : Number(value);
  return Number.isSafeInteger(n) && n >= 0 ? n : 0;
}

function scalar(value: unknown): string | number | null {
  return typeof value === "string" || typeof value === "number" ? value : null;
}

function safeSearch(value: string | string[] | undefined) {
  const text = Array.isArray(value) ? value[0] : value;
  return (text ?? "").replace(/[^\p{L}\p{N}\s-]/gu, " ").trim().slice(0, 80);
}

function parseView(value: string | string[] | undefined): HppAcceptanceView {
  const text = Array.isArray(value) ? value[0] : value;
  return VIEWS.includes(text as HppAcceptanceView) ? text as HppAcceptanceView : "EXCEPTIONS";
}

function parsePage(value: string | string[] | undefined) {
  const text = Array.isArray(value) ? value[0] : value;
  const page = Number(text);
  return Number.isSafeInteger(page) && page > 0 ? Math.min(page, 100000) : 1;
}

function errorData(view: HppAcceptanceView, page: number, search: string, message: string): HppAcceptanceWorkspaceData {
  return { outletId: null, batch: null, summary: null, rows: [], total: 0, page, pageSize: PAGE_SIZE, view, search, error: message };
}

function parsePreviewRow(value: unknown): HppAcceptanceRow | null {
  if (!isObject(value) || typeof value.productId !== "string") return null;
  return {
    productId: value.productId,
    sku: typeof value.sku === "string" ? value.sku : "—",
    name: typeof value.name === "string" ? value.name : "Produk",
    stock: scalar(value.effectiveQuantity) ?? 0,
    currentHpp: scalar(value.currentHpp),
    sellingPrice: scalar(value.sellingPrice),
    blockers: Array.isArray(value.blockingReasons) ? value.blockingReasons.filter((x): x is string => typeof x === "string") : [],
    warnings: Array.isArray(value.warnings) ? value.warnings.filter((x): x is string => typeof x === "string") : [],
    reviewStatus: typeof value.latestReviewStatus === "string" ? value.latestReviewStatus : null,
    disposition: null,
    acceptedHpp: null,
    reason: null,
    resolved: false,
    preparedEvidence: false,
  };
}

export async function readHppAcceptanceWorkspace(
  params: Record<string, string | string[] | undefined>,
): Promise<HppAcceptanceWorkspaceData> {
  const view = parseView(params.view);
  const page = parsePage(params.page);
  const search = safeSearch(params.q);
  const supabase = await createClient();

  const { data: snapshotData, error: snapshotError } = await supabase.rpc("product_workspace_latest_snapshot");
  const snapshot = Array.isArray(snapshotData) ? snapshotData[0] as Json | undefined : undefined;
  const outletId = snapshot && typeof snapshot.outlet_id === "string" ? snapshot.outlet_id : null;
  if (snapshotError || !outletId) {
    return errorData(view, page, search, "Data persiapan HPP belum dapat dimuat. Pastikan snapshot produk tersedia, lalu coba lagi.");
  }

  const { data: batchRow, error: batchError } = await supabase.from("inventory_cost_hpp_acceptance_batches")
    .select("id,status,candidate_count,exception_count,warning_product_count,candidate_estimated_opening_value,estimated_opening_value,approved_at")
    .eq("outlet_id", outletId).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (batchError) {
    console.error("[hpp-awal] batch read failed", { code: batchError.code });
    return { ...errorData(view, page, search, "Status persiapan HPP belum dapat dimuat. Coba muat ulang."), outletId };
  }

  const batchStatus = typeof batchRow?.status === "string" ? batchRow.status : null;
  const hasWorkingBatch = batchStatus === "PREPARED" || batchStatus === "APPROVED" || batchStatus === "CONSUMED";
  let batch: HppAcceptanceWorkspaceData["batch"] = null;
  let summary: HppAcceptanceWorkspaceData["summary"] = null;
  let rows: HppAcceptanceRow[] = [];
  let total = 0;
  let normalizedPage = page;

  if (hasWorkingBatch && batchRow) {
    const batchId = String(batchRow.id);
    const exceptionCount = integer(batchRow.exception_count);
    const { count: unresolved, error: unresolvedError } = await supabase.from("inventory_cost_hpp_acceptance_items")
      .select("product_id", { count: "exact", head: true }).eq("batch_id", batchId)
      .eq("classification", "EXCEPTION").is("resolved_by", null);
    if (unresolvedError) {
      console.error("[hpp-awal] resolution count failed", { code: unresolvedError.code });
      return { ...errorData(view, page, search, "Progress peninjauan belum dapat dimuat. Coba muat ulang."), outletId };
    }
    batch = {
      id: batchId,
      status: batchStatus as "PREPARED" | "APPROVED" | "INVALIDATED" | "CONSUMED",
      candidates: integer(batchRow.candidate_count),
      exceptions: exceptionCount,
      warningProducts: integer(batchRow.warning_product_count),
      candidateValue: scalar(batchRow.candidate_estimated_opening_value),
      approvedValue: scalar(batchRow.estimated_opening_value),
      unresolved: integer(unresolved),
    };
    const summaryItemCount = batch.candidates + batch.exceptions;
    const summaryRead = await readAllPreparedValuationItems(
      summaryItemCount,
      SUMMARY_READ_PAGE_SIZE,
      async (start, end) => await supabase.from("inventory_cost_hpp_acceptance_items")
        .select("disposition,accepted_opening_hpp,quantity_at_prepare")
        .eq("batch_id", batchId).order("product_id")
        .range(start, end),
    );
    if (summaryRead.error) {
      console.error("[hpp-awal] prepared valuation summary read failed", { code: summaryRead.error.code });
      return { ...errorData(view, page, search, "Estimasi modal awal belum dapat dimuat. Coba muat ulang."), outletId };
    }
    if (!summaryRead.complete || !summaryRead.items) {
      console.error("[hpp-awal] prepared valuation summary incomplete", { expected: summaryItemCount });
      return { ...errorData(view, page, search, "Estimasi modal awal belum lengkap. Coba muat ulang."), outletId };
    }
    let preparedValuation: ReturnType<typeof summarizePreparedOpeningValue>;
    try {
      preparedValuation = summarizePreparedOpeningValue(summaryRead.items.map((item) => ({
        disposition: item.disposition,
        acceptedOpeningHpp: scalar(item.accepted_opening_hpp),
        quantity: scalar(item.quantity_at_prepare),
      })));
    } catch {
      console.error("[hpp-awal] prepared valuation evidence invalid");
      return { ...errorData(view, page, search, "Estimasi modal awal belum dapat dipastikan. Coba muat ulang."), outletId };
    }
    summary = {
      positiveStock: batch.candidates + batch.exceptions,
      candidates: batch.candidates,
      exceptions: batch.exceptions,
      warningProducts: batch.warningProducts,
      openingValue: batch.status === "APPROVED" || batch.status === "CONSUMED"
        ? batch.approvedValue ?? preparedValuation.openingValue
        : preparedValuation.openingValue,
      valuationState: batch.status === "APPROVED" || batch.status === "CONSUMED"
        ? "APPROVED_VALUE"
        : "PREPARED_PROPOSAL",
      unvaluedProducts: preparedValuation.unvaluedProducts,
    };

    let query = supabase.from("inventory_cost_hpp_acceptance_items")
      .select("product_id,classification,blocking_reasons,warning_codes,current_hpp,selling_price,latest_review_status,disposition,accepted_opening_hpp,resolution_reason,resolved_by,product:products!inner(name,sku)", { count: "exact" })
      .eq("batch_id", batchId);
    if (view === "EXCEPTIONS") query = query.eq("classification", "EXCEPTION");
    if (view === "CANDIDATES") query = query.eq("classification", "AUTO_CANDIDATE");
    if (view === "WARNINGS") query = query.not("warning_codes", "eq", "{}");
    if (search) query = query.or(`name.ilike.%${search}%,sku.ilike.%${search}%`, { referencedTable: "product" });
    const { data, error, count } = await query.order("product_id").range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
    if (error) {
      console.error("[hpp-awal] items read failed", { code: error.code });
      return { ...errorData(view, page, search, "Daftar produk belum dapat dimuat. Coba muat ulang."), outletId, batch, summary };
    }
    total = count ?? 0;
    const pages = Math.max(1, Math.ceil(total / PAGE_SIZE));
    normalizedPage = Math.min(page, pages);
    const itemRows = (data ?? []) as unknown as Array<Record<string, unknown>>;
    const productIds = itemRows.map((row) => String(row.product_id));
    const stockByProduct = new Map<string, string | number | null>();
    if (productIds.length > 0) {
      const { data: balances, error: balanceError } = await supabase.from("stock_balance_projection")
        .select("product_id,effective_quantity").eq("outlet_id", outletId).in("product_id", productIds);
      if (balanceError) {
        console.error("[hpp-awal] stock read failed", { code: balanceError.code });
        return { ...errorData(view, page, search, "Stok produk belum dapat dimuat. Coba muat ulang."), outletId, batch, summary };
      }
      for (const balance of balances ?? []) stockByProduct.set(balance.product_id, scalar(balance.effective_quantity));
    }
    rows = itemRows.map((row) => {
      const product = row.product as { name?: string; sku?: string } | null;
      return {
        productId: String(row.product_id),
        sku: product?.sku ?? "—",
        name: product?.name ?? "Produk",
        stock: stockByProduct.get(String(row.product_id)) ?? null,
        currentHpp: scalar(row.current_hpp),
        sellingPrice: scalar(row.selling_price),
        blockers: Array.isArray(row.blocking_reasons) ? row.blocking_reasons.filter((x): x is string => typeof x === "string") : [],
        warnings: Array.isArray(row.warning_codes) ? row.warning_codes.filter((x): x is string => typeof x === "string") : [],
        reviewStatus: typeof row.latest_review_status === "string" ? row.latest_review_status : null,
        disposition: typeof row.disposition === "string" ? row.disposition : null,
        acceptedHpp: scalar(row.accepted_opening_hpp),
        reason: typeof row.resolution_reason === "string" ? row.resolution_reason : null,
        resolved: typeof row.resolved_by === "string",
        preparedEvidence: true,
      };
    });
  } else {
    const filter = view;
    const previewStartedAt = performance.now();
    const { data, error } = await supabase.rpc("inventory_cost_initial_hpp_acceptance_preview", {
      p_outlet_id: outletId,
      p_filter: filter,
      p_search: search || null,
      p_page: page,
      p_page_size: PAGE_SIZE,
    });
    const previewContext = {
      elapsedMs: Math.round(performance.now() - previewStartedAt),
      view: filter,
      hasSearch: search.length > 0,
      page,
      pageSize: PAGE_SIZE,
    };
    if (error || !isObject(data) || data.ok !== true) {
      if (process.env.NODE_ENV !== "production") {
        console.error("[hpp-awal] preview read failed", {
          code: error?.code ?? "INVALID_RESPONSE",
          message: error?.message ?? null,
          details: error?.details ?? null,
          hint: error?.hint ?? null,
          ...previewContext,
        });
      } else {
        console.error("[hpp-awal] preview read failed", { code: error?.code ?? "INVALID_RESPONSE" });
      }
      return { ...errorData(view, page, search, "Ringkasan HPP belum dapat dimuat. Coba muat ulang."), outletId };
    }
    if (process.env.NODE_ENV !== "production") {
      console.info("[hpp-awal] preview read completed", previewContext);
    }
    const rawSummary = isObject(data.summary) ? data.summary : {};
    summary = {
      positiveStock: integer(rawSummary.positiveStockProducts),
      candidates: integer(rawSummary.autoCandidates),
      exceptions: integer(rawSummary.exceptions),
      warningProducts: integer(rawSummary.warningProducts),
      openingValue: scalar(rawSummary.estimatedAutoCandidateValue) ?? "0",
      valuationState: "CANDIDATE_ESTIMATE",
      unvaluedProducts: null,
    };
    total = integer(data.total);
    rows = Array.isArray(data.rows) ? data.rows.map(parsePreviewRow).filter((row): row is HppAcceptanceRow => row !== null) : [];
    if (batchStatus === "INVALIDATED" && batchRow) {
      batch = {
        id: String(batchRow.id), status: "INVALIDATED", candidates: integer(batchRow.candidate_count),
        exceptions: integer(batchRow.exception_count), warningProducts: integer(batchRow.warning_product_count),
        candidateValue: scalar(batchRow.candidate_estimated_opening_value),
        approvedValue: scalar(batchRow.estimated_opening_value), unresolved: integer(batchRow.exception_count),
      };
    }
  }

  return {
    outletId,
    batch,
    summary,
    rows,
    total,
    page: normalizedPage,
    pageSize: PAGE_SIZE,
    view,
    search,
    error: null,
  };
}
