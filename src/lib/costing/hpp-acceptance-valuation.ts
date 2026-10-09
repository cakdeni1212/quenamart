const VALUED_DISPOSITIONS = new Set([
  "ACCEPT_CURRENT_HPP",
  "OPENING_HPP_OVERRIDE",
  "AUTHORITATIVE_ZERO",
]);

type PreparedValuationItem = {
  disposition: string | null;
  acceptedOpeningHpp: string | number | null;
  quantity: string | number | null;
};

type PreparedPageResult<T, E> = { data: T[] | null; error: E | null };

/** Read every bounded page used by the prepared summary, independent of the visible table page. */
export async function readAllPreparedValuationItems<T, E>(
  expectedCount: number,
  pageSize: number,
  fetchPage: (from: number, to: number) => Promise<PreparedPageResult<T, E>>,
): Promise<{ items: T[] | null; error: E | null; complete: boolean }> {
  if (!Number.isSafeInteger(expectedCount) || expectedCount < 0 || !Number.isSafeInteger(pageSize) || pageSize < 1) {
    throw new Error("Invalid prepared valuation pagination bounds");
  }

  const pages = Array.from({ length: Math.ceil(expectedCount / pageSize) }, (_, index) => ({
    from: index * pageSize,
    to: index * pageSize + pageSize - 1,
  }));
  const results = await Promise.all(pages.map(({ from, to }) => fetchPage(from, to)));
  const failed = results.find((result) => result.error !== null);
  if (failed) return { items: null, error: failed.error, complete: false };

  const items = results.flatMap((result) => result.data ?? []);
  if (items.length !== expectedCount) return { items: null, error: null, complete: false };
  return { items, error: null, complete: true };
}

function toScaledInteger(value: string | number | null, scale: number): bigint | null {
  if (value === null) return null;
  const match = String(value).match(/^(\d+)(?:\.(\d+))?$/);
  if (!match || (match[2]?.length ?? 0) > scale) return null;
  const factor = BigInt(10) ** BigInt(scale);
  const fraction = BigInt((match[2] ?? "").padEnd(scale, "0") || "0");
  return BigInt(match[1]) * factor + fraction;
}

function fromScaledInteger(value: bigint, scale: number) {
  const factor = BigInt(10) ** BigInt(scale);
  const whole = value / factor;
  const fraction = (value % factor).toString().padStart(scale, "0").replace(/0+$/, "");
  return fraction ? `${whole}.${fraction}` : whole.toString();
}

/** Exact display-only proposed value from the immutable preparation quantities and saved decisions. */
export function summarizePreparedOpeningValue(items: PreparedValuationItem[]) {
  let valueAtScaleFive = BigInt(0);
  let valuedProducts = 0;
  let unvaluedProducts = 0;

  for (const item of items) {
    if (!item.disposition || item.disposition === "LEAVE_UNVALUED") {
      unvaluedProducts += 1;
      continue;
    }
    if (!VALUED_DISPOSITIONS.has(item.disposition)) {
      unvaluedProducts += 1;
      continue;
    }

    const hppCents = toScaledInteger(item.acceptedOpeningHpp, 2);
    const quantityMillis = toScaledInteger(item.quantity, 3);
    if (hppCents === null || quantityMillis === null) {
      throw new Error("Prepared valuation evidence is incomplete or has invalid precision");
    }
    valueAtScaleFive += hppCents * quantityMillis;
    valuedProducts += 1;
  }

  return {
    openingValue: fromScaledInteger(valueAtScaleFive, 5),
    valuedProducts,
    unvaluedProducts,
  };
}
