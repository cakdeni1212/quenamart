"use server";

import { createHash, randomBytes } from "node:crypto";
import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import type { PosPaymentMethod } from "@/lib/settings/pos-shared";

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
    POS_PAYMENT_METHOD_DISABLED: "Metode pembayaran ini baru saja dinonaktifkan. Muat ulang kasir lalu pilih metode lain.",
    POS_HOLD_DISABLED: "Hold transaksi baru saja dinonaktifkan. Keranjang tetap tersimpan dan dapat dilanjutkan atau dibatalkan.",
    POS_CHECKOUT_CONFLICT: "Permintaan pembayaran berbeda dari transaksi sebelumnya. Muat ulang data.",
    POS_UNAUTHORIZED: "Transaksi tidak dapat diakses oleh akun ini.",
    POS_MEMBER_INACTIVE_OR_NOT_FOUND: "Member sudah tidak aktif atau tidak ditemukan. Hapus pilihan member sebelum membayar.",
    MEMBER_FIELDS_INVALID: "Periksa nama, nomor WhatsApp, dan persetujuan layanan.",
    MEMBER_PHONE_DUPLICATE: "Nomor WhatsApp ini sudah terdaftar. Cari dan pilih Member tersebut.",
    MEMBER_CONSENT_REQUIRED: "Persetujuan layanan membership diperlukan.",
    POS_LOYALTY_MEMBER_REQUIRED: "Pilih member sebelum menukar poin.",
    POS_LOYALTY_REDEEM_DISABLED: "Penukaran poin sedang tidak tersedia. Muat ulang kasir.",
    POS_LOYALTY_POLICY_CHANGED: "Aturan penukaran berubah. Periksa jumlah poin dan terapkan kembali sebelum membayar.",
    POS_LOYALTY_BELOW_MINIMUM: "Jumlah penukaran belum mencapai minimum.",
    POS_LOYALTY_INSUFFICIENT_POINTS: "Saldo poin berubah atau tidak mencukupi. Muat ulang kasir.",
    POS_LOYALTY_EXCEEDS_PAYABLE: "Nilai poin melebihi total belanja.",
    POS_LOYALTY_REDEEM_INVALID: "Jumlah penukaran poin tidak valid.",
    MEMBER_POS_REQUEST_REUSED: "Permintaan perubahan member dipakai untuk data yang berbeda. Muat ulang transaksi.",
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
    const code = error.message?.match(/POS_[A-Z_]+|BARCODE_[A-Z_]+|MEMBER_[A-Z_]+/)?.[0] ?? "POS_REQUEST_FAILED";
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

export async function searchPosMembers(search: string): Promise<PosResult> {
  if (search.trim().length < 2 || search.length > 80) return { ok: true, value: { rows: [] } };
  return invoke("member_pos_search", { p_search: search.trim(), p_limit: 10 });
}

export async function registerPosMember(input: { cartId: string; expectedRevision: number; name: string; phone: string; email: string; serviceConsent: boolean; promotionalConsent: boolean }): Promise<PosResult> {
  if (!validUuid(input.cartId) || !Number.isSafeInteger(input.expectedRevision) || input.expectedRevision < 1
    || input.name.trim().length < 1 || input.name.length > 160 || input.phone.length > 40 || input.email.length > 254 || !input.serviceConsent) {
    return { ok: false, code: "MEMBER_FIELDS_INVALID", message: "Periksa nama, nomor WhatsApp, dan persetujuan layanan." };
  }
  const result = await invoke("pos_member_register", { p_cart: input.cartId, p_expected_revision: input.expectedRevision,
    p_full_name: input.name, p_phone: input.phone, p_email: input.email.trim() || null,
    p_request_id: crypto.randomUUID(), p_membership_consent: true,
    p_promotional_consent: Boolean(input.promotionalConsent) });
  if (!result.ok) return result;
  return { ok: true, value: { member_number: result.value.member_number } };
}

export async function setPosCartMember(cartId: string, memberId: string | null, revision: number, requestId: string): Promise<PosResult> {
  if (!validUuid(cartId) || (memberId !== null && !validUuid(memberId)) || !validUuid(requestId)
      || !Number.isSafeInteger(revision) || revision < 1) return { ok: false, code: "INVALID_INPUT", message: "Data member atau transaksi tidak valid." };
  return invoke("pos_cart_member_set", { p_cart: cartId, p_member: memberId, p_expected_revision: revision, p_request: requestId });
}

export async function setPosCartRedeemPoints(cartId: string, points: number, revision: number, requestId: string): Promise<PosResult> {
  if (!validUuid(cartId) || !validUuid(requestId) || !Number.isSafeInteger(points) || points < 0 || points > 1_000_000_000
      || !Number.isSafeInteger(revision) || revision < 1) {
    return { ok: false, code: "POS_LOYALTY_REDEEM_INVALID", message: messageFor("POS_LOYALTY_REDEEM_INVALID") };
  }
  return invoke("pos_cart_redeem_points_set", { p_cart: cartId, p_points: points, p_expected_revision: revision, p_request: requestId });
}

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
  method: PosPaymentMethod;
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

export type DigitalReceiptLinkResult =
  | { ok: true; path: string; publicUrl: string | null; publicUrlConfigured: boolean }
  | { ok: false; message: string };

export async function issueDigitalReceiptLink(saleId: string): Promise<DigitalReceiptLinkResult> {
  if (!validUuid(saleId)) return { ok: false, message: "Struk digital tidak tersedia untuk transaksi ini." };
  try {
    const context = await allowedClient();
    if (!context) return { ok: false, message: messageFor("POS_CART_ACCESS_DENIED") };
    const token = randomBytes(32).toString("base64url");
    const tokenHash = createHash("sha256").update(token, "utf8").digest("hex");
    const { data, error } = await context.supabase.rpc("pos_sale_public_receipt_issue", { p_sale_id: saleId, p_token_hash: tokenHash });
    if (error || !record(data) || data.ok !== true) {
      return { ok: false, message: "Tautan struk tidak dapat dibuat untuk transaksi ini." };
    }
    const path = `/struk/${token}`;
    const configured = process.env.NEXT_PUBLIC_APP_URL?.trim();
    if (!configured) return { ok: true, path, publicUrl: null, publicUrlConfigured: false };
    try {
      const origin = new URL(configured);
      if (origin.protocol !== "https:" || origin.username || origin.password) {
        return { ok: true, path, publicUrl: null, publicUrlConfigured: false };
      }
      return { ok: true, path, publicUrl: new URL(path, origin).toString(), publicUrlConfigured: true };
    } catch {
      return { ok: true, path, publicUrl: null, publicUrlConfigured: false };
    }
  } catch (error) {
    console.error("[issueDigitalReceiptLink] issuance failed", { name: error instanceof Error ? error.name : "unknown" });
    return { ok: false, message: "Tautan struk tidak dapat dibuat untuk transaksi ini." };
  }
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
