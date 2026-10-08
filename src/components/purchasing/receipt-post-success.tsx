"use client";

import Link from "next/link";
import { useEffect, useRef } from "react";
import { formatReceiptQuantity } from "@/lib/purchasing/receipt-model";

type Summary = { itemCount: number; stockAdded: number; financial?: "COMPLETE" | "PENDING" | "SKIPPED" };

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
        if (summaryRef.current) {
          const operational = `${value.itemCount} produk · stok bertambah ${formatReceiptQuantity(value.stockAdded)}. `;
          const financial = value.financial === "COMPLETE"
            ? "Nota dan pembayaran berhasil dicatat."
            : value.financial === "PENDING"
              ? "Nota belum terkonfirmasi; lanjutkan dari detail barang masuk."
              : "Nota masih menunggu dilengkapi.";
          summaryRef.current.textContent = operational + financial;
        }
      }
    } catch { /* Ignore stale or malformed transient UI state. */ }
  }, [receiptId]);

  return <aside className="purchase-success-banner" role="status"><span aria-hidden="true">✓</span><div><strong>Barang masuk {reference} berhasil diposting</strong><p ref={summaryRef}>Penerimaan sudah tercatat dan menambah stok.</p></div><div className="purchase-banner-actions"><Link href={`/pembelian/barang-masuk/${receiptId}`}>Lihat detail</Link><Link href="/pembelian/barang-masuk/baru">Pembelian baru</Link></div></aside>;
}
