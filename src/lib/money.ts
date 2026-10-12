/** Parse a user-facing Indonesian amount. Dots are grouping; comma is decimal. */
export function parseRupiahInput(input: string): string | null {
  const raw = input.trim().replace(/^rp\s*/i, "").replace(/[\s\u00a0]/g, "");
  if (!raw) return "";
  const parts = raw.split(",");
  if (parts.length > 2) return null;
  const [groupedWhole, fraction = ""] = parts;
  if (parts.length === 2 && fraction === "") return null;
  if (!/^[\d.]+$/.test(groupedWhole) || !/^\d*$/.test(fraction) || fraction.length > 2) return null;
  const whole = groupedWhole.replaceAll(".", "");
  if (!/^\d+$/.test(whole)) return null;
  const integer = BigInt(whole).toString();
  if (BigInt(integer) > BigInt(Number.MAX_SAFE_INTEGER)) return null;
  return parts.length === 2 ? `${integer}.${fraction}` : integer;
}

/** Parse the canonical server/application representation: integer digits and optional dot decimals. */
export function parseCanonicalRupiah(value: string): string | null {
  const raw = value.trim();
  if (!raw) return "";
  const match = /^(\d+)(?:\.(\d{1,2}))?$/.exec(raw);
  if (!match) return null;
  const integer = BigInt(match[1]).toString();
  if (BigInt(integer) > BigInt(Number.MAX_SAFE_INTEGER)) return null;
  return match[2] === undefined ? integer : `${integer}.${match[2]}`;
}

export function formatRupiahInput(value: string): string {
  const canonical = parseCanonicalRupiah(value);
  if (canonical === null || canonical === "") return "";
  const [whole, fraction] = canonical.split(".");
  const grouped = BigInt(whole).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  return `${grouped}${fraction ? `,${fraction}` : ""}`;
}

export type RupiahEditResult = { canonical: string; display: string; incomplete: boolean } | { canonical: null; display: string; incomplete: true };

/** Shared edit transition used by RupiahInput for keystrokes, paste, and deletion. */
export function editRupiahInput(next: string): RupiahEditResult {
  const canonical = parseRupiahInput(next);
  if (canonical !== null) return { canonical, display: formatRupiahInput(canonical), incomplete: false };
  const cleaned = next.replace(/^rp\s*/i, "").replace(/[^\d.,\s]/g, "").replace(/[\s\u00a0]/g, "");
  if (cleaned.endsWith(",")) {
    const base = parseRupiahInput(cleaned.slice(0, -1));
    if (base !== null) return { canonical: base, display: `${formatRupiahInput(base)},`, incomplete: true };
  }
  return { canonical: null, display: cleaned, incomplete: true };
}

export function formatRupiah(value: string | number | null | undefined): string {
  if (value === null || value === undefined || value === "") return "—";
  const match = /^(\d+)(?:\.(\d+))?$/.exec(String(value));
  if (!match) return String(value);
  const grouped = BigInt(match[1]).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  const fraction = (match[2] ?? "").replace(/0+$/, "");
  return `Rp ${grouped}${fraction ? `,${fraction}` : ""}`;
}

export function compareRupiah(left: string, right: string): number | null {
  const parseComparable = (value: string) => {
    const raw = value.trim().replace(/^rp\s*/i, "").replace(/[\s\u00a0]/g, "");
    const grouped = /^\d{1,3}(?:\.\d{3})+$/.test(raw);
    return grouped || raw.includes(",") ? parseRupiahInput(value) : parseCanonicalRupiah(value);
  };
  const a = parseComparable(left);
  const b = parseComparable(right);
  if (a === null || b === null || a === "" || b === "") return null;
  const cents = (value: string) => {
    const [whole, fraction = ""] = value.split(".");
    return BigInt(whole) * BigInt("100") + BigInt(fraction.padEnd(2, "0"));
  };
  const aCents = cents(a);
  const bCents = cents(b);
  return aCents < bCents ? -1 : aCents > bCents ? 1 : 0;
}

export function subtractRupiah(left: string, right: string): string | null {
  const a = parseCanonicalRupiah(left);
  const b = parseCanonicalRupiah(right);
  if (a === null || b === null || a === "" || b === "") return null;
  const cents = (value: string) => {
    const [whole, fraction = ""] = value.split(".");
    return BigInt(whole) * BigInt("100") + BigInt(fraction.padEnd(2, "0"));
  };
  const result = cents(a) - cents(b);
  if (result < BigInt("0")) return null;
  const hundred = BigInt("100");
  const whole = result / hundred;
  const fraction = result % hundred;
  return fraction === BigInt("0") ? whole.toString() : `${whole}.${fraction.toString().padStart(2, "0")}`;
}

export function ceilRupiah(value: string): string | null {
  const canonical = parseCanonicalRupiah(value);
  if (canonical === null || canonical === "") return null;
  const [whole, fraction = ""] = canonical.split(".");
  return (BigInt(whole) + (BigInt(fraction.padEnd(2, "0")) > BigInt("0") ? BigInt("1") : BigInt("0"))).toString();
}
