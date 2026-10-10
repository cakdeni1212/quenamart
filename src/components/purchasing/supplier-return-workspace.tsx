"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { cancelSupplierReturn, createSupplierReturn, postSupplierReturn, resolveSupplierReturnBarcode, searchSupplierReturnProducts, supplierReturnReceiptCandidates, updateSupplierReturn } from "@/app/actions/supplier-return";
import type { SupplierReturnRead } from "@/lib/stock/supplier-return-read";

type Supplier = { id: string; display_name: string };
type Product = { product_id: string; name: string; sku: string; barcode: string | null; effective_quantity: number | string };
type Receipt = { receipt_id: string; receipt_reference: string; receipt_item_id: string; received_quantity: number | string; available_quantity: number | string };
type Line = { productId: string; name: string; sku: string; stock: number; quantity: string; receiptId: string; receiptItemId: string; receiptLabel: string; note: string };
const reasons = [["DAMAGED","Rusak"],["WRONG_ITEM","Barang salah"],["EXCESS","Kelebihan barang"],["DEFECTIVE","Cacat"],["EXPIRED","Kedaluwarsa"],["SUPPLIER_REQUEST","Permintaan supplier"],["OTHER","Lainnya"]] as const;
const fmt = (v: number | string) => new Intl.NumberFormat("id-ID", { maximumFractionDigits: 3 }).format(Number(v));

