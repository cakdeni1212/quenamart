"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";

export type NativeProductFormState = {
  error?: string;
  values?: Record<string, string>;
};

const messages: Record<string, string> = {
  NATIVE_PRODUCT_UNAUTHORIZED: "Hanya OWNER dan ADMIN yang dapat menambahkan produk.",
  NATIVE_PRODUCT_OUTLET_UNAVAILABLE: "Outlet aktif belum tersedia untuk membuat produk.",
  NATIVE_PRODUCT_INVALID_REQUEST: "Permintaan tidak valid. Muat ulang halaman lalu coba lagi.",
  NATIVE_PRODUCT_REQUIRED_FIELD_INVALID: "Lengkapi nama, kategori, dan satuan dengan format yang benar.",
  NATIVE_PRODUCT_SKU_INVALID: "Kode SKU tidak valid.",
  NATIVE_PRODUCT_SKU_EXISTS: "Kode SKU sudah digunakan.",
  NATIVE_PRODUCT_BARCODE_INVALID: "Barcode tidak valid.",
  NATIVE_PRODUCT_BARCODE_EXISTS: "Barcode sudah digunakan oleh produk lain.",
  NATIVE_PRODUCT_PRICE_INVALID: "Harga jual harus lebih besar dari Rp0 dan maksimal 2 angka desimal.",
  NATIVE_PRODUCT_REQUEST_CONFLICT: "Permintaan ini sudah digunakan dengan data berbeda. Muat ulang formulir.",
};

function errorMessage(message: string) {
  const code = Object.keys(messages).find((candidate) => message.includes(candidate));
  return code ? messages[code] : "Produk belum dapat disimpan. Periksa data lalu coba lagi.";
}

function text(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function containsControl(value: string) {
  return /[\u0000-\u001f\u007f-\u009f]/u.test(value);
}

export async function createNativeProduct(
  _previous: NativeProductFormState,
  formData: FormData,
): Promise<NativeProductFormState> {
  const profile = await getProfile();
  if (!profile || (profile.role !== "OWNER" && profile.role !== "ADMIN")) {
    return { error: "Hanya OWNER dan ADMIN yang dapat menambahkan produk." };
  }

  const rawBarcode = formData.get("barcode");
  const rawSku = formData.get("sku");
  if ((typeof rawBarcode === "string" && containsControl(rawBarcode)) || (typeof rawSku === "string" && containsControl(rawSku))) {
    return { error: "SKU atau barcode mengandung karakter yang tidak didukung." };
  }
  const values = Object.fromEntries(
    ["sku", "name", "category", "unit", "brand", "rack", "barcode", "sellingPrice", "autoSku"].map((key) => [key, text(formData, key)]),
  );
  const requestId = text(formData, "requestId");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(requestId)) {
    return { error: "Permintaan tidak valid. Muat ulang halaman lalu coba lagi.", values };
  }
  if (!values.name || !values.category || !values.unit) {
    return { error: "Nama produk, kategori, dan satuan wajib diisi.", values };
  }
  const rawPrice = values.sellingPrice.replace(/\s/g, "");
  if (!/^\d+(?:[.,]\d{1,2})?$/.test(rawPrice)) {
    return { error: "Masukkan harga jual yang valid, maksimal 2 angka desimal.", values };
  }
  const sellingPrice = rawPrice.replace(",", ".");
  if (!/^\d+(?:\.\d{1,2})?$/.test(sellingPrice) || Number(sellingPrice) <= 0 || Number(sellingPrice) >= 1_000_000_000_000) {
    return { error: "Harga jual harus lebih besar dari Rp0.", values };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("native_product_create", {
    p_request_id: requestId,
    p_sku: values.autoSku === "on" ? null : values.sku || null,
    p_name: values.name,
    p_category_label: values.category,
    p_unit_label: values.unit,
    p_brand_label: values.brand || null,
    p_rack_label: values.rack || null,
    p_barcode: values.barcode || null,
    p_selling_price: sellingPrice,
  });
  if (error) return { error: errorMessage(error.message), values };

  const result = data as { ok?: boolean; product_id?: string } | null;
  if (!result?.ok || !result.product_id) return { error: "Produk belum dapat disimpan. Coba lagi.", values };
  revalidatePath("/produk");
  revalidatePath(`/produk/${result.product_id}`);
  redirect(`/produk/${result.product_id}?created=1`);
}
