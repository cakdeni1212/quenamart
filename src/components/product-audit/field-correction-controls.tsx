"use client";

import { useEffect, useRef, useState, useTransition, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { RupiahInput } from "@/components/ui/rupiah-input";
import {
  applyProductFieldCorrectionIntentAction,
  issueProductFieldCorrectionIntentAction,
  readProductFieldCorrectionIntentAction,
} from "@/app/actions/product-field-correction-intents";
import {
  forgetCorrectionRequestId,
  readStoredCorrectionRequestId,
  storeCorrectionRequestId,
  type BarcodeOperation,
  type CorrectionField,
  formatIndonesianMoney,
  formatIndonesianMoneyInput,
  correctionReviewEligible,
  type CorrectionIntentSummary,
} from "@/lib/product-audit/correction-intent-core";

type Props = {
  productId: string;
  fieldKey: CorrectionField;
  outletId: string | null;
  sourceRowId: string | null;
  reviewStatus: string | null;
  sourceDisplay: string;
  currentDisplay: string;
};

type Feedback = { kind: "success" | "error" | "info"; message: string } | null;

const FIELD_LABEL: Record<CorrectionField, string> = {
  barcode: "Barcode",
  rack_label: "Rak",
  hpp: "HPP",
  selling_price: "Harga jual",
};

export function FieldCorrectionControls(props: Props) {
  const { productId, fieldKey, outletId, sourceRowId, reviewStatus, sourceDisplay, currentDisplay } = props;
  const router = useRouter();
  const [barcodeOperation, setBarcodeOperation] = useState<BarcodeOperation>("ADD_ALIAS");
  const [value, setValue] = useState("");
  const [reason, setReason] = useState("");
  const [confirming, setConfirming] = useState(false);
  const [requestId, setRequestId] = useState<string | null>(null);
  const [recovered, setRecovered] = useState(false);
  const [recoverySummary, setRecoverySummary] = useState<CorrectionIntentSummary | null>(null);
  const [recoveryBlocked, setRecoveryBlocked] = useState(false);
  const [ready, setReady] = useState(false);
  const [feedback, setFeedback] = useState<Feedback>(null);
  const [pending, startTransition] = useTransition();
  const busy = useRef(false);
  const allowedForReview = correctionReviewEligible(reviewStatus, sourceRowId);
  const moneyField = fieldKey === "hpp" || fieldKey === "selling_price";
  const inputId = `correction-value-${productId}-${fieldKey}`;
  const reasonId = `correction-reason-${productId}-${fieldKey}`;
  const label = fieldKey === "rack_label" ? "Rak baru"
    : fieldKey === "hpp" ? "HPP baru"
      : fieldKey === "selling_price" ? "Harga jual baru" : "Barcode baru";
  const requestKey = `quena:product-correction-intent:${productId}:${fieldKey}`;

  useEffect(() => {
    let active = true;
    void Promise.resolve().then(async () => {
      try {
        const restoredId = readStoredCorrectionRequestId(window.localStorage, productId, fieldKey);
        if (restoredId) {
          const summary = await readProductFieldCorrectionIntentAction(restoredId);
          if (active) {
            if (summary && summary.requestId === restoredId && summary.productId === productId && summary.fieldKey === fieldKey) {
              setRecoverySummary(summary);
              setRequestId(restoredId);
              setRecovered(true);
            } else {
              // Keep the opaque token in storage, but never execute it until
              // the actor-scoped recovery RPC confirms its intended context.
              setRecoveryBlocked(true);
              setFeedback({ kind: "info", message: "Permintaan tersimpan belum dapat diverifikasi. Muat ulang halaman untuk memulihkan status sebelum melanjutkan." });
            }
          }
        }
      } catch {
        if (active) {
          setRecoveryBlocked(true);
          setFeedback({ kind: "info", message: "Permintaan tersimpan belum dapat diperiksa. Muat ulang saat jaringan tersedia." });
        }
      }
      if (active) setReady(true);
    });
    return () => { active = false; };
  }, [productId, fieldKey]);

  useEffect(() => {
    const clearOnOtherTabSuccess = (event: StorageEvent) => {
      if (event.key === requestKey && event.newValue === null) {
        setRequestId(null);
        setRecovered(false);
        setRecoverySummary(null);
        setRecoveryBlocked(false);
      }
    };
    window.addEventListener("storage", clearOnOtherTabSuccess);
    return () => window.removeEventListener("storage", clearOnOtherTabSuccess);
  }, [requestKey]);

  function consumeIntent() {
    if (requestId) forgetCorrectionRequestId(window.localStorage, productId, fieldKey);
    setRequestId(null);
    setRecovered(false);
    setRecoverySummary(null);
    setRecoveryBlocked(false);
  }

  function handleFormSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!allowedForReview || pending || busy.current) return;
    if (!value.trim() || !reason.trim()) {
      setFeedback({ kind: "error", message: "Isi nilai koreksi dan alasan sebelum melanjutkan." });
      return;
    }
    setFeedback(null);
    setConfirming(true);
  }

  function confirmCorrection() {
    if (!allowedForReview || !sourceRowId || pending || busy.current) return;
    busy.current = true;
    const submittedValue = fieldKey === "barcode" || fieldKey === "rack_label" ? value : value.trim();
    const submittedReason = reason;
    const submittedOperation = fieldKey === "barcode" ? barcodeOperation : null;
    startTransition(async () => {
      try {
        const form = new FormData();
        form.set("productId", productId);
        form.set("outletId", outletId ?? "");
        form.set("fieldKey", fieldKey);
        form.set("sourceImportRowId", sourceRowId);
        form.set("correctedValue", submittedValue);
        form.set("reason", submittedReason);
        form.set("barcodeOperation", submittedOperation ?? "");
        const issued = await issueProductFieldCorrectionIntentAction(form);
        if (!issued.ok) {
          setFeedback({ kind: "error", message: issued.message });
          if (issued.code === "STALE") router.refresh();
          return;
        }
        try {
          storeCorrectionRequestId(window.localStorage, productId, fieldKey, issued.requestId);
        } catch {
          setFeedback({ kind: "error", message: "Permintaan sudah disiapkan, tetapi perangkat tidak dapat menyimpan kode pemulihan. Jangan tutup halaman; coba lagi di sini." });
          setRequestId(issued.requestId);
          setRecovered(true);
          setValue("");
          setReason("");
          setConfirming(false);
          return;
        }
        setRequestId(issued.requestId);
        setRecovered(true);
        setValue("");
        setReason("");
        setConfirming(false);
        const result = await applyProductFieldCorrectionIntentAction(issued.requestId);
        if (!result.ok) {
          if (result.code === "STALE") {
            consumeIntent();
            setFeedback({ kind: "error", message: "Data sumber berubah. Muat ulang pemeriksaan sebelum melanjutkan." });
            router.refresh();
          } else {
            setFeedback({ kind: "info", message: "Hasil koreksi belum dapat dipastikan. Gunakan Coba Lagi untuk mengirim ulang permintaan tersimpan." });
          }
          return;
        }
        if (result.outcome === "BARCODE_CONFLICT") {
          consumeIntent();
          setFeedback({ kind: "error", message: "Barcode ini sudah digunakan produk lain." });
          return;
        }
        consumeIntent();
        setFeedback({ kind: "success", message: "Koreksi tersimpan dan status pemeriksaan diperbarui." });
        router.refresh();
      } catch {
        setFeedback({ kind: "info", message: "Hasil koreksi belum dapat dipastikan. Gunakan Coba Lagi untuk mengirim ulang permintaan tersimpan." });
      } finally {
        busy.current = false;
      }
    });
  }

  function retryCorrection() {
    if (!requestId || pending || busy.current) return;
    busy.current = true;
    startTransition(async () => {
      try {
        const result = await applyProductFieldCorrectionIntentAction(requestId);
        if (!result.ok) {
          if (result.code === "STALE") {
            consumeIntent();
            setFeedback({ kind: "error", message: "Data sumber berubah. Muat ulang pemeriksaan sebelum melanjutkan." });
            router.refresh();
          } else {
            setFeedback({ kind: "info", message: "Hasil koreksi belum dapat dipastikan. Kode pemulihan tetap tersimpan; coba lagi." });
          }
          return;
        }
        if (result.outcome === "BARCODE_CONFLICT") {
          consumeIntent();
          setFeedback({ kind: "error", message: "Barcode ini sudah digunakan produk lain." });
          return;
        }
        consumeIntent();
        setFeedback({ kind: "success", message: "Koreksi tersimpan dan status pemeriksaan diperbarui." });
        router.refresh();
      } catch {
        setFeedback({ kind: "info", message: "Hasil koreksi belum dapat dipastikan. Kode pemulihan tetap tersimpan; coba lagi." });
      } finally {
        busy.current = false;
      }
    });
  }

  if (!ready) return <div className="field-correction-controls" aria-live="polite">Memeriksa permintaan koreksi tersimpan…</div>;

  return <section className="field-correction-controls" aria-label={`Koreksi ${FIELD_LABEL[fieldKey]}`}>
    <div className="field-correction-heading">
      <div><span className="eyebrow">KOREKSI NILAI</span><h3>{FIELD_LABEL[fieldKey]}</h3></div>
      <span className="field-correction-state">{allowedForReview ? "Dapat dikoreksi" : "Mulai atau ulangi pemeriksaan untuk koreksi"}</span>
    </div>
    {recoveryBlocked ? <div className="field-correction-retry"><p>Permintaan tersimpan tetap aman. Aplikasi belum memperoleh metadata yang cocok untuk bidang ini, jadi permintaan tidak akan dijalankan sekarang.</p><button type="button" className="field-correction-secondary" onClick={() => window.location.reload()}>Coba pulihkan lagi</button></div> : requestId ? <div className="field-correction-retry">
      <p role="status">{recovered ? "Ada permintaan koreksi tersimpan yang belum dipastikan." : "Permintaan koreksi menunggu kepastian."} Nilai dan alasan tetap tersimpan aman di server.</p>
      {recoverySummary?.completed && <small>Permintaan sebelumnya sudah selesai; pengiriman ulang hanya memastikan hasilnya.</small>}
      <button type="button" className="field-correction-button" onClick={retryCorrection} disabled={pending}>{pending ? "Memeriksa hasil…" : "Coba Lagi"}</button>
    </div> : allowedForReview ? <form className="field-correction-form" onSubmit={handleFormSubmit}>
      {fieldKey === "barcode" && <fieldset className="barcode-operation-options" disabled={pending || confirming}>
        <legend>Pilih tindakan barcode</legend>
        <label><input type="radio" name={`barcode-operation-${productId}`} value="ADD_ALIAS" checked={barcodeOperation === "ADD_ALIAS"} onChange={() => setBarcodeOperation("ADD_ALIAS")} /><span><strong>Tambah barcode lain</strong><small>Tambahkan barcode lain tanpa menghapus barcode dari iPos.</small></span></label>
        <label><input type="radio" name={`barcode-operation-${productId}`} value="REPLACE_SOURCE" checked={barcodeOperation === "REPLACE_SOURCE"} onChange={() => setBarcodeOperation("REPLACE_SOURCE")} /><span><strong>Perbaiki barcode iPos</strong><small>Perbaiki barcode yang berasal dari iPos. Barcode tambahan tetap disimpan.</small></span></label>
      </fieldset>}
      <label htmlFor={inputId}>{label}</label>
      {moneyField ? <RupiahInput id={inputId} name="correctedValue" required value={value} onValueChange={setValue}
        placeholder="15.000" aria-label={label} /> : <input id={inputId} name="correctedValue" type="text" autoComplete="off"
        autoCapitalize="off" spellCheck={false} required maxLength={fieldKey === "barcode" ? 256 : 4000}
        value={value} onChange={(event) => setValue(event.target.value)}
        placeholder={fieldKey === "barcode" ? "Pindai atau ketik barcode" : "Contoh: Rak A-03"} />}
      <label htmlFor={reasonId}>Alasan koreksi</label>
      <textarea id={reasonId} name="reason" required maxLength={4000} value={reason} onChange={(event) => setReason(event.target.value)}
        placeholder={fieldKey === "rack_label" ? "Contoh: posisi barang di toko berbeda dari data iPos" : "Jelaskan alasan koreksi singkat"} rows={2} />
      {!confirming ? <button type="submit" className="field-correction-button" disabled={pending || !value.trim() || !reason.trim()}>Simpan Koreksi</button> : <div className="field-correction-confirmation">
        <h4>Periksa sebelum menyimpan</h4>
        <dl><div><dt>Bidang</dt><dd>{FIELD_LABEL[fieldKey]}</dd></div><div><dt>Nilai sumber iPos</dt><dd>{moneyField ? formatIndonesianMoney(sourceDisplay === "—" ? null : sourceDisplay) : sourceDisplay}</dd></div><div><dt>Nilai saat ini</dt><dd>{moneyField ? formatIndonesianMoney(currentDisplay === "—" ? null : currentDisplay) : currentDisplay}</dd></div><div><dt>Nilai usulan</dt><dd>{moneyField ? formatIndonesianMoneyInput(value) : value}</dd></div><div><dt>Alasan</dt><dd>{reason.trim()}</dd></div></dl>
        {fieldKey === "barcode" && <p className="field-correction-operation-note">{barcodeOperation === "ADD_ALIAS" ? "Barcode tambahan akan ditambahkan." : "Barcode iPos akan diperbaiki."}</p>}
        <div className="field-correction-confirm-actions"><button type="button" className="field-correction-secondary" onClick={() => setConfirming(false)} disabled={pending}>Ubah</button><button type="button" className="field-correction-button" onClick={confirmCorrection} disabled={pending}>{pending ? "Menyimpan…" : "Konfirmasi & simpan koreksi"}</button></div>
      </div>}
    </form> : <p className="field-correction-unavailable">Koreksi tersedia setelah status pemeriksaan bidang ini menjadi “Sedang diperiksa”.</p>}
    {feedback && <p className={`field-correction-feedback is-${feedback.kind}`} role={feedback.kind === "error" ? "alert" : "status"}>{feedback.message}</p>}
  </section>;
}
