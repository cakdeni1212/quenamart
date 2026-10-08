export const RECEIPT_PAGE_SIZE = 25;
export const RECEIPT_ITEM_LIMIT = 500;
export const RECEIPT_QTY_SCALE = 3;
export const RECEIPT_QTY_MAX = 100_000_000_000;

export type ReceiptDraftItem = {
  product_id: string;
  accepted_quantity: string;
  bonus_quantity: string;
  rejected_quantity: string;
  short_quantity: string | null;
  operational_note: string | null;
};

export type ReceiptInvoiceLine = { productId: string; name: string; sku: string; quantity: string; unitPrice: string; priceSource: "PEMBELIAN_TERAKHIR" | "CURRENT_COST_REFERENCE" | null };

export function receiptInvoiceSubtotal(quantity: unknown, unitPrice: unknown): number | null {
  if (quantity === "" || unitPrice === "" || quantity === null || unitPrice === null) return null;
  const qty = Number(quantity); const price = Number(unitPrice);
  return Number.isFinite(qty) && qty >= 0 && Number.isFinite(price) && price >= 0
    ? Math.round(qty * price * 100) / 100 : null;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID.test(value);
}

export function parseReceiptQuantity(value: unknown, optional = false): number | null {
  if (optional && (value === null || value === "" || value === undefined)) return null;
  const text = typeof value === "number" && Number.isFinite(value) ? String(value) : typeof value === "string" ? value.trim() : "";
  if (!/^\d+(?:\.\d+)?$/.test(text)) return null;
  const fraction = text.split(".")[1] ?? "";
  if (fraction.replace(/0+$/, "").length > RECEIPT_QTY_SCALE) return null;
  const parsed = Number(text);
  if (!Number.isFinite(parsed) || parsed < 0 || parsed >= RECEIPT_QTY_MAX) return null;
  return parsed;
}

export function receiptStockQuantity(accepted: unknown, bonus: unknown): number | null {
  const acceptedQty = parseReceiptQuantity(accepted);
  const bonusQty = parseReceiptQuantity(bonus);
  return acceptedQty === null || bonusQty === null ? null : acceptedQty + bonusQty;
}

export function parseReceiptPage(value: unknown): number {
  const parsed = typeof value === "string" ? Number(value) : NaN;
  return Number.isSafeInteger(parsed) && parsed > 0 ? Math.min(parsed, 100_000) : 1;
}

export function formatReceiptQuantity(value: number | string | null | undefined): string {
  if (value === null || value === undefined || value === "") return "—";
  const amount = Number(value);
  if (!Number.isFinite(amount)) return "—";
  return new Intl.NumberFormat("id-ID", { maximumFractionDigits: 3 }).format(amount);
}

export function receiptPostRetryKey(sessionId: string) {
  return `quena:purchasing:POST_PURCHASE_RECEIPT:${sessionId}`;
}

export function normalizeReceiptDraftItems(value: unknown): ReceiptDraftItem[] | null {
  if (!Array.isArray(value) || value.length < 1 || value.length > RECEIPT_ITEM_LIMIT) return null;
  const products = new Set<string>();
  const result: ReceiptDraftItem[] = [];
  for (const candidate of value) {
    if (!candidate || typeof candidate !== "object") return null;
    const item = candidate as Record<string, unknown>;
    if (!isUuid(item.product_id) || products.has(item.product_id)) return null;
    products.add(item.product_id);
    const accepted = parseReceiptQuantity(item.accepted_quantity);
    const bonus = parseReceiptQuantity(item.bonus_quantity);
    const rejected = parseReceiptQuantity(item.rejected_quantity);
    const short = parseReceiptQuantity(item.short_quantity, true);
    if (accepted === null || bonus === null || rejected === null || short === null && item.short_quantity !== null && item.short_quantity !== "") return null;
    if (accepted + bonus + rejected + (short ?? 0) <= 0) return null;
    const note = typeof item.operational_note === "string" ? item.operational_note.trim() : "";
    if (note.length > 300) return null;
    result.push({ product_id: item.product_id, accepted_quantity: String(accepted), bonus_quantity: String(bonus),
      rejected_quantity: String(rejected), short_quantity: short === null ? null : String(short), operational_note: note || null });
  }
  return result;
}
