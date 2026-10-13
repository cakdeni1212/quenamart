"use server";

import { revalidatePath } from "next/cache";
import { getProfile } from "@/lib/auth/session";
import { POS_PAYMENT_METHODS, type PosPaymentMethod } from "@/lib/settings/pos-shared";
import { createClient } from "@/lib/supabase/server";

export type PosSettingsInput = {
  outlet_id: string;
  receipt_footer_note: string;
  receipt_show_address: boolean;
  receipt_show_phone: boolean;
  enabled_payment_methods: PosPaymentMethod[];
  allow_hold_transactions: boolean;
  confirm_cart_cancellation: boolean;
};

type ActionResult = { ok: true; message: string } | { ok: false; message: string };

export async function updatePosSettings(input: PosSettingsInput): Promise<ActionResult> {
  try {
    const profile = await getProfile();
    if (!profile || profile.role !== "OWNER") return { ok: false, message: "Hanya Owner yang dapat mengubah pengaturan kasir." };
    if (!input || typeof input !== "object" || typeof input.outlet_id !== "string"
      || typeof input.receipt_footer_note !== "string" || input.receipt_footer_note.length > 200
      || typeof input.receipt_show_address !== "boolean" || typeof input.receipt_show_phone !== "boolean"
      || !Array.isArray(input.enabled_payment_methods)
      || !input.enabled_payment_methods.every((method) => POS_PAYMENT_METHODS.includes(method))
      || new Set(input.enabled_payment_methods).size !== input.enabled_payment_methods.length
      || input.enabled_payment_methods.length < 1 || input.enabled_payment_methods.length > POS_PAYMENT_METHODS.length
      || typeof input.allow_hold_transactions !== "boolean" || typeof input.confirm_cart_cancellation !== "boolean") {
      return { ok: false, message: "Periksa kembali pengaturan dan pilih sedikitnya satu metode pembayaran." };
    }
    const footer = input.receipt_footer_note.trim();
    if (footer.length > 200 || /[\u0000-\u001f\u007f]/.test(footer)) {
      return { ok: false, message: "Catatan struk maksimal 200 karakter dan tidak dapat berisi karakter khusus." };
    }

    const supabase = await createClient();
    const { error } = await supabase.rpc("pos_settings_update", {
      p_outlet_id: input.outlet_id,
      p_payload: {
        receipt_footer_note: footer,
        receipt_show_address: input.receipt_show_address,
        receipt_show_phone: input.receipt_show_phone,
        enabled_payment_methods: input.enabled_payment_methods,
        allow_hold_transactions: input.allow_hold_transactions,
        confirm_cart_cancellation: input.confirm_cart_cancellation,
      },
    });
    if (error) {
      const message = error.message;
      if (message.includes("POS_SETTINGS_UPDATE_DENIED")) return { ok: false, message: "Hanya Owner yang dapat mengubah pengaturan kasir." };
      if (message.includes("POS_SETTINGS_INVALID_PAYMENT_METHODS")) return { ok: false, message: "Aktifkan sedikitnya satu metode pembayaran yang didukung." };
      if (message.includes("POS_SETTINGS_INVALID_FOOTER")) return { ok: false, message: "Catatan struk maksimal 200 karakter dan tidak dapat berisi karakter khusus." };
      if (message.includes("POS_SETTINGS_SCOPE_DENIED")) return { ok: false, message: "Outlet aktif berubah. Muat ulang halaman sebelum menyimpan." };
      return { ok: false, message: "Perubahan belum tersimpan. Periksa data lalu coba kembali." };
    }
    revalidatePath("/pengaturan");
    revalidatePath("/pengaturan/kasir-penjualan");
    revalidatePath("/kasir");
    return { ok: true, message: "Pengaturan kasir berhasil disimpan." };
  } catch {
    return { ok: false, message: "Perubahan belum tersimpan. Periksa koneksi lalu coba kembali." };
  }
}
