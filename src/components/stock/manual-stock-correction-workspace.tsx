"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { cancelManualCorrection, createManualCorrection, postManualCorrection, resolveManualCorrectionBarcode, searchManualCorrectionProducts, updateManualCorrection } from "@/app/actions/manual-stock-correction";
import type { ManualCorrectionRead } from "@/lib/stock/manual-correction-read";

type Product = { product_id: string; name: string; sku: string; barcode: string | null; effective_quantity: number | string };
type Line = { productId: string; name: string; sku: string; barcode: string | null; stock: number | null; direction: "IN" | "OUT"; quantity: string; note: string };
const reasonOptions = [["DAMAGED","Rusak"],["LOST","Hilang"],["FOUND","Ditemukan"],["INPUT_ERROR","Kesalahan input"],["EXPIRED","Kedaluwarsa"],["OTHER","Lainnya"]] as const;
const fmt = (value: number | string) => new Intl.NumberFormat("id-ID", { maximumFractionDigits: 3 }).format(Number(value));

export function ManualStockCorrectionWorkspace({ outletId, outletName, corrections }: {
  outletId: string; outletName: string; corrections: ManualCorrectionRead[];
}) {
  const router = useRouter();
  const [reasonCategory, setReasonCategory] = useState("DAMAGED");
  const [reason, setReason] = useState("");
  const [lines, setLines] = useState<Line[]>([]);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<Product[]>([]);
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [editing, setEditing] = useState<ManualCorrectionRead | null>(null);
  const [scanText, setScanText] = useState("");

  const quantityTotal = useMemo(() => lines.reduce((sum, line) => sum + Number(line.quantity || 0), 0), [lines]);

  async function search(value: string) {
    setQuery(value);
    if (value.trim().length < 2) { setResults([]); return; }
    const result = await searchManualCorrectionProducts(value);
    if (!result.ok) { setNotice(result.message); return; }
    setResults((result.value.rows as Product[]) ?? []);
  }

  function addProduct(product: Product) {
    setLines((current) => current.some((line) => line.productId === product.product_id) ? current : [...current, {
      productId: product.product_id, name: product.name, sku: product.sku, barcode: product.barcode,
      stock: Number(product.effective_quantity), direction: "OUT", quantity: "", note: "",
    }]);
    setQuery(""); setResults([]);
  }

  async function scanBarcode() {
    const code = scanText.trim();
    if (!code) return;
    setBusy(true);
    const result = await resolveManualCorrectionBarcode(code);
    setBusy(false);
    if (!result.ok) { setNotice(result.message); return; }
    const row = result.value as unknown as { productId: string; name: string; sku: string; barcode: string | null; stock: string | number };
    addProduct({ product_id: row.productId, name: row.name, sku: row.sku, barcode: row.barcode, effective_quantity: row.stock });
    setNotice(`Produk ditemukan: ${row.name}`); setScanText("");
  }

  function editCorrection(correction: ManualCorrectionRead) {
    setEditing(correction); setReasonCategory(correction.reason_category); setReason(correction.reason);
    setLines(correction.manual_stock_correction_items.map((item) => ({
      productId: item.product_id, name: item.products?.name ?? item.product_id, sku: item.products?.sku ?? "",
      barcode: null, stock: null, direction: Number(item.quantity_delta) > 0 ? "IN" : "OUT",
      quantity: String(Math.abs(Number(item.quantity_delta))), note: item.note ?? "",
    })));
    setNotice(`Mengubah draft ${correction.correction_no}.`);
  }

  function resetForm() { setEditing(null); setReasonCategory("DAMAGED"); setReason(""); setLines([]); setNotice(""); }

  async function saveDraft(event: React.FormEvent) {
    event.preventDefault();
    if (!lines.length || lines.some((line) => !Number.isFinite(Number(line.quantity)) || Number(line.quantity) <= 0 || Number(line.quantity) !== Math.round(Number(line.quantity) * 1000) / 1000)) {
      setNotice("Masukkan produk dan jumlah positif dengan maksimal tiga angka desimal."); return;
    }
    setBusy(true);
    const payload = {
      reasonCategory,
      reason,
      lines: lines.map((line) => ({ productId: line.productId, quantityDelta: Number(line.quantity) * (line.direction === "IN" ? 1 : -1), note: line.note || null })),
    };
    const result = editing
      ? await updateManualCorrection({ id: editing.id, expectedRevision: editing.revision, ...payload })
      : await createManualCorrection({ outletId, ...payload });
    setBusy(false);
    if (!result.ok) { setNotice(result.message); return; }
    setNotice(editing ? "Draft koreksi diperbarui." : `Draft ${String(result.value.correctionNo)} tersimpan.`);
    resetForm(); router.refresh();
  }

  async function postCorrection(correction: ManualCorrectionRead) {
    if (!window.confirm("Koreksi stok akan mengubah stok dan tidak dapat diedit setelah diposting. Lanjutkan?")) return;
    const storageKey = `quena-stock-correction-post:${correction.id}`;
    let requestId = window.sessionStorage.getItem(storageKey);
    if (!requestId) { requestId = window.crypto.randomUUID(); window.sessionStorage.setItem(storageKey, requestId); }
    setBusy(true); setNotice("");
    const result = await postManualCorrection(correction.id, requestId);
    setBusy(false);
    if (!result.ok) { setNotice(result.message); return; }
    window.sessionStorage.removeItem(storageKey);
    setNotice(`Koreksi ${correction.correction_no} berhasil diposting.`); router.refresh();
  }

  async function cancelCorrection(correction: ManualCorrectionRead) {
    const why = window.prompt("Alasan pembatalan draft");
    if (!why) return;
    setBusy(true); const result = await cancelManualCorrection(correction.id, why); setBusy(false);
    setNotice(result.ok ? `Draft ${correction.correction_no} dibatalkan.` : result.message); router.refresh();
  }

  return <div className="manual-stock-correction-workspace">
    <section className="surface-card manual-stock-correction-form">
      <div className="manual-stock-correction-form-heading"><div><span className="eyebrow">KOREKSI TERKONTROL · {outletName}</span><h2>{editing ? `Ubah ${editing.correction_no}` : "Buat koreksi"}</h2></div>
        {editing && <button type="button" className="button-secondary" onClick={resetForm}>Batal mengubah</button>}</div>
      <form onSubmit={saveDraft}>
        <div className="manual-stock-correction-reasons">
          <label>Kategori alasan<select value={reasonCategory} onChange={(e) => setReasonCategory(e.target.value)}>{reasonOptions.map(([value,label]) => <option key={value} value={value}>{label}</option>)}</select></label>
          <label>Alasan dan keterangan<input value={reason} onChange={(e) => setReason(e.target.value)} required minLength={reasonCategory === "OTHER" ? 10 : 3} maxLength={1000} placeholder={reasonCategory === "OTHER" ? "Jelaskan setidaknya 10 karakter" : "Contoh: botol bocor saat pemeriksaan rak"} /></label>
        </div>
        <div className="manual-stock-correction-scan">
          <label>Scan barcode<input value={scanText} onChange={(e) => setScanText(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); void scanBarcode(); } }} placeholder="Pindai lalu tekan Enter" autoComplete="off" /></label>
          <button type="button" className="button-secondary" disabled={busy} onClick={() => void scanBarcode()}>Cari barcode</button>
        </div>
        <label className="manual-stock-correction-search">Cari nama, SKU, atau barcode<input value={query} onChange={(e) => void search(e.target.value)} placeholder="Ketik minimal dua karakter" autoComplete="off" /></label>
        {results.length > 0 && <div className="manual-stock-correction-results">{results.map((product) => <button type="button" key={product.product_id} onClick={() => addProduct(product)}>
          <span><strong>{product.name}</strong><small>{product.sku} · {product.barcode ?? "Tanpa barcode"}</small></span><span>Stok {fmt(product.effective_quantity)} <b>Tambah</b></span>
        </button>)}</div>}
        <div className="manual-stock-correction-lines">
          {lines.length === 0 ? <p>Tambahkan satu atau beberapa produk untuk dikoreksi.</p> : lines.map((line) => <div className="manual-stock-correction-line" key={line.productId}>
            <div className="manual-stock-correction-product"><strong>{line.name}</strong><small>{line.sku} · {line.stock === null ? "Saldo akan diperiksa saat posting" : `Stok saat dipilih ${fmt(line.stock)}`}</small></div>
            <label>Aksi<select value={line.direction} onChange={(e) => setLines((all) => all.map((x) => x.productId === line.productId ? { ...x, direction: e.target.value as "IN" | "OUT" } : x))}><option value="OUT">Kurangi</option><option value="IN">Tambah</option></select></label>
            <label>Jumlah<input type="number" min="0.001" step="0.001" value={line.quantity} onChange={(e) => setLines((all) => all.map((x) => x.productId === line.productId ? { ...x, quantity: e.target.value } : x))} required /></label>
            <label>Catatan barang<input value={line.note} onChange={(e) => setLines((all) => all.map((x) => x.productId === line.productId ? { ...x, note: e.target.value } : x))} maxLength={500} placeholder="Opsional" /></label>
            <button type="button" aria-label={`Hapus ${line.name}`} onClick={() => setLines((all) => all.filter((x) => x.productId !== line.productId))}>Hapus</button>
          </div>)}
        </div>
        {lines.length > 0 && <div className="manual-stock-correction-review"><strong>Periksa kembali {lines.length} barang</strong><span>Total kuantitas perubahan: {fmt(quantityTotal)} unit</span>
          <p>Koreksi stok akan mengubah stok dan tidak dapat diedit setelah diposting.</p></div>}
        {notice && <p className="manual-stock-correction-notice" role="status">{notice}</p>}
        <button type="submit" className="button-primary" disabled={busy || !lines.length}>{busy ? "Menyimpan…" : "Simpan sebagai draft"}</button>
      </form>
    </section>
    <section className="manual-stock-correction-list" aria-label="Riwayat koreksi stok"><h2>Riwayat koreksi</h2>
      {corrections.length === 0 ? <p className="surface-card">Belum ada koreksi stok.</p> : corrections.map((correction) => <article className="surface-card manual-stock-correction-card" key={correction.id}>
        <div className="manual-stock-correction-card-heading"><div><span>{correction.correction_no}</span><strong>{correction.status === "DRAFT" ? "Draft" : correction.status === "POSTED" ? "Diposting" : "Dibatalkan"}</strong></div><time>{new Date(correction.created_at).toLocaleString("id-ID")}</time></div>
        <p><b>{reasonOptions.find(([value]) => value === correction.reason_category)?.[1]}</b> · {correction.reason}</p>
        <ul>{correction.manual_stock_correction_items.map((item) => <li key={item.id}>{item.products?.name ?? item.product_id}: {Number(item.quantity_delta) > 0 ? "+" : "−"}{fmt(Math.abs(Number(item.quantity_delta)))} unit</li>)}</ul>
        {correction.status === "DRAFT" && <div className="manual-stock-correction-card-actions"><button type="button" className="button-secondary" disabled={busy} onClick={() => editCorrection(correction)}>Ubah draft</button><button type="button" className="button-secondary" disabled={busy} onClick={() => void cancelCorrection(correction)}>Batalkan draft</button><button type="button" className="button-primary" disabled={busy} onClick={() => void postCorrection(correction)}>Tinjau &amp; posting</button></div>}
        {correction.status === "POSTED" && <small>Diposting {correction.posted_by_name ?? "pengguna tidak tersedia"}{correction.posted_at ? ` · ${new Date(correction.posted_at).toLocaleString("id-ID")}` : ""}. Perubahan stok final dan hanya dapat dikoreksi melalui pembalikan terkontrol.</small>}
      </article>)}
    </section>
  </div>;
}
