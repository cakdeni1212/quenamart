export const STOCK_OPNAME_LIFECYCLE_OPERATIONS = [
  "SUBMIT_REVIEW",
  "RETURN_TO_COUNTING",
  "CANCEL_SESSION",
] as const;

export type StockOpnameLifecycleOperation = (typeof STOCK_OPNAME_LIFECYCLE_OPERATIONS)[number];
export type StockOpnameLifecycleStatus = "COUNTING" | "REVIEW" | "CANCELLED" | "POSTED";

export function stockOpnameLifecycleStateKey(
  sessionId: string,
  operation: StockOpnameLifecycleOperation,
): string {
  return `${sessionId}:${operation}`;
}

export function hasSessionLifecycleInFlight(entries: Set<string>, sessionId: string): boolean {
  const prefix = `${sessionId}:`;
  return [...entries].some((key) => key.startsWith(prefix));
}

export function canRetryStockOpnameLifecycle(
  operation: StockOpnameLifecycleOperation,
  status: StockOpnameLifecycleStatus,
): boolean {
  if (operation === "SUBMIT_REVIEW") return status === "COUNTING";
  if (operation === "RETURN_TO_COUNTING") return status === "REVIEW";
  return status === "COUNTING" || status === "REVIEW";
}

export function removeSessionOperationEntry<T>(
  entries: Map<string, T>,
  sessionId: string,
  operation: StockOpnameLifecycleOperation,
): Map<string, T> {
  const next = new Map(entries);
  next.delete(stockOpnameLifecycleStateKey(sessionId, operation));
  return next;
}

export function removeSessionEntries<T extends { sessionId: string }>(
  entries: Map<string, T>,
  sessionId: string,
): Map<string, T> {
  const next = new Map(entries);
  for (const [key, value] of next) if (value.sessionId === sessionId) next.delete(key);
  return next;
}

export type StockOpnameLifecycleProgress = {
  remaining: number;
  recountRequired: number;
} | null;

export function isSubmitReviewAdvisoryEligible(progress: StockOpnameLifecycleProgress): boolean {
  return progress !== null && progress.remaining === 0 && progress.recountRequired === 0;
}

export function stockOpnameLifecycleRequestKey(
  sessionId: string,
  operation: StockOpnameLifecycleOperation,
): string {
  return `quena-opname-lifecycle:${sessionId}:${operation}`;
}

export function lifecycleOperationLabel(operation: StockOpnameLifecycleOperation): string {
  switch (operation) {
    case "SUBMIT_REVIEW": return "Ajukan review";
    case "RETURN_TO_COUNTING": return "Kembali ke penghitungan";
    case "CANCEL_SESSION": return "Batalkan sesi";
  }
}
