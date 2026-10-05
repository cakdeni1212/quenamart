"use client";

import Link from "next/link";
import { useEffect, useRef } from "react";
import { formatReceiptQuantity } from "@/lib/purchasing/receipt-model";

type Summary = { itemCount: number; stockAdded: number };

export function ReceiptPostSuccess({ receiptId, reference }: { receiptId: string; reference: string }) {
  const summaryRef = useRef<HTMLParagraphElement>(null);
  useEffect(() => {
    const key = `quena:purchasing:POST_SUCCESS:${receiptId}`;
    const raw = window.sessionStorage.getItem(key);
    if (!raw) return;
    window.sessionStorage.removeItem(key);
    try {
      const value = JSON.parse(raw) as Partial<Summary>;
      if (Number.isSafeInteger(value.itemCount) && typeof value.stockAdded === "number" && Number.isFinite(value.stockAdded)) {
        if (summaryRef.current) summaryRef.current.textContent = `${value.itemCount} produk · stok bertambah ${formatReceiptQuantity(value.stockAdded)}`;
      }
    } catch { /* Ignore stale or malformed transient UI state. */ }
  }, [receiptId]);

  return <aside className="purchase-success-banner" role="status"><span aria-hidden="true">✓</span><div><strong>Barang masuk {reference} berhasil diposting</strong><p ref={summaryRef}>Penerimaan sudah tercatat dan menambah stok.</p></div><div className="purchase-banner-actions"><Link href={`/pembelian/barang-masuk/${receiptId}`}>Lihat detail</Link><Link href="/pembelian/barang-masuk/baru">Barang masuk baru</Link></div></aside>;
}
