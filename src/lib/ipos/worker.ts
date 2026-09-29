import "server-only";
import { createHash } from "node:crypto";
import { createAdminClient } from "@/lib/supabase/admin";
import { chunkIposRows } from "@/lib/ipos/chunks";
import { parseIposWorkbook } from "@/lib/ipos/xlsx-parser";

const BUCKET = "quena-ipos-imports";
const INSERT_CHUNK_SIZE = 100;

type Claim = {
  request_id: string;
  batch_id: string;
  outlet_id: string;
  storage_bucket: string;
  storage_path: string;
  original_filename: string;
  requested_by: string;
};

export type IposWorkerResult =
  | { result: "COMPLETED"; requestId: string; batchId: string; rawRowCount: number }
  | { result: "NOT_CLAIMED"; requestId: string }
  | { result: "ALREADY_PROCESSING" | "ALREADY_COMPLETED" | "ALREADY_FAILED"; requestId: string };

function safeWorkerError(error: unknown) {
  const message = error instanceof Error ? error.message : "iPos import processing failed.";
  return message
    .replace(/\b(?:SUPABASE_SERVICE_ROLE_KEY|service_role)\b/gi, "server credential")
    .slice(0, 500);
}

function isClaim(value: unknown): value is Claim {
  if (!value || typeof value !== "object") return false;
  const claim = value as Partial<Claim>;
  return typeof claim.request_id === "string"
    && typeof claim.batch_id === "string"
    && typeof claim.outlet_id === "string"
    && claim.storage_bucket === BUCKET
    && typeof claim.storage_path === "string"
    && typeof claim.original_filename === "string"
    && typeof claim.requested_by === "string";
}

async function insertRawRows(claim: Claim, rows: ReturnType<typeof parseIposWorkbook>["rows"]) {
  const admin = createAdminClient();
  for (const rowChunk of chunkIposRows(rows, INSERT_CHUNK_SIZE)) {
    const chunk = rowChunk.map(({ sourceRowNumber, rawData }) => ({
      batch_id: claim.batch_id,
      outlet_id: claim.outlet_id,
      source_row_number: sourceRowNumber,
      raw_data: rawData,
      status: "RAW_ONLY",
      product_id: null,
      validation_errors: [],
    }));
    const { error } = await admin.from("ipos_import_rows").insert(chunk);
    if (error) throw new Error(`Raw row insert failed: ${error.message}`);
  }
}

export async function processIposImportRequest(requestId: string): Promise<IposWorkerResult> {
  const admin = createAdminClient();
  const { data: claimedRaw, error: claimError } = await admin.rpc("claim_ipos_import_request", {
    p_request_id: requestId,
  });
  if (claimError) throw new Error(`Could not claim iPos request: ${claimError.message}`);

  if (claimedRaw === null) {
    const { data: existing, error } = await admin
      .from("ipos_import_requests")
      .select("state")
      .eq("id", requestId)
      .maybeSingle();
    if (error) throw new Error(`Could not read iPos request state: ${error.message}`);
    if (!existing) return { result: "NOT_CLAIMED", requestId };
    if (existing.state === "PROCESSING") return { result: "ALREADY_PROCESSING", requestId };
    if (existing.state === "COMPLETED") return { result: "ALREADY_COMPLETED", requestId };
    if (existing.state === "FAILED") return { result: "ALREADY_FAILED", requestId };
    return { result: "NOT_CLAIMED", requestId };
  }

  if (!isClaim(claimedRaw)) throw new Error("Claim RPC returned an invalid result.");
  const claim = claimedRaw;

  try {
    if (!claim.storage_path.startsWith("incoming/") || !claim.storage_path.endsWith(".xlsx")) {
      throw new Error("Claimed iPos request has an invalid storage path.");
    }
    const { data: blob, error: downloadError } = await admin.storage
      .from(BUCKET)
      .download(claim.storage_path);
    if (downloadError || !blob) throw new Error("Workbook could not be downloaded from private Storage.");
    const workbookBytes = new Uint8Array(await blob.arrayBuffer());
    const fileSha256 = createHash("sha256").update(workbookBytes).digest("hex");
    const parsed = parseIposWorkbook(workbookBytes);

    const { error: hashError } = await admin.from("ipos_import_batches")
      .update({ file_sha256: fileSha256 })
      .eq("id", claim.batch_id);
    if (hashError) throw new Error(`Could not record workbook checksum: ${hashError.message}`);

    await insertRawRows(claim, parsed.rows);

    const { data: finalCount, error: completeError } = await admin.rpc("complete_ipos_import_request", {
      p_request_id: claim.request_id,
      p_batch_id: claim.batch_id,
      p_expected_row_count: parsed.rows.length,
    });
    if (completeError) throw new Error(`Could not finalize raw snapshot: ${completeError.message}`);
    if (finalCount !== parsed.rows.length) throw new Error("Finalized raw snapshot count did not match parsed row count.");

    return {
      result: "COMPLETED",
      requestId: claim.request_id,
      batchId: claim.batch_id,
      rawRowCount: parsed.rows.length,
    };
  } catch (error) {
    const message = safeWorkerError(error);
    const errorCode = error instanceof Error && error.message.includes("sheet") ? "INVALID_WORKBOOK" : "RAW_SNAPSHOT_FAILED";
    const { error: failError } = await admin.rpc("fail_ipos_import_request", {
      p_request_id: claim.request_id,
      p_batch_id: claim.batch_id,
      p_error_code: errorCode,
      p_error_message: message,
    });
    if (failError) {
      throw new Error(`iPos processing failed and failure status could not be recorded: ${failError.message}`);
    }
    throw new Error(`iPos raw snapshot failed; request was marked FAILED: ${message}`);
  }
}
