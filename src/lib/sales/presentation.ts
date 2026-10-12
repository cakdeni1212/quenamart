import { formatRupiah } from "@/lib/money";

export function salesMoney(value: unknown): string {
  return formatRupiah(value === null || value === undefined ? null : String(value));
}

export function salesQuantity(value: unknown): string {
  const quantity = Number(value);
  return Number.isFinite(quantity)
    ? new Intl.NumberFormat("id-ID", { maximumFractionDigits: 3 }).format(quantity)
    : "0";
}

export function salesDateTime(value: string): string {
  return new Intl.DateTimeFormat("id-ID", {
    day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit",
    timeZone: "Asia/Jakarta",
  }).format(new Date(value));
}

const PAYMENT_LABELS: Record<string, string> = {
  CASH: "Tunai", QRIS: "QRIS", CARD: "Kartu", E_WALLET: "E-Wallet", MIXED: "Campuran",
};

export function salesPaymentLabel(value: unknown): string {
  return PAYMENT_LABELS[String(value)] ?? "—";
}
