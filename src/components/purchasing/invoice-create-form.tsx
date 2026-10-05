"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { createPurchaseInvoiceDraft, linkPurchaseReceipt } from "@/lib/purchasing/actions";

type Supplier = { id: string; display_name: string; supplier_code: string };
type Receipt = { id: string; reference: string; status: string; receivedAt: string };

export function InvoiceCreateForm({ suppliers, outletId, initialSupplierId, receiptId, receipts }: {
  suppliers: Supplier[]; outletId: string | null; initialSupplierId?: string; receiptId?: string; receipts: Receipt[];
}) {
  const router = useRouter();
  const [supplierId, setSupplierId] = useState(initialSupplierId ?? "");
  const [error, setError] = useState("");
  const [pending, startTransition] = useTransition();
  function create() {
    if (pending || !supplierId || !outletId) return;
    setError("");
    startTransition(async () => {
      const key = `quena:purchasing:CREATE_INVOICE:${supplierId}:${receiptId ?? "new"}`;
      let requestId = sessionStorage.getItem(key);
      if (!requestId) { requestId = crypto.randomUUID(); sessionStorage.setItem(key, requestId); }
      const result = await createPurchaseInvoiceDraft(supplierId, requestId);
      if (result.error || !result.id) { setError(result.error ?? "Nota belum dapat dibuat. Coba lagi."); return; }
      if (receiptId) {
        const linked = await linkPurchaseReceipt(result.id, receiptId);
        if (linked.error) { setError(`Draf nota dibuat, tetapi penerimaan belum tertaut. Buka nota untuk melanjutkan. ${linked.error}`); router.push(`/pembelian/nota/${result.id}`); return; }
      }
      sessionStorage.removeItem(key);
      router.push(`/pembelian/nota/${result.id}`);
    });
  }
  return <section className="surface-card purchase-create-form">
    <label>Supplier<select required value={supplierId} onChange={(event) => setSupplierId(event.target.value)}><option value="">Pilih supplier</option>{suppliers.map((supplier) => <option key={supplier.id} value={supplier.id}>{supplier.display_name} · {supplier.supplier_code}</option>)}</select></label>
    {receiptId && <label>Penerimaan barang<select disabled value={receiptId}><option value={receiptId}>{receipts.find((receipt) => receipt.id === receiptId)?.reference ?? "Barang masuk"}</option></select></label>}
    {error && <p className="purchase-action-error" role="alert">{error}</p>}
    <button className="purchase-primary" type="button" disabled={pending || !supplierId || !outletId} onClick={create}>{pending ? "Membuat nota…" : "Buat draf nota"}</button>
  </section>;
}
