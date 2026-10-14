import "server-only";
import { createClient } from "@/lib/supabase/server";

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function readMemberPage(search = "", page = 1) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("member_workspace_read", { p_search: search, p_page: page, p_page_size: 20 });
  if (error) {
    console.error("[member_workspace_read] Supabase RPC failed", { code: error.code, message: error.message });
    return { rows: [], total: 0, page, pageSize: 20, error: "Data member belum dapat dimuat." };
  }
  if (!record(data) || !Array.isArray(data.rows)) {
    console.error("[member_workspace_read] Invalid response contract", { responseType: Array.isArray(data) ? "array" : typeof data, hasRows: record(data) && Array.isArray(data.rows) });
    return { rows: [], total: 0, page, pageSize: 20, error: "Data member belum dapat dimuat." };
  }
  const rows = data.rows.filter(record).map((row: Record<string, unknown>) => {
    const safeRow = { ...row };
    delete safeRow.member_token;
    return safeRow;
  });
  return { rows, total: Number(data.total ?? 0), page: Number(data.page ?? page), pageSize: Number(data.pageSize ?? 20), error: null };
}

export async function readMemberDetail(id: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("member_detail_read", { p_member: id, p_page: 1, p_page_size: 20 });
  if (error || !record(data) || !record(data.member)) return null;
  return data;
}

export async function readPosCartMember(cartId: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("member_pos_cart_read", { p_cart: cartId });
  if (error || !record(data) || !record(data.member)) return null;
  return data.member;
}

export async function readPosCartLoyalty(cartId: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("pos_member_loyalty_read", { p_cart: cartId });
  if (error || !record(data)) return null;
  const policy = record(data.policy) ? data.policy : null;
  const member = record(data.member) ? data.member : null;
  if (!policy) return null;
  return {
    member,
    policy,
    redeem_points_requested: typeof data.redeem_points_requested === "number" ? data.redeem_points_requested : Number(data.redeem_points_requested ?? 0),
    redeem_policy_updated_at: typeof data.redeem_policy_updated_at === "string" ? data.redeem_policy_updated_at : null,
    redeem_policy_revision: Number(data.redeem_policy_revision ?? 0),
  };
}
