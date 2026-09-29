import "server-only";
import { createAdminClient } from "@/lib/supabase/admin";
import { IPOS_NORMALIZATION_VERSION } from "./normalize";
import { prepareIposPreflight } from "./preflight";
import { buildIposCommitPayload } from "./commit-payload";

type CommitResult = {
  alreadyCompleted: boolean;
  commitRequired?: boolean;
  commitId?: string;
  batchId?: string;
  normalizationVersion?: string;
  rawRows?: number;
  linkedRows?: number;
  invalidRows?: number;
  auditFindingCountByType?: Record<string, number>;
  overrideConflictCount?: number;
};

function safeError(error: unknown): string {
  const message = error instanceof Error ? error.message : "iPos normalization commit failed.";
  return message
    .replace(/\b(?:SUPABASE_SERVICE_ROLE_KEY|service_role)\b/gi, "server credential")
    .slice(0, 500);
}

async function invokeCommit(batchId: string, payload: unknown | null): Promise<CommitResult> {
  const admin = createAdminClient();
  const { data, error } = await admin.rpc("commit_ipos_normalization", {
    p_batch_id: batchId,
    p_normalization_version: IPOS_NORMALIZATION_VERSION,
    p_payload: payload,
  });
  if (error) throw new Error(`Database normalization commit failed: ${error.message}`);
  if (!data || typeof data !== "object" || typeof (data as { alreadyCompleted?: unknown }).alreadyCompleted !== "boolean") {
    throw new Error("Normalization commit RPC returned an invalid result.");
  }
  return data as CommitResult;
}

export async function commitIposBatch(batchId: string): Promise<CommitResult> {
  const canonicalBatchId = batchId.toLowerCase();
  try {
    // This cheap call makes retries after a committed-but-timed-out response
    // deterministic, without requiring already-linked rows to pass preflight.
    const prior = await invokeCommit(canonicalBatchId, null);
    if (prior.alreadyCompleted) return prior;

    const { report, expectedState } = await prepareIposPreflight(canonicalBatchId);
    const payload = buildIposCommitPayload(canonicalBatchId, report, expectedState);
    const result = await invokeCommit(canonicalBatchId, payload);
    return result;
  } catch (error) {
    // A competing invocation may have committed after the preflight reads, or
    // the original response may have timed out after PostgreSQL committed.
    try {
      const prior = await invokeCommit(canonicalBatchId, null);
      if (prior.alreadyCompleted) return prior;
    } catch {
      // Preserve the original bounded failure; the database transaction rolls back.
    }
    throw new Error(safeError(error));
  }
}
