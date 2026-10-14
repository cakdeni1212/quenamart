"use server";

import { revalidatePath } from "next/cache";
import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import type { MemberPointsSettingsInput } from "@/lib/settings/member-points-shared";

type Result = { ok: true; message: string } | { ok: false; message: string };
const validInteger = (value: string | null) => value === null || (/^[1-9][0-9]{0,8}$/.test(value) && Number(value) <= 1_000_000_000);

export async function updateMemberPointsSettings(input: MemberPointsSettingsInput): Promise<Result> {
  const profile = await getProfile();
  if (!profile || profile.role !== "OWNER") return { ok: false, message: "Hanya Owner yang dapat mengubah pengaturan Member & Poin." };
  if (!input || typeof input.program_enabled !== "boolean" || typeof input.redeem_enabled !== "boolean"
    || !validInteger(input.rupiah_per_point) || !validInteger(input.rupiah_per_redeem_point) || !validInteger(input.minimum_redeem_points)
    || (input.program_enabled && !input.rupiah_per_point)
    || (input.redeem_enabled && (!input.rupiah_per_redeem_point || !input.minimum_redeem_points))) {
    return { ok: false, message: "Lengkapi nilai perolehan dan penukaran yang aktif dengan bilangan bulat positif (maksimal 999.999.999)." };
  }
  const supabase = await createClient();
  const { error } = await supabase.rpc("member_loyalty_settings_update", { p_payload: {
    program_enabled: input.program_enabled,
    rupiah_per_point: input.rupiah_per_point,
    redeem_enabled: input.redeem_enabled,
    rupiah_per_redeem_point: input.rupiah_per_redeem_point,
    minimum_redeem_points: input.minimum_redeem_points,
  } });
  if (error) {
    if (error.message.includes("LOYALTY_SETTINGS_UPDATE_DENIED")) return { ok: false, message: "Hanya Owner yang dapat mengubah pengaturan Member & Poin." };
    if (error.message.includes("LOYALTY_EARN_RATE_REQUIRED")) return { ok: false, message: "Isi nilai belanja per poin sebelum mengaktifkan program." };
    if (error.message.includes("LOYALTY_REDEEM_POLICY_REQUIRED")) return { ok: false, message: "Isi nilai dan minimum penukaran sebelum mengaktifkannya." };
    return { ok: false, message: "Pengaturan belum tersimpan. Periksa kembali nilainya." };
  }
  revalidatePath("/pengaturan");
  revalidatePath("/pengaturan/member-poin");
  revalidatePath("/kasir");
  return { ok: true, message: "Pengaturan Member & Poin berhasil disimpan." };
}
