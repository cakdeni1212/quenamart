"use server";

import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";

type PosResult = { ok: true; value: Record<string, unknown> } | { ok: false; code: string; message: string };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const QUANTITY = /^(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,3})?$/;

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function validUuid(value: string): boolean { return UUID.test(value); }
function validQuantity(value: string, allowZero = false): boolean {
  if (!QUANTITY.test(value)) return false;
  return allowZero || Number(value) > 0;
}

function messageFor(code: string): string {
  const messages: Record<string, string> = {
    POS_CART_ACCESS_DENIED: "POS hanya tersedia untuk OWNER, ADMIN, atau KASIR aktif.",
    POS_OUTLET_UNAVAILABLE: "Outlet POS aktif belum tersedia.",
    POS_CART_NOT_FOUND: "Keranjang tidak ditemukan atau bukan milik akun ini.",
    POS_CART_NOT_EDITABLE: "Keranjang ini tidak dapat diubah.",
    POS_CART_STALE_REVISION: "Keranjang berubah di perangkat lain. Muat ulang sebelum melanjutkan.",
    POS_CART_REQUEST_REUSED: "ID permintaan sudah digunakan untuk perubahan yang berbeda.",
    POS_CART_QUANTITY_INVALID: "Jumlah harus lebih dari nol dengan maksimal tiga angka desimal.",
    POS_PRODUCT_UNAVAILABLE: "Barang tidak tersedia untuk outlet ini.",
    POS_PRICE_UNAVAILABLE: "Harga jual barang belum tersedia.",
    POS_PRICE_ZERO: "Harga jual nol perlu diperbaiki sebelum barang dimasukkan.",
    POS_PRICE_CHANGED_ACK_REQUIRED: "Harga berubah. Periksa dan konfirmasi harga terbaru.",
    POS_PRICE_CHANGED_RETRY: "Harga berubah lagi. Muat ulang harga sebelum mengonfirmasi.",
    POS_PRICE_CONFIRMATION_INVALID: "Konfirmasi harga tidak valid.",
    POS_CART_LINE_LIMIT: "Keranjang mencapai batas 200 jenis barang.",
    POS_CART_TRANSITION_INVALID: "Status keranjang sudah berubah. Muat ulang.",
    POS_CART_OPERATION_INVALID: "Perintah keranjang tidak valid.",
    POS_CART_ITEM_NOT_FOUND: "Barang tidak ditemukan di keranjang ini.",
    BARCODE_NOT_FOUND: "Barcode belum terdaftar.",
    BARCODE_AMBIGUOUS: "Barcode cocok dengan beberapa barang. Cari barang secara manual.",
  };
  return messages[code] ?? "Permintaan POS belum dapat diproses. Coba muat ulang.";
}

async function allowedClient(): Promise<{ supabase: Awaited<ReturnType<typeof createClient>> } | null> {
  const profile = await getProfile();
  if (!profile || !["OWNER", "ADMIN", "KASIR"].includes(profile.role)) return null;
  return { supabase: await createClient() };
}

async function invoke(name: string, args: Record<string, unknown>): Promise<PosResult> {
  const context = await allowedClient();
  if (!context) return { ok: false, code: "FORBIDDEN", message: messageFor("POS_CART_ACCESS_DENIED") };
  const { data, error } = await context.supabase.rpc(name, args);
  if (error) {
    const code = error.message?.match(/POS_[A-Z_]+|BARCODE_[A-Z_]+/)?.[0] ?? "POS_REQUEST_FAILED";
    return { ok: false, code, message: messageFor(code) };
  }
  if (!record(data)) return { ok: false, code: "INVALID_RESPONSE", message: "Respons POS belum dapat dibaca. Muat ulang." };
  return { ok: true, value: data };
}

export async function createPosCart(requestId: string): Promise<PosResult> {
  if (!validUuid(requestId)) return { ok: false, code: "INVALID_REQUEST", message: "ID permintaan tidak valid." };
  return invoke("pos_cart_create", { p_request_id: requestId });
}

