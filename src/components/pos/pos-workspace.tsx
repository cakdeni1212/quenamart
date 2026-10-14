"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { acknowledgePosCartPrice, addPosCartItem, cancelPosCart, checkoutPos, createPosCart, ensureActivePosCart, parkPosCart, readPosSaleReceipt, resolvePosBarcode, resumePosCart, searchPosMembers, searchPosProducts, setPosCartItemQuantity, setPosCartMember, setPosCartRedeemPoints } from "@/app/actions/pos-cart";
import { PosReceipt, type PosReceiptData } from "@/components/pos/pos-receipt";
import { RupiahInput } from "@/components/ui/rupiah-input";
import { ceilRupiah, compareRupiah, formatRupiah, subtractRupiah } from "@/lib/money";
import type { PosPaymentMethod, PosSettings } from "@/lib/settings/pos-shared";
import memberStyles from "./pos-member.module.css";

type Row = Record<string, unknown>;
type Cart = Row & { id: string; status: string; revision: number; items: Row[] };
type InitialLoyalty = { member: Row | null; policy: Row; redeem_points_requested: number; redeem_policy_updated_at: string | null; redeem_policy_revision: number } | null;
const asCart = (x: Row): Cart => ({ ...x, id: String(x.id), status: String(x.status), revision: Number(x.revision), items: Array.isArray(x.items) ? x.items as Row[] : [] });
const uuid = () => crypto.randomUUID();
const rupiah = (value: unknown) => formatRupiah(value === null || value === undefined ? null : String(value));
const text = (value: unknown) => value == null ? "—" : String(value);
const priceStatus = (item: Row) => String(item.price_status ?? "UNAVAILABLE");
const paymentOptions: { method: PosPaymentMethod; label: string }[] = [
  { method: "CASH", label: "Tunai" }, { method: "QRIS", label: "QRIS" },
  { method: "CARD", label: "Kartu" }, { method: "E_WALLET", label: "E-Wallet" },
];

