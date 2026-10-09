import Link from "next/link";
import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readReceiptList } from "@/lib/purchasing/receipt-read";
import { ReceiptPostSuccess } from "@/components/purchasing/receipt-post-success";
import { formatReceiptQuantity } from "@/lib/purchasing/receipt-model";
import { ReceiptListActions } from "@/components/purchasing/receipt-list-actions";

type Params = Record<string, string | string[] | undefined>;
const one = (value: string | string[] | undefined) => typeof value === "string" ? value : "";
function queryHref(params: Params, page: number) {
  const query = new URLSearchParams();
  for (const key of ["q", "by", "status", "from", "to"]) { const value = one(params[key]); if (value) query.set(key, value); }
  if (page > 1) query.set("page", String(page));
  const suffix = query.toString();
  return `/pembelian/barang-masuk${suffix ? `?${suffix}` : ""}`;
}
const dateTime = (value: string) => new Intl.DateTimeFormat("id-ID", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));
const money = (value: number | null | undefined) => value === null || value === undefined ? "—" : new Intl.NumberFormat("id-ID", { style: "currency", currency: "IDR", maximumFractionDigits: 0 }).format(value);
const paymentLabel = (value: string | undefined) => ({ MENUNGGU_NOTA: "Menunggu Nota", BELUM_DILENGKAPI: "Belum Dilengkapi", BELUM_DIBAYAR: "Belum Dibayar", SEBAGIAN: "Sebagian", LUNAS: "Lunas", JATUH_TEMPO_SEGERA: "Jatuh Tempo Segera", TERLAMBAT: "Terlambat" }[value ?? ""] ?? "Menunggu Nota");

