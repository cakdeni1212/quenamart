"use client";

import { useCallback, useEffect, useMemo, useState, type FormEvent } from "react";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { applyRecordCountIntent, issueRecordCountIntent, type RecordCountActionResult } from "@/lib/stock/opname-count-action";
import { STOCK_OPNAME_COUNT_FILTERS, STOCK_OPNAME_COUNT_PAGE_SIZE, type StockOpnameCountFilter } from "@/lib/stock/opname-count-model";
import type { StockOpnameCountData } from "@/lib/stock/opname-count-read";

const FILTER_LABEL: Record<StockOpnameCountFilter, string> = {
  ALL: "Semua",
  UNCOUNTED: "Belum dihitung",
  COUNTED: "Sudah dihitung",
  RECOUNT: "Perlu hitung ulang",
};

type BarcodeResult = {
  resolution: "BARCODE_NOT_FOUND" | "BARCODE_MATCH" | "BARCODE_AMBIGUOUS";
  product_id: string | null;
  sku: string | null;
  product_name: string | null;
  barcode_id: string | null;
};

type PendingRequest = { requestId: string; quantity: string };

function countFormat(value: number | string | null) {
  if (value === null) return "—";
  return new Intl.NumberFormat("id-ID", { maximumFractionDigits: 3 }).format(Number(value));
}

function hrefFor(pathname: string, q: string, filter: StockOpnameCountFilter, page: number) {
  const params = new URLSearchParams();
  if (q) params.set("q", q);
  if (filter !== "ALL") params.set("filter", filter);
  if (page > 1) params.set("page", String(page));
  const suffix = params.toString();
  return suffix ? `${pathname}?${suffix}` : pathname;
}

function pendingKey(sessionId: string, productId: string) {
  return `quena-opname-count:${sessionId}:${productId}`;
}

function loadPendingValue(key: string): string | null {
  try { return window.sessionStorage.getItem(key); } catch { return null; }
}

function savePendingValue(key: string, value: string): boolean {
  try { window.sessionStorage.setItem(key, value); return true; } catch { return false; }
}

function removePendingValue(key: string) {
  try { window.sessionStorage.removeItem(key); } catch { /* replay remains safe if storage cannot be cleared */ }
}

