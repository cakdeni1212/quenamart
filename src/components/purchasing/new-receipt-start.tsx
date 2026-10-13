"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import type { Supplier } from "@/lib/purchasing/receipt-read";
import { createReceiptDraftForSupplier } from "@/lib/purchasing/actions";

export function NewReceiptStart({ suppliers, actorName, preselectedSupplierId = "" }: { suppliers: Supplier[]; actorName: string; preselectedSupplierId?: string }) {
  const router = useRouter();
  const requestLock = useRef(false);
  const [pending, startTransition] = useTransition();
  const [selectedSupplier, setSelectedSupplier] = useState("");
  const [error, setError] = useState("");
  const [uncertain, setUncertain] = useState(false);

  useEffect(() => {
    if (preselectedSupplierId && suppliers.some((supplier) => supplier.id === preselectedSupplierId)) selectSupplier(preselectedSupplierId);
    // Run only once for a validated query preselection.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [preselectedSupplierId]);

  function selectSupplier(supplierId: string) {
    setSelectedSupplier(supplierId);
    setError("");
    if (!supplierId || requestLock.current) return;
    requestLock.current = true;
    startTransition(async () => {
      try {
        const result = await createReceiptDraftForSupplier(supplierId);
        if (result.receiptId) {
          router.replace(`/pembelian/barang-masuk/baru?receipt=${encodeURIComponent(result.receiptId)}`);
          return;
        }
        setError(result.error ?? "Barang masuk belum dapat disiapkan.");
        setSelectedSupplier("");
        requestLock.current = false;
      } catch {
        setUncertain(true);
        setError("Penerimaan mungkin sudah disiapkan. Periksa daftar Barang Masuk sebelum mencoba lagi.");
        requestLock.current = false;
      }
    });
  }

  return <section className="surface-card purchase-auto-start">
    <label htmlFor="new-receipt-supplier">Supplier</label>
    <select id="new-receipt-supplier" value={selectedSupplier} disabled={pending || uncertain} onChange={(event) => selectSupplier(event.target.value)}>
      <option value="">Pilih supplier untuk mulai menerima barang</option>
      {suppliers.map((supplier) => <option key={supplier.id} value={supplier.id}>{supplier.display_name} · {supplier.supplier_code}</option>)}
    </select>
    <p className="purchase-actor-line">Diinput oleh <strong>{actorName}</strong> · menggunakan akun aktif</p>
    {pending && <p className="purchase-auto-start-status" role="status">Menyiapkan formulir penerimaan…</p>}
    {error && <p className="purchase-action-error" role="alert">{error} {uncertain && <Link href="/pembelian/barang-masuk">Buka daftar Barang Masuk</Link>}</p>}
  </section>;
}
