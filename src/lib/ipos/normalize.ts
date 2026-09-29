import { IPOS_HEADERS, type IposRawRow } from "./xlsx-parser.ts";

export type NumericField = "HARGAPOKOK" | "HARGAJUAL" | "STOK" | "STOKMIN";
export const IPOS_NORMALIZATION_VERSION = "ipos-v1-preflight";
export type NumericValue = { units: bigint; scale: number; canonical: string };
export type NumericResult =
  | { state: "blank"; value: null; error: null }
  | { state: "valid"; value: NumericValue; error: null }
  | { state: "invalid"; value: NumericValue | null; error: string };

export type RowIssue = { code: string; field: string; message: string };

export type NormalizedIposRow = {
  sku: string | null;
  name: string | null;
  nameKey: string | null;
  barcode: string | null;
  barcodeState: "BLANK" | "VALID" | "MALFORMED" | "INVALID_TYPE";
  categoryLabel: string | null;
  brandLabel: string | null;
  unitLabel: string | null;
  departmentLabel: string | null;
  sourceDescription: string | null;
  sourceReferenceCode: string | null;
  rackLabel: string | null;
  hpp: NumericResult;
  sellingPrice: NumericResult;
  quantity: NumericResult;
  minimumQuantity: NumericResult;
  rawOnly: Pick<IposRawRow, "TIPE" | "SERIAL" | "POIN" | "KOMISISALES" | "KONSINYASI" | "SISTEMHPP" | "JENISPAJAK" | "PAJAKINCLUDE" | "OPT" | "SUPPLIER1">;
  issues: RowIssue[];
};

const FIELD_NUMERIC_RULES: Record<NumericField, { scale: number; limit: bigint }> = {
  HARGAPOKOK: { scale: 2, limit: BigInt("1000000000000") },
  HARGAJUAL: { scale: 2, limit: BigInt("1000000000000") },
  STOK: { scale: 3, limit: BigInt("100000000000") },
  STOKMIN: { scale: 3, limit: BigInt("100000000000") },
};

function isBlank(value: unknown): boolean {
  return value === null || value === undefined || (typeof value === "string" && value.trim() === "");
}

function trimText(value: unknown, field: string, issues: RowIssue[]): string | null {
  if (isBlank(value)) return null;
  if (typeof value !== "string") {
    issues.push({ code: "INVALID_TEXT_TYPE", field, message: "Expected a text cell; raw value was not coerced." });
    return null;
  }
  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed;
}

export function normalizeProductNameKey(name: string): string {
  // Mirrors normalize_product_name(): NFC, ASCII-space btrim, POSIX whitespace
  // collapse, then lower-case. Punctuation is preserved; matching is exact.
  return name.normalize("NFC")
    .replace(/^ +| +$/g, "")
    .replace(/[ \t\n\r\f\v]+/g, " ")
    .toLowerCase();
}

function expandExponent(value: string): string | null {
  const match = /^([+-]?)(\d+)(?:\.(\d*))?[eE]([+-]?\d+)$/.exec(value);
  if (!match) return value;
  const [, sign, integer, fraction = "", exponentText] = match;
  const exponent = Number(exponentText);
  if (!Number.isSafeInteger(exponent) || Math.abs(exponent) > 1000) return null;
  const digits = integer + fraction;
  const point = integer.length + exponent;
  if (point <= 0) return `${sign}0.${"0".repeat(-point)}${digits}`;
  if (point >= digits.length) return `${sign}${digits}${"0".repeat(point - digits.length)}`;
  return `${sign}${digits.slice(0, point)}.${digits.slice(point)}`;
}

function parseIndonesianText(value: string): string | null {
  const text = value.trim();
  const sign = text.startsWith("-") ? "-" : text.startsWith("+") ? "+" : "";
  const unsigned = sign ? text.slice(1) : text;
  if (!unsigned) return null;

  if (unsigned.includes(",")) {
    if ((unsigned.match(/,/g) ?? []).length !== 1) return null;
    const [integerPart, fractionPart] = unsigned.split(",");
    if (!/^\d+$/.test(fractionPart)) return null;
    const validInteger = /^\d+$/.test(integerPart)
      ? integerPart
      : /^\d{1,3}(?:\.\d{3})+$/.test(integerPart)
        ? integerPart.replace(/\./g, "")
        : null;
    return validInteger === null ? null : `${sign}${validInteger}.${fractionPart}`;
  }

  if (/^\d+$/.test(unsigned)) return `${sign}${unsigned}`;
  if (/^\d{1,3}(?:\.\d{3})+$/.test(unsigned)) return `${sign}${unsigned.replace(/\./g, "")}`;
  return null;
}

function formatScaled(units: bigint, scale: number): string {
  const negative = units < BigInt(0);
  const absolute = negative ? -units : units;
  const digits = absolute.toString().padStart(scale + 1, "0");
  const integerPart = scale === 0 ? digits : digits.slice(0, -scale);
  const fractionPart = scale === 0 ? "" : digits.slice(-scale);
  const fraction = fractionPart.replace(/0+$/, "");
  return `${negative ? "-" : ""}${integerPart}${fraction ? `.${fraction}` : ""}`;
}

