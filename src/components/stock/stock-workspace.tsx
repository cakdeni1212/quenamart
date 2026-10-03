"use client";

import Link from "next/link";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useEffect, useRef, useTransition, type ChangeEvent, type FormEvent } from "react";
import type { StockFilter } from "@/lib/stock/workspace";
import type { StockWorkspaceData } from "@/lib/stock/read";
import type { StockWorkspaceRow } from "@/lib/stock/workspace";

const quantity = (value: number | null) => value == null
  ? "—"
  : new Intl.NumberFormat("id-ID", { maximumFractionDigits: 3 }).format(value);

const statusText = (status: StockWorkspaceRow["status"]) => ({
  HABIS: "Habis", MENIPIS: "Menipis", AMAN: "Aman", DATA_BELUM_TERSEDIA: "Data belum tersedia",
}[status]);

function statusHref(query: URLSearchParams, status: StockFilter) {
  const next = new URLSearchParams(query.toString());
  next.delete("scan");
  next.delete("page");
  if (status === "SEMUA") next.delete("status");
  else next.set("status", status);
  const search = next.toString();
  return search ? `/stok?${search}` : "/stok";
}

export function StockWorkspace({ data }: { data: StockWorkspaceData }) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const searchText = searchParams.toString();
  const currentQuery = new URLSearchParams(searchText);
  const currentQ = currentQuery.get("q") ?? "";
  const [isPending, startTransition] = useTransition();
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const categoryTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const searchInput = useRef<HTMLInputElement>(null);
  const categoryInput = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (searchInput.current && searchInput.current.value !== currentQ) searchInput.current.value = currentQ;
  }, [currentQ]);

  useEffect(() => {
    if (categoryInput.current && categoryInput.current.value !== data.query.category) {
      categoryInput.current.value = data.query.category;
    }
  }, [data.query.category]);

  useEffect(() => {
    if (!data.scannedProductId) return;
    document.getElementById(`stock-${data.scannedProductId}`)?.scrollIntoView({ behavior: "smooth", block: "center" });
  }, [data.scannedProductId]);

  function updateSearch(event: ChangeEvent<HTMLInputElement>) {
    if (timer.current) clearTimeout(timer.current);
    const value = event.currentTarget.value;
    if (value.trim() === currentQ) return;
    timer.current = setTimeout(() => {
      const next = new URLSearchParams(searchText);
      next.delete("scan");
      next.delete("page");
      const q = value.trim();
      if (q) next.set("q", q);
      else next.delete("q");
      const url = next.size ? `${pathname}?${next}` : pathname;
      startTransition(() => router.replace(url, { scroll: false }));
    }, 225);
  }

  function scan(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (timer.current) clearTimeout(timer.current);
    const barcode = searchInput.current?.value.trim() ?? "";
    if (!barcode) return;
    if (searchInput.current) searchInput.current.value = "";
    startTransition(() => router.push(`/stok?scan=${encodeURIComponent(barcode)}`, { scroll: false }));
  }

  function updateCategory(event: ChangeEvent<HTMLInputElement>) {
    if (categoryTimer.current) clearTimeout(categoryTimer.current);
    const value = event.currentTarget.value;
    if (value.trim() === data.query.category) return;
    categoryTimer.current = setTimeout(() => {
      const next = new URLSearchParams(searchText);
      next.delete("scan");
      next.delete("page");
      const category = value.trim();
      if (category) next.set("category", category);
      else next.delete("category");
      startTransition(() => router.replace(next.size ? `${pathname}?${next}` : pathname, { scroll: false }));
    }, 225);
  }

  function setRackEmpty(enabled: boolean) {
    const next = new URLSearchParams(searchText);
    next.delete("scan");
    next.delete("page");
    if (enabled) next.set("rak", "kosong");
    else next.delete("rak");
    startTransition(() => router.push(next.size ? `/stok?${next}` : "/stok", { scroll: false }));
  }

  function pageHref(page: number) {
    const next = new URLSearchParams(searchText);
    next.delete("scan");
    next.set("page", String(page));
    return `/stok?${next}`;
  }

  const summary = data.summary;
  const scanNoticeClass = data.scanNotice?.kind === "found" ? "stock-scan-notice stock-scan-found"
    : data.scanNotice?.kind === "ambiguous" || data.scanNotice?.kind === "error" ? "stock-scan-notice stock-scan-error"
      : "stock-scan-notice stock-scan-info";

  return <>
    <section className="stock-summary-grid" aria-label="Ringkasan stok">
      <Link href={statusHref(currentQuery, "SEMUA")} className="stock-summary-card">
        <span>Total Produk</span><strong>{summary ? summary.total.toLocaleString("id-ID") : "—"}</strong><small>Dalam hasil pencarian</small>
      </Link>
      <Link href={statusHref(currentQuery, "HABIS")} className={`stock-summary-card stock-summary-empty${data.query.status === "HABIS" ? " is-selected" : ""}`}>
        <span>Stok Habis</span><strong>{summary ? summary.habis.toLocaleString("id-ID") : "—"}</strong><small>Saldo efektif nol</small>
      </Link>
      <Link href={statusHref(currentQuery, "MENIPIS")} className={`stock-summary-card stock-summary-low${data.query.status === "MENIPIS" ? " is-selected" : ""}`}>
        <span>Stok Menipis</span><strong>{summary ? summary.menipis.toLocaleString("id-ID") : "—"}</strong><small>Sama dengan atau di bawah minimum</small>
      </Link>
      <Link href={statusHref(currentQuery, "AMAN")} className={`stock-summary-card stock-summary-safe${data.query.status === "AMAN" ? " is-selected" : ""}`}>
        <span>Stok Aman</span><strong>{summary ? summary.aman.toLocaleString("id-ID") : "—"}</strong><small>Di atas batas minimum</small>
      </Link>
    </section>

    <form className="stock-search-form" onSubmit={scan} role="search">
      <label className="stock-search-input-wrap">
        <span aria-hidden="true">⌕</span>
        <input ref={searchInput} defaultValue={data.query.q} onChange={updateSearch} placeholder="Cari nama, SKU, atau barcode" aria-label="Cari atau pindai barcode" autoComplete="off" />
      </label>
      <button className="stock-scan-button" type="submit">Pindai barcode</button>
      {data.query.q && <Link href="/stok" className="stock-clear-search">Hapus pencarian</Link>}
    </form>
    <p className="stock-search-help">Ketik untuk mencari otomatis. Scanner: arahkan lalu tekan Enter; pencarian barcode dilakukan secara tepat.</p>

    <div className="stock-filter-row" aria-label="Filter kondisi stok">
      <span className="stock-filter-label">Kondisi stok</span>
      {(["SEMUA", "HABIS", "MENIPIS", "AMAN"] as StockFilter[]).map((filter) => <Link
        key={filter}
        href={statusHref(currentQuery, filter)}
        aria-current={data.query.status === filter ? "page" : undefined}
        className={`stock-filter-chip${data.query.status === filter ? " is-active" : ""}`}
      >{filter === "SEMUA" ? "Semua" : statusText(filter)}</Link>)}
      <label className="stock-category-filter"><span>Kategori tepat</span><input ref={categoryInput} defaultValue={data.query.category} onChange={updateCategory} aria-label="Filter kategori" placeholder="Semua kategori" /></label>
      <label className="stock-rack-filter"><input type="checkbox" checked={data.query.emptyRack} onChange={(event) => setRackEmpty(event.target.checked)} /> Rak kosong</label>
    </div>

    {data.scanNotice && <div className={scanNoticeClass} role="status" aria-live="polite">
      <strong>{data.scanNotice.message}</strong>
      {data.scanNotice.kind === "not-found" && <Link href="/audit-produk">Buka Audit Produk →</Link>}
      {data.scanNotice.kind === "ambiguous" && <Link href="/audit-produk">Buka Audit Produk →</Link>}
      {data.scanNotice.kind === "found" && data.scannedProductId && <Link href={`/produk/${data.scannedProductId}`}>Buka detail produk →</Link>}
    </div>}
    {isPending && <p className="stock-loading-note" role="status">Memperbarui hasil…</p>}
    {data.error ? <div className="surface-card product-state product-error"><strong>Data stok belum dapat dimuat.</strong><span>{data.error}</span></div> : <>
      {data.missingProjectionCount > 0 && <div className="stock-data-warning" role="status">{data.missingProjectionCount.toLocaleString("id-ID")} produk belum memiliki saldo proyeksi dan tidak dihitung sebagai stok efektif.</div>}
      <div className="stock-result-note">{data.total.toLocaleString("id-ID")} produk · Halaman {data.page} dari {data.pages}{data.outletName ? ` · ${data.outletName}` : ""}</div>
      {data.total === 0 ? <div className="surface-card product-state"><strong>{data.scanNotice ? "Tidak ada produk yang cocok dengan hasil pindai" : data.query.q || data.query.status !== "SEMUA" || data.query.emptyRack ? "Tidak ada produk yang cocok" : "Belum ada data stok"}</strong><span>{data.scanNotice ? "Pindai barcode lain atau ketik nama dan SKU untuk mencari produk." : "Ubah kata pencarian atau filter untuk melihat hasil lain."}</span></div> : <div className="surface-card stock-table-wrap">
        <table className="stock-table"><thead><tr><th>Produk</th><th>SKU</th><th>Barcode</th><th>Kategori</th><th>Rak</th><th>Stok efektif</th><th>Minimum</th><th>Status</th></tr></thead>
          <tbody>{data.rows.map((row) => <tr id={`stock-${row.productId}`} key={row.productId} className={row.productId === data.scannedProductId ? "stock-row-highlight" : undefined}>
            <td data-label="Produk"><Link className="stock-product-link" href={`/produk/${row.productId}`}>{row.name}</Link></td>
            <td data-label="SKU">{row.sku}</td>
            <td data-label="Barcode">{row.barcode ?? "—"}</td>
            <td data-label="Kategori">{row.category ?? "—"}</td>
            <td data-label="Rak">{row.rack?.trim() || <span className="stock-rack-empty">Belum diatur</span>}</td>
            <td data-label="Stok efektif"><strong className="stock-quantity">{quantity(row.effectiveQuantity)}</strong></td>
            <td data-label="Minimum">{quantity(row.minimumQuantity)}</td>
            <td data-label="Status"><span className={`stock-status stock-status-${row.status.toLowerCase()}`}>{statusText(row.status)}</span></td>
          </tr>)}</tbody>
        </table>
      </div>}
      {data.total > 0 && <nav className="product-pagination" aria-label="Halaman stok"><span>{data.start}–{data.end} dari {data.total}</span><div>
        {data.page > 1 && <Link href={pageHref(data.page - 1)}>← Sebelumnya</Link>}
        {data.page < data.pages && <Link href={pageHref(data.page + 1)}>Berikutnya →</Link>}
      </div></nav>}
    </>}
    <p className="stock-source-note">Saldo efektif memakai proyeksi stok Quena Mart. Snapshot iPos ditampilkan sebagai sumber observasi terpisah dan tidak menggantikan saldo ini.</p>
  </>;
}
