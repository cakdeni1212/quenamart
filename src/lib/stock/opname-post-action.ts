"use server";

import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { canRolePostStockOpname, stockOpnamePostOutcomeFromDatabase, type StockOpnamePostOutcome } from "@/lib/stock/opname-post-model";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type StockOpnamePostIssueResult =
  | { kind: "issued"; requestId: string; message: string }
  | { kind: "known-rejection" | "uncertain-failure"; message: string };

function safeText(value: string | null | undefined) {
  return value?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 180) ?? "";
}

async function hasPostAccess() {
  const profile = await getProfile();
  return Boolean(profile?.is_active && canRolePostStockOpname(profile.role));
}

export async function issueStockOpnamePostIntent(input: {
  sessionId: string;
}): Promise<StockOpnamePostIssueResult> {
  if (!(await hasPostAccess())) return { kind: "known-rejection", message: "Hanya OWNER atau ADMIN aktif yang dapat memposting opname." };
  if (!input || typeof input.sessionId !== "string" || !UUID_PATTERN.test(input.sessionId)) {
    return { kind: "known-rejection", message: "Sesi opname tidak valid. Muat ulang halaman." };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("issue_stock_operation_intent", {
    p_operation_key: "POST_SESSION",
    p_payload: { session_id: input.sessionId },
  });
  if (error || typeof data !== "string" || !UUID_PATTERN.test(data)) {
    if (error) console.error("[stock-opname-post] intent issuance failed", {
      operation: "POST_SESSION",
      code: safeText(error.code),
      message: safeText(error.message),
    });
    if (error?.code === "42501" || error?.code === "22023") {
      return { kind: "known-rejection", message: error.code === "42501"
        ? "Hanya OWNER atau ADMIN aktif yang dapat memposting opname."
        : "Permintaan posting belum dapat disiapkan. Muat ulang status sesi." };
    }
    // Reissuing the same canonical intent is safe: the database reuses the
    // actor/operation/session pending request when its payload is unchanged.
    return { kind: "uncertain-failure", message: "Pembuatan permintaan belum terkonfirmasi. Coba siapkan kembali tindakan yang sama sebelum menerapkan posting." };
  }
  return { kind: "issued", requestId: data, message: "Permintaan posting siap diterapkan." };
}

export async function applyStockOpnamePostIntent(input: {
  sessionId: string;
  requestId: string;
}): Promise<StockOpnamePostOutcome> {
  if (!(await hasPostAccess())) return { kind: "known-rejection", requestId: input?.requestId, message: "Hanya OWNER atau ADMIN aktif yang dapat memposting opname." };
  if (!input || typeof input.sessionId !== "string" || !UUID_PATTERN.test(input.sessionId)
      || typeof input.requestId !== "string" || !UUID_PATTERN.test(input.requestId)) {
    return { kind: "known-rejection", message: "Permintaan posting tidak valid." };
  }

  const supabase = await createClient();
  const { data: request, error: requestError } = await supabase.rpc("read_stock_operation_intent", {
    p_request_id: input.requestId,
  });
  if (requestError || !request || typeof request !== "object"
      || (request as Record<string, unknown>).available !== true
      || (request as Record<string, unknown>).operation !== "POST_SESSION") {
    if (requestError) console.error("[stock-opname-post] request verification failed", {
      operation: "POST_SESSION",
      code: safeText(requestError.code),
      message: safeText(requestError.message),
    });
    return { kind: "known-rejection", requestId: input.requestId, message: "ID permintaan tidak tersedia untuk posting sesi ini." };
  }

  const { data, error } = await supabase.rpc("apply_stock_operation_intent", {
    p_request_id: input.requestId,
  });
  if (error) {
    console.error("[stock-opname-post] intent application failed", {
      operation: "POST_SESSION",
      code: safeText(error.code),
      message: safeText(error.message),
    });
    if (error.code === "42501" || error.code === "22023") {
      return { kind: "known-rejection", requestId: input.requestId, message: error.code === "42501"
        ? "Hanya OWNER atau ADMIN aktif yang dapat memposting opname."
        : "Sesi tidak lagi dapat diposting. Status terbaru akan dimuat." };
    }
    return { kind: "uncertain-failure", requestId: input.requestId, message: "Hasil posting belum terkonfirmasi. Retry akan memakai ID permintaan yang sama." };
  }

  return stockOpnamePostOutcomeFromDatabase(data, input.requestId);
}
