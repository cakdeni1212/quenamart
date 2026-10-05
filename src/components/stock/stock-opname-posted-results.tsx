"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import {
  hasCurrentMetadataFallback,
  stockOpnameMetadataLabel,
  stockOpnameResultValues,
  stockOpnameResultEventLabel,
  stockOpnameResultsHref,
  STOCK_OPNAME_RESULTS_FILTERS,
  type StockOpnameResultsFilter,
} from "@/lib/stock/opname-results-model";
import type { StockOpnamePostedResultRow, StockOpnamePostedResultsReadData } from "@/lib/stock/opname-results-read";

const FILTER_LABELS: Record<StockOpnameResultsFilter, string> = {
  ALL: "Semua",
  DIFFERENCE: "Ada selisih",
  MATCH: "Sesuai",
  INCREASE: "Stok bertambah",
  DECREASE: "Stok berkurang",
  EXCEPTION: "Pengecualian",
};

function dateLabel(value: string | null): string {
  if (!value) return "—";
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "—" : new Intl.DateTimeFormat("id-ID", {
    dateStyle: "medium", timeStyle: "short",
  }).format(date);
}

function metadata(row: StockOpnamePostedResultRow) {
  return {
    name: stockOpnameMetadataLabel(row.productName, row.metadataProvenance),
    sku: stockOpnameMetadataLabel(row.sku, row.metadataProvenance),
    barcode: stockOpnameMetadataLabel(row.displayBarcode, row.metadataProvenance),
    rack: stockOpnameMetadataLabel(row.rack, row.metadataProvenance),
    unit: stockOpnameMetadataLabel(row.unit, row.metadataProvenance),
  };
}

function ResultRow({ row }: { row: StockOpnamePostedResultRow }) {
  const info = metadata(row);
  const exception = row.exceptionState;
  const values = stockOpnameResultValues({
    exception,
    baseline: row.baselineQuantity,
    physical: row.physicalQuantity,
    difference: row.difference,
    after: row.historicalAfterQuantity,
  });
  return <article className={`stock-opname-result-row${exception ? " is-exception" : ""}`}>
    <div className="stock-opname-result-product">
      <strong>{info.name}</strong>
      <span>SKU {info.sku}</span>
      <small>Barcode {info.barcode} · Rak {info.rack} · Satuan {info.unit}</small>
      {exception && <span className="stock-opname-result-exception-badge">Pengecualian</span>}
    </div>
    <div className="stock-opname-result-values" aria-label={exception ? "Hasil pengecualian" : "Hasil stok opname"}>
      <div><span>Stok sebelum</span><strong>{values.before}</strong></div>
      <div><span>Hasil fisik</span><strong>{values.physical}</strong></div>
      <div className={exception ? "is-muted" : row.difference !== null && Number(row.difference) > 0 ? "is-positive" : row.difference !== null && Number(row.difference) < 0 ? "is-negative" : ""}>
        <span>Selisih</span><strong>{values.difference}</strong>
      </div>
      <div><span>Stok setelah</span><strong>{values.after}</strong></div>
    </div>
    {exception && <div className="stock-opname-result-exception-detail">
      <span>Penyesuaian: {values.adjustment}</span>
      <p><strong>Alasan:</strong> {row.exceptionReason?.trim() || "Tidak tersedia"}</p>
    </div>}
  </article>;
}

