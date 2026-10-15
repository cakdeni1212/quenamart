import "server-only";

import { createHash, randomBytes } from "node:crypto";
import { createAdminClient } from "@/lib/supabase/admin";

type JsonRecord = Record<string, unknown>;
export type DigitalReceipt = {
  store: { name: string; address: string | null; phone: string | null; footer: string | null };
  sale: { number: string; completed_at: string; cashier: string };
  items: Array<{ name: string; unit: string | null; quantity: string; unit_price: string; line_total: string }>;
  totals: { subtotal: string; discount_total: string; grand_total: string };
  payments: Array<{ method: string; amount: string; received: string | null; change: string | null }>;
  member: { name: string; member_number: string } | null;
  loyalty: { points_earned: string; points_redeemed: string; points_discount: string; balance_after: string | null } | null;
};

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function string(value: unknown, fallback = ""): string {
  return value === null || value === undefined ? fallback : String(value);
}
function nullableString(value: unknown): string | null {
  return value === null || value === undefined ? null : String(value);
}

function parseReceipt(value: unknown): DigitalReceipt | null {
  if (!isRecord(value) || !isRecord(value.store) || !isRecord(value.sale) || !isRecord(value.totals)
    || !Array.isArray(value.items) || !Array.isArray(value.payments)
    || value.items.some((item) => !isRecord(item)) || value.payments.some((payment) => !isRecord(payment))) return null;
  const store = value.store, sale = value.sale, totals = value.totals;
  if (typeof sale.number !== "string" || typeof sale.completed_at !== "string") return null;
  const items = value.items.filter(isRecord).map((item) => ({
    name: string(item.name, "Barang"), unit: nullableString(item.unit), quantity: string(item.quantity, "0"),
    unit_price: string(item.unit_price, "0"), line_total: string(item.line_total, "0"),
  }));
  const payments = value.payments.filter(isRecord).map((payment) => ({
    method: string(payment.method), amount: string(payment.amount, "0"),
    received: nullableString(payment.received), change: nullableString(payment.change),
  }));
  const member = isRecord(value.member) && typeof value.member.name === "string" && typeof value.member.member_number === "string"
    ? { name: value.member.name, member_number: value.member.member_number } : null;
  const loyalty = isRecord(value.loyalty) ? {
    points_earned: string(value.loyalty.points_earned, "0"), points_redeemed: string(value.loyalty.points_redeemed, "0"),
    points_discount: string(value.loyalty.points_discount, "0"), balance_after: nullableString(value.loyalty.balance_after),
  } : null;
  return {
    store: { name: string(store.name, "QUENA MART"), address: nullableString(store.address), phone: nullableString(store.phone), footer: nullableString(store.footer) },
    sale: { number: sale.number, completed_at: sale.completed_at, cashier: string(sale.cashier, "Kasir") },
    items, totals: { subtotal: string(totals.subtotal, "0"), discount_total: string(totals.discount_total, "0"), grand_total: string(totals.grand_total, "0") },
    payments, member, loyalty,
  };
}

export async function readPublicCustomerReceipt(token: string): Promise<DigitalReceipt | null> {
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) return null;
  const tokenHash = createHash("sha256").update(token, "utf8").digest("hex");
  try {
    const { data, error } = await createAdminClient().rpc("customer_public_receipt_read", { p_token_hash: tokenHash });
    if (error) {
      console.error("[customer_public_receipt_read] receipt lookup failed", { code: error.code });
      return null;
    }
    const receipt = parseReceipt(data);
    if (!receipt) console.error("[customer_public_receipt_read] malformed receipt projection");
    return receipt;
  } catch (error) {
    console.error("[customer_public_receipt_read] receipt lookup failed", { name: error instanceof Error ? error.name : "unknown" });
    return null;
  }
}

export type CustomerReceiptDeliveryPayload = {
  destinationWhatsApp: string;
  customerName: string;
  saleNumber: string;
  total: string;
  pointsEarned: string;
  pointsRedeemed: string;
  pointsDiscount: string;
  balanceAfter: string | null;
  receiptUrl: string;
};

function publicOrigin(): string | null {
  const configured = process.env.NEXT_PUBLIC_APP_URL?.trim();
  if (!configured) return null;
  try {
    const url = new URL(configured);
    if (url.protocol !== "https:" || url.username || url.password) return null;
    return url.origin;
  } catch { return null; }
}

/** Server-only contract for a future notification worker. It never sends a message. */
export async function getCustomerReceiptDeliveryPayload(saleId: string): Promise<CustomerReceiptDeliveryPayload | null> {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(saleId)) return null;
  const origin = publicOrigin();
  if (!origin) return null;
  const token = randomBytes(32).toString("base64url");
  const tokenHash = createHash("sha256").update(token, "utf8").digest("hex");
  let data: unknown;
  try {
    const response = await createAdminClient().rpc("customer_receipt_delivery_payload", { p_sale_id: saleId, p_token_hash: tokenHash });
    if (response.error) {
      console.error("[customer_receipt_delivery_payload] payload unavailable", { code: response.error.code });
      return null;
    }
    data = response.data;
  } catch (error) {
    console.error("[customer_receipt_delivery_payload] payload unavailable", { name: error instanceof Error ? error.name : "unknown" });
    return null;
  }
  if (!isRecord(data) || typeof data.destination_whatsapp !== "string" || typeof data.sale_number !== "string") return null;
  return {
    destinationWhatsApp: data.destination_whatsapp, customerName: string(data.customer_name), saleNumber: data.sale_number,
    total: string(data.total, "0"), pointsEarned: string(data.points_earned, "0"), pointsRedeemed: string(data.points_redeemed, "0"),
    pointsDiscount: string(data.points_discount, "0"), balanceAfter: nullableString(data.balance_after),
    receiptUrl: new URL(`/struk/${token}`, `${origin}/`).toString(),
  };
}
