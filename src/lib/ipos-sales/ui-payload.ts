import "server-only";

type Json = Record<string, unknown>;
const record = (value: unknown): Json => value && typeof value === "object" && !Array.isArray(value) ? value as Json : {};

/** Keep the browser payload to summary fields and only actionable source rows. */
export function projectIposSalesBatch(value: unknown) {
  const root = record(value);
  const batch = record(root.batch);
  if (typeof batch.id !== "string") return null;
  const sourceTransactions = Array.isArray(root.transactions) ? root.transactions.map(record) : [];
  const lines = sourceTransactions.flatMap((transaction) => (Array.isArray(transaction.lines) ? transaction.lines : []).map(record));
  const uniqueSkuCount = new Set(lines.map((line) => line.sku).filter((sku): sku is string => typeof sku === "string" && sku.length > 0)).size;
  const duplicateTransactionCount = sourceTransactions.filter((transaction) => transaction.duplicate === true).length;
  let unresolvedCount = 0;
  let sentUnresolvedCount = 0;
  let sentDuplicateCount = 0;
  const transactions = sourceTransactions.flatMap((transaction) => {
    const actionable = (Array.isArray(transaction.lines) ? transaction.lines : []).map(record).filter((line) => line.resolution === "MISSING" || line.resolution === "INVALID");
    unresolvedCount += actionable.length;
    const duplicate = transaction.duplicate === true && sentDuplicateCount < 100;
    if (duplicate) sentDuplicateCount += 1;
    if (!duplicate && actionable.length === 0) return [];
    const includedLines = actionable.slice(0, Math.max(0, 500 - sentUnresolvedCount));
    sentUnresolvedCount += includedLines.length;
    return [{
      sourceTransactionNumber: transaction.sourceTransactionNumber,
      sourceOccurredAt: transaction.sourceOccurredAt,
      total: transaction.total,
      duplicate,
      lines: includedLines.map((line) => ({
        sku: line.sku, name: line.name, quantity: line.quantity, resolution: line.resolution,
      })),
    }];
  });
  return {
    batch: {
      id: batch.id, status: batch.status, revision: batch.revision,
      report_from: batch.report_from, report_to: batch.report_to,
      original_filename: batch.original_filename, transaction_count: batch.transaction_count,
      sale_line_count: batch.sale_line_count, total_quantity: batch.total_quantity,
      total_amount: batch.total_amount, reconciliation: batch.reconciliation,
      preflight_result: batch.preflight_result, unique_sku_count: uniqueSkuCount,
      duplicate_transaction_count: duplicateTransactionCount,
      unresolved_details_truncated: unresolvedCount > 500,
    },
    transactions,
    estimate: root.estimate && typeof root.estimate === "object" && !Array.isArray(root.estimate)
      ? root.estimate
      : null,
  };
}
