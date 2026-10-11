"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { acknowledgePosCartPrice, addPosCartItem, cancelPosCart, ensureActivePosCart, parkPosCart, resolvePosBarcode, resumePosCart, searchPosProducts, setPosCartItemQuantity } from "@/app/actions/pos-cart";

type Row = Record<string, unknown>;
type Cart = Row & { id: string; status: string; revision: number; items: Row[] };
const asCart = (x: Row): Cart => ({ ...x, id: String(x.id), status: String(x.status), revision: Number(x.revision), items: Array.isArray(x.items) ? x.items as Row[] : [] });
const uuid = () => crypto.randomUUID();
const rupiah = (value: unknown) => new Intl.NumberFormat("id-ID", { style: "currency", currency: "IDR", maximumFractionDigits: 2 }).format(Number(value ?? 0));
const text = (value: unknown) => value == null ? "—" : String(value);
const priceStatus = (item: Row) => String(item.price_status ?? "UNAVAILABLE");

export function PosWorkspace({ initialCarts, initialError }: { initialCarts: Row[]; initialError: string | null }) {
  const router = useRouter();
  const carts = initialCarts.map(asCart);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<Row[]>([]);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState(initialError ?? "");
  const input = useRef<HTMLInputElement>(null);
  const searchSequence = useRef(0);
  const cart = carts.find((x) => x.status === "ACTIVE");
  const parked = carts.filter((x) => x.status === "PARKED");
  const isSuccessNotice = ["Barang ditambahkan", "Transaksi ditahan", "Transaksi dilanjutkan", "Transaksi dibatalkan", "Harga terbaru digunakan"].includes(notice);

  const reload = useCallback(() => router.refresh(), [router]);
  const finishMutation = (message?: string) => { setBusy(false); if (message) setNotice(message); reload(); input.current?.focus(); };

  useEffect(() => {
    if (!isSuccessNotice) return;
    const timer = window.setTimeout(() => setNotice(""), 2400);
    return () => window.clearTimeout(timer);
  }, [isSuccessNotice, notice]);

  useEffect(() => {
    const sequence = ++searchSequence.current;
    if (query.trim().length < 2) return;
    const timer = window.setTimeout(async () => {
      const result = await searchPosProducts(query);
      if (sequence !== searchSequence.current) return;
      if (result.ok) setResults(Array.isArray(result.value.rows) ? result.value.rows as Row[] : []);
      else setNotice(result.message);
    }, 230);
    return () => window.clearTimeout(timer);
  }, [query]);

  const add = async (productId: string, scannerAlreadyBusy = false) => {
    if (!cart || (busy && !scannerAlreadyBusy)) return;
    setBusy(true); setNotice("");
    const result = await addPosCartItem({ cartId: cart.id, productId, quantityDelta: "1", expectedRevision: cart.revision, requestId: uuid() });
    if (!result.ok) {
      setBusy(false); setNotice(result.message); reload(); input.current?.focus(); return;
    }
    setQuery(""); setResults([]); setNotice("Barang ditambahkan"); finishMutation();
  };

  const scan = async () => {
    const code = query.trim();
    if (!code || busy) return;
    searchSequence.current += 1;
    setResults([]);
    setBusy(true); setNotice("");
    const found = await resolvePosBarcode(code);
    if (!found.ok) { setBusy(false); setNotice(found.message); input.current?.focus(); return; }
    const resolution = String(found.value.resolution);
    if (resolution !== "BARCODE_MATCH" || !found.value.product || typeof found.value.product !== "object") {
      const messages: Record<string, string> = { BARCODE_NOT_FOUND: "Barcode belum terdaftar", BARCODE_AMBIGUOUS: "Barcode terdaftar pada lebih dari satu produk", PRICE_UNAVAILABLE: "Harga jual belum tersedia", PRICE_ZERO: "Harga jual belum tersedia", PRODUCT_UNAVAILABLE: "Produk tidak tersedia untuk outlet ini" };
      setBusy(false); setNotice(messages[resolution] ?? "Produk tidak tersedia"); input.current?.focus(); return;
    }
    await add(String((found.value.product as Row).product_id), true);
  };

  const setQuantity = async (item: Row, value: string) => {
    if (!cart || busy) return;
    if (!/^(?:0|[1-9]\d{0,11})(?:\.\d{1,3})?$/.test(value) || Number(value) < 0) { setNotice("Jumlah tidak valid. Gunakan maksimal tiga angka desimal."); return; }
    setBusy(true);
    const result = await setPosCartItemQuantity({ cartId: cart.id, itemId: String(item.id), quantity: value, expectedRevision: cart.revision, requestId: uuid() });
    finishMutation(result.ok ? undefined : result.message);
  };

  const transition = async (target: Cart, action: "park" | "resume" | "cancel") => {
    if (busy) return;
    if (action === "cancel" && !window.confirm("Batalkan transaksi ini? Barang di keranjang akan dibatalkan.")) return;
    setBusy(true);
    const result = action === "park" ? await parkPosCart(target.id, target.revision, uuid()) : action === "resume" ? await resumePosCart(target.id, target.revision, uuid()) : await cancelPosCart(target.id, target.revision, uuid());
    if (!result.ok) { finishMutation(result.message); return; }
    if (action === "park" || (action === "cancel" && target.status === "ACTIVE")) {
      const created = await ensureActivePosCart();
      if (!created.ok) { finishMutation(created.message); return; }
    }
    finishMutation(action === "park" ? "Transaksi ditahan" : action === "resume" ? "Transaksi dilanjutkan" : "Transaksi dibatalkan");
  };

  const acknowledge = async (item: Row) => {
    if (!cart || busy) return;
    setBusy(true);
    const [whole, fraction = ""] = String(item.current_unit_price).split(".");
    const currentPrice = `${whole}.${fraction.padEnd(2, "0").slice(0, 2)}`;
    const result = await acknowledgePosCartPrice({ cartId: cart.id, itemId: String(item.id), currentPrice, expectedRevision: cart.revision, requestId: uuid() });
    finishMutation(result.ok ? "Harga terbaru digunakan" : result.message);
  };

  return <div className="pos-workspace">
    <section className="pos-entry surface-card" aria-label="Cari dan masukkan produk">
      <div className="pos-section-head"><div><span className="eyebrow">INPUT BARANG</span><h2>Scan atau cari produk</h2></div><span className="pos-live-dot">Siap scan</span></div>
      <label className="pos-search-label" htmlFor="pos-product-query">Barcode, nama produk, atau SKU</label>
      <div className="pos-search-box"><span aria-hidden="true">⌕</span><input id="pos-product-query" ref={input} autoFocus value={query} onChange={(event) => setQuery(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") { event.preventDefault(); void scan(); } if (event.key === "Escape") setResults([]); }} placeholder="Scan barcode lalu tekan Enter" autoComplete="off" /><kbd>ENTER</kbd></div>
      <p className="pos-search-hint">Barcode diproses tepat saat Enter. Pencarian manual mulai dari 2 karakter.</p>
      {notice && <div className={`pos-notice${isSuccessNotice ? " pos-notice-success" : ""}`} role="status">{notice}</div>}
      {results.length > 0 && <div className="pos-results" role="listbox" aria-label="Hasil pencarian produk">{results.map((item) => <button type="button" className="pos-result" key={String(item.product_id)} disabled={busy} onClick={() => void add(String(item.product_id))}><span><strong>{text(item.name)}</strong><small>{text(item.sku)} · Stok efektif {text(item.effective_stock)} {text(item.unit)}</small></span><span className="pos-result-price">{rupiah(item.unit_price)}<small>Tambah +</small></span></button>)}</div>}
      {query.trim().length >= 2 && results.length === 0 && <div className="pos-no-results">Tidak ada hasil pencarian.</div>}
    </section>

    <section className="pos-cart surface-card" aria-label="Transaksi aktif">
      <header className="pos-cart-heading"><div><span className="eyebrow">KASIR</span><h2>Transaksi Aktif</h2></div><span className="pos-cart-status">Aktif</span></header>
      <div className="pos-items">{cart?.items.length ? cart.items.map((item) => <article className="pos-item" key={String(item.id)}><div className="pos-item-main"><strong>{text(item.name)}</strong><small>{text(item.sku)} · {rupiah(item.observed_unit_price)} / unit</small>{priceStatus(item) === "CHANGED" && <div className="pos-price-changed"><b>Harga berubah</b><span>Harga saat dimasukkan: {rupiah(item.observed_unit_price)}</span><span>Harga terbaru: {rupiah(item.current_unit_price)}</span><button type="button" disabled={busy} onClick={() => void acknowledge(item)}>Gunakan harga terbaru</button></div>}{priceStatus(item) === "UNAVAILABLE" && <div className="pos-price-unavailable">Harga jual belum tersedia</div>}</div><div className="pos-item-controls"><button type="button" aria-label={`Kurangi ${text(item.name)}`} disabled={busy} onClick={() => void setQuantity(item, String(Math.max(0, Number(item.quantity) - 1)))}>−</button><input aria-label={`Jumlah ${text(item.name)}`} inputMode="decimal" defaultValue={text(item.quantity)} key={`${item.id}:${item.quantity}`} onBlur={(event) => { if (event.currentTarget.value !== String(item.quantity)) void setQuantity(item, event.currentTarget.value); }} onKeyDown={(event) => { if (event.key === "Enter") event.currentTarget.blur(); }} /><button type="button" aria-label={`Tambah ${text(item.name)}`} disabled={busy} onClick={() => void setQuantity(item, String(Number(item.quantity) + 1))}>+</button><button type="button" className="pos-remove-line" aria-label={`Hapus ${text(item.name)}`} disabled={busy} onClick={() => void setQuantity(item, "0")}>×</button></div><strong className="pos-line-total">{rupiah(item.observed_line_total)}</strong></article>) : <div className="pos-empty"><strong>Belum ada barang</strong><small>Scan barcode atau cari produk untuk mulai transaksi.</small></div>}</div>
      <div className="pos-total"><span>TOTAL</span><strong>{rupiah(cart?.observed_total)}</strong></div>
      <div className="pos-cart-actions"><button type="button" className="pos-hold" disabled={!cart || busy} onClick={() => cart && void transition(cart, "park")}>Tahan Transaksi</button><button type="button" className="pos-cancel" disabled={!cart || busy} onClick={() => cart && void transition(cart, "cancel")}>Batalkan Transaksi</button></div>
      <button type="button" className="pos-pay" disabled aria-disabled="true">Bayar</button><p className="pos-pay-note">Pembayaran akan tersedia setelah modul checkout aktif.</p>
    </section>

    <section className={`pos-parked surface-card${parked.length ? " pos-parked-has-items" : " pos-parked-empty-state"}`}><header><div><span className="eyebrow">PARKIR</span><h2>Transaksi Ditahan <small>{parked.length}</small></h2></div></header>{parked.length ? <ul>{parked.map((item) => <li key={item.id}><div><strong>Transaksi ditahan</strong><small>{new Date(String(item.updated_at)).toLocaleString("id-ID", { dateStyle: "short", timeStyle: "short" })} · {item.items.length} barang</small></div><b>{rupiah(item.observed_total)}</b><button type="button" disabled={busy || !cart || cart.items.length > 0} title={cart?.items.length ? "Tahan transaksi aktif sebelum melanjutkan" : undefined} onClick={() => void transition(item, "resume")}>Lanjutkan</button><button type="button" className="pos-cancel-small" disabled={busy} aria-label="Batalkan transaksi ditahan" onClick={() => void transition(item, "cancel")}>×</button></li>)}</ul> : <p className="pos-parked-empty">Belum ada transaksi yang ditahan.</p>}</section>
  </div>;
}
