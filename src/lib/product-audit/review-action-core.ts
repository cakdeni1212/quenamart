import { canAccessSection, type UserRole } from "../auth/roles.ts";
import { isUuid } from "./context.ts";

export const REVIEW_FIELDS = ["barcode", "rack_label", "hpp", "selling_price", "quantity", "minimum_quantity"] as const;
export type ReviewField = (typeof REVIEW_FIELDS)[number];
export type ReviewStatus = "SEDANG_DICEK" | "SUDAH_DIVERIFIKASI";

export type ProductFieldReviewActionState = {
  ok: boolean;
  code: "OK" | "VALIDATION" | "DENIED" | "STALE" | "CONFLICT" | "UNAVAILABLE";
  message: string;
} | null;

export type ReviewRpcPayload = {
  p_request_id: string;
  p_product_id: string;
  p_outlet_id: string | null;
  p_field_key: ReviewField;
  p_status: ReviewStatus;
  p_source_import_row_id: string;
  p_evidence_notes: string | null;
};

export type CanonicalReviewIntent = Omit<ReviewRpcPayload, "p_request_id">;
export type StoredReviewIntent = {
  requestId: string;
  payload: CanonicalReviewIntent;
  completed: boolean;
};

type CurrentReviewScope = {
  kind: "ok";
  outletId: string;
  fields: Partial<Record<ReviewField, { outletId: string | null; sourceRowId: string | null }>>;
};

export type ReviewActionDependencies = {
  getProfile: () => Promise<{ role: UserRole } | null>;
  readIntent: (requestId: string) => Promise<StoredReviewIntent | null>;
  callRpc: (payload: ReviewRpcPayload) => Promise<{ error: { code?: string; message: string } | null }>;
  revalidate: (paths: string[]) => void;
  logFailure: (phase: string, error: unknown) => void;
};

export type ReviewIntentDependencies = {
  getProfile: () => Promise<{ role: UserRole } | null>;
  readCurrent: (productId: string) => Promise<CurrentReviewScope | { kind: "not-found" | "error" }>;
  issueIntent: (payload: CanonicalReviewIntent) => Promise<{ requestId: string | null; error: { code?: string; message: string } | null }>;
  logFailure: (phase: string, error: unknown) => void;
};

function parseField(value: FormDataEntryValue | null): ReviewField | null {
  return typeof value === "string" && REVIEW_FIELDS.includes(value as ReviewField)
    ? value as ReviewField
    : null;
}

function parseStatus(value: FormDataEntryValue | null): ReviewStatus | null {
  return value === "SEDANG_DICEK" || value === "SUDAH_DIVERIFIKASI" ? value : null;
}

export function normalizeEvidenceNotes(value: string | null) {
  return value?.trim() || null;
}

function readCanonicalIntent(formData: FormData): CanonicalReviewIntent | null {
  const productId = formData.get("productId");
  const sourceRowId = formData.get("sourceRowId");
  const outletValue = formData.get("outletId");
  const field = parseField(formData.get("fieldKey"));
  const status = parseStatus(formData.get("status"));
  const rawNotes = formData.get("evidenceNotes");
  if (typeof productId !== "string" || !isUuid(productId)
    || typeof sourceRowId !== "string" || !isUuid(sourceRowId)
    || (outletValue !== "" && (typeof outletValue !== "string" || !isUuid(outletValue)))
    || !field || !status || (rawNotes !== null && typeof rawNotes !== "string")
    || (typeof rawNotes === "string" && rawNotes.length > 500)) return null;
  return {
    p_product_id: productId,
    p_outlet_id: outletValue === "" ? null : outletValue as string,
    p_field_key: field,
    p_status: status,
    p_source_import_row_id: sourceRowId,
    p_evidence_notes: normalizeEvidenceNotes(rawNotes as string | null),
  };
}

function roleCanReview(role: UserRole | undefined, field: ReviewField) {
  return !!role && canAccessSection(role, "audit-produk") && role !== "KASIR"
    && (role !== "GUDANG" || ["barcode", "rack_label", "quantity", "minimum_quantity"].includes(field));
}

