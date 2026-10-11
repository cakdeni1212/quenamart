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
    POS_CART_STALE_REVISION: "Transaksi berubah di perangkat lain. Data telah diperbarui.",
    POS_CART_STALE: "Transaksi berubah di perangkat lain. Data telah diperbarui.",
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
    POS_COSTING_NOT_ACTIVE: "Sistem kasir belum diaktifkan untuk transaksi penjualan.",
    POS_COST_PROJECTION_STALE: "Data transaksi perlu diperbarui. Muat ulang lalu coba kembali.",
    POS_INSUFFICIENT_STOCK: "Stok barang tidak mencukupi. Periksa transaksi dan muat ulang.",
    POS_PRICE_CHANGED: "Harga berubah. Periksa dan konfirmasi harga terbaru sebelum membayar.",
    POS_ALREADY_COMPLETED: "Transaksi ini sudah selesai.",
    POS_CART_NOT_ACTIVE: "Transaksi tidak aktif. Muat ulang keranjang.",
    POS_CART_EMPTY: "Tambahkan barang sebelum melanjutkan pembayaran.",
    POS_PAYMENT_INVALID: "Pembayaran tidak valid. Periksa jumlah uang yang diterima.",
    POS_CHECKOUT_CONFLICT: "Permintaan pembayaran berbeda dari transaksi sebelumnya. Muat ulang data.",
    POS_UNAUTHORIZED: "Transaksi tidak dapat diakses oleh akun ini.",
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

export async function parkPosCart(cartId: string, expectedRevision: number, requestId: string) { return transitionPosCart("park", cartId, expectedRevision, requestId); }
export async function resumePosCart(cartId: string, expectedRevision: number, requestId: string) { return transitionPosCart("resume", cartId, expectedRevision, requestId); }
export async function cancelPosCart(cartId: string, expectedRevision: number, requestId: string) { return transitionPosCart("cancel", cartId, expectedRevision, requestId); }

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

export async function checkoutPos(input: {
  requestId: string;
  cartId: string;
  expectedRevision: number;
  method: "CASH" | "QRIS" | "CARD" | "E_WALLET";
  cashReceivedAmount?: string;
  referenceText?: string;
}): Promise<PosResult> {
  if (!validUuid(input.requestId) || !validUuid(input.cartId)
      || !Number.isSafeInteger(input.expectedRevision) || input.expectedRevision < 1
      || !["CASH", "QRIS", "CARD", "E_WALLET"].includes(input.method)
      || (input.method === "CASH" && (!input.cashReceivedAmount || !/^(?:0|[1-9][0-9]{0,29})(?:\.[0-9]{1,2})?$/.test(input.cashReceivedAmount)))
      || (input.method !== "CASH" && input.cashReceivedAmount !== undefined)
      || (input.referenceText !== undefined && (input.referenceText.trim().length === 0 || input.referenceText.length > 160))) {
    return { ok: false, code: "POS_PAYMENT_INVALID", message: messageFor("POS_PAYMENT_INVALID") };
  }
  return invoke("pos_checkout_complete", {
    p_request_id: input.requestId,
    p_cart_id: input.cartId,
    p_expected_cart_revision: input.expectedRevision,
    p_payment_method: input.method,
    p_cash_received_amount: input.method === "CASH" ? input.cashReceivedAmount : null,
    p_reference_text: input.referenceText?.trim() || null,
  });
}

export async function readPosSaleReceipt(saleId: string): Promise<PosResult> {
  if (!validUuid(saleId)) return { ok: false, code: "INVALID_REQUEST", message: "Struk tidak dapat dimuat." };
  const result = await invoke("pos_sale_receipt_read", { p_sale_id: saleId });
  if (!result.ok) return result;
  if (!record(result.value) || !Array.isArray(result.value.items) || !Array.isArray(result.value.payments)) {
    return { ok: false, code: "POS_RECEIPT_NOT_FOUND", message: "Struk tidak tersedia untuk akun ini." };
  }
  return result;
}

export async function ensureActivePosCart(): Promise<PosResult> {
  const context = await allowedClient();
  if (!context) return { ok: false, code: "FORBIDDEN", message: messageFor("POS_CART_ACCESS_DENIED") };
  const { data, error } = await context.supabase.rpc("pos_cart_workspace_read", { p_cart_id: null, p_limit: 20 });
  if (error || !record(data) || !Array.isArray(data.carts)) return { ok: false, code: "POS_READ_FAILED", message: "Keranjang POS belum dapat dimuat." };
  const active = data.carts.find((cart) => record(cart) && cart.status === "ACTIVE");
  if (record(active)) return { ok: true, value: active };
  return createPosCart(crypto.randomUUID());
}
