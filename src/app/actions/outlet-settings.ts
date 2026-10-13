"use server";

import { revalidatePath } from "next/cache";
import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";

export type OutletSettingsInput = {
  id: string;
  name: string;
  customer_display_name: string;
  address: string;
  city: string;
  province: string;
  postal_code: string;
  phone: string;
  whatsapp: string;
  email: string;
  is_active: boolean;
};

const limits: Record<Exclude<keyof OutletSettingsInput, "id" | "is_active">, number> = {
  name: 120,
  customer_display_name: 160,
  address: 300,
  city: 100,
  province: 100,
  postal_code: 20,
  phone: 40,
  whatsapp: 40,
  email: 254,
};

export async function updateOutletSettings(input: OutletSettingsInput): Promise<{ ok: boolean; message: string }> {
  try {
    const profile = await getProfile();
    if (!profile || profile.role !== "OWNER") return { ok: false, message: "Hanya Owner yang dapat mengubah identitas outlet." };
    if (!input || typeof input !== "object" || typeof input.id !== "string" || typeof input.is_active !== "boolean") {
      return { ok: false, message: "Periksa kembali data outlet." };
    }

    const values = {} as Record<string, string>;
    for (const [field, maxLength] of Object.entries(limits)) {
      const value = input[field as keyof typeof limits];
      if (typeof value !== "string" || value.length > maxLength) return { ok: false, message: "Periksa kembali panjang data yang diisi." };
      values[field] = value.trim();
    }
    if (!values.name) return { ok: false, message: "Nama outlet wajib diisi." };
    if (values.email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(values.email)) return { ok: false, message: "Format email belum benar." };

    const supabase = await createClient();
    const { data, error } = await supabase.rpc("outlet_settings_update", {
      p_outlet_id: input.id,
      p_payload: { ...values, is_active: input.is_active },
    });
    if (error) {
      const message = error.message;
      if (message.includes("OUTLET_SETTINGS_INVALID_EMAIL")) return { ok: false, message: "Format email belum benar." };
      if (message.includes("OUTLET_SETTINGS_INVALID_NAME")) return { ok: false, message: "Nama outlet wajib diisi." };
      if (message.includes("OUTLET_SETTINGS_DEACTIVATION_BLOCKED")) return { ok: false, message: "Outlet yang sedang digunakan tidak dapat dinonaktifkan." };
      if (message.includes("OUTLET_SETTINGS_SCOPE_DENIED")) return { ok: false, message: "Outlet aktif berubah. Muat ulang halaman sebelum menyimpan." };
      return { ok: false, message: "Perubahan belum tersimpan. Periksa data lalu coba kembali." };
    }
    if (!data || typeof data !== "object") return { ok: false, message: "Perubahan belum dapat dikonfirmasi. Muat ulang sebelum mencoba lagi." };
    revalidatePath("/pengaturan");
    revalidatePath("/pengaturan/toko-outlet");
    revalidatePath("/transaksi");
    return { ok: true, message: "Perubahan outlet berhasil disimpan." };
  } catch {
    return { ok: false, message: "Perubahan belum tersimpan. Periksa koneksi lalu coba kembali." };
  }
}
