import type { UserRole } from "@/lib/auth/roles";

export const STOCK_OPNAME_POST_OPERATION = "POST_SESSION" as const;

export type StockOpnamePostStatus = "COUNTING" | "REVIEW" | "CANCELLED" | "POSTED";
export type StockOpnamePostOutcomeKind =
  | "success-posted"
  | "stale-session-changed"
  | "stale-baseline"
  | "known-rejection"
  | "uncertain-failure";

export type StockOpnamePostProgress = {
  remaining: number;
  recountRequired: number;
} | null;

export type StockOpnamePostOutcome = {
  kind: StockOpnamePostOutcomeKind;
  requestId?: string;
  message: string;
  movementCount?: number;
  movementBatchId?: string | null;
  staleItemCount?: number;
};

export function canRolePostStockOpname(role: UserRole | string | null | undefined): boolean {
  return role === "OWNER" || role === "ADMIN";
}

export function canRetryStockOpnamePost(status: StockOpnamePostStatus | null | undefined): boolean {
  return status === "REVIEW";
}

export function isStockOpnamePostAdvisoryEligible(progress: StockOpnamePostProgress): boolean {
  return progress !== null && progress.remaining === 0 && progress.recountRequired === 0;
}

export function stockOpnamePostStateKey(sessionId: string): string {
  return `${sessionId}:POST_SESSION`;
}

export function stockOpnamePostRequestKey(sessionId: string): string {
  return `quena-opname-lifecycle:${sessionId}:POST_SESSION`;
}

export function stockOpnamePostOutcomeFromDatabase(
  value: unknown,
  requestId: string,
): StockOpnamePostOutcome {
  if (!value || typeof value !== "object") {
    return { kind: "uncertain-failure", requestId, message: "Hasil posting belum dapat dipastikan. Coba ulangi permintaan tersimpan." };
  }

  const result = value as Record<string, unknown>;
  if (result.ok === true && result.status === "POSTED") {
    const movementCount = result.movementCount;
    return {
      kind: "success-posted",
      requestId,
      message: "Opname berhasil diposting dan stok sistem telah disesuaikan.",
      movementCount: Number.isSafeInteger(movementCount) && Number(movementCount) >= 0 ? Number(movementCount) : undefined,
      movementBatchId: typeof result.movementBatchId === "string" ? result.movementBatchId : null,
    };
  }

  if (result.code === "SESSION_CHANGED") {
    return { kind: "stale-session-changed", requestId, message: "Data opname berubah setelah permintaan posting disiapkan. Tidak ada penyesuaian stok yang diposting; muat ulang sesi dan periksa kembali." };
  }
  if (result.code === "STALE_BASELINE") {
    const staleItemCount = result.staleItemCount;
    return {
      kind: "stale-baseline",
      requestId,
      message: "Stok berubah sejak penghitungan. Tidak ada item yang diposting; sesi kembali ke penghitungan dan item terdampak perlu dihitung ulang.",
      staleItemCount: Number.isSafeInteger(staleItemCount) && Number(staleItemCount) >= 0 ? Number(staleItemCount) : undefined,
    };
  }

  return { kind: "known-rejection", requestId, message: "Posting tidak diterapkan. Muat ulang status opname sebelum mencoba lagi." };
}
