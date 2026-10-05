"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { applyReceiptPost, issueReceiptPost, resolveReceiptBarcode, saveReceiptDraft, searchReceiptProducts } from "@/lib/purchasing/actions";
import { formatReceiptQuantity, receiptPostRetryKey, receiptStockQuantity, type ReceiptDraftItem } from "@/lib/purchasing/receipt-model";
import type { ReceiptDetail } from "@/lib/purchasing/receipt-read";

type Product = { id: string; name: string; sku: string; barcode: string | null };
type DraftItem = ReceiptDraftItem & { name: string; sku: string; barcode: string | null; unit: string | null };

function dateLocal(value: string) {
  const date = new Date(value);
  return new Date(date.getTime() - date.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
}

export function PurchaseReceiptEditor({ receipt }: { receipt: ReceiptDetail }) {
  const router = useRouter();
  const readOnly = receipt.status === "POSTED";
  const [items, setItems] = useState<DraftItem[]>(() => receipt.items.map((item) => ({
    product_id: item.product_id, name: item.product?.name ?? "Produk tidak tersedia", sku: item.product?.sku ?? "—",
    barcode: null, unit: item.product?.unit_label ?? null, accepted_quantity: String(item.accepted_quantity),
    bonus_quantity: String(item.bonus_quantity), rejected_quantity: String(item.rejected_quantity),
    short_quantity: item.short_quantity === null ? null : String(item.short_quantity), operational_note: item.operational_note,
  })));
  const [receivedAt, setReceivedAt] = useState(dateLocal(receipt.received_at));
  const [note, setNote] = useState(receipt.operational_note ?? "");
  const [hasUnsavedChanges, setHasUnsavedChanges] = useState(false);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<Product[]>([]);
  const [resultsForQuery, setResultsForQuery] = useState("");
  const [lookupMessage, setLookupMessage] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [isPending, startTransition] = useTransition();
  const actionLock = useRef(false);
  const [pendingRequest, setPendingRequest] = useState<string | null>(null);
  const retryKey = receiptPostRetryKey(receipt.id);
  const searchRequestNo = useRef(0);

  useEffect(() => {
    const stored = window.sessionStorage.getItem(retryKey);
    if (!stored) return;
    const timer = window.setTimeout(() => setPendingRequest(stored), 0);
    return () => window.clearTimeout(timer);
  }, [retryKey]);

  useEffect(() => {
    if (readOnly || query.trim().length < 2) return;
    const requestNo = ++searchRequestNo.current;
    const timer = window.setTimeout(() => {
      void (async () => {
        const found = await searchReceiptProducts(query.trim());
        if (requestNo !== searchRequestNo.current) return;
        setResults(found.rows);
        setResultsForQuery(query.trim());
        if (found.error) setLookupMessage(found.error);
      })();
    }, 280);
    return () => { window.clearTimeout(timer); searchRequestNo.current += 1; };
  }, [query, readOnly]);

  function addProduct(product: Product) {
    const existing = items.find((item) => item.product_id === product.id);
    if (existing) {
      document.getElementById(`receipt-item-${product.id}`)?.scrollIntoView({ behavior: "smooth", block: "center" });
      setLookupMessage(`${product.name} sudah ada pada draf; barisnya disorot.`);
      setQuery(""); setResults([]); return;
    }
    setItems((current) => [...current, { product_id: product.id, name: product.name, sku: product.sku,
      barcode: product.barcode, unit: null, accepted_quantity: "0", bonus_quantity: "0", rejected_quantity: "0",
      short_quantity: null, operational_note: null }]);
    setHasUnsavedChanges(true);
    setLookupMessage(`${product.name} ditambahkan.`);
    setQuery(""); setResults([]);
  }

  async function scanBarcode() {
    const barcode = query.trim();
    if (!barcode) return;
    setLookupMessage("Mencari barcode…");
    const result = await resolveReceiptBarcode(barcode);
    if (result.product) addProduct(result.product);
    else setLookupMessage(result.code === "BARCODE_NOT_FOUND" ? "Barcode aktif tidak ditemukan." :
      result.code === "BARCODE_AMBIGUOUS" ? "Barcode digunakan lebih dari satu produk. Periksa data barcode sebelum melanjutkan." : "Barcode belum dapat diperiksa.");
  }

  function updateItem(productId: string, key: keyof DraftItem, value: string) {
    setHasUnsavedChanges(true);
    setItems((current) => current.map((item) => item.product_id === productId ? { ...item, [key]: value } : item));
  }

  async function saveDraft(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (actionLock.current || readOnly) return;
    actionLock.current = true; setError(""); setMessage("");
    const form = new FormData();
    form.set("received_at", new Date(receivedAt).toISOString()); form.set("operational_note", note);
    form.set("items", JSON.stringify(items.map(({ product_id, accepted_quantity, bonus_quantity, rejected_quantity, short_quantity, operational_note }) => ({
      product_id, accepted_quantity, bonus_quantity, rejected_quantity, short_quantity: short_quantity || null, operational_note,
    }))));
    startTransition(async () => {
      const result = await saveReceiptDraft(receipt.id, receipt.draft_revision, form);
      setError(result.error ?? ""); setMessage(result.success ?? "");
      actionLock.current = false;
      if (!result.error) { setHasUnsavedChanges(false); router.refresh(); }
    });
  }

  async function postReceipt() {
    if (actionLock.current || pendingRequest || readOnly) return;
    actionLock.current = true; setError(""); setMessage("");
    const issued = await issueReceiptPost(receipt.id);
    if (issued.error || !issued.requestId) { setError(issued.error ?? "Permintaan posting belum dapat disiapkan."); actionLock.current = false; return; }
    window.sessionStorage.setItem(retryKey, issued.requestId);
    setPendingRequest(issued.requestId);
    await applyRequest(issued.requestId);
  }

  async function applyRequest(requestId: string) {
    setError(""); setMessage("");
    const outcome = await applyReceiptPost(requestId);
    actionLock.current = false;
    if (outcome.error) {
      if (outcome.terminal) { window.sessionStorage.removeItem(retryKey); setPendingRequest(null); router.refresh(); }
      setError(outcome.terminal ? outcome.error : `${outcome.error} Jika hasilnya belum pasti, ulangi posting dengan permintaan yang sama.`); return;
    }
    if (!outcome.result) { setError("Hasil belum dapat dipastikan. Gunakan percobaan ulang dengan permintaan yang sama."); return; }
    window.sessionStorage.removeItem(retryKey); setPendingRequest(null);
    if (outcome.result.ok && outcome.result.code === "POSTED") {
      setMessage(`Barang masuk diposting. ${outcome.result.movementCount ?? 0} produk menambah stok.`);
      router.refresh(); return;
    }
    setError(outcome.result.code === "RECEIPT_CHANGED"
      ? "Draf berubah saat proses posting disiapkan. Muat ulang, periksa kembali, lalu siapkan permintaan baru."
      : "Barang masuk tidak dapat diposting. Muat ulang dan periksa status terbaru.");
    router.refresh();
  }

  const hasPositiveStock = items.some((item) => (receiptStockQuantity(item.accepted_quantity, item.bonus_quantity) ?? 0) > 0);

  return <section className="purchase-receipt-editor surface-card">
    <header className="purchase-detail-header"><div><div className="eyebrow">BARANG MASUK</div><h1>{receipt.receipt_reference}</h1><p>{receipt.supplier?.display_name ?? "Supplier tidak tersedia"} · {receipt.outlet?.name ?? "Outlet"}</p></div>
      <span className={`purchase-status purchase-status-${receipt.status.toLowerCase()}`}>{receipt.status === "POSTED" ? "Diposting" : "Draf"}</span></header>
    {readOnly && <div className="purchase-readonly-notice">Riwayat barang masuk ini sudah diposting dan tidak dapat diubah.</div>}
    <form onSubmit={saveDraft}>
      <div className="purchase-fields"><label>Tanggal barang diterima<input type="datetime-local" value={receivedAt} disabled={readOnly} onChange={(event) => { setReceivedAt(event.target.value); setHasUnsavedChanges(true); }} required /></label>
        <label>Catatan operasional<input value={note} disabled={readOnly} maxLength={1000} onChange={(event) => { setNote(event.target.value); setHasUnsavedChanges(true); }} placeholder="Opsional" /></label></div>
      {!readOnly && <div className="purchase-product-search"><label htmlFor="receipt-product-query">Scan barcode atau cari produk</label><div className="purchase-search-row"><input id="receipt-product-query" value={query} onChange={(event) => setQuery(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") { event.preventDefault(); void scanBarcode(); } }} placeholder="Barcode, nama, atau SKU" autoComplete="off"/><button type="button" onClick={() => void scanBarcode()}>Cari barcode</button></div>
        {lookupMessage && <p role="status">{lookupMessage}</p>}
        {!readOnly && query.trim().length >= 2 && resultsForQuery === query.trim() && results.length > 0 && <ul className="purchase-search-results">{results.map((product) => <li key={product.id}><button type="button" onClick={() => addProduct(product)}><strong>{product.name}</strong><span>{product.sku} · {product.barcode ?? "Tanpa barcode"}</span></button></li>)}</ul>}
      </div>}
      <div className="purchase-items-heading"><div><h2>Barang diterima</h2><p>Stok bertambah dari jumlah diterima + bonus.</p></div><strong>{items.length} produk</strong></div>
      {items.length === 0 ? <div className="purchase-empty">Tambahkan produk melalui barcode atau pencarian.</div> : <div className="purchase-receipt-items">{items.map((item) => <article id={`receipt-item-${item.product_id}`} key={item.product_id} className="purchase-receipt-item">
        <header><div><strong>{item.name}</strong><span>{item.sku}{item.unit ? ` · ${item.unit}` : ""}</span></div>{!readOnly && <button type="button" className="purchase-remove" onClick={() => { setItems((current) => current.filter((row) => row.product_id !== item.product_id)); setHasUnsavedChanges(true); }}>Hapus</button>}</header>
        <div className="purchase-quantity-grid">{([["accepted_quantity","Diterima"],["bonus_quantity","Bonus"],["rejected_quantity","Rusak / ditolak"],["short_quantity","Kurang"]] as const).map(([key,label]) => <label key={key}>{label}<input type="number" min="0" max="99999999999.999" step="0.001" value={item[key] ?? ""} disabled={readOnly} onChange={(event) => updateItem(item.product_id,key,event.target.value)} placeholder={key === "short_quantity" ? "Opsional" : "0"}/></label>)}</div>
        <p className="purchase-line-total">Ditambahkan ke stok <strong>{formatReceiptQuantity(receiptStockQuantity(item.accepted_quantity,item.bonus_quantity))}</strong></p>
        {!readOnly && <label className="purchase-item-note">Catatan item<input maxLength={300} value={item.operational_note ?? ""} onChange={(event) => updateItem(item.product_id,"operational_note",event.target.value)} placeholder="Opsional"/></label>}
      </article>)}</div>}
      {error && <p className="purchase-action-error" role="alert">{error}</p>}{message && <p className="purchase-action-success" role="status">{message}</p>}
      {!readOnly && <div className="purchase-actions"><button className="purchase-secondary" type="submit" disabled={isPending || actionLock.current}>Simpan draf</button>
        {!pendingRequest && receipt.draft_revision > 1 && <button className="purchase-primary" type="button" disabled={isPending || actionLock.current || !hasPositiveStock || hasUnsavedChanges}
          onClick={() => { if (window.confirm("Posting akan menambah stok efektif berdasarkan barang diterima dan bonus. Draf menjadi permanen dan tidak dapat diedit. Lanjutkan?")) void postReceipt(); }}>Posting barang masuk</button>}
        {hasUnsavedChanges && <span className="purchase-unsaved-note">Simpan perubahan draf sebelum posting.</span>}
        {pendingRequest && <button className="purchase-retry" type="button" disabled={isPending || actionLock.current} onClick={() => { if (!actionLock.current) { actionLock.current = true; void applyRequest(pendingRequest); } }}>Ulangi konfirmasi posting</button>}
      </div>}
    </form>
    <section className="purchase-timeline"><h2>Riwayat barang masuk</h2><ol>{receipt.events.map((event,index) => <li key={`${event.created_at}-${index}`}><strong>{event.event_type === "CREATED" ? "Draf dibuat" : event.event_type === "POSTED" ? "Barang masuk diposting" : "Draf diperbarui"}</strong><time>{new Intl.DateTimeFormat("id-ID",{dateStyle:"medium",timeStyle:"short"}).format(new Date(event.created_at))}</time></li>)}</ol></section>
  </section>;
}
