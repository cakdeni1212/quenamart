"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { createPurchaseInvoiceDraftForReceipt, linkPurchaseReceipt } from "@/lib/purchasing/actions";

export function ReceiptInvoiceStart({ receiptId, hasItems, autoStart = false }: { receiptId: string; hasItems: boolean; autoStart?: boolean }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState("");
  const requestLock = useRef(false);
  const started = useRef(false);

  function start() {
    if (pending || requestLock.current) return;
    requestLock.current = true;
    setError("");
    startTransition(async () => {
      try {
        const key = `quena:purchasing:CREATE_INVOICE:${receiptId}`;
        let requestId = sessionStorage.getItem(key);
        if (!requestId) {
          requestId = crypto.randomUUID();
          sessionStorage.setItem(key, requestId);
        }
        const created = await createPurchaseInvoiceDraftForReceipt(receiptId, requestId);
        if (created.error || !created.id) {
          setError(created.error ?? "Nota belum dapat disiapkan. Coba lagi.");
          requestLock.current = false;
          return;
        }
        const linked = await linkPurchaseReceipt(created.id, receiptId);
        if (linked.error) {
          setError("Draf nota sudah dibuat tetapi belum terhubung. Coba lagi; stok tidak berubah.");
          requestLock.current = false;
          return;
        }
        sessionStorage.removeItem(key);
        router.refresh();
      } catch {
        setError("Status persiapan nota belum dapat dipastikan. Coba lagi; permintaan yang sama akan digunakan.");
        requestLock.current = false;
      }
    });
  }

  useEffect(() => {
    if (!autoStart || started.current) return;
    started.current = true;
    start();
    // The ref makes this one automatic attempt per mounted receipt workflow.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [autoStart, receiptId]);

  return <section className="purchase-finance-section">
    <h2>Nota Supplier</h2>
    <p><strong>{autoStart ? "Menyiapkan nota untuk barang ini…" : "Nota: Menunggu Nota."}</strong> Produk yang dipilih pada penerimaan digunakan otomatis. Barang tetap dapat diposting tanpa nota.</p>
    {error && <p role="alert" className="purchase-action-error">{error}</p>}
    {(!autoStart || error) && (hasItems || autoStart) ? <button type="button" className="purchase-primary" disabled={pending} onClick={start}>
      {pending ? "Menyiapkan nota…" : autoStart ? "Coba siapkan nota" : "Lengkapi Nota"}
    </button> : !autoStart && <p>Tambahkan barang penerimaan agar produk digunakan otomatis pada nota.</p>}
    <p className="purchase-operational-note">Jika nota belum tersedia, barang tetap dapat diposting. Stok hanya diposting melalui penerimaan.</p>
  </section>;
}
