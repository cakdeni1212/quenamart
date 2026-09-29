import { IPOS_NORMALIZATION_VERSION } from "./normalize.ts";

export function buildIposCommitPayload(
  batchId: string,
  report: ReturnType<typeof import("./preflight-engine").analyzeIposPreflight>,
  expectedState: unknown,
) {
  if (report.normalizationVersion !== IPOS_NORMALIZATION_VERSION || report.batchId !== batchId) {
    throw new Error("Preflight report does not match this batch and normalization version.");
  }
  return {
    batchId,
    outletId: report.outletId,
    normalizationVersion: report.normalizationVersion,
    expectedState,
    rows: report.plannedProductActions.map((row) => ({
      source_row_id: row.sourceRowId,
      source_row: row.sourceRow,
      action: row.action,
      sku: row.sourceNormalizedProposal.sku,
      expected_product_id: row.productId,
      normalized_data: row.sourceNormalizedProposal,
      audit_findings: row.auditFindings,
      issues: row.issues,
      blocked_override_fields: row.blockedOverrideFields,
    })),
  };
}
