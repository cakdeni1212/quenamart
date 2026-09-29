"use client";

import { useEffect, useState, useTransition, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import {
  ensureProductFieldReviewIntentAction,
  readProductFieldReviewIntentAction,
  recordProductFieldReviewAction,
} from "@/app/actions/product-field-audit";
import {
  forgetReviewIntentId,
  restoreStoredReviewIntent,
  storeReviewIntentId,
} from "@/lib/product-audit/review-intent-storage";
import type { CanonicalReviewIntent, ProductFieldReviewActionState, ReviewField } from "@/lib/product-audit/review-action-core";

type Props = {
  productId: string;
  fieldKey: ReviewField;
  outletId: string | null;
  sourceRowId: string | null;
  status: string | null;
  evidenceNotes: string | null;
};

function payloadFromIntent(payload: CanonicalReviewIntent): CanonicalReviewIntent {
  return { ...payload };
}

function formDataFromPayload(payload: CanonicalReviewIntent) {
  const form = new FormData();
  form.set("productId", payload.p_product_id);
  form.set("fieldKey", payload.p_field_key);
  form.set("status", payload.p_status);
  form.set("outletId", payload.p_outlet_id ?? "");
  form.set("sourceRowId", payload.p_source_import_row_id);
  form.set("evidenceNotes", payload.p_evidence_notes ?? "");
  return form;
}

export function FieldReviewControls({ productId, fieldKey, outletId, sourceRowId, status, evidenceNotes }: Props) {
  const router = useRouter();
  const currentPayload: CanonicalReviewIntent = {
    p_product_id: productId,
    p_outlet_id: fieldKey === "barcode" ? null : outletId,
    p_field_key: fieldKey,
    p_status: status === "SEDANG_DICEK" ? "SUDAH_DIVERIFIKASI" : "SEDANG_DICEK",
    p_source_import_row_id: sourceRowId ?? "",
    p_evidence_notes: evidenceNotes,
  };
  const [payload, setPayload] = useState<CanonicalReviewIntent>(() => ({
    p_product_id: productId,
    p_outlet_id: fieldKey === "barcode" ? null : outletId,
    p_field_key: fieldKey,
    p_status: status === "SEDANG_DICEK" ? "SUDAH_DIVERIFIKASI" : "SEDANG_DICEK",
    p_source_import_row_id: sourceRowId ?? "",
    p_evidence_notes: evidenceNotes,
  }));
  const [requestId, setRequestId] = useState<string | null>(null);
  const [restored, setRestored] = useState(false);
  const [ready, setReady] = useState(false);
  const [retrying, setRetrying] = useState(false);
  const [state, setState] = useState<ProductFieldReviewActionState>(null);
  const [pending, startTransition] = useTransition();

  useEffect(() => {
    let active = true;
    void Promise.resolve().then(async () => {
      try {
        const restoredIntent = await restoreStoredReviewIntent(
          window.localStorage,
          productId,
          fieldKey,
          readProductFieldReviewIntentAction,
          (intent) => intent.completed
            && intent.payload.p_source_import_row_id === (sourceRowId ?? "")
            && intent.payload.p_status !== (status === "SEDANG_DICEK" ? "SUDAH_DIVERIFIKASI" : "SEDANG_DICEK"),
        );
        const intent = restoredIntent?.value;
        if (active && restoredIntent && intent?.payload.p_product_id === productId && intent.payload.p_field_key === fieldKey) {
          setPayload(payloadFromIntent(intent.payload));
          setRequestId(restoredIntent.requestId);
          setRestored(true);
        }
      } catch {
        // Preserve an opaque ID on transient storage or lookup failures.
        if (active) setState({ ok: false, code: "UNAVAILABLE", message: "Penyimpanan permintaan tidak tersedia di perangkat ini." });
      }
      if (active) setReady(true);
    });
    return () => { active = false; };
  }, [productId, fieldKey, outletId, sourceRowId, status, evidenceNotes]);

  useEffect(() => {
    if (!requestId) return;
    const key = `quena:product-review-intent:${productId}:${fieldKey}:${requestId}`;
    const resetConsumed = (event: Event) => {
      const detail = (event as CustomEvent<{ productId?: string; fieldKey?: string; requestId?: string }>).detail;
      if (detail?.productId === productId && detail.fieldKey === fieldKey && detail.requestId === requestId) {
        setRequestId(null);
        setPayload({
          p_product_id: productId,
          p_outlet_id: fieldKey === "barcode" ? null : outletId,
          p_field_key: fieldKey,
          p_status: status === "SEDANG_DICEK" ? "SUDAH_DIVERIFIKASI" : "SEDANG_DICEK",
          p_source_import_row_id: sourceRowId ?? "",
          p_evidence_notes: evidenceNotes,
        });
        setRestored(false);
        setRetrying(false);
      }
    };
    const resetRemoved = (event: StorageEvent) => {
      if (event.key === key) {
        setRequestId(null);
        setPayload({
          p_product_id: productId,
          p_outlet_id: fieldKey === "barcode" ? null : outletId,
          p_field_key: fieldKey,
          p_status: status === "SEDANG_DICEK" ? "SUDAH_DIVERIFIKASI" : "SEDANG_DICEK",
          p_source_import_row_id: sourceRowId ?? "",
          p_evidence_notes: evidenceNotes,
        });
        setRestored(false);
        setRetrying(false);
      }
    };
    window.addEventListener("quena:review-intent-consumed", resetConsumed);
    window.addEventListener("storage", resetRemoved);
    return () => {
      window.removeEventListener("quena:review-intent-consumed", resetConsumed);
      window.removeEventListener("storage", resetRemoved);
    };
  }, [productId, fieldKey, sourceRowId, outletId, status, evidenceNotes, requestId]);

  function updateNotes(value: string) {
    setPayload((current) => ({ ...current, p_evidence_notes: value.trim() || null }));
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!ready || pending || !payload.p_source_import_row_id) return;
    const formData = formDataFromPayload(payload);
    startTransition(async () => {
      try {
        let activeRequestId = requestId;
        if (!activeRequestId) {
          const issued = await ensureProductFieldReviewIntentAction(formData);
          if (!issued.ok || !issued.requestId) {
            setState({ ok: false, code: issued.code, message: issued.message });
            return;
          }
          activeRequestId = issued.requestId;
          // Persist only the opaque server-issued UUID. The server-side intent
          // ledger binds it to actor and canonical payload and rejects tampering.
          storeReviewIntentId(window.localStorage, productId, fieldKey, activeRequestId);
          setRequestId(activeRequestId);
        }

        const result = await recordProductFieldReviewAction(activeRequestId, null, formData);
        setState(result);
        if (result?.ok) {
          forgetReviewIntentId(window.localStorage, productId, fieldKey, activeRequestId);
          window.dispatchEvent(new CustomEvent("quena:review-intent-consumed", {
            detail: { productId, fieldKey, requestId: activeRequestId },
          }));
          setRequestId(null);
          setPayload(currentPayload);
          setRestored(false);
          router.refresh();
        } else if (result?.code === "STALE") {
          forgetReviewIntentId(window.localStorage, productId, fieldKey, activeRequestId);
          window.dispatchEvent(new CustomEvent("quena:review-intent-consumed", {
            detail: { productId, fieldKey, requestId: activeRequestId },
          }));
          setRequestId(null);
          setRestored(false);
          router.refresh();
        } else if (result?.code === "UNAVAILABLE") {
          setRetrying(true);
        }
      } catch {
        setRetrying(true);
        setState({ ok: false, code: "UNAVAILABLE", message: "Hasil belum dapat dipastikan. Kirim ulang permintaan yang sama." });
      }
    });
  }

  if (!sourceRowId && !requestId) {
    return <div className="field-review-unavailable">Belum ada baris sumber iPos yang dapat diperiksa.</div>;
  }

  const inProgress = status === "SEDANG_DICEK";
  const newIntentStatus = inProgress ? "SUDAH_DIVERIFIKASI" : "SEDANG_DICEK";
  const displayingResumedIntent = !!requestId && (restored || retrying);
  const buttonText = pending ? "Menyimpan…"
    : displayingResumedIntent ? "Kirim ulang untuk memastikan hasil sebelumnya"
      : newIntentStatus === "SUDAH_DIVERIFIKASI" ? "Tandai Sudah Diverifikasi"
        : status === "SUDAH_DIVERIFIKASI" ? "Cek Ulang" : "Mulai Cek";

  return <div className="field-review-controls">
    <div className="field-review-current" aria-live="polite">
      <span className="field-review-current-label">Status pemeriksaan</span>
      <strong>{inProgress ? "Sedang diperiksa" : status === "SUDAH_DIVERIFIKASI" ? "Sudah dicek" : "Belum dicek"}</strong>
    </div>
    <p className="field-review-explainer">Cek barang fisik dan pastikan datanya sesuai. Pemeriksaan ini tidak menghapus temuan iPos.</p>
    {restored && <p className="field-review-feedback" role="status">Ada permintaan sebelumnya yang belum terkonfirmasi. Data permintaan lama dipertahankan agar aman dikirim ulang.</p>}
    <form onSubmit={submit} className="field-review-form">
      <label htmlFor={`review-notes-${productId}-${fieldKey}`}>Catatan singkat (opsional)</label>
      <input id={`review-notes-${productId}-${fieldKey}`} name="evidenceNotes" maxLength={500}
        value={payload.p_evidence_notes ?? ""} onChange={(event) => updateNotes(event.target.value)}
        placeholder="Contoh: sudah dicocokkan di rak" />
      <button type="submit" disabled={!ready || pending || !payload.p_source_import_row_id} className="field-review-button">
        {!ready ? "Memulihkan permintaan…" : buttonText}
      </button>
    </form>
    {state && <p className={`field-review-feedback ${state.ok ? "is-success" : "is-error"}`} role={state.ok ? "status" : "alert"}>{state.message}</p>}
  </div>;
}
