import Link from "next/link";
import { redirect } from "next/navigation";
import { readSalesHistory } from "@/lib/sales/history-read";
import { isSalesDate, jakartaDateString, salesPresetRange, type SalesDatePreset } from "@/lib/sales/history-date";
import { salesDateTime, salesMoney, salesPaymentLabel } from "@/lib/sales/presentation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import styles from "@/components/sales/sales-history.module.css";
import primaryAction from "@/components/ui/workspace-primary-action.module.css";

type SearchParams = Record<string, string | string[] | undefined>;
const METHODS = ["CASH", "QRIS", "CARD", "E_WALLET"] as const;
const first = (value: string | string[] | undefined) => Array.isArray(value) ? value[0] : value;
const paramsFor = (values: Record<string, string | undefined>) => {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(values)) if (value) params.set(key, value);
  return params.toString();
};

export default async function TransactionsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "transaksi")) redirect("/dashboard");
  const params = await searchParams;
  const today = jakartaDateString();
  const rawFrom = first(params.from);
  const rawTo = first(params.to);
  const validRange = isSalesDate(rawFrom) && isSalesDate(rawTo) && rawTo >= rawFrom && rawTo <= today
    && (Date.parse(`${rawTo}T00:00:00Z`) - Date.parse(`${rawFrom}T00:00:00Z`)) / 86_400_000 <= 365;
  const from = validRange ? rawFrom : today;
  const to = validRange ? rawTo : today;
  const methodParam = first(params.method);
  const method = METHODS.includes(methodParam as (typeof METHODS)[number]) ? methodParam! : null;
  const search = (first(params.search) ?? "").trim().slice(0, 80);
  const pageParam = Number(first(params.page));
  const page = Number.isSafeInteger(pageParam) && pageParam > 0 ? Math.min(pageParam, 1_000_000) : 1;
  const result = await readSalesHistory({ from, to, method, search: search || null, page });
  const data = result.data;
  const filterValues = { from, to, search: search || undefined, method: method ?? undefined };
  const pageHref = (nextPage: number) => `/transaksi?${paramsFor({ ...filterValues, page: String(nextPage) })}`;
  const presetHref = (preset: SalesDatePreset) => {
    const range = salesPresetRange(preset, today);
    return `/transaksi?${paramsFor({ ...filterValues, from: range.from, to: range.to, page: undefined })}`;
  };

  return <main className={`page-content ${styles.page}`}>
    <header className={styles.heading}>
      <div><div className="eyebrow">TRANSAKSI PENJUALAN</div><h1>Transaksi</h1><p>Riwayat dan pengelolaan transaksi penjualan.</p></div>
      <Link className={primaryAction.primary} href="/kasir">+ Transaksi Baru</Link>
    </header>

    {data && <section className={styles.summary} aria-label="Ringkasan periode filter">
      <article className={styles.summaryCard}><span>Total Penjualan</span><strong>{salesMoney(data.summary.total_sales)}</strong></article>
      <article className={styles.summaryCard}><span>Jumlah Transaksi</span><strong>{data.summary.transaction_count.toLocaleString("id-ID")}</strong></article>
      <article className={styles.summaryCard}><span>Rata-rata Transaksi</span><strong>{salesMoney(data.summary.average_transaction)}</strong></article>
    </section>}

    <section className={styles.presets} aria-label="Periode cepat">
      <span>Periode:</span>
      <Link href={presetHref("today")}>Hari ini</Link><Link href={presetHref("yesterday")}>Kemarin</Link>
      <Link href={presetHref("7d")}>7 hari</Link><Link href={presetHref("30d")}>30 hari</Link>
    </section>

    <form className={styles.filters} method="get">
      <label>Cari nomor transaksi<input type="search" name="search" maxLength={80} defaultValue={search} placeholder="QPOS-..." /></label>
      <label>Dari tanggal<input type="date" name="from" defaultValue={from} max={today} /></label>
      <label>Sampai tanggal<input type="date" name="to" defaultValue={to} max={today} /></label>
      <label>Metode pembayaran<select name="method" defaultValue={method ?? ""}><option value="">Semua</option><option value="CASH">Tunai</option><option value="QRIS">QRIS</option><option value="CARD">Kartu</option><option value="E_WALLET">E-Wallet</option></select></label>
      <button className={styles.filterButton} type="submit">Terapkan</button>
    </form>

    {result.error ? <div className={styles.error} role="alert"><p>{result.error}</p></div> : data?.rows.length ? <>
      <div className={styles.tableWrap}><table className={styles.table}>
        <thead><tr><th>NO. TRANSAKSI</th><th>TANGGAL &amp; JAM</th><th>KASIR</th><th>JUMLAH ITEM</th><th>TOTAL</th><th>METODE</th><th>STATUS</th><th>AKSI</th></tr></thead>
        <tbody>{data.rows.map((row) => <tr key={row.id}>
          <td><span className={styles.saleNumber}>{row.sale_number}</span></td>
          <td>{salesDateTime(row.completed_at)}</td><td>{row.cashier_label}</td>
          <td>{row.item_count} item</td><td className={styles.money}>{salesMoney(row.grand_total)}</td>
          <td><span className={styles.badge}>{salesPaymentLabel(row.payment_method)}</span></td>
          <td><span className={`${styles.badge} ${styles.status}`}>Selesai</span></td>
          <td><Link className={styles.detailLink} href={`/transaksi/${row.id}`}>Lihat Detail</Link></td>
        </tr>)}</tbody>
      </table></div>
      <div className={styles.mobileList}>{data.rows.map((row) => <Link className={styles.mobileCard} href={`/transaksi/${row.id}`} key={row.id}>
        <div className={styles.mobileTop}><strong>{row.sale_number}</strong><span className={`${styles.badge} ${styles.status}`}>Selesai</span></div>
        <span className={styles.mobileDate}>{salesDateTime(row.completed_at)} · {row.cashier_label}</span>
        <div className={styles.mobileBottom}><span>{row.item_count} item · {salesPaymentLabel(row.payment_method)}</span><strong className={styles.money}>{salesMoney(row.grand_total)}</strong></div>
      </Link>)}</div>
      <nav className={styles.pagination} aria-label="Halaman transaksi">
        <span>Halaman {data.page} dari {data.total_pages} · {data.total_count.toLocaleString("id-ID")} transaksi</span>
        <div className={styles.paginationActions}>
          <Link className={`${styles.secondary}${data.page <= 1 ? ` ${styles.disabled}` : ""}`} aria-disabled={data.page <= 1} href={pageHref(Math.max(1, data.page - 1))}>Sebelumnya</Link>
          <Link className={`${styles.secondary}${data.page >= data.total_pages ? ` ${styles.disabled}` : ""}`} aria-disabled={data.page >= data.total_pages} href={pageHref(Math.min(data.total_pages, data.page + 1))}>Berikutnya</Link>
        </div>
      </nav>
    </> : <div className={styles.empty}><strong>Belum ada transaksi penjualan pada periode ini.</strong><p>Transaksi yang selesai melalui Kasir akan muncul di sini.</p><Link className={styles.primary} href="/kasir">Buka Kasir</Link></div>}
  </main>;
}
