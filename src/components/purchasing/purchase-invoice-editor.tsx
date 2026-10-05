"use client";

import { useEffect, useMemo, useRef, useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { attachPurchaseInvoiceDocument, finalizePurchaseInvoice, linkPurchaseReceipt, recordSupplierPayment, savePurchaseInvoiceDraft, searchReceiptProducts, signPurchaseInvoiceDocument } from "@/lib/purchasing/actions";
import type { InvoiceDetailData } from "@/lib/purchasing/finance-read";
import { invoiceSystemTotal, invoiceTotalDifference } from "@/lib/purchasing/finance-model";

type Line = { productId: string; name: string; sku: string; quantity: string; unitPrice: string };
type SearchProduct = { id: string; name: string; sku: string; barcode: string | null };
const idr = (value: number) => new Intl.NumberFormat("id-ID", { style: "currency", currency: "IDR", maximumFractionDigits: 2 }).format(value);
const moneyNumber = (value: string) => Number.isFinite(Number(value)) ? Number(value) : 0;
const day = () => { const now = new Date(); return new Date(now.getTime() - now.getTimezoneOffset() * 60_000).toISOString().slice(0, 10); };

export function PurchaseInvoiceEditor({ invoice, linkableReceipts, initialReceiptId }: { invoice: InvoiceDetailData; linkableReceipts: Array<{ id: string; reference: string; status: "DRAFT" | "POSTED"; receivedAt: string }>; initialReceiptId?: string }) {
  const router = useRouter();
  const { header } = invoice;
  const editable = header.status === "DRAFT";
  const [invoiceNumber, setInvoiceNumber] = useState(header.invoice_number ?? "");
  const [invoiceDate, setInvoiceDate] = useState(header.invoice_date ?? day());
  const [dueDate, setDueDate] = useState(header.due_date ?? "");
  const [paymentType, setPaymentType] = useState<"CASH" | "TEMPO">(header.payment_type ?? "CASH");
  const [supplierTotal, setSupplierTotal] = useState(header.supplier_invoice_total === null ? "" : String(header.supplier_invoice_total));
  const [lines, setLines] = useState<Line[]>(invoice.items.map((item) => ({ productId: item.productId, name: item.name, sku: item.sku, quantity: String(item.quantity), unitPrice: String(item.unitPrice) })));
  const [query, setQuery] = useState(""); const [products, setProducts] = useState<SearchProduct[]>([]); const [searchPending, setSearchPending] = useState(false);
  const [initialPaid, setInitialPaid] = useState(header.payment_type === "CASH" ? String(header.supplier_invoice_total ?? "") : "0");
  const [initialPaidEdited, setInitialPaidEdited] = useState(false);
  const [paymentAmount, setPaymentAmount] = useState(""); const [paymentDate, setPaymentDate] = useState(day()); const [paymentMethod, setPaymentMethod] = useState<"CASH" | "TRANSFER" | "OTHER">("TRANSFER"); const [paymentNote, setPaymentNote] = useState("");
  const [dirty, setDirty] = useState(false);
  const [finalizeRetry, setFinalizeRetry] = useState(false);
  const [paymentRetry, setPaymentRetry] = useState(false);
  const finalizeLock = useRef(false);
  const paymentLock = useRef(false);
  const [error, setError] = useState(""); const [success, setSuccess] = useState(""); const [busy, startTransition] = useTransition();
  const systemTotal = useMemo(() => invoiceSystemTotal(lines.map((line) => ({ quantity: moneyNumber(line.quantity), purchaseUnitPrice: moneyNumber(line.unitPrice) }))), [lines]);
  const invoiceTotal = moneyNumber(supplierTotal); const difference = invoiceTotalDifference(systemTotal, invoiceTotal);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      const finalizeKey = `quena:purchasing:FINALIZE_INVOICE:${header.id}`;
      const paymentKey = `quena:purchasing:RECORD_PAYMENT:${header.id}`;
      if (!editable) { sessionStorage.removeItem(finalizeKey); setFinalizeRetry(false); }
      else setFinalizeRetry(Boolean(sessionStorage.getItem(finalizeKey)));
      if (!invoice.payable || invoice.payable.outstanding <= 0) { sessionStorage.removeItem(paymentKey); setPaymentRetry(false); }
      else setPaymentRetry(Boolean(sessionStorage.getItem(paymentKey)));
    }, 0);
    return () => window.clearTimeout(timer);
  }, [header.id, editable, invoice.payable]);

  async function search() { if (query.trim().length < 2) return; setSearchPending(true); const result = await searchReceiptProducts(query.trim()); setProducts(result.rows); setSearchPending(false); if (result.error) setError(result.error); }
  function addProduct(product: SearchProduct) { if (lines.some((line) => line.productId === product.id)) { setError("Produk sudah ada di nota."); return; } setDirty(true); setLines((rows) => [...rows, { productId: product.id, name: product.name, sku: product.sku, quantity: "1", unitPrice: "0" }]); setQuery(""); setProducts([]); }
  async function saveDraft() {
    if (busy) return; setError(""); setSuccess("");
    startTransition(async () => { const result = await savePurchaseInvoiceDraft(header.id, header.draft_revision, { invoiceNumber, invoiceDate, dueDate: dueDate || null, paymentType, supplierTotal: invoiceTotal, items: lines.map((line) => ({ product_id: line.productId, invoice_quantity: moneyNumber(line.quantity), purchase_unit_price: moneyNumber(line.unitPrice) })) });
      if (result.error) { setError(result.error); return; } setDirty(false); setSuccess("Draf nota tersimpan."); router.refresh(); });
  }
  async function finalize() {
    if (busy || finalizeLock.current || dirty) { if (dirty) setError("Simpan perubahan nota sebelum finalisasi."); return; }
    const paid = moneyNumber(initialPaid);
    if (!window.confirm("Finalisasi nota akan mencatat nilai tagihan supplier. Ini tidak mengubah atau memposting stok. Lanjutkan?")) return;
    setError(""); setSuccess("");
    finalizeLock.current = true;
    startTransition(async () => {
      const key = `quena:purchasing:FINALIZE_INVOICE:${header.id}`;
      try {
        let stored: { requestId: string; revision: number; input: { initialPaid: number; paymentMethod: string | null; paymentDate: string | null; paymentNote: string | null } } | null = null;
        try { stored = JSON.parse(sessionStorage.getItem(key) ?? "null"); } catch { stored = null; }
        if (!stored?.requestId) {
          const requestId = crypto.randomUUID();
          stored = { requestId, revision: header.draft_revision, input: { initialPaid: paid, paymentMethod: paid > 0 ? paymentMethod : null, paymentDate: paid > 0 ? paymentDate : null, paymentNote: paid > 0 ? paymentNote || null : null } };
          sessionStorage.setItem(key, JSON.stringify(stored));
        }
        const result = await finalizePurchaseInvoice(header.id, stored.requestId, stored.revision, stored.input);
        if (result.error) { if (result.terminal) { sessionStorage.removeItem(key); setFinalizeRetry(false); } else setFinalizeRetry(true); setError(result.error); if (result.terminal) router.refresh(); return; }
        if (!result.result) { setFinalizeRetry(true); setError("Hasil belum dapat dipastikan. Ulangi finalisasi dengan permintaan yang sama."); return; }
        sessionStorage.removeItem(key); setFinalizeRetry(false);
        if (!result.result.ok) { setError("Nota berubah atau tidak lagi dapat difinalisasi. Muat ulang halaman."); router.refresh(); return; }
        setSuccess("Nota difinalisasi. Tagihan dan pembayaran awal tercatat; stok tidak berubah."); router.refresh();
      } finally { finalizeLock.current = false; }
    });
  }
  async function upload(file: File | undefined) {
    if (!file) return;
    const allowed = ["image/jpeg", "image/png", "image/webp", "application/pdf"];
    if (!allowed.includes(file.type) || file.size > 10 * 1024 * 1024) { setError("Gunakan JPG, PNG, WEBP, atau PDF maksimal 10 MB."); return; }
    setError(""); setSuccess("");
    const extension = file.type === "image/jpeg" ? "jpg" : file.type === "application/pdf" ? "pdf" : file.type.split("/")[1];
    const path = `invoices/${header.id}/${crypto.randomUUID()}.${extension}`;
    const client = createClient();
    const { error: uploadError } = await client.storage.from("quena-purchasing-invoices").upload(path, file, { contentType: file.type, upsert: false });
    if (uploadError) { setError("Foto nota belum dapat diunggah."); return; }
    const attached = await attachPurchaseInvoiceDocument(header.id, path);
    if (attached.error) { setError(attached.error); return; }
    setSuccess("Dokumen nota tersimpan secara privat."); router.refresh();
  }
  async function openDocument(path: string) { const result = await signPurchaseInvoiceDocument(path); if (result.url) window.open(result.url, "_blank", "noopener,noreferrer"); else setError("Dokumen tidak dapat dibuka."); }
  async function pay() {
    if (busy || paymentLock.current || !invoice.payable || moneyNumber(paymentAmount) <= 0) return;
    setError(""); setSuccess("");
    paymentLock.current = true;
    startTransition(async () => {
      const key = `quena:purchasing:RECORD_PAYMENT:${header.id}`;
      try {
        let stored: { requestId: string; date: string; amount: number; method: "CASH" | "TRANSFER" | "OTHER"; reference: string | null; payableId: string } | null = null;
        try { stored = JSON.parse(sessionStorage.getItem(key) ?? "null"); } catch { stored = null; }
        if (!stored?.requestId) { stored = { requestId: crypto.randomUUID(), date: paymentDate, amount: moneyNumber(paymentAmount), method: paymentMethod, reference: paymentNote || null, payableId: invoice.payable!.id }; sessionStorage.setItem(key, JSON.stringify(stored)); }
        const result = await recordSupplierPayment(stored.requestId, header.supplier_id, header.outlet_id, stored.date, stored.amount, stored.method, stored.reference, [{ payable_id: stored.payableId, amount: stored.amount }]);
        if (result.error) { if (result.terminal) { sessionStorage.removeItem(key); setPaymentRetry(false); } else setPaymentRetry(true); setError(result.error); if (result.terminal) router.refresh(); return; }
        if (!result.result) { setPaymentRetry(true); setError("Hasil pembayaran belum dapat dipastikan. Ulangi dengan permintaan yang sama."); return; }
        sessionStorage.removeItem(key); setPaymentRetry(false); if (!result.result.ok) { setError("Pembayaran tidak dapat dicatat. Muat ulang status nota."); router.refresh(); return; }
        setPaymentAmount(""); setPaymentNote(""); setSuccess("Pembayaran tercatat. Stok tidak berubah."); router.refresh();
      } finally { paymentLock.current = false; }
    });
  }
  async function toggleReceipt(receiptId: string, linked: boolean) { const result = await linkPurchaseReceipt(header.id, receiptId, !linked); if (result.error) setError(result.error); else router.refresh(); }

  return <section className="purchase-invoice-editor surface-card">
    <header className="purchase-detail-header"><div><div className="eyebrow">NOTA SUPPLIER</div><h1>{header.invoice_number || header.invoice_reference}</h1><p>{header.supplier.name} · {header.outlet}</p></div><span className={`purchase-status purchase-status-${header.status.toLowerCase()}`}>{header.status === "FINALIZED" ? "Final" : "Draf"}</span></header>
    <p className="purchase-actor-line">Diinput oleh {header.createdByName} · {new Intl.DateTimeFormat("id-ID", { dateStyle: "medium", timeStyle: "short" }).format(new Date(header.created_at))}{header.finalizedByName && header.finalized_at ? ` · Difinalisasi oleh ${header.finalizedByName}` : ""}</p>
    {error && <p role="alert" className="purchase-action-error">{error}</p>}{success && <p role="status" className="purchase-action-success">{success}</p>}
    <section className="purchase-finance-section"><h2>Nota pembelian</h2>
      {editable ? <>
        <div className="purchase-fields"><label>Nomor nota supplier<input value={invoiceNumber} onChange={(e) => { setInvoiceNumber(e.target.value); setDirty(true); }} maxLength={120} /></label><label>Tanggal nota<input type="date" value={invoiceDate} onChange={(e) => { setInvoiceDate(e.target.value); setDirty(true); }} /></label><label>Jenis pembayaran<select value={paymentType} onChange={(e) => { const next = e.target.value as "CASH" | "TEMPO"; setPaymentType(next); if (!initialPaidEdited) setInitialPaid(next === "CASH" ? supplierTotal : "0"); setDirty(true); }}><option value="CASH">Cash</option><option value="TEMPO">Tempo</option></select></label>{paymentType === "TEMPO" && <label>Jatuh tempo<input type="date" required value={dueDate} onChange={(e) => { setDueDate(e.target.value); setDirty(true); }} /></label>}<label>Total pada nota supplier<input type="number" min="0" step="0.01" value={supplierTotal} onChange={(e) => { setSupplierTotal(e.target.value); if (paymentType === "CASH" && !initialPaidEdited) setInitialPaid(e.target.value); setDirty(true); }} /></label></div>
        <div className="purchase-product-search"><label htmlFor="invoice-product-search">Tambah produk dalam nota</label><div className="purchase-search-row"><input id="invoice-product-search" value={query} onChange={(e) => setQuery(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); void search(); } }} placeholder="Nama produk atau SKU"/><button type="button" className="purchase-filter-submit" onClick={() => void search()} disabled={searchPending}>{searchPending ? "Mencari…" : "Cari"}</button></div>{products.length > 0 && <ul className="purchase-search-results">{products.map((p) => <li key={p.id}><button type="button" onClick={() => addProduct(p)}><strong>{p.name}</strong><span>{p.sku}</span></button></li>)}</ul>}</div>
        <div className="purchase-invoice-lines"><table className="purchase-receipt-table"><thead><tr><th>Produk</th><th>Qty nota</th><th>Harga satuan</th><th>Subtotal</th><th></th></tr></thead><tbody>{lines.map((line) => <tr key={line.productId}><td>{line.name}<small>{line.sku}</small></td><td><input aria-label={`Kuantitas nota ${line.name}`} type="number" min="0.001" step="0.001" value={line.quantity} onChange={(e) => { setDirty(true); setLines((old) => old.map((v) => v.productId === line.productId ? { ...v, quantity: e.target.value } : v)); }}/></td><td><input aria-label={`Harga satuan ${line.name}`} type="number" min="0" step="0.01" value={line.unitPrice} onChange={(e) => { setDirty(true); setLines((old) => old.map((v) => v.productId === line.productId ? { ...v, unitPrice: e.target.value } : v)); }}/></td><td>{idr(Math.round(moneyNumber(line.quantity) * moneyNumber(line.unitPrice) * 100) / 100)}</td><td><button type="button" className="purchase-remove" onClick={() => { setDirty(true); setLines((old) => old.filter((v) => v.productId !== line.productId)); }}>Hapus</button></td></tr>)}</tbody></table></div>
        <div className="purchase-invoice-totals"><div><span>Total Sistem</span><strong>{idr(systemTotal)}</strong></div><div><span>Total Nota Supplier</span><strong>{supplierTotal === "" ? "—" : idr(invoiceTotal)}</strong></div><div className={difference === 0 ? "purchase-total-match" : "purchase-total-difference"}><span>{difference === 0 ? "✓ Cocok" : "⚠ Selisih"}</span><strong>{idr(difference)}</strong></div></div>
        <button type="button" className="purchase-secondary" disabled={busy} onClick={() => void saveDraft()}>Simpan nota</button>
        <section className="purchase-finance-subsection"><h3>Pembayaran saat finalisasi</h3><p>Nilai nota menjadi tagihan saat difinalisasi. Pembayaran tidak mengubah stok.</p><div className="purchase-fields"><label>Sudah dibayar<input type="number" min="0" step="0.01" max={invoiceTotal} value={initialPaid} onChange={(e) => { setInitialPaid(e.target.value); setInitialPaidEdited(true); }} /></label>{moneyNumber(initialPaid) > 0 && <><label>Tanggal pembayaran<input type="date" value={paymentDate} onChange={(e) => setPaymentDate(e.target.value)} /></label><label>Metode<select value={paymentMethod} onChange={(e) => setPaymentMethod(e.target.value as "CASH" | "TRANSFER" | "OTHER")}><option value="CASH">Tunai</option><option value="TRANSFER">Transfer</option><option value="OTHER">Lainnya</option></select></label><label>Referensi / catatan<input value={paymentNote} onChange={(e) => setPaymentNote(e.target.value)} maxLength={300}/></label></>}</div></section>
        <button type="button" className={finalizeRetry ? "purchase-retry" : "purchase-post-button"} disabled={busy || dirty || !invoiceNumber || !supplierTotal || lines.length === 0} onClick={() => void finalize()}>{finalizeRetry ? "Ulangi finalisasi dengan permintaan yang sama" : "Finalisasi Nota & Catat Tagihan"}</button>
      </> : <>
        <div className="purchase-result-meta"><div><span>Nomor nota</span><strong>{header.invoice_number ?? "—"}</strong></div><div><span>Tanggal nota</span><strong>{header.invoice_date ?? "—"}</strong></div><div><span>Jenis pembayaran</span><strong>{header.payment_type === "TEMPO" ? "Tempo" : "Cash"}</strong></div><div><span>Jatuh tempo</span><strong>{header.due_date ?? "—"}</strong></div><div><span>Total Sistem</span><strong>{idr(invoice.items.reduce((sum, item) => sum + item.subtotal, 0))}</strong></div><div><span>Total Nota Supplier</span><strong>{idr(header.supplier_invoice_total ?? 0)}</strong></div></div>
        <div className="purchase-invoice-totals"><div><span>Total Sistem</span><strong>{idr(invoice.items.reduce((sum, item) => sum + item.subtotal, 0))}</strong></div><div><span>Total Nota Supplier</span><strong>{idr(header.supplier_invoice_total ?? 0)}</strong></div><div className={invoiceTotalDifference(invoice.items.reduce((sum, item) => sum + item.subtotal, 0), header.supplier_invoice_total ?? 0) === 0 ? "purchase-total-match" : "purchase-total-difference"}><span>{invoiceTotalDifference(invoice.items.reduce((sum, item) => sum + item.subtotal, 0), header.supplier_invoice_total ?? 0) === 0 ? "✓ Cocok" : "⚠ Selisih"}</span><strong>{idr(invoiceTotalDifference(invoice.items.reduce((sum, item) => sum + item.subtotal, 0), header.supplier_invoice_total ?? 0))}</strong></div></div>
        <div className="purchase-posted-table-wrap"><table className="purchase-posted-table"><thead><tr><th>Produk</th><th>Qty nota</th><th>Harga satuan</th><th>Subtotal</th></tr></thead><tbody>{invoice.items.map((line) => <tr key={line.id}><td><strong>{line.name}</strong><span>{line.sku}</span></td><td>{line.quantity}</td><td>{idr(line.unitPrice)}</td><td>{idr(line.subtotal)}</td></tr>)}</tbody></table></div>
        <div className="purchase-finance-subsection"><h3>Pembayaran</h3><p>Status: <strong>{invoice.payable?.status ?? "Lunas"}</strong> · Dibayar {idr(invoice.payable?.paid ?? 0)} · Sisa {idr(invoice.payable?.outstanding ?? 0)}</p>
          {invoice.payable && invoice.payable.outstanding > 0 && <div className="purchase-fields">{!paymentRetry && <><label>Jumlah pembayaran<input type="number" min="0.01" max={invoice.payable.outstanding} step="0.01" value={paymentAmount} onChange={(e) => setPaymentAmount(e.target.value)}/></label><label>Tanggal pembayaran<input type="date" value={paymentDate} onChange={(e) => setPaymentDate(e.target.value)}/></label><label>Metode<select value={paymentMethod} onChange={(e) => setPaymentMethod(e.target.value as "CASH" | "TRANSFER" | "OTHER")}><option value="CASH">Tunai</option><option value="TRANSFER">Transfer</option><option value="OTHER">Lainnya</option></select></label><label>Referensi / catatan<input value={paymentNote} onChange={(e) => setPaymentNote(e.target.value)} maxLength={300}/></label></>}<button type="button" className={paymentRetry ? "purchase-retry" : "purchase-primary"} disabled={busy || (!paymentAmount && !paymentRetry)} onClick={() => void pay()}>{paymentRetry ? "Ulangi pembayaran dengan permintaan yang sama" : "Catat pembayaran"}</button></div>}
          <ol className="purchase-payment-history">{invoice.payments.map((payment) => <li key={payment.id}><strong>{idr(payment.amount)}</strong><span>{payment.date} · {payment.method} · dicatat {payment.recordedByName}</span></li>)}</ol>
        </div>
      </>}
    </section>
    <section className="purchase-finance-section"><h2>Hubungkan barang masuk</h2><p>Satu nota dapat terkait dengan beberapa penerimaan supplier/outlet yang sama.</p>
      {initialReceiptId && invoice.receipts.some((receipt) => receipt.id === initialReceiptId) && <p role="status">Penerimaan barang berhasil dihubungkan ke nota ini.</p>}
      {invoice.receipts.map((receipt) => <div className="purchase-linked-receipt" key={receipt.id}><Link href={`/pembelian/barang-masuk/${receipt.id}`}>{receipt.reference} · {receipt.status === "POSTED" ? "Diposting" : "Draf"}</Link>{editable && <button type="button" className="purchase-remove" onClick={() => void toggleReceipt(receipt.id, true)}>Lepas</button>}</div>)}
      {linkableReceipts.filter((receipt) => !invoice.receipts.some((linked) => linked.id === receipt.id)).map((receipt) => <div className="purchase-linked-receipt" key={receipt.id}><span>{receipt.reference} · {receipt.status === "POSTED" ? "Diposting" : "Draf"}</span><button type="button" className="purchase-secondary" onClick={() => void toggleReceipt(receipt.id, false)}>Hubungkan</button></div>)}
    </section>
    <section className="purchase-finance-section"><h2>Foto nota</h2><p>Dokumen hanya dapat dibuka OWNER/ADMIN melalui tautan privat yang kedaluwarsa.</p><label className="purchase-upload-control">Ambil foto / pilih file<input type="file" accept="image/jpeg,image/png,image/webp,application/pdf" capture="environment" onChange={(e) => void upload(e.currentTarget.files?.[0])}/></label>
      {invoice.documents.map((document) => <button type="button" className="purchase-secondary" key={document.id} onClick={() => void openDocument(document.path)}>Buka nota · {document.uploadedAt.slice(0,10)} · diunggah {document.uploadedByName}</button>)}</section>
    {invoice.events.length > 0 && <section className="purchase-timeline"><h2>Riwayat nota</h2><ol>{invoice.events.map((event, index) => <li key={`${event.at}-${index}`}><strong>{event.type.replaceAll("_", " ")}</strong><span>{event.actorName}</span><time>{new Intl.DateTimeFormat("id-ID", { dateStyle: "medium", timeStyle: "short" }).format(new Date(event.at))}</time></li>)}</ol></section>}
    <p className="purchase-operational-note">Nota/pembayaran tidak memposting stok dan tidak memperbarui HPP. Stok bertambah satu kali melalui Barang Masuk.</p>
  </section>;
}
