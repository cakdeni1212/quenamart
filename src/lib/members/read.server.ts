import "server-only";
import { createClient } from "@/lib/supabase/server";

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function readMemberPage(search = "", page = 1) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("member_workspace_read", { p_search: search, p_page: page, p_page_size: 20 });
  if (error || !record(data) || !Array.isArray(data.rows)) return { rows: [], total: 0, page, pageSize: 20, error: "Data member belum dapat dimuat." };
  return { rows: data.rows.filter(record), total: Number(data.total ?? 0), page: Number(data.page ?? page), pageSize: Number(data.pageSize ?? 20), error: null };
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
