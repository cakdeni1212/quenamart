import type { HppAcceptanceRow } from "@/lib/costing/hpp-acceptance-read";

export type HppActionError = { message: string; routeKey: string } | null;

export function visibleHppActionError(actionError: HppActionError, routeKey: string) {
  return actionError?.routeKey === routeKey ? actionError.message : "";
}

function compareDecimal(left: string | number | null, right: string | number | null) {
  if (left === null || right === null) return null;
  const normalize = (value: string | number) => {
    const match = String(value).match(/^(-?)(\d+)(?:\.(\d+))?$/);
    if (!match) return null;
    return { negative: match[1] === "-", whole: BigInt(match[2]), fraction: (match[3] ?? "").replace(/0+$/, "") };
  };
  const a = normalize(left);
  const b = normalize(right);
  if (!a || !b) return null;
  if (a.negative !== b.negative) return a.negative ? -1 : 1;
  const sign = a.negative ? -1 : 1;
  if (a.whole !== b.whole) return (a.whole > b.whole ? 1 : -1) * sign;
  const places = Math.max(a.fraction.length, b.fraction.length);
  const af = BigInt((a.fraction + "0".repeat(places)).slice(0, places) || "0");
  const bf = BigInt((b.fraction + "0".repeat(places)).slice(0, places) || "0");
  return af === bf ? 0 : (af > bf ? 1 : -1) * sign;
}

export function compareRupiahValues(left: string | number | null, right: string | number | null) {
  return compareDecimal(left, right);
}

export function formatRupiah(value: string | number | null, fractions = 2) {
  if (value === null) return "—";
  const text = String(value);
  const match = text.match(/^(-?)(\d+)(?:\.(\d+))?$/);
  if (!match) return "—";
  const sign = match[1];
  const grouped = new Intl.NumberFormat("id-ID", { maximumFractionDigits: 0 }).format(BigInt(match[2]));
  const decimal = (match[3] ?? "").slice(0, fractions).replace(/0+$/, "");
  return `Rp${sign}${grouped}${decimal ? `,${decimal}` : ""}`;
}

export function openingHppDisplayValue(row: {
  preparedEvidence: boolean;
  disposition: string | null;
  acceptedHpp: string | number | null;
  currentHpp: string | number | null;
  blockers: string[];
}) {
  if (row.preparedEvidence) {
    if (row.disposition === "LEAVE_UNVALUED") return "Belum dinilai";
    if (row.acceptedHpp !== null) return formatRupiah(row.acceptedHpp);
    return "Belum ditinjau";
  }
  return row.blockers.length === 0 ? formatRupiah(row.currentHpp) : "Belum ditinjau";
}

export function formatCompactRupiah(value: string | number | null) {
  if (value === null) return "—";
  const match = String(value).match(/^(\d+)(?:\.(\d+))?$/);
  if (!match) return "—";
  const fraction = (match[2] ?? "").padEnd(3, "0");
  const cents = BigInt(match[1]) * BigInt("100") + BigInt(fraction.slice(0, 2)) + (Number(fraction[2]) >= 5 ? BigInt("1") : BigInt("0"));
  const units = [
    { threshold: BigInt("100000000000000"), divisor: BigInt("1000000000000"), suffix: " triliun" },
    { threshold: BigInt("100000000000"), divisor: BigInt("1000000000"), suffix: " miliar" },
    { threshold: BigInt("100000000"), divisor: BigInt("1000000"), suffix: " jt" },
  ];
  const unit = units.find((candidate) => cents >= candidate.threshold);
  if (!unit) return formatRupiah(value);
  const hundredths = (cents + unit.divisor / BigInt("2")) / unit.divisor;
  const whole = hundredths / BigInt("100");
  const fractionText = (hundredths % BigInt("100")).toString().padStart(2, "0").replace(/0+$/, "");
  const grouped = new Intl.NumberFormat("id-ID").format(whole);
  return `Rp${grouped}${fractionText ? `,${fractionText}` : ""}${unit.suffix}`;
}

export function blockerLabel(code: string, row: Pick<HppAcceptanceRow, "currentHpp" | "sellingPrice" | "blockers">) {
  switch (code) {
    case "HPP_MISSING": return "HPP belum tersedia";
    case "HPP_ZERO": return "HPP masih Rp0";
    case "HPP_NOT_BELOW_SELLING_PRICE":
      return compareDecimal(row.currentHpp, row.sellingPrice) === 0 ? "HPP sama dengan harga jual" : "Harga jual di bawah HPP";
    case "OPEN_COST_AUDIT_FINDING":
      return row.blockers.some((item) => ["HPP_MISSING", "HPP_ZERO", "HPP_NOT_BELOW_SELLING_PRICE"].includes(item))
        ? "" : "Ada temuan audit HPP";
    case "UNRESOLVED_OR_CONFLICTING_HPP_REVIEW": return "Pemeriksaan HPP belum selesai";
    case "HPP_INVALID_BOUNDS_OR_SCALE": return "Nilai HPP perlu diperiksa";
    case "SOURCE_PROVENANCE_MISSING": return "Sumber HPP belum tercatat";
    case "SOURCE_PROVENANCE_INVALID": return "Sumber HPP perlu diperiksa";
    case "NORMALIZED_SOURCE_HPP_MISSING": return "HPP pada data sumber belum tersedia";
    case "NORMALIZED_SOURCE_HPP_INVALID_BOUNDS_OR_SCALE": return "HPP pada data sumber perlu diperiksa";
    case "CURRENT_SOURCE_HPP_MISMATCH": return "HPP berbeda dari data sumber";
    case "SOURCE_OVERRIDE_CONFLICT": return "Ada perbedaan pada data sumber";
    case "COST_HISTORY_MISSING": return "Riwayat HPP belum tersedia";
    case "LATEST_COST_HISTORY_MISMATCH": return "Riwayat HPP berbeda";
    case "ACTIVE_HPP_OVERRIDE": return "Ada perubahan HPP yang perlu diperiksa";
    case "OPEN_HPP_SOURCE_CONFLICT": return "Perbedaan HPP belum diselesaikan";
    case "SELLING_PRICE_MISSING_OR_INVALID": return "Harga jual belum tersedia";
    default: return "Data HPP perlu diperiksa";
  }
}

export function warningLabel(code: string) {
  switch (code) {
    case "GROSS_MARGIN_AT_OR_BELOW_5_PERCENT": return "Margin sangat tipis";
    case "GROSS_MARGIN_ABOVE_80_PERCENT": return "Margin sangat tinggi";
    case "ONE_RUPIAH_HPP": return "HPP Rp1";
    case "HIGH_ABSOLUTE_HPP_OUTLIER": return "Nilai HPP sangat tinggi";
    default: return "Informasi HPP";
  }
}

export function blockerLabels(row: HppAcceptanceRow) {
  return [...new Set(row.blockers.map((code) => blockerLabel(code, row)).filter(Boolean))];
}
