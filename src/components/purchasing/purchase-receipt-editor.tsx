"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { applyReceiptPost, issueReceiptPost, resolveReceiptBarcode, saveReceiptDraft, searchReceiptProducts } from "@/lib/purchasing/actions";
import { formatReceiptQuantity, receiptPostRetryKey, receiptStockQuantity, type ReceiptDraftItem } from "@/lib/purchasing/receipt-model";
import type { ReceiptDetail } from "@/lib/purchasing/receipt-read";

type Product = { id: string; name: string; sku: string; barcode: string | null };
type DraftItem = ReceiptDraftItem & { name: string; sku: string; barcode: string | null; unit: string | null };
type LookupMode = "scan" | "search";

function dateLocal(value: string) {
  const date = new Date(value);
  return new Date(date.getTime() - date.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
}
function dateTime(value: string | null) {
  return value ? new Intl.DateTimeFormat("id-ID", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value)) : "Tidak tersedia";
}
function sumStock(items: DraftItem[]) { return items.reduce((sum, item) => sum + (receiptStockQuantity(item.accepted_quantity, item.bonus_quantity) ?? 0), 0); }
function eventLabel(value: string) { return value === "CREATED" ? "Draf dibuat" : value === "POSTED" ? "Barang masuk diposting" : "Draf diperbarui"; }

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
  const [lookupMode, setLookupMode] = useState<LookupMode>("scan");
  const [results, setResults] = useState<Product[]>([]);
  const [resultsForQuery, setResultsForQuery] = useState("");
  const [lookupMessage, setLookupMessage] = useState("");
  const [error, setError] = useState("");
  const [isPending, startTransition] = useTransition();
  const [isActionBusy, setIsActionBusy] = useState(false);
  const actionLock = useRef(false);
  const [pendingRequest, setPendingRequest] = useState<string | null>(null);
  const [reviewMode, setReviewMode] = useState(false);
  const retryKey = receiptPostRetryKey(receipt.id);
  const searchRequestNo = useRef(0);

  useEffect(() => {
    const stored = window.sessionStorage.getItem(retryKey);
    if (!stored) return;
    const timer = window.setTimeout(() => setPendingRequest(stored), 0);
    return () => window.clearTimeout(timer);
  }, [retryKey]);

  useEffect(() => {
    if (readOnly || lookupMode !== "search" || query.trim().length < 2) return;
    const requestNo = ++searchRequestNo.current;
    const timer = window.setTimeout(() => {
      void (async () => {
        const found = await searchReceiptProducts(query.trim());
        if (requestNo !== searchRequestNo.current) return;
        setResults(found.rows); setResultsForQuery(query.trim());
        if (found.error) setLookupMessage(found.error);
      })();
    }, 280);
    return () => { window.clearTimeout(timer); searchRequestNo.current += 1; };
  }, [query, readOnly, lookupMode]);

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
    setHasUnsavedChanges(true); setLookupMessage(`${product.name} ditambahkan.`); setQuery(""); setResults([]);
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
    actionLock.current = true; setIsActionBusy(true); setError("");
    const form = new FormData();
    form.set("received_at", new Date(receivedAt).toISOString()); form.set("operational_note", note);
    form.set("items", JSON.stringify(items.map(({ product_id, accepted_quantity, bonus_quantity, rejected_quantity, short_quantity, operational_note }) => ({
      product_id, accepted_quantity, bonus_quantity, rejected_quantity, short_quantity: short_quantity || null, operational_note,
    }))));
    startTransition(async () => {
      const result = await saveReceiptDraft(receipt.id, receipt.draft_revision, form);
      setError(result.error ?? ""); actionLock.current = false; setIsActionBusy(false);
      if (!result.error) { setHasUnsavedChanges(false); router.refresh(); }
    });
  }

  async function postReceipt() {
    if (actionLock.current || readOnly || hasUnsavedChanges || receipt.draft_revision <= 1) return;
    const storedRequest = window.sessionStorage.getItem(retryKey);
    const retryRequest = pendingRequest ?? storedRequest;
    if (retryRequest) { setPendingRequest(retryRequest); actionLock.current = true; setIsActionBusy(true); await applyRequest(retryRequest); return; }
    actionLock.current = true; setIsActionBusy(true); setError("");
    const issued = await issueReceiptPost(receipt.id);
    if (issued.error || !issued.requestId) { setError(issued.error ?? "Permintaan posting belum dapat disiapkan."); actionLock.current = false; setIsActionBusy(false); return; }
    window.sessionStorage.setItem(retryKey, issued.requestId); setPendingRequest(issued.requestId);
    await applyRequest(issued.requestId);
  }

  async function applyRequest(requestId: string) {
    setError("");
    const outcome = await applyReceiptPost(requestId);
    actionLock.current = false; setIsActionBusy(false);
    if (outcome.error) {
      if (outcome.terminal) { window.sessionStorage.removeItem(retryKey); setPendingRequest(null); router.refresh(); }
      setError(outcome.terminal ? outcome.error : `${outcome.error} Jika hasilnya belum pasti, ulangi posting dengan permintaan yang sama.`); return;
    }
    if (!outcome.result) { setError("Hasil belum dapat dipastikan. Gunakan percobaan ulang dengan permintaan yang sama."); return; }
    window.sessionStorage.removeItem(retryKey); setPendingRequest(null);
    if (outcome.result.ok && outcome.result.code === "POSTED") {
      window.sessionStorage.setItem(`quena:purchasing:POST_SUCCESS:${receipt.id}`, JSON.stringify({ itemCount: items.length, stockAdded: totalStock }));
      router.replace(`/pembelian/barang-masuk?posted=${encodeURIComponent(receipt.id)}`); return;
    }
    setError(outcome.result.code === "RECEIPT_CHANGED"
      ? "Draf berubah saat proses posting disiapkan. Muat ulang, periksa kembali, lalu siapkan permintaan baru."
      : "Barang masuk tidak dapat diposting. Muat ulang dan periksa status terbaru.");
    router.refresh();
  }

  const hasPositiveStock = items.some((item) => (receiptStockQuantity(item.accepted_quantity, item.bonus_quantity) ?? 0) > 0);
  const totalStock = sumStock(items);
  const timeline = <section className={`purchase-timeline ${readOnly ? "purchase-history-timeline" : ""}`}><h2>Riwayat barang masuk</h2><ol>{receipt.events.map((event,index) => <li key={`${event.created_at}-${index}`}><strong>{eventLabel(event.event_type)}</strong><time>{dateTime(event.created_at)}</time></li>)}</ol></section>;

  if (readOnly) return <section className="purchase-receipt-result surface-card">
    <header className="purchase-detail-header purchase-result-header"><div><div className="eyebrow">HASIL BARANG MASUK</div><h1>{receipt.receipt_reference}</h1><p>{receipt.supplier?.display_name ?? "Supplier tidak tersedia"} · {receipt.outlet?.name ?? "Outlet tidak tersedia"}</p></div><span className="purchase-status purchase-status-posted">Diposting</span></header>
    <div className="purchase-result-meta"><div><span>Tanggal diterima</span><strong>{dateTime(receipt.received_at)}</strong></div><div><span>Waktu diposting</span><strong>{dateTime(receipt.posted_at)}</strong></div><div><span>Diinput oleh</span><strong>{receipt.created_by_name}</strong></div><div><span>Diposting oleh</span><strong>{receipt.posted_by_name}</strong></div><div><span>Catatan operasional</span><strong>{receipt.operational_note?.trim() || "—"}</strong></div></div>
    <section className="purchase-result-items"><div className="purchase-items-heading"><div><h2>Barang yang diterima</h2><p>Riwayat stok dari penerimaan ini · metadata produk mengikuti data saat ini.</p></div><strong>{items.length} produk</strong></div>
      <div className="purchase-posted-table-wrap"><table className="purchase-posted-table"><thead><tr><th>Produk</th><th>Diterima</th><th>Bonus</th><th>Rusak / ditolak</th><th>Kurang</th><th>Stok +</th></tr></thead><tbody>{items.map((item) => <tr key={item.product_id}><td><strong>{item.name}</strong><span>{item.sku}{item.unit ? ` · ${item.unit}` : ""}</span>{item.operational_note && <small>{item.operational_note}</small>}</td><td>{formatReceiptQuantity(item.accepted_quantity)}</td><td>{formatReceiptQuantity(item.bonus_quantity)}</td><td>{formatReceiptQuantity(item.rejected_quantity)}</td><td>{formatReceiptQuantity(item.short_quantity)}</td><td className="purchase-stock-positive">+{formatReceiptQuantity(receiptStockQuantity(item.accepted_quantity,item.bonus_quantity))}</td></tr>)}</tbody></table></div>
      <div className="purchase-posted-mobile-list">{items.map((item) => <article key={item.product_id}><header><div><strong>{item.name}</strong><span>{item.sku}{item.unit ? ` · ${item.unit}` : ""}</span></div><b className="purchase-stock-positive">Stok +{formatReceiptQuantity(receiptStockQuantity(item.accepted_quantity,item.bonus_quantity))}</b></header><dl><div><dt>Diterima</dt><dd>{formatReceiptQuantity(item.accepted_quantity)}</dd></div><div><dt>Bonus</dt><dd>{formatReceiptQuantity(item.bonus_quantity)}</dd></div><div><dt>Rusak / ditolak</dt><dd>{formatReceiptQuantity(item.rejected_quantity)}</dd></div><div><dt>Kurang</dt><dd>{formatReceiptQuantity(item.short_quantity)}</dd></div></dl>{item.operational_note && <p>{item.operational_note}</p>}</article>)}</div>
      <div className="purchase-posted-summary"><span>{items.length} produk</span><strong>Total stok bertambah {formatReceiptQuantity(totalStock)} unit</strong></div>
    </section>
    {timeline}
  </section>;

  return <section className="purchase-receipt-editor surface-card">
    <header className="purchase-detail-header"><div><div className="eyebrow">BARANG MASUK · DRAF</div><h1>{receipt.receipt_reference}</h1><p>{receipt.supplier?.display_name ?? "Supplier tidak tersedia"} · {receipt.outlet?.name ?? "Outlet"}</p><p className="purchase-actor-line">Diinput oleh {receipt.created_by_name}</p></div><span className="purchase-status purchase-status-draft">Draf</span></header>
    {!reviewMode ? <form className="purchase-draft-form" onSubmit={saveDraft}>
      <div className="purchase-fields"><label>Supplier<input value={receipt.supplier?.display_name ?? "Supplier tidak tersedia"} readOnly /></label><label>Tanggal diterima<input type="datetime-local" value={receivedAt} onChange={(event) => { setReceivedAt(event.target.value); setHasUnsavedChanges(true); }} required /></label><label className="purchase-operational-note-field">Catatan operasional<input value={note} maxLength={1000} onChange={(event) => { setNote(event.target.value); setHasUnsavedChanges(true); }} placeholder="Opsional" /></label></div>
      <section className="purchase-entry-section"><div className="purchase-entry-heading"><div><span className="eyebrow">TAMBAHKAN PRODUK</span><h2>Scan atau cari barang</h2><p>Pindai barcode untuk memilih produk secara tepat, atau cari berdasarkan nama/SKU.</p></div><span className="purchase-entry-icon" aria-hidden="true">＋</span></div>
        <div className="purchase-lookup-tabs" role="tablist" aria-label="Cara memilih produk"><button type="button" role="tab" aria-selected={lookupMode === "scan"} onClick={() => { setLookupMode("scan"); setQuery(""); setResults([]); setLookupMessage(""); }}>Scan Barcode</button><button type="button" role="tab" aria-selected={lookupMode === "search"} onClick={() => { setLookupMode("search"); setQuery(""); setResults([]); setLookupMessage(""); }}>Cari Produk</button></div>
        <div className="purchase-product-search"><label htmlFor="receipt-product-query">{lookupMode === "scan" ? "Barcode produk" : "Nama produk atau SKU"}</label><div className="purchase-search-row"><input id="receipt-product-query" value={query} onChange={(event) => setQuery(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && lookupMode === "scan") { event.preventDefault(); void scanBarcode(); } }} placeholder={lookupMode === "scan" ? "Pindai atau masukkan barcode" : "Ketik minimal 2 karakter"} autoComplete="off" inputMode={lookupMode === "scan" ? "text" : "search"}/>{lookupMode === "scan" && <button type="button" className="purchase-scan-button" onClick={() => void scanBarcode()}>Pilih barcode</button>}</div>
          {lookupMessage && <p role="status">{lookupMessage}</p>}
          {lookupMode === "search" && query.trim().length >= 2 && resultsForQuery === query.trim() && results.length > 0 && <ul className="purchase-search-results">{results.map((product) => <li key={product.id}><button type="button" onClick={() => addProduct(product)}><strong>{product.name}</strong><span>{product.sku} · {product.barcode ?? "Tanpa barcode"}</span></button></li>)}</ul>}
          {lookupMode === "search" && query.trim().length >= 2 && resultsForQuery === query.trim() && results.length === 0 && !lookupMessage && <p role="status">Produk tidak ditemukan.</p>}
        </div>
      </section>
      <div className="purchase-items-heading"><div><h2>Produk dalam penerimaan</h2><p>Stok + adalah jumlah diterima ditambah bonus.</p></div><strong>{items.length} produk</strong></div>
      {items.length === 0 ? <div className="purchase-empty">Pindai barcode atau cari produk untuk mulai mencatat penerimaan.</div> : <div className="purchase-receipt-items">{items.map((item) => <article id={`receipt-item-${item.product_id}`} key={item.product_id} className="purchase-receipt-item">
        <header><div><strong>{item.name}</strong><span>{item.sku}{item.unit ? ` · ${item.unit}` : ""}</span></div><button type="button" className="purchase-remove" onClick={() => { setItems((current) => current.filter((row) => row.product_id !== item.product_id)); setHasUnsavedChanges(true); }}>Hapus</button></header>
        <div className="purchase-quantity-grid">{([ ["accepted_quantity","Diterima"], ["bonus_quantity","Bonus"], ["rejected_quantity","Rusak / ditolak"], ["short_quantity","Kurang"] ] as const).map(([key,label]) => <label key={key}>{label}<input type="number" min="0" max="99999999999.999" step="0.001" value={item[key] ?? ""} onChange={(event) => updateItem(item.product_id,key,event.target.value)} placeholder={key === "short_quantity" ? "Opsional" : "0"}/></label>)}</div>
        <p className="purchase-line-total"><span>Stok bertambah</span><strong>+{formatReceiptQuantity(receiptStockQuantity(item.accepted_quantity,item.bonus_quantity))}</strong></p>
        <label className="purchase-item-note">Catatan item<input maxLength={300} value={item.operational_note ?? ""} onChange={(event) => updateItem(item.product_id,"operational_note",event.target.value)} placeholder="Opsional"/></label>
      </article>)}</div>}
      <div className="purchase-draft-summary"><div><span>Jumlah produk</span><strong>{items.length}</strong></div><div><span>Total stok bertambah</span><strong>+{formatReceiptQuantity(totalStock)}</strong></div></div>
      {error && <p className="purchase-action-error" role="alert">{error}</p>}
      <div className="purchase-actions purchase-draft-actions"><button className="purchase-secondary" type="submit" disabled={isPending || isActionBusy}>Simpan draf</button><button className="purchase-primary" type="button" disabled={isPending || isActionBusy || hasUnsavedChanges || !hasPositiveStock || receipt.draft_revision <= 1} onClick={() => { setError(""); setReviewMode(true); }}>Review Barang Masuk</button>{hasUnsavedChanges && <span className="purchase-unsaved-note">Simpan perubahan draf sebelum review.</span>}</div>
    </form> : <section className="purchase-review-panel">
      <div className="purchase-review-heading"><div><span className="eyebrow">PERIKSA SEBELUM POSTING</span><h2>Review barang masuk</h2><p>Pastikan supplier, tanggal, dan jumlah fisik sudah benar.</p></div><span className="purchase-status purchase-status-draft">Siap ditinjau</span></div>
      <div className="purchase-review-meta"><div><span>Supplier</span><strong>{receipt.supplier?.display_name ?? "Supplier tidak tersedia"}</strong></div><div><span>Tanggal diterima</span><strong>{dateTime(receivedAt ? new Date(receivedAt).toISOString() : receipt.received_at)}</strong></div><div><span>Catatan</span><strong>{note.trim() || "—"}</strong></div></div>
      <div className="purchase-review-table-wrap"><table className="purchase-review-table"><thead><tr><th>Produk</th><th>Diterima</th><th>Bonus</th><th>Rusak</th><th>Kurang</th><th>Stok +</th></tr></thead><tbody>{items.map((item) => <tr key={item.product_id}><td><strong>{item.name}</strong><span>{item.sku}</span></td><td>{formatReceiptQuantity(item.accepted_quantity)}</td><td>{formatReceiptQuantity(item.bonus_quantity)}</td><td>{formatReceiptQuantity(item.rejected_quantity)}</td><td>{formatReceiptQuantity(item.short_quantity)}</td><td className="purchase-stock-positive">+{formatReceiptQuantity(receiptStockQuantity(item.accepted_quantity,item.bonus_quantity))}</td></tr>)}</tbody></table></div>
      <div className="purchase-review-mobile-list">{items.map((item) => <article key={item.product_id}><strong>{item.name}</strong><span>{item.sku}</span><dl><div><dt>Diterima</dt><dd>{formatReceiptQuantity(item.accepted_quantity)}</dd></div><div><dt>Bonus</dt><dd>{formatReceiptQuantity(item.bonus_quantity)}</dd></div><div><dt>Rusak</dt><dd>{formatReceiptQuantity(item.rejected_quantity)}</dd></div><div><dt>Kurang</dt><dd>{formatReceiptQuantity(item.short_quantity)}</dd></div></dl><b className="purchase-stock-positive">Stok +{formatReceiptQuantity(receiptStockQuantity(item.accepted_quantity,item.bonus_quantity))}</b></article>)}</div>
      <div className="purchase-review-total"><span>Total stok bertambah</span><strong>{formatReceiptQuantity(totalStock)} unit</strong></div>
      {error && <p className="purchase-action-error" role="alert">{error}</p>}
      <div className="purchase-actions purchase-review-actions"><button type="button" className="purchase-secondary" disabled={isPending || isActionBusy} onClick={() => setReviewMode(false)}>Kembali</button>{pendingRequest ? <button className="purchase-retry" type="button" disabled={isPending || isActionBusy} onClick={() => { if (!actionLock.current) { actionLock.current = true; setIsActionBusy(true); void applyRequest(pendingRequest); } }}>Ulangi posting dengan permintaan yang sama</button> : <button className="purchase-post-button" type="button" disabled={isPending || isActionBusy} onClick={() => { if (window.confirm("Posting akan menambah stok efektif berdasarkan jumlah diterima dan bonus. Penerimaan menjadi permanen dan tidak dapat diedit. Lanjutkan?")) void postReceipt(); }}>Posting Barang Masuk</button>}</div>
    </section>}
    {timeline}
  </section>;
}
