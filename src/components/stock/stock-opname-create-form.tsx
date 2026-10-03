"use client";

import { useActionState, useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { createClient } from "@/lib/supabase/client";
import { createStockOpname, type CreateStockOpnameState } from "@/lib/stock/opname-create-action";
import type { StockOpnameCreateInfo } from "@/lib/stock/opname-create-read";

type SearchRow = {
  product_id: string;
  name: string;
  sku: string;
  barcode: string | null;
  effective_quantity: number | string;
};

type SearchResponse = {
  rows: SearchRow[];
  pagination: { filtered_total: number; page_count: number };
};

type Selection = {
  productId: string;
  name: string;
  sku: string;
  quantity: number;
};

type ScanResult = {
  resolution: "BARCODE_NOT_FOUND" | "BARCODE_MATCH" | "BARCODE_AMBIGUOUS";
  product_id: string | null;
  sku: string | null;
  product_name: string | null;
  system_quantity: number | string | null;
};

const PAGE_SIZE = 20;
const INITIAL_ACTION_STATE: CreateStockOpnameState = { error: null };

function asQuantity(value: number | string | null): number | null {
  if (value === null) return null;
  const quantity = typeof value === "number" ? value : Number(value);
  return Number.isFinite(quantity) ? quantity : null;
}

export function StockOpnameCreateForm({ info }: { info: StockOpnameCreateInfo }) {
  const [actionState, formAction, pending] = useActionState(createStockOpname, INITIAL_ACTION_STATE);
  const [scope, setScope] = useState<"FULL" | "PARTIAL">("FULL");
  const [selected, setSelected] = useState<Map<string, Selection>>(() => new Map());
  const [searchText, setSearchText] = useState("");
  const [searchQuery, setSearchQuery] = useState("");
  const [searchRows, setSearchRows] = useState<SearchRow[]>([]);
  const [searchPage, setSearchPage] = useState(1);
  const [searchPages, setSearchPages] = useState(0);
  const [searchTotal, setSearchTotal] = useState(0);
  const [searching, setSearching] = useState(false);
  const [searchError, setSearchError] = useState<string | null>(null);
  const [barcode, setBarcode] = useState("");
  const [scanNotice, setScanNotice] = useState<string | null>(null);
  const [scanError, setScanError] = useState(false);
  const client = useMemo(() => createClient(), []);
  const requestNo = useRef(0);

  const runSearch = useCallback(async (query: string, page: number, append: boolean) => {
    if (!info.outletId || !query.trim()) {
      setSearchRows([]);
      setSearchPage(1);
      setSearchPages(0);
      setSearchTotal(0);
      return;
    }
    const request = ++requestNo.current;
    setSearching(true);
    setSearchError(null);
    const { data, error } = await client.rpc("stock_workspace_read_page", {
      p_outlet_id: info.outletId,
      p_q: query.trim(),
      p_stock_status: "ALL",
      p_rack_empty: false,
      p_category: null,
      p_page: page,
      p_page_size: PAGE_SIZE,
    });
    if (request !== requestNo.current) return;
    if (error) {
      console.error("[stock-opname-create] product search failed", {
        operation: "stock_workspace_read_page",
        code: error.code?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 80),
        message: error.message.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240),
      });
      setSearchError("Pencarian produk belum dapat dimuat. Coba lagi.");
      setSearching(false);
      return;
    }

    const result = data as unknown as SearchResponse;
    const candidates = result.rows ?? [];
    const ids = candidates.map((row) => row.product_id);
    let usableIds = new Set<string>();
    if (ids.length) {
      const { data: projections, error: projectionError } = await client
        .from("stock_balance_projection")
        .select("product_id")
        .eq("outlet_id", info.outletId)
        .not("effective_quantity", "is", null)
        .not("baseline_source_import_row_id", "is", null)
        .in("product_id", ids);
      if (request !== requestNo.current) return;
      if (projectionError) {
        console.error("[stock-opname-create] candidate validation failed", {
          operation: "stock_balance_projection_candidate_check",
          code: projectionError.code?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 80),
          message: projectionError.message.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240),
        });
        setSearchError("Kelayakan saldo produk belum dapat diperiksa. Coba lagi.");
        setSearching(false);
        return;
      }
      usableIds = new Set((projections ?? []).map((row) => row.product_id as string));
    }
    const usableRows = candidates.filter((row) => usableIds.has(row.product_id));
    setSearchRows((current) => append ? [...current, ...usableRows] : usableRows);
    setSearchPage(page);
    setSearchPages(Number(result.pagination.page_count ?? 0));
    setSearchTotal(Number(result.pagination.filtered_total ?? 0));
    setSearching(false);
  }, [client, info.outletId]);

  useEffect(() => {
    const timer = setTimeout(() => {
      const query = searchText.trim();
      setSearchQuery(query);
      void runSearch(query, 1, false);
    }, 225);
    return () => clearTimeout(timer);
  }, [runSearch, searchText]);

  function addSelection(item: Selection) {
    setSelected((current) => {
      if (current.has(item.productId)) return current;
      const next = new Map(current);
      next.set(item.productId, item);
      return next;
    });
    setScanNotice(null);
    setScanError(false);
  }

  async function resolveBarcode(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const value = barcode.trim();
    if (!value || !info.outletId) return;
    setScanNotice(null);
    setScanError(false);
    const { data, error } = await client.rpc("resolve_stock_barcode", {
      p_outlet_id: info.outletId,
      p_barcode: value,
    });
    if (error) {
      console.error("[stock-opname-create] barcode resolution failed", {
        operation: "resolve_stock_barcode",
        code: error.code?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 80),
        message: error.message.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240),
      });
      setScanNotice("Barcode belum dapat diperiksa. Coba lagi.");
      setScanError(true);
      return;
    }
    const result = ((data ?? []) as ScanResult[])[0];
    if (!result || result.resolution === "BARCODE_NOT_FOUND") {
      setScanNotice("Barcode belum terdaftar");
      return;
    }
    if (result.resolution === "BARCODE_AMBIGUOUS") {
      setScanNotice("Barcode terhubung ke beberapa produk. Pilih produk secara manual dari hasil pencarian.");
      setScanError(true);
      return;
    }
    const quantity = asQuantity(result.system_quantity);
    if (!result.product_id || !result.product_name || !result.sku || quantity === null) {
      setScanNotice("Produk ditemukan, tetapi belum memiliki saldo proyeksi yang dapat digunakan untuk opname.");
      setScanError(true);
      return;
    }
    const { data: projection, error: projectionError } = await client
      .from("stock_balance_projection")
      .select("product_id")
      .eq("outlet_id", info.outletId)
      .eq("product_id", result.product_id)
      .not("effective_quantity", "is", null)
      .not("baseline_source_import_row_id", "is", null)
      .maybeSingle();
    if (projectionError || !projection) {
      if (projectionError) console.error("[stock-opname-create] scanned candidate validation failed", {
        operation: "stock_balance_projection_scanned_candidate_check",
        code: projectionError.code?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 80),
        message: projectionError.message.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240),
      });
      setScanNotice("Produk ditemukan, tetapi belum memiliki baseline yang dapat digunakan untuk opname.");
      setScanError(true);
      return;
    }
    addSelection({ productId: result.product_id, name: result.product_name, sku: result.sku, quantity });
    setBarcode("");
    setScanNotice(`Dipilih: ${result.product_name}`);
  }

  const canCreate = info.error === null && (scope === "FULL"
    ? info.projectionCount > 0 && info.unusableProjectionCount === 0
    : selected.size > 0);

  return <div className="stock-opname-create-layout">
    {info.error && <div className="surface-card product-state product-error" role="alert"><strong>Informasi stok belum tersedia</strong><span>{info.error}</span></div>}
    {!info.error && <section className="surface-card stock-opname-scope-card" aria-label="Cakupan outlet">
      <strong>{info.outletName}</strong>
      <span>{info.projectionCount.toLocaleString("id-ID")} produk dalam proyeksi stok</span>
      {info.missingProjectionCount > 0 && <p className="stock-opname-warning" role="status">{info.missingProjectionCount.toLocaleString("id-ID")} produk pada snapshot outlet belum memiliki proyeksi stok yang dapat digunakan.</p>}
      {info.unusableProjectionCount > 0 && <p className="stock-opname-warning" role="alert">{info.unusableProjectionCount.toLocaleString("id-ID")} baris proyeksi belum memiliki saldo atau provenance baseline yang lengkap. Selesaikan pemeriksaan sebelum membuat opname.</p>}
      {info.projectionCount === 0 && <p className="stock-opname-warning" role="alert">Belum ada saldo proyeksi untuk dijadikan cakupan opname.</p>}
    </section>}

    <div className="stock-opname-mode-grid" role="radiogroup" aria-label="Jenis opname">
      <label className={`surface-card stock-opname-mode${scope === "FULL" ? " is-selected" : ""}`}>
        <input type="radio" name="scope-choice" checked={scope === "FULL"} onChange={() => setScope("FULL")} />
        <span><strong>Opname Penuh</strong><small>Semua produk dengan saldo dalam proyeksi outlet saat sesi dibuat akan masuk ke cakupan.</small></span>
      </label>
      <label className={`surface-card stock-opname-mode${scope === "PARTIAL" ? " is-selected" : ""}`}>
        <input type="radio" name="scope-choice" checked={scope === "PARTIAL"} onChange={() => setScope("PARTIAL")} />
        <span><strong>Opname Sebagian</strong><small>Hanya produk yang Anda pilih satu per satu yang akan masuk ke cakupan.</small></span>
      </label>
    </div>

    {scope === "PARTIAL" && <section className="stock-opname-partial-panel">
      <label className="field-label">Cari produk berdasarkan nama atau SKU
        <input className="field-input" value={searchText} onChange={(event) => setSearchText(event.currentTarget.value)} placeholder="Ketik nama atau SKU" autoComplete="off" />
      </label>
      <form className="stock-opname-scan-form" onSubmit={resolveBarcode}>
        <label className="field-label">Pindai barcode (tekan Enter)
          <input className="field-input" value={barcode} onChange={(event) => setBarcode(event.currentTarget.value)} placeholder="Barcode produk" autoComplete="off" />
        </label>
        <button className="secondary-button" type="submit" disabled={!barcode.trim()}>Periksa barcode</button>
      </form>
      {searching && <p className="stock-opname-hint" role="status">Mencari produk…</p>}
      {searchError && <p className="stock-opname-warning" role="alert">{searchError}</p>}
      {scanNotice && <p className={`stock-opname-scan-note${scanError ? " is-error" : ""}`} role="status">{scanNotice}</p>}
      {searchQuery && !searching && !searchError && <>
        <p className="stock-opname-hint">{searchTotal.toLocaleString("id-ID")} hasil cocok · menampilkan produk dengan projection dan baseline yang siap digunakan.</p>
        <ul className="stock-opname-search-results">
          {searchRows.map((row) => <li className="surface-card" key={row.product_id}>
            <div><strong>{row.name}</strong><span>{row.sku} · Saldo {Number(row.effective_quantity).toLocaleString("id-ID", { maximumFractionDigits: 3 })}</span></div>
            <button className="secondary-button" type="button" disabled={selected.has(row.product_id)} onClick={() => addSelection({ productId: row.product_id, name: row.name, sku: row.sku, quantity: Number(row.effective_quantity) })}>
              {selected.has(row.product_id) ? "Sudah dipilih" : "Pilih"}
            </button>
          </li>)}
        </ul>
        {searchRows.length === 0 && <p className="stock-opname-hint">Tidak ada produk dengan baseline yang dapat digunakan pada halaman hasil ini.</p>}
        {searchPage < searchPages && <button className="secondary-button" type="button" disabled={searching} onClick={() => void runSearch(searchQuery, searchPage + 1, true)}>Muat hasil berikutnya</button>}
      </>}
      {!searchQuery && !scanNotice && <p className="stock-opname-hint">Ketik nama atau SKU, atau gunakan scanner barcode untuk memilih produk.</p>}

      <section className="stock-opname-selected-panel" aria-label="Produk terpilih">
        <h2>Produk terpilih <span>{selected.size}</span></h2>
        {selected.size === 0 ? <p className="stock-opname-hint">Belum ada produk. Pilih produk dari hasil pencarian.</p> : <ul className="stock-opname-selected-list">
          {[...selected.values()].map((item) => <li className="surface-card" key={item.productId}>
            <div><strong>{item.name}</strong><span>{item.sku} · Saldo efektif {item.quantity.toLocaleString("id-ID", { maximumFractionDigits: 3 })}</span></div>
            <button type="button" className="stock-opname-remove" aria-label={`Hapus ${item.name}`} onClick={() => setSelected((current) => {
              const next = new Map(current);
              next.delete(item.productId);
              return next;
            })}>Hapus</button>
          </li>)}
        </ul>}
      </section>
    </section>}

    <form action={formAction} className="surface-card stock-opname-confirm-form">
      <input type="hidden" name="scope_type" value={scope} />
      {scope === "PARTIAL" && [...selected.keys()].map((id) => <input key={id} type="hidden" name="product_id" value={id} />)}
      <label className="stock-opname-confirm"><input type="checkbox" name="confirm" value="yes" required />
        <span>Saya memahami cakupan opname dan ingin membuat sesi dengan status Menghitung.</span>
      </label>
      {actionState.error && <p className="stock-opname-warning" role="alert">{actionState.error}</p>}
      <button type="submit" className="primary-button" disabled={pending || !canCreate}>
        {pending ? "Membuat sesi…" : scope === "FULL" ? "Buat opname penuh" : `Buat opname sebagian · ${selected.size} produk`}
      </button>
    </form>
  </div>;
}
