import { formatRupiah } from "../money.ts";

/** PostgreSQL numeric JSON values may arrive as a JS number or a decimal string. */
export function formatIposSalesRevenue(value: unknown): string {
  if (typeof value === "string" && /^\d+(?:\.\d+)?$/.test(value)) return formatRupiah(value);
  if (typeof value === "number" && Number.isFinite(value) && value >= 0) return formatRupiah(value);
  return "—";
}