export function SupplierReturnWorkspace({ outletId, outletName, suppliers, returns, canPost }: {
  outletId: string; outletName: string; suppliers: Supplier[]; returns: SupplierReturnRead[]; canPost: boolean;
}) {
  const router = useRouter();
  const [supplierId, setSupplierId] = useState(""); const [reasonCategory, setReasonCategory] = useState("DAMAGED");
  const [reason, setReason] = useState(""); const [note, setNote] = useState(""); const [lines, setLines] = useState<Line[]>([]);
  const [query, setQuery] = useState(""); const [results, setResults] = useState<Product[]>([]); const [barcode, setBarcode] = useState("");
  const [notice, setNotice] = useState(""); const [busy, setBusy] = useState(false); const [editing, setEditing] = useState<SupplierReturnRead | null>(null);
  const [receiptOptions, setReceiptOptions] = useState<Record<string, Receipt[]>>({});

  async function search(value: string) {
    setQuery(value); if (value.trim().length < 2) { setResults([]); return; }
    const result = await searchSupplierReturnProducts(value); if (!result.ok) { setNotice(result.message); return; }
    setResults((result.value.rows as Product[]) ?? []);
  }
  function addProduct(p: Product) {
    setLines((current) => current.some((line) => line.productId === p.product_id) ? current : [...current, {
      productId: p.product_id, name: p.name, sku: p.sku, stock: Number(p.effective_quantity), quantity: "",
      receiptId: "", receiptItemId: "", receiptLabel: "", note: "",
    }]); setQuery(""); setResults([]);
  }
  async function scan() {
    if (!barcode.trim()) return; setBusy(true); const result = await resolveSupplierReturnBarcode(barcode); setBusy(false);
    if (!result.ok) { setNotice(result.message); return; } addProduct(result.value as unknown as Product); setBarcode("");
  }
  async function chooseReceipt(productId: string, value: string) {
    if (!value) { setLines((all) => all.map((x) => x.productId === productId ? { ...x, receiptId: "", receiptItemId: "", receiptLabel: "" } : x)); return; }
    const result = await supplierReturnReceiptCandidates(supplierId, productId, "");
    if (!result.ok) { setNotice(result.message); return; }
    const row = (result.value.rows as Receipt[]).find((item) => item.receipt_item_id === value);
    if (!row) { setNotice("Penerimaan sumber tidak ditemukan."); return; }
    setLines((all) => all.map((x) => x.productId === productId ? { ...x, receiptId: row.receipt_id, receiptItemId: row.receipt_item_id, receiptLabel: `${row.receipt_reference} · ${fmt(row.available_quantity)} tersisa` } : x));
  }
  async function loadReceiptOptions(productId: string) {
    if (!supplierId) { setNotice("Pilih supplier terlebih dahulu."); return; }
    const result = await supplierReturnReceiptCandidates(supplierId, productId, "");
    if (!result.ok) { setNotice(result.message); return; }
    setReceiptOptions((current) => ({ ...current, [productId]: result.value.rows as Receipt[] }));
  }
  function reset() { setEditing(null); setSupplierId(""); setReasonCategory("DAMAGED"); setReason(""); setNote(""); setLines([]); setNotice(""); }
  function edit(row: SupplierReturnRead) {
    setEditing(row); setSupplierId(row.supplier_id); setReasonCategory(row.reason_category); setReason(row.reason); setNote(row.note ?? "");
    setLines(row.supplier_return_items.map((item) => ({ productId: item.product_id, name: item.products?.name ?? item.product_id,
      sku: item.products?.sku ?? "", stock: 0, quantity: String(item.quantity), receiptId: item.source_receipt_id ?? "",
      receiptItemId: item.source_receipt_item_id ?? "", receiptLabel: item.source_receipt_id ? "Penerimaan sumber tersimpan" : "",
      note: item.note ?? "" }))); setNotice(`Mengubah draft ${row.return_no}.`);
  }
  async function save(event: React.FormEvent) {
    event.preventDefault();
    if (!supplierId || !lines.length || lines.some((x) => !Number.isFinite(Number(x.quantity)) || Number(x.quantity) <= 0 || Number(x.quantity) !== Math.round(Number(x.quantity) * 1000) / 1000)) {
      setNotice("Pilih supplier, barang, dan jumlah positif (maksimal tiga desimal)."); return;
    }
    setBusy(true); const payload = { supplierId, reasonCategory, reason, note, lines: lines.map((x) => ({ productId: x.productId,
      quantity: Number(x.quantity), sourceReceiptId: x.receiptId || null, sourceReceiptItemId: x.receiptItemId || null, note: x.note || null })) };
    const result = editing ? await updateSupplierReturn({ id: editing.id, expectedRevision: editing.revision, ...payload }) : await createSupplierReturn({ outletId, ...payload });
    setBusy(false); if (!result.ok) { setNotice(result.message); return; }
    setNotice(editing ? "Draft retur diperbarui." : `Draft ${String(result.value.returnNo)} tersimpan.`); reset(); router.refresh();
  }
  async function cancel(row: SupplierReturnRead) {
    const why = window.prompt("Alasan pembatalan draft"); if (!why) return; setBusy(true); const result = await cancelSupplierReturn(row.id, why); setBusy(false);
    setNotice(result.ok ? `Draft ${row.return_no} dibatalkan.` : result.message); router.refresh();
  }
  async function post(row: SupplierReturnRead) {
    if (!window.confirm("Retur supplier akan mengurangi stok dan tidak dapat diedit setelah diposting. Lanjutkan?")) return;
    const key = `quena-supplier-return-post:${row.id}`; let request = window.sessionStorage.getItem(key);
    if (!request) { request = window.crypto.randomUUID(); window.sessionStorage.setItem(key, request); }
    setBusy(true); const result = await postSupplierReturn(row.id, request); setBusy(false);
    if (!result.ok) { setNotice(result.message); return; } window.sessionStorage.removeItem(key); setNotice(`Retur ${row.return_no} diposting.`); router.refresh();
  }

  return <div className="supplier-return-workspace">
    <section className="surface-card supplier-return-form"><div className="supplier-return-heading"><div><span className="eyebrow">RETUR FISIK · {outletName}</span><h2>{editing ? `Ubah ${editing.return_no}` : "Buat retur"}</h2></div>{editing && <button type="button" className="button-secondary" onClick={reset}>Batal mengubah</button>}</div>
      <form onSubmit={save}>
        <div className="supplier-return-reason-fields"><label>Supplier<select required value={supplierId} onChange={(e) => setSupplierId(e.target.value)}><option value="">Pilih supplier</option>{suppliers.map((s) => <option key={s.id} value={s.id}>{s.display_name}</option>)}</select></label>
          <label>Kategori alasan<select value={reasonCategory} onChange={(e) => setReasonCategory(e.target.value)}>{reasons.map(([value,label]) => <option key={value} value={value}>{label}</option>)}</select></label>
          <label className="supplier-return-reason-text">Alasan<input required minLength={reasonCategory === "OTHER" ? 10 : 3} maxLength={1000} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Jelaskan barang yang dikembalikan" /></label>
          <label className="supplier-return-reason-text">Catatan<input maxLength={1000} value={note} onChange={(e) => setNote(e.target.value)} placeholder="Opsional" /></label></div>
        <div className="supplier-return-scan"><label>Scan barcode<input value={barcode} onChange={(e) => setBarcode(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); void scan(); } }} placeholder="Pindai lalu tekan Enter" autoComplete="off" /></label><button type="button" className="button-secondary" disabled={busy} onClick={() => void scan()}>Cari barcode</button></div>
        <label className="supplier-return-search">Cari barang<input value={query} onChange={(e) => void search(e.target.value)} placeholder="Nama, SKU, atau barcode" autoComplete="off" /></label>
        {results.length > 0 && <div className="supplier-return-results">{results.map((p) => <button type="button" key={p.product_id} onClick={() => addProduct(p)}><span><strong>{p.name}</strong><small>{p.sku}</small></span><span>Stok {fmt(p.effective_quantity)} · Tambah</span></button>)}</div>}
        <div className="supplier-return-lines">{lines.length === 0 ? <p>Tambahkan barang yang akan dikembalikan.</p> : lines.map((line) => <div className="supplier-return-line" key={line.productId}>
          <div className="supplier-return-product"><strong>{line.name}</strong><small>{line.sku} · Stok saat dipilih {fmt(line.stock)}</small></div>
          <label>Jumlah<input type="number" min="0.001" step="0.001" required value={line.quantity} onChange={(e) => setLines((all) => all.map((x) => x.productId === line.productId ? { ...x, quantity: e.target.value } : x))} /></label>
          <div className="supplier-return-source"><label>Penerimaan sumber (opsional)<select disabled={!supplierId} value={line.receiptItemId} onChange={(e) => void chooseReceipt(line.productId, e.target.value)}><option value="">Tidak ditautkan / legacy</option>{line.receiptItemId && !receiptOptions[line.productId]?.some((item) => item.receipt_item_id === line.receiptItemId) && <option value={line.receiptItemId}>{line.receiptLabel}</option>}{(receiptOptions[line.productId] ?? []).map((item) => <option key={item.receipt_item_id} value={item.receipt_item_id}>{item.receipt_reference} · sisa {fmt(item.available_quantity)}</option>)}</select></label><button type="button" className="supplier-return-link-source" disabled={!supplierId} onClick={() => void loadReceiptOptions(line.productId)}>Cari penerimaan</button></div>
          <label>Catatan<input value={line.note} maxLength={500} onChange={(e) => setLines((all) => all.map((x) => x.productId === line.productId ? { ...x, note: e.target.value } : x))} /></label>
          <button type="button" aria-label={`Hapus ${line.name}`} onClick={() => setLines((all) => all.filter((x) => x.productId !== line.productId))}>Hapus</button>
        </div>)}</div>
        {lines.length > 0 && <div className="supplier-return-review"><strong>Tinjau {lines.length} barang</strong><p>Retur mengurangi stok saat diposting. Nota, utang, dan pembayaran supplier tidak berubah otomatis.</p></div>}
        {notice && <p className="supplier-return-notice" role="status">{notice}</p>}<button className="button-primary" type="submit" disabled={busy || !lines.length}>{busy ? "Menyimpan…" : "Simpan draft"}</button>
      </form>
    </section>
    <section className="supplier-return-list"><h2>Riwayat retur</h2>{returns.length === 0 ? <p className="surface-card">Belum ada retur supplier.</p> : returns.map((row) => <article className="surface-card supplier-return-card" key={row.id}>
      <header><div><strong>{row.return_no}</strong><span>{row.status === "DRAFT" ? "Draft" : row.status === "POSTED" ? "Diposting" : "Dibatalkan"}</span></div><time>{new Date(row.created_at).toLocaleString("id-ID")}</time></header>
      <p><b>{row.suppliers?.display_name ?? suppliers.find((s) => s.id === row.supplier_id)?.display_name ?? "Supplier"}</b> · {reasons.find(([value]) => value === row.reason_category)?.[1]} · {row.reason}</p>
      <ul>{row.supplier_return_items.map((item) => <li key={item.id}>{item.products?.name ?? item.product_id}: {fmt(item.quantity)} unit{item.source_receipt_id ? " · penerimaan ditautkan" : ""}</li>)}</ul>
      {row.status === "DRAFT" && <div className="supplier-return-actions"><button className="button-secondary" disabled={busy} onClick={() => edit(row)}>Ubah draft</button><button className="button-secondary" disabled={busy} onClick={() => void cancel(row)}>Batalkan draft</button>{canPost && <button className="button-primary" disabled={busy} onClick={() => void post(row)}>Tinjau &amp; posting</button>}</div>}
      {row.status === "POSTED" && <small>Diposting {row.posted_by_name ?? "pengguna tidak tersedia"}{row.posted_at ? ` · ${new Date(row.posted_at).toLocaleString("id-ID")}` : ""}. Perubahan stok final; nota/refund supplier dikelola terpisah.</small>}
    </article>)}</section>
  </div>;
}