export default async function ReceiptListPage({ searchParams }: { searchParams: Promise<Params> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "pembelian")) redirect("/dashboard");
  const params = await searchParams;
  const search = one(params.q).slice(0, 80);
  const searchBy = one(params.by) === "supplier" ? "supplier" : "reference";
  const status = one(params.status);
  const isManager = profile.role === "OWNER" || profile.role === "ADMIN";
  const data = await readReceiptList(profile, params.page, { search, searchBy, status, receivedFrom: params.from, receivedTo: params.to });
  const postedId = one(params.posted);
  const postedRow = data.rows.find((row) => row.id === postedId && row.status === "POSTED");
  const cancelledId = one(params.cancelled);
  const cancelledRow = data.rows.find((row) => row.id === cancelledId && row.status === "CANCELLED");
  return <main className="page-content purchasing-page">
    <div className="eyebrow">PEMBELIAN · STOK MASUK</div>
    <div className="page-heading purchase-list-heading"><div><h1>Barang Masuk</h1><p>Kelola penerimaan barang dan penambahan stok.</p></div><Link className="purchase-primary purchase-link-button" href="/pembelian/barang-masuk/baru">+ {isManager ? "Pembelian Baru" : "Barang Masuk Baru"}</Link></div>
    {postedRow && <ReceiptPostSuccess receiptId={postedRow.id} reference={postedRow.receipt_reference} />}
    {cancelledRow && <aside className="purchase-cancelled-banner" role="status"><strong>Draf {cancelledRow.receipt_reference} dibatalkan.</strong><span>{cancelledRow.financial?.documentCleanupPending ? "Pembersihan dokumen nota masih tertunda. Buka detail untuk mencoba lagi." : "Draf tidak memengaruhi stok; riwayatnya tetap tersimpan."}</span><Link href={`/pembelian/barang-masuk/${cancelledRow.id}?mode=view`}>{cancelledRow.financial?.documentCleanupPending ? "Coba pembersihan" : "Lihat riwayat"} →</Link></aside>}
    <form className="purchase-receipt-filters surface-card" method="get">
      <label className="purchase-filter-search">Cari penerimaan<input name="q" defaultValue={search} placeholder="Nomor barang masuk atau supplier" /></label>
      <label>Cari berdasarkan<select name="by" defaultValue={searchBy}><option value="reference">Nomor</option><option value="supplier">Supplier</option></select></label>
      <label>Status<select name="status" defaultValue={status}><option value="">Semua status</option><option value="DRAFT">Draf</option><option value="POSTED">Diposting</option>{isManager && <option value="CANCELLED">Dibatalkan</option>}</select></label>
      <label>Diterima dari<input type="date" name="from" defaultValue={one(params.from)} /></label>
      <label>Sampai<input type="date" name="to" defaultValue={one(params.to)} /></label>
      <button className="purchase-filter-submit" type="submit">Terapkan</button>
    </form>
    {data.error ? <div className="surface-card purchase-empty" role="alert">{data.error}</div> : data.rows.length === 0 ? <div className="surface-card purchase-empty"><strong>{search || status || params.from || params.to ? "Penerimaan tidak ditemukan" : "Belum ada barang masuk"}</strong><span>{search || status || params.from || params.to ? "Coba ubah pencarian atau filter." : "Penerimaan barang akan tercatat di sini."}</span></div> : <>
      <p className="purchase-result-note">{data.outletName ?? "Outlet"} · {data.total} penerimaan</p>
      <div className="purchase-receipt-table-wrap"><table className="purchase-receipt-table"><thead><tr><th>Nomor Barang Masuk</th><th>Supplier</th><th>Diterima</th><th>Barang</th>{isManager && <><th>Total Nota</th><th>Pembayaran</th></>}<th>Diinput Oleh</th><th>Status</th><th className="purchase-actions-heading">Aksi</th></tr></thead><tbody>{data.rows.map((row) => <tr key={row.id}><td><Link className="purchase-reference-link" href={`/pembelian/barang-masuk/${row.id}`}>{row.receipt_reference}</Link></td><td>{row.supplier?.display_name ?? "Supplier tidak tersedia"}</td><td><time dateTime={row.received_at}>{dateTime(row.received_at)}</time></td><td>{formatReceiptQuantity(row.stock_added)} · {row.product_count} SKU</td>{isManager && <><td>{money(row.financial?.invoiceTotal)}</td><td>{row.financial?.paymentType ? `${row.financial.paymentType === "TEMPO" ? "Tempo" : "Cash"} · ${paymentLabel(row.financial.status)}` : paymentLabel(undefined)}</td></>}<td>{row.created_by_name}</td><td><span className={`purchase-status purchase-status-${row.status.toLowerCase()}`}>{row.status === "POSTED" ? "Diposting" : row.status === "CANCELLED" ? "Dibatalkan" : "Draf"}</span></td><td><ReceiptListActions receiptId={row.id} reference={row.receipt_reference} canEdit={row.status === "DRAFT"} canCancel={isManager && row.status === "DRAFT"} /></td></tr>)}</tbody></table></div>
      <ol className="purchase-receipt-mobile-list">{data.rows.map((row) => <li key={row.id}><div className="purchase-mobile-receipt-card"><Link className="purchase-mobile-receipt-main" href={`/pembelian/barang-masuk/${row.id}${row.status === "DRAFT" ? "?mode=view" : ""}`}><div className="purchase-mobile-receipt-top"><strong>{row.receipt_reference}</strong><span className={`purchase-status purchase-status-${row.status.toLowerCase()}`}>{row.status === "POSTED" ? "Diposting" : row.status === "CANCELLED" ? "Dibatalkan" : "Draf"}</span></div><span>{row.supplier?.display_name ?? "Supplier tidak tersedia"}</span><time dateTime={row.received_at}>{dateTime(row.received_at)}</time><span>{formatReceiptQuantity(row.stock_added)} · {row.product_count} SKU</span><span>Diinput oleh {row.created_by_name}</span>{isManager && <span>{money(row.financial?.invoiceTotal)} · {paymentLabel(row.financial?.status)}</span>}<div className="purchase-mobile-receipt-bottom"><b>Lihat detail</b></div></Link><ReceiptListActions receiptId={row.id} reference={row.receipt_reference} canEdit={row.status === "DRAFT"} canCancel={isManager && row.status === "DRAFT"} /></div></li>)}</ol>
      <nav className="purchase-list-pagination" aria-label="Halaman barang masuk"><span>Halaman {data.page} dari {data.pages}</span><div>{data.page > 1 && <Link href={queryHref(params, data.page - 1)}>← Sebelumnya</Link>}{data.page < data.pages && <Link href={queryHref(params, data.page + 1)}>Berikutnya →</Link>}</div></nav>
    </>}
  </main>;
}
