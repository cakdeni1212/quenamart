import "server-only";
import { createClient } from "@/lib/supabase/server";

export type ManualCorrectionItemRead = {
  id: string;
  product_id: string;
  quantity_delta: string | number;
  note: string | null;
  products: { name: string; sku: string } | null;
};

export type ManualCorrectionRead = {
  id: string;
  correction_no: string;
  outlet_id: string;
  status: "DRAFT" | "POSTED" | "CANCELLED";
  correction_at: string;
  reason_category: string;
  reason: string;
  revision: number;
  created_at: string;
  created_by: string;
  posted_at: string | null;
  posted_by: string | null;
  posted_by_name: string | null;
  manual_stock_correction_items: ManualCorrectionItemRead[];
};

export type ManualCorrectionWorkspace = {
  outletId: string | null;
  outletName: string | null;
  corrections: ManualCorrectionRead[];
  error: string | null;
};

export async function readManualCorrectionWorkspace(): Promise<ManualCorrectionWorkspace> {
  const supabase = await createClient();
  const { data: periods, error: periodError } = await supabase.from("stock_authority_periods")
    .select("outlet_id, outlets(name,is_active)").is("ended_at", null);
  if (periodError || !periods || periods.length !== 1) {
    return { outletId: null, outletName: null, corrections: [], error: "Informasi outlet stok belum dapat dimuat." };
  }
  const period = periods[0] as unknown as { outlet_id: string; outlets: { name: string; is_active: boolean } | null };
  if (!period.outlets?.is_active) return { outletId: null, outletName: null, corrections: [], error: "Outlet stok aktif belum tersedia." };
  const { data, error } = await supabase.from("manual_stock_corrections")
    .select("id,correction_no,outlet_id,status,correction_at,reason_category,reason,revision,created_at,created_by,posted_at,posted_by,manual_stock_correction_items(id,product_id,quantity_delta,note,products(name,sku))")
    .eq("outlet_id", period.outlet_id).order("created_at", { ascending: false }).limit(50);
  if (error) return { outletId: period.outlet_id, outletName: period.outlets.name, corrections: [], error: "Daftar koreksi stok belum dapat dimuat." };
  const rows = (data ?? []) as unknown as Array<ManualCorrectionRead & { created_by: string; posted_by: string | null }>;
  const actorIds = [...new Set(rows.flatMap((row) => [row.created_by, row.posted_by].filter(Boolean)))];
  const { data: actors } = actorIds.length
    ? await supabase.from("profiles").select("id,full_name").in("id", actorIds)
    : { data: [] };
  const actorNames = new Map((actors ?? []).map((actor) => [actor.id, actor.full_name]));
  return { outletId: period.outlet_id, outletName: period.outlets.name,
    corrections: rows.map((row) => ({ ...row, posted_by_name: row.posted_by ? actorNames.get(row.posted_by) ?? null : null })), error: null };
}
