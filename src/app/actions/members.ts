"use server";

import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";

type Result = { ok: true; value: Record<string, unknown> } | { ok: false; code: string; message: string; existingMember?: Record<string, unknown> };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const normalizePhone = (phone: string) => {
  const digits = phone.replace(/\D/g, "").replace(/^00/, "");
  return digits.startsWith("0") ? `62${digits.slice(1)}` : digits;
};
const message: Record<string, string> = {
  MEMBER_FIELDS_INVALID: "Nama, nomor HP, atau email belum valid.",
  MEMBER_WRITE_DENIED: "Akun ini tidak memiliki izin untuk mengubah data member.",
  MEMBER_NOT_FOUND: "Member tidak ditemukan.",
  MEMBER_STATUS_INVALID: "Status member atau alasan perubahan belum valid.",
  MEMBER_PHONE_DUPLICATE: "Nomor HP ini sudah digunakan member aktif lainnya.",
  MEMBER_OUTLET_UNAVAILABLE: "Outlet aktif belum tersedia.",
};

async function call(name: string, args: Record<string, unknown>): Promise<Result> {
  const profile = await getProfile();
  if (!profile || !["OWNER", "ADMIN", "KASIR"].includes(profile.role)) return { ok: false, code: "FORBIDDEN", message: message.MEMBER_WRITE_DENIED };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc(name, args);
  if (error) {
    const code = error.message?.match(/MEMBER_[A-Z_]+/)?.[0] ?? "MEMBER_REQUEST_FAILED";
    if (error.code === "23505" && error.message?.includes("members_active_phone_once")) {
      const lookup = profile.role === "KASIR" ? "member_pos_search" : "member_workspace_read";
      const { data: duplicate } = await supabase.rpc(lookup, lookup === "member_pos_search"
        ? { p_search: String(args.p_phone ?? ""), p_limit: 10 }
        : { p_search: String(args.p_phone ?? ""), p_page: 1, p_page_size: 10 });
      const existingMember = duplicate && typeof duplicate === "object" && Array.isArray((duplicate as Record<string, unknown>).rows)
        ? ((duplicate as Record<string, unknown>).rows as unknown[]).find((row) => typeof row === "object" && row !== null && normalizePhone(String((row as Record<string, unknown>).phone ?? "")) === normalizePhone(String(args.p_phone ?? ""))) as Record<string, unknown> | undefined
        : undefined;
      return { ok: false, code: "MEMBER_PHONE_DUPLICATE", message: message.MEMBER_PHONE_DUPLICATE, existingMember };
    }
    return { ok: false, code, message: message[code] ?? "Permintaan member belum dapat diproses." };
  }
  return { ok: true, value: data && typeof data === "object" ? data as Record<string, unknown> : {} };
}

export async function searchMembers(search: string, page = 1): Promise<Result> {
  const profile = await getProfile();
  if (!profile || !["OWNER", "ADMIN"].includes(profile.role)) return { ok: false, code: "FORBIDDEN", message: message.MEMBER_WRITE_DENIED };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("member_workspace_read", { p_search: search.slice(0, 80), p_page: page, p_page_size: 20 });
  if (error) {
    console.error("[member_workspace_read] Supabase RPC failed", { code: error.code, message: error.message });
    return { ok: false, code: "MEMBER_READ_FAILED", message: "Data member belum dapat dimuat." };
  }
  if (!data || typeof data !== "object" || !Array.isArray((data as Record<string, unknown>).rows)) {
    console.error("[member_workspace_read] Invalid response contract", { responseType: Array.isArray(data) ? "array" : typeof data });
    return { ok: false, code: "MEMBER_READ_CONTRACT_INVALID", message: "Data member belum dapat dimuat." };
  }
  return { ok: true, value: data && typeof data === "object" ? data as Record<string, unknown> : {} };
}

export async function saveMember(input: { id?: string; name: string; phone: string; email: string }): Promise<Result> {
  if ((input.id && !UUID.test(input.id)) || input.name.length > 160 || input.phone.length > 40 || input.email.length > 254) return { ok: false, code: "INVALID_INPUT", message: "Periksa kembali data member." };
  return call("member_upsert", { p_member_id: input.id ?? null, p_full_name: input.name, p_phone: input.phone, p_email: input.email || null, p_request_id: crypto.randomUUID() });
}

export async function setMemberStatus(id: string, status: "ACTIVE" | "INACTIVE", reason: string): Promise<Result> {
  if (!UUID.test(id)) return { ok: false, code: "INVALID_INPUT", message: "Member tidak valid." };
  return call("member_status_set", { p_member_id: id, p_status: status, p_reason: reason, p_request_id: crypto.randomUUID() });
}
