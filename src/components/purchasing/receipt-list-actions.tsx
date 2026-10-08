"use client";

import Link from "next/link";
import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { cancelReceiptDraft } from "@/lib/purchasing/actions";

function Icon({ kind }: { kind: "edit" | "view" | "cancel" }) {
  if (kind === "edit") return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m4 16.5-.8 4.3 4.3-.8L19.8 7.7a2.1 2.1 0 0 0-3-3L4 16.5Z"/><path d="m14.9 6.6 3 3"/></svg>;
  if (kind === "view") return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M2.5 12s3.4-6 9.5-6 9.5 6 9.5 6-3.4 6-9.5 6-9.5-6-9.5-6Z"/><circle cx="12" cy="12" r="2.5"/></svg>;
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M9 7V4h6v3m3 0-.8 13H6.8L6 7m4 4v5m4-5v5"/></svg>;
}

export function ReceiptListActions({ receiptId, reference, canEdit, canCancel }: { receiptId: string; reference: string; canEdit: boolean; canCancel: boolean }) {
  const router = useRouter();
  const [confirming, setConfirming] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [pending, startTransition] = useTransition();
  const detail = `/pembelian/barang-masuk/${receiptId}`;

  function cancel() {
    if (pending) return;
    setError(""); setMessage("");
    startTransition(async () => {
      const result = await cancelReceiptDraft(receiptId);
      if (result.error) { setError(result.error); return; }
      setMessage(result.cleanupPending
        ? "Draf dibatalkan. Penghapusan dokumen nota masih tertunda dan dapat dicoba kembali."
        : "Draf pembelian berhasil dibatalkan.");
      setConfirming(false);
      router.replace(`/pembelian/barang-masuk?status=CANCELLED&cancelled=${encodeURIComponent(receiptId)}`);
      router.refresh();
    });
  }

  return <div className="purchase-row-actions">
    {canEdit && <Link className="purchase-row-action" href={detail} title="Edit pembelian" aria-label="Edit pembelian"><Icon kind="edit" /></Link>}
    <Link className="purchase-row-action" href={`${detail}?mode=view`} title="Lihat detail" aria-label="Lihat detail"><Icon kind="view" /></Link>
    {canCancel && <button className="purchase-row-action purchase-row-action-cancel" type="button" title="Batalkan draf" aria-label="Batalkan draf" onClick={() => { setConfirming(true); setError(""); }}><Icon kind="cancel" /></button>}
    {message && <span className="sr-only" role="status">{message}</span>}
    {error && <span className="purchase-row-action-error" role="alert">{error}</span>}
    {confirming && <div className="purchase-cancel-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && !pending) setConfirming(false); }}>
      <section className="purchase-cancel-dialog" role="alertdialog" aria-modal="true" aria-labelledby={`cancel-title-${receiptId}`} aria-describedby={`cancel-description-${receiptId}`}>
        <h2 id={`cancel-title-${receiptId}`}>Batalkan draf pembelian ini?</h2>
        <p id={`cancel-description-${receiptId}`}>Draf tidak akan memengaruhi stok dan akan dipindahkan ke riwayat pembatalan.</p>
        <p className="purchase-cancel-reference">{reference}</p>
        {error && <p className="purchase-action-error" role="alert">{error}</p>}
        <div className="purchase-cancel-actions"><button type="button" className="purchase-secondary" disabled={pending} onClick={() => setConfirming(false)}>Kembali</button><button type="button" className="purchase-cancel-confirm" disabled={pending} onClick={cancel}>{pending ? "Membatalkan…" : "Ya, Batalkan Draf"}</button></div>
      </section>
    </div>}
  </div>;
}
