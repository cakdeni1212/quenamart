import "server-only";
import { createClient } from "@/lib/supabase/server";

export type SupplierReturnItemRead = {
  id: string; product_id: string; quantity: string | number; source_receipt_id: string | null;
  source_receipt_item_id: string | null; note: string | null; products: { name: string; sku: string } | null;
};
export type SupplierReturnRead = {
  id: string; return_no: string; outlet_id: string; supplier_id: string; status: "DRAFT" | "POSTED" | "CANCELLED";
  return_at: string; reason_category: string; reason: string; note: string | null; revision: number;
  created_at: string; created_by: string; posted_at: string | null; posted_by: string | null;
  posted_by_name?: string | null; supplier_return_items: SupplierReturnItemRead[]; suppliers: { display_name: string } | null;
};
export type SupplierReturnWorkspaceRead = {
  outletId: string | null; outletName: string | null; suppliers: Array<{ id: string; display_name: string }>;
  returns: SupplierReturnRead[]; error: string | null;
};

export async function readSupplierReturnWorkspace(): Promise<SupplierReturnWorkspaceRead> {
  const supabase = await createClient();
  const { data: periods, error: periodError } = await supabase.from("stock_authority_periods")
    .select("outlet_id,outlets(name,is_active)").is("ended_at", null);
  if (periodError || !periods || periods.length !== 1) return { outletId: null, outletName: null, suppliers: [], returns: [], error: "Informasi outlet stok belum dapat dimuat." };
  const period = periods[0] as unknown as { outlet_id: string; outlets: { name: string; is_active: boolean } | null };
  if (!period.outlets?.is_active) return { outletId: null, outletName: null, suppliers: [], returns: [], error: "Outlet stok aktif belum tersedia." };
  const [{ data: suppliers, error: supplierError }, { data: rows, error: returnError }] = await Promise.all([
    supabase.from("suppliers").select("id,display_name").eq("is_active", true).order("display_name").limit(250),
    supabase.from("supplier_returns").select("id,return_no,outlet_id,supplier_id,status,return_at,reason_category,reason,note,revision,created_at,created_by,posted_at,posted_by,suppliers(display_name),supplier_return_items(id,product_id,quantity,source_receipt_id,source_receipt_item_id,note,products(name,sku))")
      .eq("outlet_id", period.outlet_id).order("created_at", { ascending: false }).limit(50),
  ]);
  if (supplierError || returnError) return { outletId: period.outlet_id, outletName: period.outlets.name, suppliers: [], returns: [], error: "Data retur supplier belum dapat dimuat." };
  const typedRows = (rows ?? []) as unknown as SupplierReturnRead[];
  const actorIds = [...new Set(typedRows.map((row) => row.posted_by).filter((id): id is string => Boolean(id)))];
  const { data: actors } = actorIds.length
    ? await supabase.from("profiles").select("id,full_name").in("id", actorIds)
    : { data: [] };
  const actorNames = new Map((actors ?? []).map((actor) => [actor.id, actor.full_name]));
  return { outletId: period.outlet_id, outletName: period.outlets.name,
    suppliers: (suppliers ?? []) as Array<{ id: string; display_name: string }>,
    returns: typedRows.map((row) => ({ ...row, posted_by_name: row.posted_by ? actorNames.get(row.posted_by) ?? null : null })), error: null };
}
