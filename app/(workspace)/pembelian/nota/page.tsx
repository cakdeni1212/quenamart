import Link from "next/link";
import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readInvoiceList } from "@/lib/purchasing/finance-read";

type Params = Record<string, string | string[] | undefined>;
const one = (value: string | string[] | undefined) => typeof value === "string" ? value : "";
const money = (value: number | null) => value === null ? "—" : new Intl.NumberFormat("id-ID", { style: "currency", currency: "IDR", maximumFractionDigits: 0 }).format(value);
const statusLabel = (value: string) => ({ BELUM_DILENGKAPI: "Belum Dilengkapi", BELUM_DIBAYAR: "Belum Dibayar", SEBAGIAN: "Sebagian", LUNAS: "Lunas", JATUH_TEMPO_SEGERA: "Jatuh Tempo Segera", TERLAMBAT: "Terlambat" }[value] ?? value);

export default async function InvoiceListPage({ searchParams }: { searchParams: Promise<Params> }) {
  const profile = await requireProfile();
  if (!profile.is_active || !["OWNER", "ADMIN"].includes(profile.role)) redirect("/dashboard");
  const params = await searchParams;
  const q = one(params.q).slice(0, 80), status = one(params.status), page = Number(one(params.page) || 1);
  const data = await readInvoiceList(profile, q, status, page);
  return <main className="page-content purchasing-page"><Link className="purchase-back" href="/pembelian">← Pembelian</Link>
    <div className="eyebrow">PEMBELIAN · NOTA SUPPLIER</div><div className="page-heading"><div><h1>Nota & pembayaran</h1><p>Catat nilai nota dan pembayaran supplier. Stok hanya bertambah dari Barang Masuk.</p></div><Link className="purchase-primary purchase-link-button" href="/pembelian/nota/baru">+ Nota supplier</Link></div>
    <form className="purchase-receipt-filters surface-card" method="get"><label className="purchase-filter-search">Cari supplier atau nomor nota<input name="q" defaultValue={q} placeholder="Nama supplier, nomor nota" /></label><label>Status<select name="status" defaultValue={status}><option value="">Semua</option><option value="DRAFT">Belum dilengkapi</option><option value="BELUM_DIBAYAR">Belum dibayar</option><option value="SEBAGIAN">Sebagian</option><option value="LUNAS">Lunas</option><option value="JATUH_TEMPO_SEGERA">Jatuh tempo segera</option><option value="TERLAMBAT">Terlambat</option></select></label><button className="purchase-filter-submit">Terapkan</button></form>
    {data.error ? <div className="surface-card purchase-empty" role="alert">{data.error}</div> : data.rows.length === 0 ? <div className="surface-card purchase-empty"><strong>Belum ada nota</strong><span>Nota supplier dapat dicatat sebelum atau sesudah barang diterima.</span></div> : <>
      <div className="purchase-receipt-table-wrap"><table className="purchase-receipt-table"><thead><tr><th>Supplier / Nota</th><th>Tanggal</th><th>Total Nota</th><th>Pembayaran</th><th>Sudah dibayar</th><th>Status</th><th></th></tr></thead><tbody>{data.rows.map((row) => <tr key={row.id}><td><strong>{row.supplier_name}</strong><br/><Link href={`/pembelian/nota/${row.id}`}>{row.invoice_number ?? row.invoice_reference}</Link></td><td>{row.invoice_date ?? "Draf"}</td><td>{money(row.supplier_invoice_total)}</td><td>{row.payment_type ?? "—"}</td><td>{money(row.paid)}</td><td><span className={`purchase-status purchase-status-${row.status.toLowerCase()}`}>{statusLabel(row.payment_status)}</span></td><td><Link href={`/pembelian/nota/${row.id}`}>Detail →</Link></td></tr>)}</tbody></table></div>
      <ol className="purchase-receipt-mobile-list">{data.rows.map((row) => <li key={row.id}><Link href={`/pembelian/nota/${row.id}`}><div className="purchase-mobile-receipt-top"><strong>{row.supplier_name}</strong><span className="purchase-status">{statusLabel(row.payment_status)}</span></div><span>{row.invoice_number ?? row.invoice_reference} · {row.invoice_date ?? "Draf"}</span><span>Total {money(row.supplier_invoice_total)} · Dibayar {money(row.paid)}</span><span>{row.payment_type ?? "Belum dipilih"}</span><b>Kelola nota →</b></Link></li>)}</ol>
      <nav className="purchase-list-pagination"><span>Halaman {data.page} dari {data.pages}</span><div>{data.page > 1 && <Link href={`?q=${encodeURIComponent(q)}&status=${encodeURIComponent(status)}&page=${data.page - 1}`}>← Sebelumnya</Link>}{data.page < data.pages && <Link href={`?q=${encodeURIComponent(q)}&status=${encodeURIComponent(status)}&page=${data.page + 1}`}>Berikutnya →</Link>}</div></nav>
    </>}
  </main>;
}