export async function addPosCartItem(input: { cartId: string; productId: string; quantityDelta: string; expectedRevision: number; requestId: string }): Promise<PosResult> {
  if (!validUuid(input.cartId) || !validUuid(input.productId) || !validUuid(input.requestId)
      || !validQuantity(input.quantityDelta) || !Number.isSafeInteger(input.expectedRevision) || input.expectedRevision < 1) {
    return { ok: false, code: "INVALID_INPUT", message: "Barang, jumlah, revisi, atau ID permintaan tidak valid." };
  }
  return invoke("pos_cart_add_item", { p_cart: input.cartId, p_product: input.productId,
    p_quantity_delta: input.quantityDelta, p_expected_revision: input.expectedRevision, p_request_id: input.requestId });
}

export async function setPosCartItemQuantity(input: { cartId: string; itemId: string; quantity: string; expectedRevision: number; requestId: string }): Promise<PosResult> {
  if (!validUuid(input.cartId) || !validUuid(input.itemId) || !validUuid(input.requestId)
      || !validQuantity(input.quantity, true) || !Number.isSafeInteger(input.expectedRevision) || input.expectedRevision < 1) {
    return { ok: false, code: "INVALID_INPUT", message: "Jumlah, revisi, atau ID permintaan tidak valid." };
  }
  return invoke("pos_cart_set_item_quantity", { p_cart: input.cartId, p_item: input.itemId,
    p_quantity: input.quantity, p_expected_revision: input.expectedRevision, p_request_id: input.requestId });
}

export async function acknowledgePosCartPrice(input: { cartId: string; itemId: string; currentPrice: string; expectedRevision: number; requestId: string }): Promise<PosResult> {
  if (!validUuid(input.cartId) || !validUuid(input.itemId) || !validUuid(input.requestId)
      || !/^(?:0|[1-9][0-9]{0,11})\.[0-9]{2}$/.test(input.currentPrice) || Number(input.currentPrice) <= 0
      || !Number.isSafeInteger(input.expectedRevision) || input.expectedRevision < 1) {
    return { ok: false, code: "INVALID_INPUT", message: "Konfirmasi harga, revisi, atau ID permintaan tidak valid." };
  }
  return invoke("pos_cart_acknowledge_price", { p_cart: input.cartId, p_item: input.itemId,
    p_confirmed_price: input.currentPrice, p_expected_revision: input.expectedRevision, p_request_id: input.requestId });
}

async function transitionPosCart(operation: "park" | "resume" | "cancel", cartId: string, expectedRevision: number, requestId: string): Promise<PosResult> {
  if (!validUuid(cartId) || !validUuid(requestId) || !Number.isSafeInteger(expectedRevision) || expectedRevision < 1) {
    return { ok: false, code: "INVALID_INPUT", message: "Keranjang, revisi, atau ID permintaan tidak valid." };
  }
  return invoke(`pos_cart_${operation}`, { p_cart: cartId, p_expected_revision: expectedRevision, p_request_id: requestId });
}

export const parkPosCart = (cartId: string, expectedRevision: number, requestId: string) => transitionPosCart("park", cartId, expectedRevision, requestId);
export const resumePosCart = (cartId: string, expectedRevision: number, requestId: string) => transitionPosCart("resume", cartId, expectedRevision, requestId);
export const cancelPosCart = (cartId: string, expectedRevision: number, requestId: string) => transitionPosCart("cancel", cartId, expectedRevision, requestId);

export async function resolvePosBarcode(barcode: string): Promise<PosResult> {
  if (typeof barcode !== "string" || barcode.trim().length === 0 || barcode.trim().length > 128 || /[\u0000-\u001f\u007f]/.test(barcode)) {
    return { ok: true, value: { resolution: "BARCODE_NOT_FOUND" } };
  }
  const result = await invoke("pos_resolve_barcode", { p_barcode: barcode.trim() });
  if (!result.ok) return result;
  const resolution = result.value.resolution;
  return { ok: true, value: { resolution, product: record(result.value.product) ? result.value.product : null } };
}

export async function searchPosProducts(query: string): Promise<PosResult> {
  if (typeof query !== "string" || query.trim().length < 2 || query.trim().length > 80 || /[\u0000-\u001f\u007f]/.test(query)) {
    return { ok: true, value: { rows: [], count: 0 } };
  }
  const result = await invoke("pos_search_products", { p_query: query.trim(), p_limit: 25 });
  if (!result.ok) return result;
  return { ok: true, value: { rows: Array.isArray(result.value.rows) ? result.value.rows.filter(record) : [], count: Number(result.value.count) || 0 } };
}