export function StockOpnamePostedResults({ data }: { data: StockOpnamePostedResultsReadData }) {
  const router = useRouter();
  const pathname = usePathname();
  const [searchDraft, setSearchDraft] = useState(data.query.search);
  const [isPending, startTransition] = useTransition();
  const searchTimer = useRef<number | null>(null);

  useEffect(() => {
    const normalized = searchDraft.trim().slice(0, 120);
    if (normalized === data.query.search) return;
    searchTimer.current = window.setTimeout(() => {
      searchTimer.current = null;
      startTransition(() => router.replace(stockOpnameResultsHref(pathname, data.query, { search: normalized, page: 1 }), { scroll: false }));
    }, 300);
    return () => {
      if (searchTimer.current !== null) window.clearTimeout(searchTimer.current);
      searchTimer.current = null;
    };
  }, [data.query, pathname, router, searchDraft]);

  const cancelPendingSearch = () => {
    if (searchTimer.current !== null) window.clearTimeout(searchTimer.current);
    searchTimer.current = null;
  };

  const chooseFilter = (filter: StockOpnameResultsFilter) => {
    cancelPendingSearch();
    startTransition(() => router.push(stockOpnameResultsHref(pathname, data.query, { search: searchDraft.trim(), filter, page: 1 }), { scroll: false }));
  };

  if (data.error || !data.header || !data.summary || !data.page) {
    return <section className="stock-opname-results-error" role="alert">
      <Link className="stock-opname-back" href="/stok/opname">Kembali ke daftar opname</Link>
      <p>{data.error ?? "Hasil opname belum dapat dimuat. Coba muat ulang halaman."}</p>
      <button type="button" onClick={() => router.refresh()}>Coba lagi</button>
    </section>;
  }

  const { header, summary, page, rows, timeline } = data;
  const pageCount = Math.max(1, Math.ceil(page.totalMatching / page.pageSize));
  const hasFallback = hasCurrentMetadataFallback(header.outletMetadataProvenance, rows.map((row) => row.metadataProvenance));
  const reference = header.reference.length > 12 ? header.reference.slice(0, 8).toUpperCase() : header.reference;

  return <section className="stock-opname-posted-results">
    <Link className="stock-opname-back" href="/stok/opname">Kembali ke daftar opname</Link>
    <header className="stock-opname-results-header">
      <div>
        <span className="stock-opname-results-status">Selesai</span>
        <h1>Hasil opname #{reference}</h1>
        <p>Ringkasan hasil akhir stock opname.</p>
      </div>
      <dl className="stock-opname-results-session-meta">
        <div><dt>Outlet</dt><dd>{header.outletMetadataProvenance === "LEGACY_UNAVAILABLE" ? "Tidak tersedia" : header.outletName || "—"}</dd></div>
        <div><dt>Cakupan</dt><dd>{header.scope === "FULL" ? "Penuh" : "Sebagian"}</dd></div>
        <div><dt>Dibuat</dt><dd>{dateLabel(header.createdAt)}</dd></div>
        <div><dt>Diposting</dt><dd>{dateLabel(header.postedAt)}</dd></div>
      </dl>
    </header>

    {hasFallback && <p className="stock-opname-results-provenance" role="note">
      Metadata untuk opname lama ini menggunakan data produk atau outlet saat ini karena snapshot metadata belum tersedia saat opname diposting.
    </p>}

    <section className="stock-opname-results-summary" aria-label="Ringkasan hasil opname">
      {[
        ["Total item", summary.totalItems],
        ["Item dihitung", summary.counted],
        ["Sesuai", summary.match],
        ["Ada selisih", summary.difference],
        ["Stok bertambah", summary.increased],
        ["Stok berkurang", summary.decreased],
        ["Pengecualian", summary.exceptions],
      ].map(([label, value]) => <div className="stock-opname-results-summary-card" key={label}>
        <span>{label}</span><strong>{value}</strong>
      </div>)}
    </section>

    <section className="stock-opname-results-browser" aria-label="Cari dan filter hasil opname">
      <label className="stock-opname-results-search">
        <span>Cari produk atau SKU</span>
        <input value={searchDraft} maxLength={120} onChange={(event) => setSearchDraft(event.target.value)} placeholder="Nama produk atau SKU" />
      </label>
      <div className="stock-opname-results-filters" aria-label="Filter hasil">
        {STOCK_OPNAME_RESULTS_FILTERS.map((filter) => <button
          type="button"
          key={filter}
          aria-pressed={data.query.filter === filter}
          className={data.query.filter === filter ? "is-active" : ""}
          onClick={() => chooseFilter(filter)}
        >{FILTER_LABELS[filter]}</button>)}
      </div>
      {isPending && <p className="stock-opname-results-loading" role="status">Memuat hasil…</p>}
    </section>

    <section className="stock-opname-results-list" aria-label="Rincian hasil opname">
      <div className="stock-opname-results-columns" aria-hidden="true">
        <span>Produk</span><span>Stok sebelum</span><span>Hasil fisik</span><span>Selisih</span><span>Stok setelah</span>
      </div>
      {rows.length ? rows.map((row) => <ResultRow row={row} key={row.itemId} />) : <div className="stock-opname-results-empty">
        <strong>Tidak ada item yang cocok.</strong>
        <span>{data.query.search || data.query.filter !== "ALL" ? "Coba ubah pencarian atau filter." : "Belum ada rincian hasil untuk ditampilkan."}</span>
      </div>}
    </section>

    <nav className="stock-opname-results-pagination" aria-label="Halaman hasil opname">
      <span>Halaman {page.page} dari {pageCount} · {page.totalMatching} item</span>
      <div>
        {page.page > 1 && <Link onClick={cancelPendingSearch} href={stockOpnameResultsHref(pathname, data.query, { search: searchDraft.trim(), page: page.page - 1 })} scroll={false}>Sebelumnya</Link>}
        {page.page < pageCount && <Link onClick={cancelPendingSearch} href={stockOpnameResultsHref(pathname, data.query, { search: searchDraft.trim(), page: page.page + 1 })} scroll={false}>Berikutnya</Link>}
      </div>
    </nav>

    <section className="stock-opname-results-timeline" aria-labelledby="stock-opname-results-timeline-title">
      <h2 id="stock-opname-results-timeline-title">Riwayat opname</h2>
      {timeline.length ? <ol>{timeline.map((event) => <li key={event.eventId}>
        <div><strong>{stockOpnameResultEventLabel(event.eventType)}</strong>
          {event.actorId && <small title={event.actorId}>Aktor · {event.actorId.slice(0, 8)}</small>}
        </div>
        <time dateTime={event.createdAt}>{dateLabel(event.createdAt)}</time>
      </li>)}</ol> : <p>Riwayat sesi belum tersedia.</p>}
    </section>
  </section>;
}