export function StockOpnameCounting({ data }: { data: StockOpnameCountData }) {
  const router = useRouter();
  const pathname = usePathname();
  const supabase = useMemo(() => createClient(), []);
  const [barcode, setBarcode] = useState("");
  const [scanNotice, setScanNotice] = useState<string | null>(null);
  const [scanError, setScanError] = useState(false);
  const [focusedProduct, setFocusedProduct] = useState<string | null>(null);
  const [scannedBarcodeByProduct, setScannedBarcodeByProduct] = useState<Map<string, string>>(() => new Map());
  const [editingProduct, setEditingProduct] = useState<string | null>(null);
  const [quantityDraft, setQuantityDraft] = useState("");
  const [pendingByProduct, setPendingByProduct] = useState<Map<string, PendingRequest>>(() => new Map());
  const [busyProduct, setBusyProduct] = useState<string | null>(null);
  const [feedback, setFeedback] = useState<{ productId: string; result: RecordCountActionResult } | null>(null);
  const backHref = "/stok/opname";

  useEffect(() => {
    if (!data.session) return;
    const timer = window.setTimeout(() => {
      const restored = new Map<string, PendingRequest>();
      for (const item of data.items) {
        const storageKey = pendingKey(data.session!.id, item.productId);
        const raw = loadPendingValue(storageKey);
        if (!raw) continue;
        try {
          const parsed = JSON.parse(raw) as PendingRequest;
          if (typeof parsed.requestId === "string" && typeof parsed.quantity === "string") restored.set(item.productId, parsed);
        } catch {
          removePendingValue(storageKey);
        }
      }
      setPendingByProduct(restored);
    }, 0);
    return () => window.clearTimeout(timer);
  }, [data.items, data.session]);

  useEffect(() => {
    if (!focusedProduct) return;
    const item = data.items.find((row) => row.productId === focusedProduct);
    if (!item) return;
    requestAnimationFrame(() => {
      setEditingProduct(item.productId);
      setQuantityDraft(item.physicalQuantity === null ? "" : String(item.physicalQuantity));
      document.getElementById(`opname-item-${item.productId}`)?.scrollIntoView({ behavior: "smooth", block: "center" });
      setFocusedProduct(null);
    });
  }, [data.items, focusedProduct]);

  const finishApply = useCallback(async (productId: string, requestId: string) => {
    setBusyProduct(productId);
    let result: RecordCountActionResult;
    try {
      result = await applyRecordCountIntent(requestId);
    } catch {
      result = { kind: "error", requestId, message: "Respons belum diterima. Ulangi permintaan tersimpan dengan tombol yang sama." };
    }
    setFeedback({ productId, result });
    setBusyProduct(null);
    if (result.kind === "success" || result.kind === "stale-item" || result.kind === "stale-baseline") {
      if (data.session) removePendingValue(pendingKey(data.session.id, productId));
      setPendingByProduct((current) => {
        const next = new Map(current);
        next.delete(productId);
        return next;
      });
      if (result.kind === "success") {
        setScannedBarcodeByProduct((current) => {
          const next = new Map(current);
          next.delete(productId);
          return next;
        });
      }
      if (result.kind === "stale-item" || result.kind === "stale-baseline") {
        setEditingProduct(null);
      }
      router.refresh();
    }
  }, [data.session, router]);

  async function saveCount(item: StockOpnameCountData["items"][number]) {
    if (!data.session) return;
    setFeedback(null);
    setBusyProduct(item.productId);
    const input = {
      sessionId: data.session.id,
      productId: item.productId,
      physicalQuantity: quantityDraft,
      expectedRevision: item.revision,
      barcodeId: scannedBarcodeByProduct.get(item.productId) ?? null,
    };
    let issued: RecordCountActionResult;
    try {
      issued = await issueRecordCountIntent(input);
    } catch {
      setFeedback({ productId: item.productId, result: { kind: "error", message: "Permintaan belum dapat dikonfirmasi. Kirim ulang nilai yang sama untuk melanjutkan." } });
      setBusyProduct(null);
      return;
    }
    if (issued.kind !== "issued" || !issued.requestId) {
      setFeedback({ productId: item.productId, result: issued });
      setBusyProduct(null);
      return;
    }
    const pending = { requestId: issued.requestId, quantity: quantityDraft };
    if (!savePendingValue(pendingKey(data.session.id, item.productId), JSON.stringify(pending))) {
      setFeedback({ productId: item.productId, result: { kind: "error", requestId: issued.requestId, message: "Browser tidak dapat menyimpan ID permintaan untuk retry aman. Aktifkan penyimpanan sesi browser lalu kirim ulang nilai yang sama." } });
      setBusyProduct(null);
      return;
    }
    setPendingByProduct((current) => new Map(current).set(item.productId, pending));
    setBusyProduct(null);
    await finishApply(item.productId, issued.requestId);
  }

  async function scanBarcode(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const value = barcode.trim();
    if (!data.session || !value) return;
    setScanNotice(null);
    setScanError(false);
    const { data: rows, error } = await supabase.rpc("resolve_stock_barcode", {
      p_outlet_id: data.session.outletId,
      p_barcode: value,
    });
    if (error) {
      console.error("[stock-opname-count] barcode resolver failed", {
        operation: "resolve_stock_barcode",
        code: error.code?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 80),
        message: error.message.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240),
      });
      setScanNotice("Barcode belum dapat diperiksa. Coba lagi.");
      setScanError(true);
      return;
    }
    const match = ((rows ?? []) as BarcodeResult[])[0];
    if (!match || match.resolution === "BARCODE_NOT_FOUND") {
      setScanNotice("Barcode belum terdaftar");
      return;
    }
    if (match.resolution === "BARCODE_AMBIGUOUS") {
      setScanNotice("Barcode terhubung ke beberapa produk. Pemilihan otomatis diblokir.");
      setScanError(true);
      return;
    }
    if (!match.product_id || !match.sku || !match.barcode_id) {
      setScanNotice("Produk tidak dapat dipastikan dari barcode ini.");
      setScanError(true);
      return;
    }
    const { data: item, error: itemError } = await supabase.from("stock_opname_items")
      .select("product_id").eq("session_id", data.session.id).eq("product_id", match.product_id).maybeSingle();
    if (itemError) {
      console.error("[stock-opname-count] session item lookup failed", {
        operation: "stock_opname_item_barcode_membership",
        code: itemError.code?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 80),
        message: itemError.message.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240),
      });
      setScanNotice("Item opname belum dapat diperiksa. Coba lagi.");
      setScanError(true);
      return;
    }
    if (!item) {
      setScanNotice("Produk ini tidak termasuk dalam sesi opname.");
      setScanError(true);
      return;
    }
    setScannedBarcodeByProduct((current) => new Map(current).set(match.product_id!, match.barcode_id!));
    setFocusedProduct(match.product_id);
    setScanNotice("Produk ditemukan. Periksa item dan simpan jumlah fisik secara manual.");
    setBarcode("");
    const target = hrefFor(pathname, match.sku, "ALL", 1);
    router.replace(target);
  }

  const progressPercent = data.progress.total ? Math.round((data.progress.counted / data.progress.total) * 100) : 0;
  const canCount = data.session?.status === "COUNTING";

  return <div className="stock-opname-counting">
    <Link className="stock-opname-back" href={backHref}>← Kembali ke daftar opname</Link>
    {data.error ? <div className="surface-card product-state product-error" role="alert"><strong>Ruang hitung belum dapat dimuat.</strong><span>{data.error}</span></div> : !data.session ? null : <>
      <div className="eyebrow">PERSEDIAAN OUTLET · PENCATATAN FISIK</div>
      <div className="page-heading stock-opname-heading">
        <div><h1>Opname #{data.session.id.slice(0, 8).toUpperCase()}</h1><p>{data.session.outletName} · {data.session.scope === "FULL" ? "Opname penuh" : "Opname sebagian"}</p></div>
        <span className={`stock-opname-status stock-opname-status-${data.session.status.toLowerCase()}`}>{data.session.status === "COUNTING" ? "Menghitung" : data.session.status === "REVIEW" ? "Menunggu posting" : data.session.status === "POSTED" ? "Selesai" : "Dibatalkan"}</span>
      </div>

      <section className="surface-card stock-opname-progress" aria-label="Progress opname">
        <div className="stock-opname-progress-numbers">
          <div><strong>{data.progress.counted.toLocaleString("id-ID")}</strong><span>terhitung</span></div>
          <div><strong>{data.progress.total.toLocaleString("id-ID")}</strong><span>total item</span></div>
          <div><strong>{data.progress.remaining.toLocaleString("id-ID")}</strong><span>tersisa</span></div>
        </div>
        <div className="stock-opname-progress-track" role="progressbar" aria-valuenow={progressPercent} aria-valuemin={0} aria-valuemax={100}><span style={{ width: `${progressPercent}%` }} /></div>
        {data.progress.requiresRecount > 0 && <p className="stock-opname-warning">{data.progress.requiresRecount} item memerlukan hitung ulang setelah baseline stok berubah.</p>}
      </section>

      {!canCount && <div className="stock-opname-warning" role="status">Sesi tidak lagi dalam tahap menghitung. Halaman ini hanya menampilkan data.</div>}

      {canCount && <form className="surface-card stock-opname-scanner" onSubmit={scanBarcode}>
        <label htmlFor="opname-barcode">Pindai barcode lalu tekan Enter</label>
        <div><input id="opname-barcode" value={barcode} onChange={(event) => setBarcode(event.target.value)} autoComplete="off" inputMode="none" /><button type="submit" disabled={!barcode.trim()}>Cari item</button></div>
        <span className={`stock-opname-scan-note${scanError ? " is-error" : ""}`} aria-live="polite">{scanNotice ?? "Pemindaian hanya memilih item; jumlah tidak berubah sampai Anda menyimpan hitungan."}</span>
      </form>}

      <form className="stock-opname-count-search" action={pathname} method="get">
        <label htmlFor="opname-item-q">Cari nama atau SKU</label>
        <div><input id="opname-item-q" name="q" type="search" defaultValue={data.query.q} maxLength={100} placeholder="Nama produk atau SKU" />
          {data.query.filter !== "ALL" && <input type="hidden" name="filter" value={data.query.filter} />}
          <button type="submit">Cari</button></div>
      </form>

      <nav className="stock-opname-filters" aria-label="Filter item opname">
        {STOCK_OPNAME_COUNT_FILTERS.map((filter) => <Link key={filter}
          href={hrefFor(pathname, data.query.q, filter, 1)} aria-current={data.query.filter === filter ? "page" : undefined}
          className={`stock-opname-filter${data.query.filter === filter ? " is-active" : ""}`}>{FILTER_LABEL[filter]}</Link>)}
      </nav>
      <p className="stock-opname-result-note">Menampilkan {data.items.length ? ((data.query.page - 1) * STOCK_OPNAME_COUNT_PAGE_SIZE + 1).toLocaleString("id-ID") : 0}–{((data.query.page - 1) * STOCK_OPNAME_COUNT_PAGE_SIZE + data.items.length).toLocaleString("id-ID")} dari {data.filteredTotal.toLocaleString("id-ID")} item sesuai pencarian/filter.</p>

      {data.items.length === 0 ? <div className="surface-card product-state"><strong>Tidak ada item yang cocok</strong><span>Ubah pencarian atau filter untuk melihat item lain.</span></div> : <ol className="stock-opname-count-list">
        {data.items.map((item) => {
          const pending = pendingByProduct.get(item.productId);
          const result = feedback && feedback.productId === item.productId ? feedback.result : null;
          const isEditing = editingProduct === item.productId;
          const editable = canCount && !item.requiresRecount;
          return <li className="surface-card stock-opname-count-card" id={`opname-item-${item.productId}`} key={item.id}>
            <div className="stock-opname-count-heading"><div><strong>{item.name}</strong><span>{item.sku}{item.barcode ? ` · ${item.barcode}` : ""}{item.rack ? ` · Rak ${item.rack}` : " · Rak kosong"}</span></div>
              <span className={`stock-opname-counted${item.physicalQuantity === null || item.requiresRecount ? " is-pending" : ""}`}>{item.requiresRecount ? "Perlu hitung ulang" : item.physicalQuantity === null ? "Belum dihitung" : "Sudah dihitung"}</span></div>
            <dl className="stock-opname-count-values">
              <div><dt>Saldo saat sesi dibuat</dt><dd>{countFormat(item.baselineQuantity)}</dd></div>
              <div><dt>Hitungan fisik</dt><dd>{countFormat(item.physicalQuantity)}</dd></div>
              <div><dt>Selisih</dt><dd>{countFormat(item.variance)}</dd></div>
              <div><dt>Revisi item</dt><dd>{item.revision}</dd></div>
            </dl>
            {item.requiresRecount && <p className="stock-opname-warning">Baseline proyeksi berubah. Simpan hitungan dinonaktifkan sampai baseline diperbarui pada checkpoint berikutnya.</p>}
            {pending && <div className="stock-opname-pending-request" role="status"><span>Permintaan {pending.quantity} belum terkonfirmasi.</span><button type="button" className="secondary-button" disabled={busyProduct === item.productId} onClick={() => void finishApply(item.productId, pending.requestId)}>Coba ulang permintaan yang sama</button></div>}
            {canCount && !pending && !isEditing && <button type="button" className="secondary-button stock-opname-edit-count" disabled={!editable} onClick={() => {
              setEditingProduct(item.productId);
              setQuantityDraft(item.physicalQuantity === null ? "" : String(item.physicalQuantity));
              setFeedback(null);
            }}>{item.physicalQuantity === null ? "Masukkan hitungan" : "Ubah hitungan"}</button>}
            {canCount && !pending && isEditing && editable && <div className="stock-opname-count-editor">
              <label htmlFor={`physical-${item.productId}`}>Jumlah fisik (maks. 3 desimal)</label>
              <div><input id={`physical-${item.productId}`} type="text" inputMode="decimal" autoComplete="off" value={quantityDraft} onChange={(event) => setQuantityDraft(event.target.value)} placeholder="Contoh: 0 atau 12,5" />
                <button type="button" disabled={busyProduct === item.productId} onClick={() => void saveCount(item)}>{busyProduct === item.productId ? "Menyimpan…" : "Simpan hitungan"}</button></div>
              <p>Nilai nol sah. Kosong bukan nol. Gunakan titik atau koma untuk desimal. Revisi yang dikirim: {item.revision}.</p>
              {result?.kind === "error" && <p className="stock-opname-action-error" role="alert">{result.message}</p>}
              <button type="button" className="stock-opname-cancel-edit" onClick={() => setEditingProduct(null)}>Tutup tanpa menyimpan</button>
            </div>}
            {result && result.kind !== "error" && <p className={`stock-opname-count-feedback ${result.kind}`} role="status">{result.message}</p>}
          </li>;
        })}
      </ol>}

      {data.pageCount > 1 && <nav className="product-pagination" aria-label="Halaman item opname"><span>Halaman {data.query.page} dari {data.pageCount}</span><div>
        {data.query.page > 1 && <Link href={hrefFor(pathname, data.query.q, data.query.filter, data.query.page - 1)}>← Sebelumnya</Link>}
        {data.query.page < data.pageCount && <Link href={hrefFor(pathname, data.query.q, data.query.filter, data.query.page + 1)}>Berikutnya →</Link>}
      </div></nav>}
    </>}
  </div>;
}
