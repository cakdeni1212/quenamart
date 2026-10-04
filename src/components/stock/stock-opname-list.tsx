import Link from "next/link";
import type { StockOpnameListData } from "@/lib/stock/opname-list-read";
import { STOCK_OPNAME_LIST_STATUSES, type StockOpnameListStatus } from "@/lib/stock/opname-list-model";

const STATUS_LABEL: Record<StockOpnameListStatus, string> = {
  ALL: "Semua",
  COUNTING: "Menghitung",
  REVIEW: "Menunggu posting",
  POSTED: "Selesai",
  CANCELLED: "Dibatalkan",
};

const OPEN_ACTION: Record<Exclude<StockOpnameListStatus, "ALL">, string> = {
  COUNTING: "Lanjutkan opname",
  REVIEW: "Buka review",
  POSTED: "Lihat hasil",
  CANCELLED: "Lihat detail",
};

function hrefFor(status: StockOpnameListStatus, page: number) {
  const params = new URLSearchParams();
  if (status !== "ALL") params.set("status", status);
  if (page > 1) params.set("page", String(page));
  const search = params.toString();
  return search ? `/stok/opname?${search}` : "/stok/opname";
}

function dateTime(value: string) {
  return new Intl.DateTimeFormat("id-ID", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

export function StockOpnameList({ data }: { data: StockOpnameListData }) {
  return <>
    <nav className="stock-opname-filters" aria-label="Filter status opname">
      {STOCK_OPNAME_LIST_STATUSES.map((status) => <Link
        key={status}
        href={hrefFor(status, 1)}
        aria-current={data.query.status === status ? "page" : undefined}
        className={`stock-opname-filter${data.query.status === status ? " is-active" : ""}`}
      >{STATUS_LABEL[status]}</Link>)}
    </nav>

    {data.error ? <div className="surface-card product-state product-error" role="alert">
      <strong>Daftar opname belum dapat dimuat.</strong><span>{data.error}</span>
    </div> : data.rows.length === 0 ? <div className="surface-card product-state">
      <strong>{data.query.status === "ALL" ? "Belum ada sesi opname" : `Belum ada sesi ${STATUS_LABEL[data.query.status].toLowerCase()}`}</strong>
      <span>Sesi opname akan muncul di sini setelah dibuat.</span>
    </div> : <>
      <p className="stock-opname-result-note">Menampilkan {data.start}–{data.end} dari {data.total} sesi</p>
      <ol className="stock-opname-list">
        {data.rows.map((row) => <li className="surface-card stock-opname-card" key={row.id}>
          <Link className="stock-opname-card-link" href={`/stok/opname/${row.id}`}>
            <div className="stock-opname-card-main">
              <div className="stock-opname-card-title"><strong>Opname #{row.reference}</strong><span className={`stock-opname-status stock-opname-status-${row.status.toLowerCase()}`}>{STATUS_LABEL[row.status]}</span></div>
              <dl className="stock-opname-card-details">
                <div><dt>Outlet</dt><dd>{row.outletName}</dd></div>
                <div><dt>Ruang lingkup</dt><dd>{row.scope === "FULL" ? "Penuh" : "Sebagian"}</dd></div>
                <div><dt>Dibuat</dt><dd><time dateTime={row.createdAt}>{dateTime(row.createdAt)}</time></dd></div>
              </dl>
            </div>
            <span className="stock-opname-card-action">{OPEN_ACTION[row.status]} <span aria-hidden="true">→</span></span>
          </Link>
        </li>)}
      </ol>
      <nav className="product-pagination" aria-label="Halaman daftar opname">
        <span>Halaman {data.page} dari {data.pages}</span>
        <div>
          {data.page > 1 && <Link href={hrefFor(data.query.status, data.page - 1)}>← Sebelumnya</Link>}
          {data.page < data.pages && <Link href={hrefFor(data.query.status, data.page + 1)}>Berikutnya →</Link>}
        </div>
      </nav>
    </>}
  </>;
}