export function PosWorkspace({ initialCarts, initialError, settings, initialLoyalty }: { initialCarts: Row[]; initialError: string | null; settings: Omit<PosSettings, "outlet_id">; initialLoyalty: InitialLoyalty }) {
  const router = useRouter();
  const carts = initialCarts.map(asCart);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<Row[]>([]);
  const [memberQuery, setMemberQuery] = useState("");
  const [memberResults, setMemberResults] = useState<Row[]>([]);
  const loyalty = initialLoyalty;
  const selectedMember = initialLoyalty?.member ?? null;
  const [redeemDraft, setRedeemDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState(initialError ?? "");
  const [paymentOpen, setPaymentOpen] = useState(false);
  const [paymentMethod, setPaymentMethod] = useState<PosPaymentMethod>(() => settings.enabled_payment_methods[0] ?? "CASH");
  const [cashReceived, setCashReceived] = useState("");
  const [referenceText, setReferenceText] = useState("");
  const [receipt, setReceipt] = useState<PosReceiptData | null>(null);
  const [receiptSize, setReceiptSize] = useState<"58" | "80">("80");
  const input = useRef<HTMLInputElement>(null);
  const checkoutRequestId = useRef<string | null>(null);
  const checkoutInFlight = useRef(false);
  const searchSequence = useRef(0);
  const memberSearchSequence = useRef(0);
  const cart = carts.find((x) => x.status === "ACTIVE");
  const parked = carts.filter((x) => x.status === "PARKED");
  const total = String(cart?.observed_total ?? "0");
  const pointsRequested = loyalty?.redeem_points_requested ?? 0;
  const redeemRate = Number(loyalty?.policy.rupiah_per_redeem_point ?? 0);
  const redeemDiscount = pointsRequested > 0 && Number.isSafeInteger(redeemRate) ? (BigInt(pointsRequested) * BigInt(redeemRate)).toString() : "0";
  const payableTotal = pointsRequested > 0 ? subtractRupiah(total, redeemDiscount) ?? "0" : total;
  const redemptionPolicyStale = pointsRequested > 0 && loyalty?.redeem_policy_revision !== Number(loyalty?.policy.policy_revision ?? 0);
  const cashSufficient = Boolean(cashReceived) && compareRupiah(cashReceived, payableTotal) !== -1;
  const changeAmount = cashReceived ? subtractRupiah(cashReceived, payableTotal) : null;
  const paymentReady = Boolean(cart && cart.status === "ACTIVE" && cart.items.length > 0
    && cart.items.every((item) => priceStatus(item) === "CURRENT") && !busy && !redemptionPolicyStale);
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

  useEffect(() => {
    const sequence = ++memberSearchSequence.current;
    if (memberQuery.trim().length < 2) return;
    const timer = window.setTimeout(async () => {
      const result = await searchPosMembers(memberQuery);
      if (sequence !== memberSearchSequence.current) return;
      if (result.ok) setMemberResults(Array.isArray(result.value.rows) ? result.value.rows as Row[] : []);
      else setNotice(result.message);
    }, 250);
    return () => window.clearTimeout(timer);
  }, [memberQuery]);

  const chooseMember = async (candidate: Row | null) => {
    if (!cart || busy) return;
    setBusy(true);
    const result = await setPosCartMember(cart.id, candidate ? String(candidate.id) : null, cart.revision, uuid());
    if (!result.ok) { setBusy(false); setNotice(result.message); reload(); return; }
    setRedeemDraft(""); setMemberQuery(""); setMemberResults([]); setNotice(""); setBusy(false); reload();
  };

  const applyRedeem = async () => {
    const pointsInput = redeemDraft || (redemptionPolicyStale ? String(pointsRequested) : "");
    if (!cart || !selectedMember || busy || !/^\d{1,10}$/.test(pointsInput)) return;
    const points = Number(pointsInput);
    const requestedDiscount = (BigInt(points) * BigInt(redeemRate)).toString();
    if (compareRupiah(requestedDiscount, total) === 1) { setNotice("Nilai poin melebihi total belanja."); return; }
    setBusy(true); setNotice("");
    const result = await setPosCartRedeemPoints(cart.id, points, cart.revision, uuid());
    if (!result.ok) { setBusy(false); setNotice(result.message); reload(); return; }
    setRedeemDraft(String(points)); setBusy(false); reload();
  };

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
    if (action === "cancel" && settings.confirm_cart_cancellation && !window.confirm("Batalkan transaksi ini? Barang di keranjang akan dibatalkan.")) return;
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

  const submitCheckout = async () => {
    if (!cart || !paymentReady || checkoutInFlight.current || (paymentMethod === "CASH" && !cashSufficient)) return;
    checkoutInFlight.current = true;
    checkoutRequestId.current ??= uuid();
    setBusy(true); setNotice("");
    try {
      const result = await checkoutPos({
        requestId: checkoutRequestId.current, cartId: cart.id, expectedRevision: cart.revision, method: paymentMethod,
        ...(paymentMethod === "CASH" ? { cashReceivedAmount: cashReceived } : {}),
        ...(referenceText.trim() ? { referenceText: referenceText.trim() } : {}),
      });
      if (!result.ok) {
        checkoutInFlight.current = false;
        setBusy(false); setNotice(result.message);
        if (["POS_CART_STALE", "POS_PRICE_CHANGED", "POS_PRICE_UNAVAILABLE", "POS_ALREADY_COMPLETED", "POS_INSUFFICIENT_STOCK", "POS_LOYALTY_POLICY_CHANGED", "POS_LOYALTY_INSUFFICIENT_POINTS", "POS_LOYALTY_REDEEM_DISABLED"].includes(result.code)) reload();
        return;
      }
      const response = result.value;
      const saleId = String(response.sale_id ?? "");
      const read = saleId ? await readPosSaleReceipt(saleId) : null;
      let data = read?.ok ? read.value : response;
      if (!Array.isArray(data.payments)) data = { ...data, payments: [{
        method: data.payment_method, applied_amount: data.grand_total,
        received_amount: data.cash_received_amount, change_amount: data.change_amount,
        reference_text: data.reference_text,
      }] };
      checkoutRequestId.current = null;
      setReceipt(data as unknown as PosReceiptData);
      setPaymentOpen(false); setBusy(false); setNotice("");
    } catch {
      checkoutInFlight.current = false;
      setBusy(false);
      setNotice("Koneksi terputus. Periksa lalu coba konfirmasi lagi dengan data pembayaran yang sama.");
    }
  };

  const startNewTransaction = async () => {
    if (busy) return;
    setBusy(true);
    const result = await createPosCart(uuid());
    setBusy(false);
    if (!result.ok) { setNotice(result.message); return; }
    setReceipt(null); setPaymentOpen(false); setCashReceived(""); setReferenceText(""); checkoutRequestId.current = null;
    reload();
    window.setTimeout(() => input.current?.focus(), 80);
  };

  const completedPayment = receipt?.payments[0];
  const completedMethod = String(completedPayment?.method ?? "");
  const methodLabel: Record<string, string> = { CASH: "Tunai", QRIS: "QRIS", CARD: "Kartu", E_WALLET: "E-Wallet" };

  if (receipt) return <section className="pos-success surface-card" aria-live="polite">
    <div className="pos-success-copy"><span className="pos-success-mark" aria-hidden="true">✓</span><span className="eyebrow">PEMBAYARAN TERCATAT</span><h2>Transaksi Berhasil</h2><strong>{receipt.sale_number}</strong><p>{new Intl.DateTimeFormat("id-ID", { dateStyle: "medium", timeStyle: "short" }).format(new Date(receipt.completed_at))} · {receipt.cashier_label}</p><p>{rupiah(receipt.grand_total)} · {compareRupiah(String(receipt.grand_total), "0") === 0 ? "Lunas dengan poin" : methodLabel[completedMethod] ?? "Pembayaran"}</p>{completedMethod === "CASH" && <p>Diterima {rupiah(completedPayment?.received_amount)} · Kembalian {rupiah(completedPayment?.change_amount)}</p>}</div>
    <div className="pos-receipt-toolbar"><label>Ukuran struk<select value={receiptSize} onChange={(event) => setReceiptSize(event.target.value as "58" | "80")}><option value="58">58 mm</option><option value="80">80 mm</option></select></label><button type="button" className="pos-secondary" onClick={() => window.print()}>Cetak Struk</button><button type="button" className="pos-pay" disabled={busy} onClick={() => void startNewTransaction()}>{busy ? "Menyiapkan…" : "Transaksi Baru"}</button></div>
    <div className="pos-receipt-preview"><PosReceipt receipt={receipt} size={receiptSize} /></div>
    <div className="pos-print-root"><PosReceipt receipt={receipt} size={receiptSize} /></div>
  </section>;

  return <div className="pos-workspace">
    <section className="pos-entry surface-card" aria-label="Cari dan masukkan produk">
      <div className={memberStyles.panel}>
        <label htmlFor="pos-member-query">Member (opsional)</label>
        {selectedMember ? <div className={memberStyles.selected}><span><strong>{text(selectedMember.full_name)}</strong><small>{text(selectedMember.member_number)} · Poin {Number(loyalty?.member?.point_balance ?? selectedMember.point_balance ?? 0).toLocaleString("id-ID")}</small></span><button type="button" disabled={busy || !cart} onClick={() => void chooseMember(null)}>Hapus</button></div> : <input id="pos-member-query" value={memberQuery} onChange={(event) => setMemberQuery(event.target.value)} placeholder="Cari nomor HP, ID Member, atau scan kode" autoComplete="off" disabled={!cart || busy} />}
        {selectedMember && loyalty?.policy.program_enabled === true && loyalty.policy.redeem_enabled === true && <div className="pos-loyalty-redeem">
          <strong>Tukar Poin</strong><small>Saldo {Number(loyalty.member?.point_balance ?? selectedMember.point_balance ?? 0).toLocaleString("id-ID")} poin · minimum {Number(loyalty.policy.minimum_redeem_points).toLocaleString("id-ID")} poin · 1 poin = {rupiah(loyalty.policy.rupiah_per_redeem_point)}</small>
          {redemptionPolicyStale && <small role="alert">Aturan penukaran berubah. Periksa jumlah poin lalu terapkan kembali.</small>}
          <div><input aria-label="Jumlah poin yang digunakan" inputMode="numeric" value={redeemDraft || (redemptionPolicyStale ? String(pointsRequested) : "")} onChange={(event) => setRedeemDraft(event.target.value.replace(/\D/g, "").slice(0, 9))} placeholder="Jumlah poin" disabled={!cart || busy} /><span>{(redeemDraft || (redemptionPolicyStale ? String(pointsRequested) : "")) && redeemRate ? rupiah((BigInt(redeemDraft || String(pointsRequested)) * BigInt(redeemRate)).toString()) : "Potongan"}</span></div>
          <button type="button" disabled={!cart || busy || !/^\d{1,9}$/.test(redeemDraft || (redemptionPolicyStale ? String(pointsRequested) : ""))} onClick={() => void applyRedeem()}>{redemptionPolicyStale ? "Terapkan Ulang" : pointsRequested > 0 ? "Perbarui Penukaran" : "Terapkan"}</button>
        </div>}
        {memberQuery.trim().length >= 2 && memberResults.length > 0 && <div className={memberStyles.results} role="group" aria-label="Hasil pencarian member">{memberResults.map((candidate) => <button type="button" key={String(candidate.id)} disabled={busy} onClick={() => void chooseMember(candidate)}><strong>{text(candidate.full_name)}</strong><small>{text(candidate.member_number)} · {text(candidate.phone)}</small></button>)}</div>}
      </div>
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
      {pointsRequested > 0 && <div className="pos-loyalty-discount"><span>Potongan poin · {pointsRequested.toLocaleString("id-ID")} poin</span><strong>-{rupiah(redeemDiscount)}</strong></div>}
      <div className="pos-total"><span>{pointsRequested > 0 ? "TOTAL BAYAR" : "TOTAL"}</span><strong>{rupiah(payableTotal)}</strong></div>
      <div className="pos-cart-actions">{settings.allow_hold_transactions && <button type="button" className="pos-hold" disabled={!cart || busy} onClick={() => cart && void transition(cart, "park")}>Tahan Transaksi</button>}<button type="button" className="pos-cancel" disabled={!cart || busy} onClick={() => cart && void transition(cart, "cancel")}>Batalkan Transaksi</button></div>
      <button type="button" className="pos-pay" disabled={!paymentReady} aria-disabled={!paymentReady} onClick={() => { setNotice(""); setPaymentOpen(true); checkoutRequestId.current ??= uuid(); }}>Bayar</button>
      {!paymentReady && <p className="pos-pay-note">{redemptionPolicyStale ? "Aturan penukaran berubah. Terapkan ulang jumlah poin sebelum membayar." : "Periksa barang dan status harga sebelum pembayaran."}</p>}
    </section>

    <section className={`pos-parked surface-card${parked.length ? " pos-parked-has-items" : " pos-parked-empty-state"}`}><header><div><span className="eyebrow">PARKIR</span><h2>Transaksi Ditahan <small>{parked.length}</small></h2></div></header>{parked.length ? <ul>{parked.map((item) => <li key={item.id}><div><strong>Transaksi ditahan</strong><small>{new Date(String(item.updated_at)).toLocaleString("id-ID", { dateStyle: "short", timeStyle: "short" })} · {item.items.length} barang</small></div><b>{rupiah(item.observed_total)}</b><button type="button" disabled={busy || !cart || cart.items.length > 0} title={cart?.items.length ? "Tahan transaksi aktif sebelum melanjutkan" : undefined} onClick={() => void transition(item, "resume")}>Lanjutkan</button><button type="button" className="pos-cancel-small" disabled={busy} aria-label="Batalkan transaksi ditahan" onClick={() => void transition(item, "cancel")}>×</button></li>)}</ul> : <p className="pos-parked-empty">Belum ada transaksi yang ditahan.</p>}</section>
    {paymentOpen && <div className="pos-payment-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && !busy) setPaymentOpen(false); }}><section className="pos-payment-panel surface-card" role="dialog" aria-modal="true" aria-labelledby="pos-payment-title"><header><div><span className="eyebrow">PEMBAYARAN</span><h2 id="pos-payment-title">Pilih metode pembayaran</h2></div><button type="button" className="pos-dialog-close" aria-label="Tutup pembayaran" disabled={busy} onClick={() => setPaymentOpen(false)}>×</button></header><div className="pos-payment-total"><span>TOTAL BAYAR</span><strong>{rupiah(payableTotal)}</strong>{pointsRequested > 0 && <small>Total barang {rupiah(total)} · potongan poin {rupiah(redeemDiscount)}</small>}</div><div className="pos-payment-methods" role="group" aria-label="Metode pembayaran">{paymentOptions.filter(({ method }) => settings.enabled_payment_methods.includes(method)).map(({ method, label }) => <button type="button" key={method} className={paymentMethod === method ? "selected" : ""} aria-pressed={paymentMethod === method} disabled={busy} onClick={() => { if (paymentMethod !== method) checkoutRequestId.current = uuid(); setPaymentMethod(method); }}>{label}</button>)}</div>{paymentMethod === "CASH" ? <div className="pos-cash-fields"><label htmlFor="pos-cash-received">UANG DITERIMA</label><RupiahInput id="pos-cash-received" className="pos-cash-input" autoFocus value={cashReceived} onValueChange={(value) => { if (cashReceived !== value) checkoutRequestId.current = uuid(); setCashReceived(value); }} placeholder="0" disabled={busy} /><div className="pos-cash-quick">{[ceilRupiah(payableTotal), "20000", "50000", "100000"].filter((amount, index, all): amount is string => amount !== null && compareRupiah(amount, payableTotal) !== -1 && all.indexOf(amount) === index).map((amount) => <button type="button" key={amount} disabled={busy} onClick={() => { if (cashReceived !== amount) checkoutRequestId.current = uuid(); setCashReceived(amount); }}>{amount === ceilRupiah(payableTotal) ? "Uang Pas" : rupiah(amount)}</button>)}</div><div className="pos-change"><span>KEMBALIAN</span><strong>{changeAmount === null ? rupiah("0") : rupiah(changeAmount)}</strong></div>{cashReceived && !cashSufficient && <p className="pos-payment-error" role="status">Uang diterima belum mencukupi.</p>}</div> : <div className="pos-noncash-note">Nominal pembayaran {rupiah(payableTotal)}. Pilih metode yang digunakan pelanggan.</div>}<label className="pos-reference" htmlFor="pos-payment-reference">Referensi (opsional)<input id="pos-payment-reference" maxLength={160} value={referenceText} onChange={(event) => { if (referenceText !== event.target.value) checkoutRequestId.current = uuid(); setReferenceText(event.target.value); }} disabled={busy} /></label>{notice && <p className="pos-payment-error" role="alert">{notice}</p>}<div className="pos-payment-actions"><button type="button" className="pos-secondary" disabled={busy} onClick={() => setPaymentOpen(false)}>Kembali</button><button type="button" className="pos-pay" disabled={!paymentReady || busy || (paymentMethod === "CASH" && !cashSufficient)} onClick={() => void submitCheckout()}>{busy ? "Memproses pembayaran…" : "Konfirmasi Pembayaran"}</button></div></section></div>}
  </div>;
}