export async function issueProductFieldReviewIntent(
  formData: FormData,
  dependencies: ReviewIntentDependencies,
): Promise<{ ok: boolean; code: "OK" | "VALIDATION" | "DENIED" | "STALE" | "UNAVAILABLE"; message: string; requestId?: string }> {
  let phase = "validation";
  try {
    const payload = readCanonicalIntent(formData);
    if (!payload) return { ok: false, code: "VALIDATION", message: "Data pemeriksaan tidak valid. Muat ulang halaman lalu coba lagi." };
    const expectedOutlet = payload.p_field_key === "barcode" ? null : payload.p_outlet_id;
    if (payload.p_outlet_id !== expectedOutlet || (payload.p_field_key !== "barcode" && !expectedOutlet)) {
      return { ok: false, code: "VALIDATION", message: "Outlet tidak sesuai dengan bidang pemeriksaan." };
    }

    phase = "profile";
    const profile = await dependencies.getProfile();
    if (!profile || !roleCanReview(profile.role, payload.p_field_key)) {
      return { ok: false, code: "DENIED", message: "Akun ini tidak memiliki akses ke pemeriksaan bidang tersebut." };
    }
    phase = "source_read";
    const current = await dependencies.readCurrent(payload.p_product_id);
    const record = current.kind === "ok" ? current.fields[payload.p_field_key] : undefined;
    if (!record || !record.sourceRowId || record.sourceRowId !== payload.p_source_import_row_id
      || record.outletId !== expectedOutlet || (payload.p_field_key !== "barcode" && current.kind === "ok" && current.outletId !== expectedOutlet)) {
      return { ok: false, code: "STALE", message: "Data iPos sudah berubah. Muat ulang halaman untuk memulai pemeriksaan terbaru." };
    }
    phase = "issue";
    const result = await dependencies.issueIntent(payload);
    if (result.error) {
      if (result.error.code === "40001" || /source changed|source row/i.test(result.error.message)) {
        return { ok: false, code: "STALE", message: "Data iPos berubah saat pemeriksaan disiapkan. Muat ulang halaman." };
      }
      if (/permission denied|access denied/i.test(result.error.message)) {
        return { ok: false, code: "DENIED", message: "Akun ini tidak diizinkan memeriksa bidang tersebut." };
      }
      dependencies.logFailure("intent_response", { code: result.error.code ?? "unknown" });
      return { ok: false, code: "UNAVAILABLE", message: "Permintaan pemeriksaan belum dapat disiapkan. Coba lagi." };
    }
    if (!result.requestId || !isUuid(result.requestId)) {
      return { ok: false, code: "UNAVAILABLE", message: "Permintaan pemeriksaan belum dapat disiapkan. Coba lagi." };
    }
    return { ok: true, code: "OK", message: "Permintaan siap.", requestId: result.requestId };
  } catch (error) {
    try { dependencies.logFailure(phase, error); } catch { /* safe failure boundary */ }
    return { ok: false, code: "UNAVAILABLE", message: "Terjadi kendala saat menyiapkan pemeriksaan. Coba lagi." };
  }
}

export async function executeProductFieldReview(
  requestId: string,
  formData: FormData,
  dependencies: ReviewActionDependencies,
): Promise<ProductFieldReviewActionState> {
  let phase = "validation";
  try {
    const canonical = readCanonicalIntent(formData);
    if (!isUuid(requestId) || !canonical) {
      return { ok: false, code: "VALIDATION", message: "Data pemeriksaan tidak valid. Muat ulang halaman lalu coba lagi." };
    }

    phase = "profile";
    const profile = await dependencies.getProfile();
    if (!roleCanReview(profile?.role, canonical.p_field_key)) {
      return { ok: false, code: "DENIED", message: "Akun ini tidak memiliki akses ke pemeriksaan produk." };
    }

    phase = "intent_read";
    const intent = await dependencies.readIntent(requestId);
    if (!intent) return { ok: false, code: "CONFLICT", message: "Permintaan pemeriksaan tidak dikenali. Muat ulang halaman sebelum mencoba lagi." };
    if (intent.requestId !== requestId) return { ok: false, code: "CONFLICT", message: "Permintaan pemeriksaan tidak dikenali. Muat ulang halaman sebelum mencoba lagi." };

    // The RPC compares the complete payload and performs current-source checks
    // only after its exact replay branch, avoiding an app-level stale precheck.
    phase = "rpc";
    const { error } = await dependencies.callRpc({ p_request_id: requestId, ...canonical });
    if (error) {
      if (error.code === "40001" || /source changed|source row/i.test(error.message)) {
        return { ok: false, code: "STALE", message: "Data iPos berubah saat pemeriksaan dikirim. Muat ulang halaman sebelum melanjutkan." };
      }
      if (/permission denied|access denied/i.test(error.message)) {
        return { ok: false, code: "DENIED", message: "Akun ini tidak diizinkan memeriksa bidang tersebut." };
      }
      if (/already used for another review|IDEMPOTENCY_KEY_REUSED/i.test(error.message)) {
        return { ok: false, code: "CONFLICT", message: "Permintaan ini sudah dipakai dengan catatan atau data berbeda. Muat ulang halaman untuk memulai pemeriksaan baru." };
      }
      if (/invalid human review transition|invalid review field/i.test(error.message)) {
        return { ok: false, code: "VALIDATION", message: "Urutan pemeriksaan tidak sesuai. Muat ulang status lalu coba lagi." };
      }
      try {
        dependencies.logFailure("rpc_response", { code: error.code ?? "unknown" });
      } catch {
        // A diagnostic failure must not affect the safe user-facing result.
      }
      return { ok: false, code: "UNAVAILABLE", message: "Pemeriksaan belum dapat dipastikan tersimpan. Coba kirim ulang formulir yang sama." };
    }

    phase = "revalidation";
    dependencies.revalidate([`/audit-produk/${canonical.p_product_id}`, "/audit-produk", `/produk/${canonical.p_product_id}`]);
    return {
      ok: true,
      code: "OK",
      message: canonical.p_status === "SEDANG_DICEK" ? "Pemeriksaan dimulai dan tercatat." : "Pemeriksaan berhasil ditandai selesai.",
    };
  } catch (error) {
    try {
      dependencies.logFailure(phase, error);
    } catch {
      // Diagnostics must never turn a safe action result into an exception.
    }
    return {
      ok: false,
      code: "UNAVAILABLE",
      message: "Terjadi kendala saat menyimpan pemeriksaan. Coba kirim ulang formulir yang sama.",
    };
  }
}
