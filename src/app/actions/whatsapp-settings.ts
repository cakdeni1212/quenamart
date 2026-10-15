"use server";
import { revalidatePath } from "next/cache";
import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";

export type WhatsAppSettingsInput = Pick<{
  whatsapp_transactions_enabled: boolean; automatic_receipt_enabled: boolean;
  include_points_earned: boolean; include_points_redeemed: boolean; include_points_balance: boolean;
}, "whatsapp_transactions_enabled" | "automatic_receipt_enabled" | "include_points_earned" | "include_points_redeemed" | "include_points_balance">;
export async function updateWhatsAppSettings(outletId: string, input: WhatsAppSettingsInput) {
  const profile = await getProfile();
  if (!profile || profile.role !== "OWNER") return { ok: false as const, message: "Hanya Owner yang dapat mengubah pengaturan WhatsApp." };
  if (!/^[0-9a-f-]{36}$/i.test(outletId) || !input || Object.values(input).some((value) => typeof value !== "boolean")
    || (input.automatic_receipt_enabled && !input.whatsapp_transactions_enabled)) {
    return { ok: false as const, message: "Periksa kembali pilihan pengaturan WhatsApp." };
  }
  const supabase = await createClient();
  const { error } = await supabase.rpc("whatsapp_settings_update", { p_outlet_id: outletId, p_payload: input });
  if (error) return { ok: false as const, message: "Pengaturan WhatsApp belum tersimpan. Silakan coba kembali." };
  revalidatePath("/pengaturan"); revalidatePath("/pengaturan/whatsapp"); revalidatePath("/whatsapp");
  return { ok: true as const, message: "Pengaturan WhatsApp berhasil disimpan." };
}
