"use client";

import { useEffect, useMemo, useRef, useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { attachPurchaseInvoiceDocument, finalizePurchaseInvoice, linkPurchaseReceipt, recordSupplierPayment, savePurchaseInvoiceDraft, searchReceiptProducts, signPurchaseInvoiceDocument } from "@/lib/purchasing/actions";
import type { InvoiceDetailData } from "@/lib/purchasing/finance-read";
import { invoiceSystemTotal, invoiceTotalDifference } from "@/lib/purchasing/finance-model";
import { useReceiptFinance } from "@/components/purchasing/receipt-finance-context";
import { RupiahInput } from "@/components/ui/rupiah-input";
import type { ReceiptInvoiceLine } from "@/lib/purchasing/receipt-model";

type Line = ReceiptInvoiceLine;
type SearchProduct = { id: string; name: string; sku: string; barcode: string | null };
export type ReceiptInvoiceSeedItem = { productId: string; name: string; sku: string; acceptedQuantity: number };
export type ReceiptInvoicePostHooks = { beforePost: () => Promise<boolean>; afterPost: () => Promise<"COMPLETE" | "PENDING" | "SKIPPED"> };
const idr = (value: number) => new Intl.NumberFormat("id-ID", { style: "currency", currency: "IDR", maximumFractionDigits: 2 }).format(value);
const moneyNumber = (value: string) => Number.isFinite(Number(value)) ? Number(value) : 0;
const day = () => { const now = new Date(); return new Date(now.getTime() - now.getTimezoneOffset() * 60_000).toISOString().slice(0, 10); };

export function PurchaseInvoiceEditor({ invoice, linkableReceipts, initialReceiptId, embedded = false, allowStandaloneFinalize = false, receiptId, seedItems = [], defaultInvoiceDate, onRegisterPostHooks }: { invoice: InvoiceDetailData; linkableReceipts: Array<{ id: string; reference: string; status: "DRAFT" | "POSTED"; receivedAt: string }>; initialReceiptId?: string; embedded?: boolean; allowStandaloneFinalize?: boolean; receiptId?: string; seedItems?: ReceiptInvoiceSeedItem[]; defaultInvoiceDate?: string; onRegisterPostHooks?: (hooks: ReceiptInvoicePostHooks | null) => void }) {
  const router = useRouter();
  const { header } = invoice;
  const editable = header.status === "DRAFT";
  const [invoiceNumber, setInvoiceNumber] = useState(header.invoice_number ?? "");
  const [invoiceDate, setInvoiceDate] = useState(header.invoice_date ?? defaultInvoiceDate ?? day());
  const [dueDate, setDueDate] = useState(header.due_date ?? "");
  const [paymentType, setPaymentType] = useState<"CASH" | "TEMPO">(header.payment_type ?? "CASH");
  const [supplierTotal, setSupplierTotal] = useState(header.supplier_invoice_total === null ? "" : String(header.supplier_invoice_total));
  const invoiceRevisionRef = useRef(header.draft_revision);
  const [lines, setLines] = useState<Line[]>(() => invoice.items.length
    ? invoice.items.map((item) => ({ productId: item.productId, name: item.name, sku: item.sku, quantity: String(item.quantity), unitPrice: String(item.unitPrice), priceSource: null }))
    : header.status === "DRAFT" ? seedItems.map((item) => ({ productId: item.productId, name: item.name, sku: item.sku, quantity: item.acceptedQuantity > 0 ? String(item.acceptedQuantity) : "", unitPrice: "", priceSource: null })) : []);
  const receiptFinance = useReceiptFinance();
  const activeLines = embedded && receiptFinance ? receiptFinance.lines : lines;
  function updateLines(next: Line[] | ((current: Line[]) => Line[])) {
    if (embedded && receiptFinance) receiptFinance.setLines(next);
    else setLines(next);
  }
  const [query, setQuery] = useState(""); const [products, setProducts] = useState<SearchProduct[]>([]); const [searchPending, setSearchPending] = useState(false);
  const [initialPaid, setInitialPaid] = useState(header.payment_type === "CASH" ? String(header.supplier_invoice_total ?? "") : "0");
  const [initialPaidEdited, setInitialPaidEdited] = useState(false);
  const [paymentAmount, setPaymentAmount] = useState(""); const [paymentDate, setPaymentDate] = useState(day()); const [paymentMethod, setPaymentMethod] = useState<"CASH" | "TRANSFER" | "OTHER">("TRANSFER"); const [paymentNote, setPaymentNote] = useState("");
  const [dirty, setDirty] = useState(() => header.status === "DRAFT" && invoice.items.length === 0 && seedItems.length > 0);
  const [finalizeRetry, setFinalizeRetry] = useState(false);
  const [paymentRetry, setPaymentRetry] = useState(false);
  const [notaUnavailable, setNotaUnavailable] = useState(false);
  const finalizeLock = useRef(false);
  const paymentLock = useRef(false);
  const [error, setError] = useState(""); const [success, setSuccess] = useState(""); const [busy, startTransition] = useTransition();
  const persistedLines = useRef(JSON.stringify(invoice.items.map((item) => ({ productId: item.productId, quantity: String(item.quantity), unitPrice: String(item.unitPrice) }))));
  const systemTotal = useMemo(() => invoiceSystemTotal(activeLines.map((line) => ({ quantity: moneyNumber(line.quantity), purchaseUnitPrice: moneyNumber(line.unitPrice) }))), [activeLines]);
  const financeLinesComplete = activeLines.length > 0 && activeLines.every((line) => line.quantity.trim() !== "" && line.unitPrice.trim() !== "");
  const invoiceComparisonReady = financeLinesComplete && supplierTotal.trim() !== "";
  const invoiceTotal = moneyNumber(supplierTotal); const difference = invoiceTotalDifference(systemTotal, invoiceTotal);
  function isNotaUnavailable() {
    return notaUnavailable || Boolean(embedded && receiptId && sessionStorage.getItem(`quena:purchasing:NOTA_MISSING:${receiptId}`) === "1");
  }

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

  useEffect(() => {
    if (!embedded || !receiptId) return;
    const timer = window.setTimeout(() => { const missing = sessionStorage.getItem(`quena:purchasing:NOTA_MISSING:${receiptId}`) === "1"; setNotaUnavailable(missing); receiptFinance?.setNotaUnavailable(missing); }, 0);
    return () => window.clearTimeout(timer);
  }, [embedded, receiptId, receiptFinance]);

  useEffect(() => {
    if (!embedded) return;
    const current = JSON.stringify(activeLines.map((line) => ({ productId: line.productId, quantity: line.quantity, unitPrice: line.unitPrice })));
    if (current !== persistedLines.current) setDirty(true);
  }, [embedded, activeLines]);

  async function search() { if (query.trim().length < 2) return; setSearchPending(true); const result = await searchReceiptProducts(query.trim()); setProducts(result.rows); setSearchPending(false); if (result.error) setError(result.error); }
  function addProduct(product: SearchProduct) { if (activeLines.some((line) => line.productId === product.id)) { setError("Produk sudah ada di nota."); return; } setDirty(true); updateLines((rows) => [...rows, { productId: product.id, name: product.name, sku: product.sku, quantity: "1", unitPrice: "0", priceSource: null }]); setQuery(""); setProducts([]); }
  async function saveDraft() {
    if (busy) return; setError(""); setSuccess("");
    startTransition(async () => { const message = await saveInvoiceDraftNow(); if (message) setError(message); else setSuccess("Draf pembelian tersimpan."); });
  }
  async function saveInvoiceDraftNow(refreshAfterSave = true): Promise<string | null> {
    if (activeLines.some((line) => !line.quantity.trim() || !line.unitPrice.trim())) return "Isi harga beli setiap produk pada daftar barang.";
    const result = await savePurchaseInvoiceDraft(header.id, invoiceRevisionRef.current, { invoiceNumber, invoiceDate, dueDate: dueDate || null, paymentType, supplierTotal: invoiceTotal, items: activeLines.map((line) => ({ product_id: line.productId, invoice_quantity: moneyNumber(line.quantity), purchase_unit_price: moneyNumber(line.unitPrice) })) });
    if (result.error) return result.error;
    const nextRevision = result.revision ?? invoiceRevisionRef.current + 1;
    invoiceRevisionRef.current = nextRevision;
    persistedLines.current = JSON.stringify(activeLines.map((line) => ({ productId: line.productId, quantity: line.quantity, unitPrice: line.unitPrice })));
    setDirty(false);
    if (refreshAfterSave) router.refresh();
    return null;
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
        stored = { requestId, revision: invoiceRevisionRef.current, input: { initialPaid: paid, paymentMethod: paid > 0 ? paymentMethod : null, paymentDate: paid > 0 ? paymentDate : null, paymentNote: paid > 0 ? paymentNote || null : null } };
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

  async function beforeReceiptPost() {
    if (!editable || isNotaUnavailable()) return true;
    if (!invoiceNumber.trim() || !supplierTotal || activeLines.length === 0
      || activeLines.some((line) => !line.quantity || !line.unitPrice)
      || (paymentType === "TEMPO" && !dueDate)
      || moneyNumber(initialPaid) > invoiceTotal) {
      setError("Lengkapi data nota dan pembayaran, atau pilih Nota belum tersedia. Barang tetap dapat diposting tanpa nota.");
      return false;
    }
    if (dirty) {
      const saveError = await saveInvoiceDraftNow(false);
      if (saveError) { setError(`Nota belum dapat disiapkan untuk posting. ${saveError}`); return false; }
    }
    return true;
  }

  async function finalizeAfterReceipt(): Promise<"COMPLETE" | "PENDING" | "SKIPPED"> {
    if (!editable) return "COMPLETE";
    if (isNotaUnavailable()) return "SKIPPED";
      if (!(await beforeReceiptPost()) || finalizeLock.current) return "PENDING";
    finalizeLock.current = true;
    const key = `quena:purchasing:FINALIZE_INVOICE:${header.id}`;
    try {
      let stored: { requestId: string; revision: number; input: { initialPaid: number; paymentMethod: string | null; paymentDate: string | null; paymentNote: string | null } } | null = null;
      try { stored = JSON.parse(sessionStorage.getItem(key) ?? "null"); } catch { stored = null; }
      if (!stored?.requestId) {
        stored = { requestId: crypto.randomUUID(), revision: invoiceRevisionRef.current, input: { initialPaid: moneyNumber(initialPaid), paymentMethod: moneyNumber(initialPaid) > 0 ? paymentMethod : null, paymentDate: moneyNumber(initialPaid) > 0 ? paymentDate : null, paymentNote: moneyNumber(initialPaid) > 0 ? paymentNote || null : null } };
        sessionStorage.setItem(key, JSON.stringify(stored));
      }
      const result = await finalizePurchaseInvoice(header.id, stored.requestId, stored.revision, stored.input);
      if (result.error) {
        if (result.terminal) sessionStorage.removeItem(key);
        else setFinalizeRetry(true);
        setError(`Stok berhasil diposting, tetapi nota belum terkonfirmasi. Buka detail barang masuk untuk menyelesaikan nota. ${result.error}`);
        return "PENDING";
      }
      if (!result.result) { setFinalizeRetry(true); setError("Stok berhasil diposting; hasil nota belum pasti. Coba lagi dari detail dengan permintaan yang sama."); return "PENDING"; }
      sessionStorage.removeItem(key); setFinalizeRetry(false);
      if (!result.result.ok) { setError("Stok berhasil diposting, tetapi nota perlu diperiksa kembali dari detail barang masuk."); router.refresh(); return "PENDING"; }
      setSuccess("Stok, nota, dan pembayaran berhasil dicatat.");
      return "COMPLETE";
    } finally { finalizeLock.current = false; }
  }

  useEffect(() => {
    if (!onRegisterPostHooks) return;
    onRegisterPostHooks({ beforePost: beforeReceiptPost, afterPost: finalizeAfterReceipt });
    return () => onRegisterPostHooks(null);
  });
  useEffect(() => { receiptFinance?.registerInvoiceDraftSaver(editable ? saveInvoiceDraftNow : null); return () => receiptFinance?.registerInvoiceDraftSaver(null); });
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

  return <section className={`purchase-invoice-editor ${embedded ? "purchase-invoice-embedded" : "surface-card"}`}>
    {!embedded && <header className="purchase-detail-header"><div><div className="eyebrow">NOTA SUPPLIER</div><h1>{header.invoice_number || header.invoice_reference}</h1><p>{header.supplier.name} · {header.outlet}</p></div><span className={`purchase-status purchase-status-${header.status.toLowerCase()}`}>{header.status === "FINALIZED" ? "Final" : header.status === "CANCELLED" ? "Dibatalkan" : "Draf"}</span></header>}
    <p className="purchase-actor-line">Diinput oleh {header.createdByName} · {new Intl.DateTimeFormat("id-ID", { dateStyle: "medium", timeStyle: "short" }).format(new Date(header.created_at))}{header.finalizedByName && header.finalized_at ? ` · Difinalisasi oleh ${header.finalizedByName}` : ""}</p>
    {error && <p role="alert" className="purchase-action-error">{error}</p>}{success && <p role="status" className="purchase-action-success">{success}</p>}
    <section className="purchase-finance-section purchase-finance-workspace"><h2>Nota &amp; Pembayaran</h2>
      <div className="purchase-finance-subheading"><h3>Nota Supplier</h3></div>
      {editable ? <>
        {embedded && <div className="purchase-nota-choice" role="group" aria-label="Ketersediaan nota"><button type="button" aria-pressed={!notaUnavailable} onClick={() => { setNotaUnavailable(false); receiptFinance?.setNotaUnavailable(false); if (receiptId) sessionStorage.setItem(`quena:purchasing:NOTA_MISSING:${receiptId}`, "0"); }}>Ada Nota</button><button type="button" aria-pressed={notaUnavailable} onClick={() => { setNotaUnavailable(true); receiptFinance?.setNotaUnavailable(true); if (receiptId) sessionStorage.setItem(`quena:purchasing:NOTA_MISSING:${receiptId}`, "1"); }}>Belum Ada Nota</button></div>}
        {embedded && notaUnavailable && <p className="purchase-missing-invoice-state"><strong>MENUNGGU NOTA</strong><span>Barang tetap dapat diposting. Nota dapat dilengkapi kemudian.</span></p>}
        <div className="purchase-fields" hidden={embedded && notaUnavailable}><label>Nomor nota supplier<input value={invoiceNumber} onChange={(e) => { setInvoiceNumber(e.target.value); setDirty(true); }} maxLength={120} /></label><label>Tanggal nota<input type="date" value={invoiceDate} onChange={(e) => { setInvoiceDate(e.target.value); setDirty(true); }} /></label><label>Jenis pembayaran<select value={paymentType} onChange={(e) => { const next = e.target.value as "CASH" | "TEMPO"; setPaymentType(next); if (!initialPaidEdited) setInitialPaid(next === "CASH" ? supplierTotal : "0"); setDirty(true); }}><option value="CASH">Cash</option><option value="TEMPO">Tempo</option></select></label>{paymentType === "TEMPO" && <label>Jatuh tempo<input type="date" required value={dueDate} onChange={(e) => { setDueDate(e.target.value); setDirty(true); }} /></label>}<label>Total pada nota supplier<RupiahInput value={supplierTotal} onValueChange={(value) => { setSupplierTotal(value); if (paymentType === "CASH" && !initialPaidEdited) setInitialPaid(value); setDirty(true); }} placeholder="0" aria-label="Total pada nota supplier Rupiah" /></label></div>
        {!embedded && <div className="purchase-product-search"><label htmlFor="invoice-product-search">Tambah produk dalam nota</label><div className="purchase-search-row"><input id="invoice-product-search" value={query} onChange={(e) => setQuery(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); void search(); } }} placeholder="Nama produk atau SKU"/><button type="button" className="purchase-filter-submit" onClick={() => void search()} disabled={searchPending}>{searchPending ? "Mencari…" : "Cari"}</button></div>{products.length > 0 && <ul className="purchase-search-results">{products.map((p) => <li key={p.id}><button type="button" onClick={() => addProduct(p)}><strong>{p.name}</strong><span>{p.sku}</span></button></li>)}</ul>}</div>}
        {(!embedded || allowStandaloneFinalize) && <div className="purchase-invoice-lines"><table className="purchase-receipt-table"><thead><tr><th>Produk</th><th>Qty nota</th><th>Harga satuan</th><th>Subtotal</th>{!embedded && <th></th>}</tr></thead><tbody>{activeLines.map((line) => <tr key={line.productId}><td data-label="Produk"><strong>{line.name}</strong><small>{line.sku}</small></td><td data-label="Qty nota">{embedded ? line.quantity : <input aria-label={`Kuantitas nota ${line.name}`} type="number" min="0.001" step="0.001" value={line.quantity} onChange={(e) => { setDirty(true); updateLines((old) => old.map((v) => v.productId === line.productId ? { ...v, quantity: e.target.value } : v)); }}/>}</td><td data-label="Harga satuan"><RupiahInput aria-label={`Harga satuan ${line.name} Rupiah`} value={line.unitPrice} onValueChange={(value) => { setDirty(true); updateLines((old) => old.map((v) => v.productId === line.productId ? { ...v, unitPrice: value } : v)); }} /></td><td data-label="Subtotal">{idr(Math.round(moneyNumber(line.quantity) * moneyNumber(line.unitPrice) * 100) / 100)}</td>{!embedded && <td data-label="Aksi"><button type="button" className="purchase-remove" onClick={() => { setDirty(true); updateLines((old) => old.filter((v) => v.productId !== line.productId)); }}>Hapus</button></td>}</tr>)}</tbody></table></div>}
        <div className="purchase-invoice-totals" hidden={embedded && notaUnavailable}><div><span>Total Sistem</span><strong>{financeLinesComplete ? idr(systemTotal) : "Lengkapi harga dan kuantitas"}</strong></div><div><span>Total Nota Supplier</span><strong>{supplierTotal === "" ? "—" : idr(invoiceTotal)}</strong></div><div className={invoiceComparisonReady && difference === 0 ? "purchase-total-match" : "purchase-total-difference"}><span>{!financeLinesComplete ? "Belum lengkap" : supplierTotal === "" ? "Isi total nota" : difference === 0 ? "✓ Cocok" : "⚠ Selisih"}</span><strong>{invoiceComparisonReady ? idr(difference) : "—"}</strong></div></div>
        {(!embedded || allowStandaloneFinalize) && <button type="button" className="purchase-secondary" disabled={busy} onClick={() => void saveDraft()}>{embedded ? "Simpan Nota" : "Simpan draf nota"}</button>}
        <div className="purchase-finance-subsection" hidden={embedded && notaUnavailable}><h3>PEMBAYARAN</h3><p>Nilai nota menjadi tagihan saat difinalisasi. Pembayaran tidak mengubah stok.</p><div className="purchase-fields"><label>Sudah dibayar<RupiahInput value={initialPaid} onValueChange={(value) => { setInitialPaid(value); setInitialPaidEdited(true); }} aria-label="Sudah dibayar Rupiah" /></label>{moneyNumber(initialPaid) > 0 && <><label>Tanggal pembayaran<input type="date" value={paymentDate} onChange={(e) => setPaymentDate(e.target.value)} /></label><label>Metode<select value={paymentMethod} onChange={(e) => setPaymentMethod(e.target.value as "CASH" | "TRANSFER" | "OTHER")}><option value="CASH">Tunai</option><option value="TRANSFER">Transfer</option><option value="OTHER">Lainnya</option></select></label><label>Referensi / catatan<input value={paymentNote} onChange={(e) => setPaymentNote(e.target.value)} maxLength={300}/></label></>}</div></div>
        {(!embedded || allowStandaloneFinalize) ? <button type="button" className={finalizeRetry ? "purchase-retry" : "purchase-post-button"} disabled={busy || dirty || !invoiceNumber.trim() || supplierTotal === "" || !financeLinesComplete} onClick={() => void finalize()}>{finalizeRetry ? "Ulangi finalisasi dengan permintaan yang sama" : "Finalisasi Nota & Catat Tagihan"}</button> : <p className="purchase-operational-note">Nota dan pembayaran awal akan difinalisasi setelah barang masuk berhasil diposting.</p>}
      </> : <>
        <div className="purchase-result-meta"><div><span>Nomor nota</span><strong>{header.invoice_number ?? "—"}</strong></div><div><span>Tanggal nota</span><strong>{header.invoice_date ?? "—"}</strong></div><div><span>Jenis pembayaran</span><strong>{header.payment_type === "TEMPO" ? "Tempo" : "Cash"}</strong></div><div><span>Jatuh tempo</span><strong>{header.due_date ?? "—"}</strong></div><div><span>Total Sistem</span><strong>{idr(invoice.items.reduce((sum, item) => sum + item.subtotal, 0))}</strong></div><div><span>Total Nota Supplier</span><strong>{idr(header.supplier_invoice_total ?? 0)}</strong></div></div>
        <div className="purchase-invoice-totals"><div><span>Total Sistem</span><strong>{idr(invoice.items.reduce((sum, item) => sum + item.subtotal, 0))}</strong></div><div><span>Total Nota Supplier</span><strong>{idr(header.supplier_invoice_total ?? 0)}</strong></div><div className={invoiceTotalDifference(invoice.items.reduce((sum, item) => sum + item.subtotal, 0), header.supplier_invoice_total ?? 0) === 0 ? "purchase-total-match" : "purchase-total-difference"}><span>{invoiceTotalDifference(invoice.items.reduce((sum, item) => sum + item.subtotal, 0), header.supplier_invoice_total ?? 0) === 0 ? "✓ Cocok" : "⚠ Selisih"}</span><strong>{idr(invoiceTotalDifference(invoice.items.reduce((sum, item) => sum + item.subtotal, 0), header.supplier_invoice_total ?? 0))}</strong></div></div>
        <div className="purchase-posted-table-wrap"><table className="purchase-posted-table"><thead><tr><th>Produk</th><th>Qty nota</th><th>Harga satuan</th><th>Subtotal</th></tr></thead><tbody>{invoice.items.map((line) => <tr key={line.id}><td><strong>{line.name}</strong><span>{line.sku}</span></td><td>{line.quantity}</td><td>{idr(line.unitPrice)}</td><td>{idr(line.subtotal)}</td></tr>)}</tbody></table></div>
        <div className="purchase-finance-subsection"><h3>PEMBAYARAN</h3><p>Status: <strong>{invoice.payable?.status ?? "Lunas"}</strong> · Dibayar {idr(invoice.payable?.paid ?? 0)} · Sisa {idr(invoice.payable?.outstanding ?? 0)}</p>
          {invoice.payable && invoice.payable.outstanding > 0 && <div className="purchase-fields">{!paymentRetry && <><label>Jumlah pembayaran<RupiahInput value={paymentAmount} onValueChange={setPaymentAmount} aria-label="Jumlah pembayaran Rupiah"/></label><label>Tanggal pembayaran<input type="date" value={paymentDate} onChange={(e) => setPaymentDate(e.target.value)}/></label><label>Metode<select value={paymentMethod} onChange={(e) => setPaymentMethod(e.target.value as "CASH" | "TRANSFER" | "OTHER")}><option value="CASH">Tunai</option><option value="TRANSFER">Transfer</option><option value="OTHER">Lainnya</option></select></label><label>Referensi / catatan<input value={paymentNote} onChange={(e) => setPaymentNote(e.target.value)} maxLength={300}/></label></>}<button type="button" className={paymentRetry ? "purchase-retry" : "purchase-primary"} disabled={busy || (!paymentAmount && !paymentRetry)} onClick={() => void pay()}>{paymentRetry ? "Ulangi pembayaran dengan permintaan yang sama" : "Catat pembayaran"}</button></div>}
          <ol className="purchase-payment-history">{invoice.payments.map((payment) => <li key={payment.id}><strong>{idr(payment.amount)}</strong><span>{payment.date} · {payment.method} · dicatat {payment.recordedByName}</span></li>)}</ol>
        </div>
      </>}
      <div className="purchase-finance-subsection purchase-document-subsection"><h3>FOTO NOTA</h3><p>Dokumen hanya dapat dibuka OWNER/ADMIN melalui tautan privat yang kedaluwarsa.</p><label className="purchase-upload-control">Ambil foto / pilih file<input type="file" accept="image/jpeg,image/png,image/webp,application/pdf" capture="environment" onChange={(e) => void upload(e.currentTarget.files?.[0])}/></label>
        {invoice.documents.map((document) => <button type="button" className="purchase-secondary" key={document.id} onClick={() => void openDocument(document.path)}>Buka nota · {document.uploadedAt.slice(0,10)} · diunggah {document.uploadedByName}</button>)}</div>
    </section>
    {!embedded && <section className="purchase-finance-section"><h2>Hubungkan barang masuk</h2><p>Satu nota dapat terkait dengan beberapa penerimaan supplier/outlet yang sama.</p>
      {initialReceiptId && invoice.receipts.some((receipt) => receipt.id === initialReceiptId) && <p role="status">Penerimaan barang berhasil dihubungkan ke nota ini.</p>}
      {invoice.receipts.map((receipt) => <div className="purchase-linked-receipt" key={receipt.id}><Link href={`/pembelian/barang-masuk/${receipt.id}`}>{receipt.reference} · {receipt.status === "POSTED" ? "Diposting" : "Draf"}</Link>{editable && <button type="button" className="purchase-remove" onClick={() => void toggleReceipt(receipt.id, true)}>Lepas</button>}</div>)}
      {linkableReceipts.filter((receipt) => !invoice.receipts.some((linked) => linked.id === receipt.id)).map((receipt) => <div className="purchase-linked-receipt" key={receipt.id}><span>{receipt.reference} · {receipt.status === "POSTED" ? "Diposting" : "Draf"}</span><button type="button" className="purchase-secondary" onClick={() => void toggleReceipt(receipt.id, false)}>Hubungkan</button></div>)}
    </section>}
    {invoice.events.length > 0 && <details className="purchase-timeline purchase-activity-details"><summary>Lihat riwayat aktivitas</summary><ol>{invoice.events.map((event, index) => <li key={`${event.at}-${index}`}><strong>{event.type.replaceAll("_", " ")}</strong><span>{event.actorName}</span><time>{new Intl.DateTimeFormat("id-ID", { dateStyle: "medium", timeStyle: "short" }).format(new Date(event.at))}</time></li>)}</ol></details>}
    <p className="purchase-operational-note">Nota/pembayaran tidak memposting stok dan tidak memperbarui HPP. Stok bertambah satu kali melalui Barang Masuk.</p>
  </section>;
}
