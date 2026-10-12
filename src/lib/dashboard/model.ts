export type TrendRow = { date: string; total: string; transaction_count: number };

export function sumRupiahAmounts(values: string[]): string {
  const totalCents = values.reduce((sum, value) => {
    const match = /^(\d+)(?:\.(\d{1,2}))?$/.exec(value);
    if (!match) return sum;
    return sum + BigInt(match[1]) * BigInt("100") + BigInt((match[2] ?? "").padEnd(2, "0"));
  }, BigInt("0"));
  const hundred = BigInt("100");
  const whole = totalCents / hundred;
  const fraction = totalCents % hundred;
  return fraction === BigInt("0") ? whole.toString() : `${whole}.${fraction.toString().padStart(2, "0")}`;
}

export function trendBarHeight(total: string, maxTotal: string): number {
  const value = Number(total);
  const max = Number(maxTotal);
  if (!Number.isFinite(value) || !Number.isFinite(max) || value <= 0 || max <= 0) return 0;
  return Math.max(3, Math.min(100, (value / max) * 100));
}

export function salesComparisonLabel(
  comparison: string,
  changePercent: string | null,
): string {
  if (comparison === "NO_SALES") return "Belum ada transaksi hari ini maupun kemarin";
  if (comparison === "NEW") return "Ada penjualan baru dibanding kemarin";
  const amount = Number(changePercent);
  if (!Number.isFinite(amount)) return "Perbandingan belum tersedia";
  const direction = amount > 0 ? "↑" : amount < 0 ? "↓" : "—";
  return `${direction} ${new Intl.NumberFormat("id-ID", {
    maximumFractionDigits: 1,
    minimumFractionDigits: 1,
  }).format(Math.abs(amount))}% dari kemarin`;
}

export function businessDayLabel(value: string): string {
  const date = new Date(`${value}T12:00:00Z`);
  return new Intl.DateTimeFormat("id-ID", {
    weekday: "short",
    day: "numeric",
    timeZone: "Asia/Jakarta",
  }).format(date);
}
