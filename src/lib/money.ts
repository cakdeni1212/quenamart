/** Exact Indonesian Rupiah input helpers. Values stay decimal strings at the UI boundary. */
export function parseRupiahInput(input: string): string | null {
  const raw = input.trim().replace(/^rp\s*/i, "").replace(/[\s\u00a0]/g, "");
  if (!raw) return "";

  let whole: string;
  let fraction = "";
  if (raw.includes(",")) {
    const match = /^(\d{1,3}(?:\.\d{3})*|\d+)(?:,(\d{1,2}))?$/.exec(raw);
    if (!match) return null;
    whole = match[1].replaceAll(".", "");
    fraction = match[2] ?? "";
  } else if (raw.includes(".")) {
    const grouped = /^(\d{1,3}(?:\.\d{3})+)$/.exec(raw);
    if (grouped) whole = raw.replaceAll(".", "");
    else {
      const decimal = /^(\d+)\.(\d{1,2})$/.exec(raw);
      if (!decimal) return null;
      whole = decimal[1];
      fraction = decimal[2];
    }
  } else {
    if (!/^\d+$/.test(raw)) return null;
    whole = raw;
  }

  const integer = BigInt(whole).toString();
  if (BigInt(integer) > BigInt(Number.MAX_SAFE_INTEGER)) return null;
  return fraction ? `${integer}.${fraction.padEnd(2, "0")}` : integer;
}

export function formatRupiahInput(value: string): string {
  const canonical = parseRupiahInput(value);
  if (!canonical) return "";
  const [whole, fraction] = canonical.split(".");
  const grouped = BigInt(whole).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  return `${grouped}${fraction ? `,${fraction.replace(/0+$/, "")}` : ""}`;
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
  const a = parseRupiahInput(left);
  const b = parseRupiahInput(right);
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
  const a = parseRupiahInput(left);
  const b = parseRupiahInput(right);
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
  const canonical = parseRupiahInput(value);
  if (canonical === null || canonical === "") return null;
  const [whole, fraction = ""] = canonical.split(".");
  return (BigInt(whole) + (BigInt(fraction.padEnd(2, "0")) > BigInt("0") ? BigInt("1") : BigInt("0"))).toString();
}
