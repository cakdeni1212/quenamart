import Link from "next/link";
import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readPayables } from "@/lib/purchasing/finance-read";

type Params = Record<string, string | string[] | undefined>;
const one = (value: string | string[] | undefined) => typeof value === "string" ? value : "";
const money = (value: number) => new Intl.NumberFormat("id-ID", { style: "currency", currency: "IDR", maximumFractionDigits: 0 }).format(value);
const statusLabel = (value: string) => ({ BELUM_DIBAYAR: "Belum Dibayar", SEBAGIAN: "Sebagian", LUNAS: "Lunas", JATUH_TEMPO_SEGERA: "Jatuh Tempo Segera", TERLAMBAT: "Terlambat" }[value] ?? value);

export default async function SupplierTempoPage({ searchParams }: { searchParams: Promise<Params> }) {
  const profile = await requireProfile();
  if (!profile.is_active || !["OWNER", "ADMIN"].includes(profile.role)) redirect("/dashboard");
  const params = await searchParams;
  const q = one(params.q).slice(0, 80), status = one(params.status), page = Number(one(params.page) || 1);
  const result = await readPayables(profile, q, status, page);
  const summary = result.summary;
  const rows = result.rows as Array<{ id: string; invoice_id: string; supplier_name: string; invoice_number: string | null; invoice_date: string | null; due_date: string | null; original_amount: number; paid: number; outstanding: number; status: string }>;
  return <main className="page-content purchasing-page"><Link className="purchase-back" href="/pembelian">← Pembelian</Link><div className="eyebrow">PEMBELIAN · TAGIHAN SUPPLIER</div><div className="page-heading"><div><h1>Tempo Supplier</h1><p>Catat pembayaran dan pantau sisa tagihan nota.</p></div><Link className="purchase-secondary purchase-link-button" href="/pembelian/nota">Semua nota</Link></div>
    {summary && <div className="purchase-invoice-totals"><div><span>Total hutang tersisa</span><strong>{money(summary.totalOutstanding)}</strong></div><div><span>Jatuh tempo segera</span><strong>{money(summary.dueSoon)}</strong></div><div><span>Terlambat</span><strong>{money(summary.overdue)}</strong></div></div>}
    <form className="purchase-receipt-filters surface-card" method="get"><label className="purchase-filter-search">Cari supplier atau nota<input name="q" defaultValue={q}/></label><label>Status<select name="status" defaultValue={status}><option value="">Semua</option><option value="BELUM_DIBAYAR">Belum dibayar</option><option value="SEBAGIAN">Sebagian</option><option value="JATUH_TEMPO_SEGERA">Jatuh tempo segera</option><option value="TERLAMBAT">Terlambat</option><option value="LUNAS">Lunas</option></select></label><button className="purchase-filter-submit">Terapkan</button></form>
    {result.error ? <div className="surface-card purchase-empty" role="alert">{result.error}</div> : rows.length === 0 ? <div className="surface-card purchase-empty"><strong>Tidak ada tagihan</strong><span>Tagihan supplier akan muncul setelah nota difinalisasi.</span></div> : <>
      <div className="purchase-receipt-table-wrap"><table className="purchase-receipt-table"><thead><tr><th>Supplier / Nota</th><th>Tanggal nota</th><th>Jatuh tempo</th><th>Total</th><th>Dibayar</th><th>Sisa</th><th>Status</th></tr></thead><tbody>{rows.map((row) => <tr key={row.id}><td><strong>{row.supplier_name}</strong><br/><Link href={`/pembelian/nota/${row.invoice_id}`}>{row.invoice_number ?? "Nota"}</Link></td><td>{row.invoice_date ?? "—"}</td><td>{row.due_date ?? "—"}</td><td>{money(row.original_amount)}</td><td>{money(row.paid)}</td><td><strong>{money(row.outstanding)}</strong></td><td><span className={`purchase-status ${row.status === "TERLAMBAT" ? "purchase-status-draft" : "purchase-status-posted"}`}>{statusLabel(row.status)}</span></td></tr>)}</tbody></table></div>
      <ol className="purchase-receipt-mobile-list">{rows.map((row) => <li key={row.id}><Link href={`/pembelian/nota/${row.invoice_id}`}><div className="purchase-mobile-receipt-top"><strong>{row.supplier_name}</strong><span className="purchase-status">{statusLabel(row.status)}</span></div><span>{row.invoice_number ?? "Nota"} · jatuh tempo {row.due_date ?? "—"}</span><span>Total {money(row.original_amount)} · dibayar {money(row.paid)}</span><strong>Sisa {money(row.outstanding)}</strong><b>Catat pembayaran →</b></Link></li>)}</ol>
      <nav className="purchase-list-pagination"><span>Halaman {result.page} dari {result.pages}</span><div>{result.page > 1 && <Link href={`?q=${encodeURIComponent(q)}&status=${encodeURIComponent(status)}&page=${result.page - 1}`}>← Sebelumnya</Link>}{result.page < result.pages && <Link href={`?q=${encodeURIComponent(q)}&status=${encodeURIComponent(status)}&page=${result.page + 1}`}>Berikutnya →</Link>}</div></nav>
    </>}
  </main>;
}
