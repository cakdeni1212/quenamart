import Link from "next/link";
import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readOwnerDashboard } from "@/lib/dashboard/read";
import { businessDayLabel, salesComparisonLabel, sumRupiahAmounts, trendBarHeight } from "@/lib/dashboard/model";
import { salesMoney, salesPaymentLabel, salesQuantity } from "@/lib/sales/presentation";
import styles from "@/components/dashboard/dashboard.module.css";

type SearchParams = Record<string, string | string[] | undefined>;
const first = (value: string | string[] | undefined) => Array.isArray(value) ? value[0] : value;
const numberLabel = (value: number) => value.toLocaleString("id-ID");
const methods = ["CASH", "QRIS", "CARD", "E_WALLET"] as const;

function dueLabel(dueDate: string, overdueDays: number, today: string) {
  if (overdueDays > 0) return `Terlambat ${overdueDays} hari`;
  const days = Math.round((Date.parse(`${dueDate}T00:00:00Z`) - Date.parse(`${today}T00:00:00Z`)) / 86_400_000);
  if (days === 0) return "Jatuh tempo hari ini";
  if (days === 1) return "Jatuh tempo besok";
  return `Jatuh tempo ${days} hari lagi`;
}

export default async function DashboardPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const profile = await requireProfile();
  if (!profile.is_active || !["OWNER", "ADMIN"].includes(profile.role)) {
    redirect(profile.role === "KASIR" ? "/kasir" : "/produk");
  }
  const params = await searchParams;
  const trendDays = first(params.hari) === "30" ? 30 : 7;
  const result = await readOwnerDashboard(profile, trendDays);
  const data = result.data;

  return <main className={`page-content ${styles.page}`}>
    <header className={styles.heading}>
      <div className={styles.titleBlock}>
        <h1>Dashboard</h1>
        {data && <time className={styles.datePill} dateTime={data.business_date}>{new Intl.DateTimeFormat("id-ID", { dateStyle: "full", timeZone: "Asia/Jakarta" }).format(new Date(`${data.business_date}T12:00:00Z`))}</time>}
      </div>
    </header>

    {result.error ? <section className={styles.error} role="alert"><strong>Ringkasan toko belum tersedia</strong><p>{result.error}</p><Link href="/dashboard">Coba lagi</Link></section> : data && <>
      {!data.attention.costing_active && <aside className={styles.goLive}>
        <span className={styles.statusDot} aria-hidden="true" />
        <div><strong>Persiapan Go-Live</strong><p>Costing belum aktif. Transaksi penjualan belum dibuka.</p></div>
        <Link href="/hpp-awal">Lihat persiapan →</Link>
      </aside>}

      <section className={styles.kpis} aria-label="Ringkasan keuangan hari ini">
        <article className={styles.kpi}><span>Omzet hari ini</span><strong>{salesMoney(data.sales.today_total)}</strong><small>{salesComparisonLabel(data.sales.comparison, data.sales.change_percent)}</small></article>
        <article className={styles.kpi}><span>Transaksi</span><strong>{numberLabel(data.sales.today_count)}</strong><small>transaksi hari ini</small></article>
        <article className={styles.kpi}><span>Rata-rata belanja</span><strong>{salesMoney(data.sales.average_basket)}</strong><small>omzet ÷ transaksi selesai</small></article>
        <article className={styles.kpi}><span>Laba kotor</span>
          {data.profit.status === "COSTING_INACTIVE" ? <><strong className={styles.kpiState}>Belum tersedia</strong><small>Costing belum aktif</small></>
            : data.profit.status === "INCOMPLETE" ? <><strong className={styles.kpiState}>Belum lengkap</strong><small>COGS sebagian belum final</small></>
              : <><strong>{salesMoney(data.profit.gross_profit)}</strong><small>berdasarkan COGS penjualan hari ini</small></>}
        </article>
        <article className={styles.kpi}><span>Pengeluaran hari ini</span><strong>{salesMoney(data.expenses.expenses_today)}</strong><small><Link className={styles.kpiLink} href="/pengeluaran">Lihat pengeluaran →</Link></small></article>
        <article className={styles.kpi}><span>Laba operasional</span>{data.expenses.operating_profit === null
          ? <><strong className={styles.kpiState}>Belum tersedia</strong><small>{data.expenses.gross_profit_status === "COSTING_INACTIVE" ? "Costing belum aktif" : "Laba kotor belum lengkap"}</small></>
          : <><strong>{salesMoney(data.expenses.operating_profit)}</strong><small>Laba kotor − pengeluaran tercatat</small></>}</article>
      </section>

      <section className={styles.mainGrid}>
        <article className={styles.card}>
          <div className={styles.cardHead}><div><h2>Tren Penjualan</h2><p>Omzet harian · {data.trend_days} hari terakhir</p></div>
            <nav className={styles.toggle} aria-label="Periode tren"><Link aria-current={trendDays === 7 ? "page" : undefined} href="/dashboard?hari=7">7 Hari</Link><Link aria-current={trendDays === 30 ? "page" : undefined} href="/dashboard?hari=30">30 Hari</Link></nav>
          </div>
          <div className={styles.trendSummary}><span>Total periode <strong>{salesMoney(sumRupiahAmounts(data.trend.map((row) => row.total)))}</strong></span><span>{numberLabel(data.trend.reduce((sum, row) => sum + row.transaction_count, 0))} transaksi</span></div>
          <div className={styles.chart} role="img" aria-label={`Tren omzet selama ${data.trend_days} hari`}>
            <div className={styles.chartGrid}><i /><i /><i /></div>
            <div className={styles.bars}>{data.trend.map((point, index) => <div className={styles.barColumn} key={point.date} title={`${businessDayLabel(point.date)}: ${salesMoney(point.total)}`}>
              <span className={styles.bar} style={{ height: `${trendBarHeight(point.total, data.trend.reduce((max, item) => Number(item.total) > Number(max) ? item.total : max, "0"))}%` }} />
              {(trendDays === 7 || index % 5 === 0 || index === data.trend.length - 1) && <small>{businessDayLabel(point.date)}</small>}
            </div>)}</div>
          </div>
          <ul className={styles.srOnly}>{data.trend.map((point) => <li key={point.date}>{businessDayLabel(point.date)}: {salesMoney(point.total)}, {point.transaction_count} transaksi</li>)}</ul>
          <Link className={styles.cardLink} href="/transaksi">Lihat transaksi →</Link>
        </article>

        <article className={styles.card}>
          <div className={styles.cardHead}><div><h2>Metode Pembayaran Hari Ini</h2><p>Total pembayaran tercatat</p></div></div>
          <div className={styles.paymentList}>{methods.map((method) => {
            const item = data.payments.find((payment) => payment.method === method);
            return <div className={styles.paymentRow} key={method}><span>{salesPaymentLabel(method)}<small>{numberLabel(item?.sale_count ?? 0)} transaksi</small></span><strong>{salesMoney(item?.total ?? "0")}</strong></div>;
          })}</div>
          {data.sales.today_count === 0 && <p className={styles.muted}>Belum ada pembayaran hari ini.</p>}
        </article>
      </section>

      <section className={styles.lowerGrid}>
        <article className={styles.card}>
          <div className={styles.cardHead}><div><h2>Stok Perlu Perhatian</h2><p>{numberLabel(data.stock.low_stock_count)} produk stok habis atau mencapai minimum</p></div><Link className={styles.cardLink} href="/stok">Lihat semua →</Link></div>
          {data.stock.items.length ? <ul className={styles.productList}>{data.stock.items.map((item) => <li key={item.product_id}><div><strong>{item.name}</strong><small>{item.rack ? `Rak ${item.rack} · ` : ""}Minimum {item.minimum_quantity === null ? "belum diatur" : salesQuantity(item.minimum_quantity)}</small></div><span className={item.effective_quantity === 0 ? styles.stockZero : styles.stockLow}>Stok {salesQuantity(item.effective_quantity)}</span></li>)}</ul> : data.stock.missing_projection_count > 0 ? <p className={styles.empty}>Data stok {numberLabel(data.stock.missing_projection_count)} produk belum tersedia di proyeksi.</p> : <p className={styles.empty}>Stok aman.</p>}
        </article>

        <article className={styles.card}>
          <div className={styles.cardHead}><div><h2>Tempo Supplier</h2><p>Nota tempo final yang belum lunas</p></div><Link className={styles.cardLink} href="/tempo-supplier">Lihat Tempo →</Link></div>
          <div className={styles.tempoTotals}><div><span>Total outstanding</span><strong>{salesMoney(data.tempo.outstanding_total)}</strong></div><div><span>Jatuh tempo segera</span><strong>{salesMoney(data.tempo.due_soon_total)}</strong></div><div><span>Terlambat</span><strong>{salesMoney(data.tempo.overdue_total)}</strong></div></div>
          {data.tempo.urgent.length ? <ul className={styles.urgentList}>{data.tempo.urgent.map((item) => <li key={item.id}><div><strong>{item.supplier_name}</strong><small>{item.invoice_number || "Nota supplier"} · {dueLabel(item.due_date, item.days_overdue, data.business_date)}</small></div><strong>{salesMoney(item.outstanding)}</strong></li>)}</ul> : <p className={styles.empty}>Tidak ada tempo yang perlu diperhatikan.</p>}
        </article>
      </section>

      <section className={styles.attention}>
        <div className={styles.cardHead}><div><h2>Perlu Perhatian</h2><p>Hal operasional yang mungkin perlu ditindaklanjuti.</p></div></div>
        <div className={styles.attentionList}>
          {!data.attention.costing_active && <Link href="/hpp-awal"><span className={styles.alertMark}>!</span><span><strong>Costing belum aktif</strong><small>Transaksi penjualan tetap terkunci sampai cutover costing selesai.</small></span><b>→</b></Link>}
          {data.attention.low_stock_count > 0 && <Link href="/stok"><span className={styles.alertMark}>!</span><span><strong>{numberLabel(data.attention.low_stock_count)} produk stok menipis atau habis</strong><small>Gunakan stok efektif dan minimum outlet untuk menentukan kebutuhan.</small></span><b>→</b></Link>}
          {data.attention.missing_stock_projection_count > 0 && <Link href="/stok"><span className={styles.alertMark}>!</span><span><strong>Proyeksi stok belum tersedia untuk {numberLabel(data.attention.missing_stock_projection_count)} produk</strong><small>Periksa data stok sebelum mengandalkan ringkasan ketersediaan.</small></span><b>→</b></Link>}
          {data.attention.overdue_count > 0 && <Link href="/tempo-supplier"><span className={styles.alertMark}>!</span><span><strong>{numberLabel(data.attention.overdue_count)} nota supplier terlambat</strong><small>Total sisa {salesMoney(data.tempo.overdue_total)}.</small></span><b>→</b></Link>}
          {data.attention.due_soon_count > 0 && <Link href="/tempo-supplier"><span className={styles.alertMark}>•</span><span><strong>{numberLabel(data.attention.due_soon_count)} nota jatuh tempo dalam 7 hari</strong><small>Total sisa {salesMoney(data.tempo.due_soon_total)}.</small></span><b>→</b></Link>}
          {data.attention.open_opname_count > 0 && <Link href="/stok/opname"><span className={styles.alertMark}>•</span><span><strong>{numberLabel(data.attention.open_opname_count)} opname belum selesai</strong><small>Ada sesi penghitungan atau review yang masih terbuka.</small></span><b>→</b></Link>}
          {data.attention.costing_active && data.attention.incomplete_profit_sales > 0 && <Link href="/transaksi"><span className={styles.alertMark}>!</span><span><strong>Laba kotor belum lengkap</strong><small>{numberLabel(data.attention.incomplete_profit_sales)} transaksi hari ini memiliki COGS yang belum final.</small></span><b>→</b></Link>}
          {data.attention.costing_active && data.attention.low_stock_count === 0 && data.attention.missing_stock_projection_count === 0 && data.attention.overdue_count === 0 && data.attention.due_soon_count === 0 && data.attention.open_opname_count === 0 && data.attention.incomplete_profit_sales === 0 && <p className={styles.empty}>Tidak ada hal mendesak.</p>}
        </div>
      </section>
    </>}
  </main>;
}