export function parseIposNumber(input: unknown, field: NumericField): NumericResult {
  if (isBlank(input)) return { state: "blank", value: null, error: null };
  const { scale, limit } = FIELD_NUMERIC_RULES[field];
  let canonical: string | null;
  if (typeof input === "number") {
    if (!Number.isFinite(input)) return { state: "invalid", value: null, error: "NON_FINITE_NUMBER" };
    canonical = expandExponent(String(input));
  } else if (typeof input === "string") {
    canonical = parseIndonesianText(input);
  } else {
    return { state: "invalid", value: null, error: "INVALID_NUMERIC_TYPE" };
  }

  if (canonical === null) return { state: "invalid", value: null, error: "AMBIGUOUS_OR_INVALID_NUMBER" };
  const match = /^([+-]?)(\d+)(?:\.(\d+))?$/.exec(canonical);
  if (!match) return { state: "invalid", value: null, error: "AMBIGUOUS_OR_INVALID_NUMBER" };
  const [, sign, integerDigits, fractionDigits = ""] = match;
  const excessFraction = fractionDigits.slice(scale);
  if (/[1-9]/.test(excessFraction)) return { state: "invalid", value: null, error: "EXCESS_PRECISION" };
  const fixedFraction = fractionDigits.slice(0, scale).padEnd(scale, "0");
  const magnitude = BigInt(integerDigits) * (BigInt(10) ** BigInt(scale)) + BigInt(fixedFraction || "0");
  const units = sign === "-" ? -magnitude : magnitude;
  const value = { units, scale, canonical: formatScaled(units, scale) };
  if (units < BigInt(0)) return { state: "invalid", value, error: "NEGATIVE_NOT_ALLOWED" };
  if (magnitude >= limit * (BigInt(10) ** BigInt(scale))) {
    return { state: "invalid", value, error: "OUT_OF_DATABASE_RANGE" };
  }
  return { state: "valid", value, error: null };
}

function normalizeBarcode(value: unknown, issues: RowIssue[]): { value: string | null; state: NormalizedIposRow["barcodeState"] } {
  if (isBlank(value)) return { value: null, state: "BLANK" };
  if (typeof value !== "string") {
    issues.push({ code: "INVALID_BARCODE_TYPE", field: "KODEBARCODE", message: "Barcode was not text; raw value was not coerced." });
    return { value: null, state: "INVALID_TYPE" };
  }
  if (/[\u0000-\u001f\u007f-\u009f]/u.test(value)) {
    return { value: null, state: "MALFORMED" };
  }
  const trimmed = value.trim();
  if (!trimmed) return { value: null, state: "BLANK" };
  return { value: trimmed, state: "VALID" };
}

export function normalizeRawIposRow(raw: IposRawRow): NormalizedIposRow {
  const issues: RowIssue[] = [];
  // Reject controls before trimming: String.trim() would otherwise erase tabs,
  // newlines, and other control characters that the deployed SKU constraint rejects.
  const rawSku = raw.KODEITEM;
  const skuContainsControl = typeof rawSku === "string" && /[\u0000-\u001f\u007f-\u009f]/u.test(rawSku);
  const skuText = skuContainsControl ? null : trimText(rawSku, "KODEITEM", issues);
  const sku = skuText;
  if (!sku) issues.push({ code: "INVALID_OR_MISSING_SKU", field: "KODEITEM", message: "A valid nonblank text SKU is required." });

  const name = trimText(raw.NAMAITEM, "NAMAITEM", issues);
  if (!name) issues.push({ code: "MISSING_PRODUCT_NAME", field: "NAMAITEM", message: "A nonblank product name is required." });

  const barcode = normalizeBarcode(raw.KODEBARCODE, issues);
  const hpp = parseIposNumber(raw.HARGAPOKOK, "HARGAPOKOK");
  const sellingPrice = parseIposNumber(raw.HARGAJUAL, "HARGAJUAL");
  const quantity = parseIposNumber(raw.STOK, "STOK");
  const minimumQuantity = parseIposNumber(raw.STOKMIN, "STOKMIN");
  const numericPairs: Array<[NumericField, NumericResult]> = [
    ["HARGAPOKOK", hpp], ["HARGAJUAL", sellingPrice], ["STOK", quantity], ["STOKMIN", minimumQuantity],
  ];
  for (const [field, parsed] of numericPairs) {
    if (parsed.state === "invalid") issues.push({
      code: "INVALID_NUMERIC_VALUE", field, message: parsed.error,
    });
  }

  const optionalText = (field: "JENIS" | "MEREK" | "SATUAN" | "DEPT" | "KETERANGAN" | "KODEREFERENSI" | "RAK") =>
    trimText(raw[field], field, issues);
  const optionalLabels = {
    categoryLabel: optionalText("JENIS"),
    brandLabel: optionalText("MEREK"),
    unitLabel: optionalText("SATUAN"),
    departmentLabel: optionalText("DEPT"),
    sourceDescription: optionalText("KETERANGAN"),
    sourceReferenceCode: optionalText("KODEREFERENSI"),
    rackLabel: optionalText("RAK"),
  };

  const rawOnly = Object.fromEntries(
    ["TIPE", "SERIAL", "POIN", "KOMISISALES", "KONSINYASI", "SISTEMHPP", "JENISPAJAK", "PAJAKINCLUDE", "OPT", "SUPPLIER1"]
      .map((key) => [key, raw[key as (typeof IPOS_HEADERS)[number]]]),
  ) as NormalizedIposRow["rawOnly"];

  return {
    sku,
    name,
    nameKey: name ? normalizeProductNameKey(name) : null,
    barcode: barcode.value,
    barcodeState: barcode.state,
    ...optionalLabels,
    hpp,
    sellingPrice,
    quantity,
    minimumQuantity,
    rawOnly,
    issues,
  };
}
