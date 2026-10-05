import Link from "next/link";
import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readReceiptList } from "@/lib/purchasing/receipt-read";

export default async function ReceiptListPage({ searchParams }: { searchParams: Promise<Record<string,string|string[]|undefined>> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role,"pembelian")) redirect("/dashboard");
  const params = await searchParams;
  const data = await readReceiptList(profile, params.page);
  return <main className="page-content purchasing-page"><Link className="purchase-back" href="/pembelian">← Pembelian</Link><div className="eyebrow">PEMBELIAN · STOK MASUK</div><div className="page-heading"><div><h1>Barang masuk</h1><p>Barang diterima menambah stok saat draf diposting.</p></div><Link className="purchase-primary purchase-link-button" href="/pembelian/barang-masuk/baru">Buat barang masuk</Link></div>
    {data.error ? <div className="surface-card purchase-empty" role="alert">{data.error}</div> : data.rows.length === 0 ? <div className="surface-card purchase-empty"><strong>Belum ada barang masuk</strong><span>Penerimaan barang akan tercatat di sini.</span></div> : <>
      <p className="purchase-result-note">{data.outletName ?? "Outlet"} · {data.total} penerimaan</p><ol className="purchase-receipt-list">{data.rows.map((row) => <li key={row.id}><Link href={`/pembelian/barang-masuk/${row.id}`}>
        <div><strong>{row.receipt_reference}</strong><span>{row.supplier?.display_name ?? "Supplier tidak tersedia"}</span></div><div><time dateTime={row.received_at}>{new Intl.DateTimeFormat("id-ID",{dateStyle:"medium",timeStyle:"short"}).format(new Date(row.received_at))}</time><span className={`purchase-status purchase-status-${row.status.toLowerCase()}`}>{row.status === "POSTED" ? "Diposting" : "Draf"}</span></div>
      </Link></li>)}</ol><nav className="product-pagination" aria-label="Halaman barang masuk"><span>Halaman {data.page} dari {data.pages}</span><div>{data.page > 1 && <Link href={`/pembelian/barang-masuk?page=${data.page-1}`}>← Sebelumnya</Link>}{data.page < data.pages && <Link href={`/pembelian/barang-masuk?page=${data.page+1}`}>Berikutnya →</Link>}</div></nav>
    </>}
  </main>;
}
