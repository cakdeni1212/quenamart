import "server-only";
import { canAccessSection, type Profile } from "@/lib/auth/roles";
import { createClient } from "@/lib/supabase/server";

type StockWorkspaceRead = {
  summary: { total: number };
  integrity: { missing_projection_count: number };
};

export type StockOpnameCreateInfo = {
  outletId: string | null;
  outletName: string | null;
  projectionCount: number;
  unusableProjectionCount: number;
  missingProjectionCount: number;
  error: string | null;
};

function failed(message: string): StockOpnameCreateInfo {
  return {
    outletId: null,
    outletName: null,
    projectionCount: 0,
    unusableProjectionCount: 0,
    missingProjectionCount: 0,
    error: message,
  };
}

function logReadFailure(operation: string, error: { code?: string | null; message?: string | null }) {
  console.error("[stock-opname-create] read failed", {
    operation,
    code: error.code?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 80),
    message: error.message?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240),
  });
}

export async function getActiveStockOutletId(): Promise<string | null> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("stock_authority_periods")
    .select("outlet_id, outlets(name, is_active)")
    .is("ended_at", null);
  if (error) {
    logReadFailure("active_authority_period", error);
    return null;
  }
  if (!data || data.length !== 1) return null;
  const period = data[0] as unknown as {
    outlet_id: string;
    outlets: { name: string; is_active: boolean } | null;
  };
  return period.outlets?.is_active ? period.outlet_id : null;
}

export async function readStockOpnameCreateInfo(profile: Profile): Promise<StockOpnameCreateInfo> {
  if (!canAccessSection(profile.role, "stok")) return failed("Anda tidak memiliki akses untuk membuat opname stok.");

  const supabase = await createClient();
  const { data: periods, error: periodError } = await supabase
    .from("stock_authority_periods")
    .select("outlet_id, outlets(name, is_active)")
    .is("ended_at", null);
  if (periodError) {
    logReadFailure("active_authority_period", periodError);
    return failed("Informasi outlet stok belum dapat dimuat.");
  }
  if (!periods?.length) return failed("Periode sumber stok aktif belum tersedia.");
  if (periods.length !== 1) return failed("Terdapat beberapa outlet aktif. Pemilihan outlet belum tersedia.");

  const period = periods[0] as unknown as {
    outlet_id: string;
    outlets: { name: string; is_active: boolean } | null;
  };
  if (!period.outlets?.is_active) return failed("Outlet stok aktif belum tersedia.");

  const [projectionResult, unusableResult, workspaceResult] = await Promise.all([
    supabase.from("stock_balance_projection").select("product_id", { count: "exact", head: true })
      .eq("outlet_id", period.outlet_id),
    supabase.from("stock_balance_projection").select("product_id", { count: "exact", head: true })
      .eq("outlet_id", period.outlet_id)
      .or("effective_quantity.is.null,baseline_source_import_row_id.is.null"),
    supabase.rpc("stock_workspace_read_page", {
      p_outlet_id: period.outlet_id,
      p_q: null,
      p_stock_status: "ALL",
      p_rack_empty: false,
      p_category: null,
      p_page: 1,
      p_page_size: 1,
    }),
  ]);

  for (const [operation, error] of [
    ["projection_scope_count", projectionResult.error],
    ["unusable_projection_count", unusableResult.error],
    ["workspace_integrity_summary", workspaceResult.error],
  ] as const) {
    if (error) {
      logReadFailure(operation, error);
      return failed("Cakupan saldo stok belum dapat diperiksa.");
    }
  }

  const workspace = workspaceResult.data as unknown as StockWorkspaceRead;
  return {
    outletId: period.outlet_id,
    outletName: period.outlets.name,
    projectionCount: projectionResult.count ?? 0,
    unusableProjectionCount: unusableResult.count ?? 0,
    missingProjectionCount: workspace.integrity.missing_projection_count ?? 0,
    error: null,
  };
}
