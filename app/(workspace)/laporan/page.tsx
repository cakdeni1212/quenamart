import Link from "next/link";
import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readReports } from "@/lib/reports/read";
import { formatReportMoney, isValidReportRange, jakartaToday, reportPeriod, type ReportPreset } from "@/lib/reports/model";
import { salesMoney, salesPaymentLabel, salesQuantity } from "@/lib/sales/presentation";
import styles from "@/components/reports/reports.module.css";

type Params = Record<string, string | string[] | undefined>;
const first = (value: string | string[] | undefined) => Array.isArray(value) ? value[0] : value;
const presets: ReportPreset[] = ["hari-ini", "kemarin", "7-hari", "30-hari", "bulan-ini", "bulan-lalu", "custom"];
const presetLabels: Record<ReportPreset, string> = { "hari-ini": "Hari Ini", kemarin: "Kemarin", "7-hari": "7 Hari", "30-hari": "30 Hari", "bulan-ini": "Bulan Ini", "bulan-lalu": "Bulan Lalu", custom: "Custom" };
const categoryLabels: Record<string, string> = { GAJI:"Gaji", SEWA:"Sewa", LISTRIK:"Listrik", INTERNET:"Internet", KEBERSIHAN:"Kebersihan", ATK:"ATK", MAINTENANCE:"Maintenance", TRANSPORT:"Transport", MARKETING:"Marketing", BIAYA_ADMIN:"Biaya Admin", KONSUMSI:"Konsumsi", LAIN_LAIN:"Lain-lain" };
const methods = ["CASH", "QRIS", "CARD", "E_WALLET"];
const idNumber = (value: number) => new Intl.NumberFormat("id-ID").format(value);
const businessDate = (value: string) => new Intl.DateTimeFormat("id-ID", { day:"numeric", month:"short", year:"numeric", timeZone:"Asia/Jakarta" }).format(new Date(`${value}T12:00:00Z`));

export default async function ReportsPage({ searchParams }: { searchParams: Promise<Params> }) {
  const profile = await requireProfile();
  if (!profile.is_active || !["OWNER", "ADMIN"].includes(profile.role)) redirect(profile.role === "KASIR" ? "/kasir" : "/produk");
  const params = await searchParams;
  const rawPreset = first(params.periode) ?? "bulan-ini";
  const preset = presets.includes(rawPreset as ReportPreset) ? rawPreset as ReportPreset : "bulan-ini";
  const fromParam = first(params.dari); const toParam = first(params.sampai);
  const invalidCustom = preset === "custom" && !isValidReportRange(fromParam, toParam);
  const period = reportPeriod(preset, jakartaToday(), fromParam, toParam);
  const result = invalidCustom ? { data: null, error: "Pilih rentang tanggal yang benar, maksimal 366 hari." } : await readReports(profile, period);
  const data = result.data;
  const maxRevenue = Math.max(0, ...(data?.sales_trend.map((point) => Number(point.revenue)) ?? []));
  const rangeLabel = data ? `${businessDate(data.period.from)} – ${businessDate(data.period.to)}` : "";
  const comparisonLabel = preset === "hari-ini" ? "dibanding kemarin" : `dibanding ${businessDate(period.compareFrom)} – ${businessDate(period.compareTo)}`;

  return <main className={`page-content ${styles.page}`}>
    <header className={styles.heading}><div><div className="eyebrow">ANALITIK</div><h1>Laporan</h1><p className="page-lead">Analisis penjualan, laba, pengeluaran, dan kondisi usaha Quena Mart.</p></div></header>
    <section className={styles.filters} aria-label="Filter periode">
      <form method="get" className={styles.filterForm}>
        <label>Periode<select name="periode" defaultValue={preset}>{presets.map((item) => <option key={item} value={item}>{presetLabels[item]}</option>)}</select></label>
        <label className={styles.customField}>Dari<input type="date" name="dari" defaultValue={preset === "custom" ? period.from : undefined} /></label>
        <label className={styles.customField}>Sampai<input type="date" name="sampai" defaultValue={preset === "custom" ? period.to : undefined} /></label>
        <button className="button-secondary" type="submit">Terapkan</button>
      </form>
      {data && <div className={styles.range}>{rangeLabel}</div>}
    </section>

    {result.error ? <section className={styles.error} role="alert"><strong>Laporan belum tersedia</strong><p>{result.error}</p><Link href="/laporan">Coba lagi</Link></section> : data && <>
      <section className={styles.kpis} aria-label="Ringkasan periode">
        <article><span>Omzet</span><strong>{formatReportMoney(data.kpis.revenue,salesMoney)}</strong><small>{data.kpis.change_percent === null ? "Belum ada pembanding" : `${Number(data.kpis.change_percent) > 0 ? "↑" : Number(data.kpis.change_percent) < 0 ? "↓" : "—"} ${new Intl.NumberFormat("id-ID", { maximumFractionDigits:1, minimumFractionDigits:1 }).format(Math.abs(Number(data.kpis.change_percent)))}% ${comparisonLabel}`}</small></article>
        <article><span>Transaksi</span><strong>{idNumber(data.kpis.transactions)}</strong><small>{idNumber(data.kpis.comparison_transactions)} pada periode pembanding</small></article>
        <article><span>Rata-rata belanja</span><strong>{salesMoney(data.kpis.average_basket)}</strong><small>Omzet ÷ transaksi selesai</small></article>
        <article><span>Laba kotor</span>{data.kpis.gross_profit === null ? <><strong className={styles.unavailable}>Belum tersedia</strong><small>{data.kpis.profit_status === "COSTING_INACTIVE" ? "Costing belum aktif" : "COGS penjualan belum lengkap"}</small></> : <><strong>{formatReportMoney(data.kpis.gross_profit,salesMoney)}</strong><small>Omzet − COGS saat penjualan</small></>}</article>
        <article><span>Margin kotor</span><strong>{data.kpis.gross_margin === null ? <em className={styles.unavailable}>Belum tersedia</em> : `${new Intl.NumberFormat("id-ID", { maximumFractionDigits:2 }).format(Number(data.kpis.gross_margin))}%`}</strong><small>{data.kpis.gross_margin === null ? "COGS harus tersedia" : "Laba kotor ÷ omzet"}</small></article>
        <article><span>Pengeluaran</span><strong>{formatReportMoney(data.kpis.expenses,salesMoney)}</strong><small>{idNumber(data.kpis.expense_count)} pengeluaran tercatat</small></article>
        <article><span>Laba operasional</span>{data.kpis.operating_profit === null ? <><strong className={styles.unavailable}>Belum tersedia</strong><small>{data.kpis.profit_status === "COSTING_INACTIVE" ? "Costing belum aktif" : "Laba kotor belum lengkap"}</small></> : <><strong>{formatReportMoney(data.kpis.operating_profit,salesMoney)}</strong><small>Laba kotor − pengeluaran</small></>}</article>
      </section>

      <section className={styles.primaryGrid}>
        <article className={styles.card}>
          <div className={styles.cardHead}><div><h2>Tren Penjualan</h2><p>Omzet harian · {rangeLabel}</p></div><Link href="/transaksi">Lihat transaksi →</Link></div>
          {data.kpis.transactions === 0 ? <p className={styles.empty}>Belum ada transaksi pada periode ini.</p> : <div className={styles.chart} role="img" aria-label={`Tren omzet ${rangeLabel}`}>
            {data.sales_trend.map((point, index) => <div className={styles.chartColumn} key={point.date} title={`${businessDate(point.date)} · ${salesMoney(point.revenue)} · ${idNumber(point.transactions)} transaksi`}>
              <span style={{ height: `${maxRevenue > 0 ? Math.max(2, Number(point.revenue) / maxRevenue * 100) : 0}%` }} />
              {(data.sales_trend.length <= 14 || index % Math.ceil(data.sales_trend.length / 10) === 0 || index === data.sales_trend.length - 1) && <small>{new Intl.DateTimeFormat("id-ID", { day:"numeric", month:"short", timeZone:"Asia/Jakarta" }).format(new Date(`${point.date}T12:00:00Z`))}</small>}
            </div>)}
          </div>}
          <div className={styles.periodSummary}><span>Total periode <strong>{formatReportMoney(data.kpis.revenue,salesMoney)}</strong></span><span>{idNumber(data.kpis.transactions)} transaksi</span></div>
        </article>
        <article className={styles.card}>
          <div className={styles.cardHead}><div><h2>Metode Pembayaran</h2><p>Jumlah dari bukti pembayaran selesai</p></div></div>
          <div className={styles.rows}>{methods.map((method) => { const payment = data.payments.find((row) => row.method === method); return <div key={method}><span>{salesPaymentLabel(method)}<small>{idNumber(payment?.transactions ?? 0)} transaksi</small></span><strong>{salesMoney(payment?.amount ?? "0")}</strong></div>; })}</div>
          {!data.kpis.transactions && <p className={styles.empty}>Belum ada pembayaran pada periode ini.</p>}
          {!data.payment_reconciliation.matches && <p className={styles.warning} role="status">Pembayaran berbeda dari omzet sebesar {salesMoney(data.payment_reconciliation.difference)}. Periksa bukti transaksi.</p>}
        </article>
      </section>

      <section className={styles.analysisGrid}>
        <article className={styles.card}>
          <div className={styles.cardHead}><div><h2>Tren Laba</h2><p>Omzet, laba kotor, dan laba operasional</p></div></div>
          {data.profit_trend === null ? <p className={styles.empty}>Data laba belum tersedia karena costing belum aktif atau belum lengkap.</p> : <div className={styles.profitTrend}>{data.profit_trend.map((point) => <div key={point.date}><span>{businessDate(point.date)}</span><span>Omzet {salesMoney(point.revenue)}</span><span>Laba kotor {salesMoney(point.gross_profit)}</span><span>Laba operasional {salesMoney(point.operating_profit)}</span></div>)}</div>}
        </article>
        <article className={styles.card}>
          <div className={styles.cardHead}><div><h2>Pengeluaran per Kategori</h2><p>Hanya pengeluaran tercatat pada periode ini</p></div><Link href="/pengeluaran">Lihat pengeluaran →</Link></div>
          {data.expenses_by_category.length ? <div className={styles.rows}>{data.expenses_by_category.map((item) => <div key={item.category}><span>{categoryLabels[item.category] ?? item.category}<small>{item.percent}% · {idNumber(item.count)} transaksi</small></span><strong>{salesMoney(item.amount)}</strong></div>)}</div> : <p className={styles.empty}>Belum ada pengeluaran pada periode ini.</p>}
        </article>
      </section>

      <section className={styles.analysisGrid}>
        <article className={styles.card}>
          <div className={styles.cardHead}><div><h2>Produk Terlaris</h2><p>10 produk teratas berdasarkan omzet · nama dan SKU dari struk penjualan</p></div></div>
          {data.top_products.length ? <div className={styles.productRows}>{data.top_products.map((product) => <div key={`${product.sku}-${product.name}`}><div><strong>{product.name}</strong><small>{product.sku} · {salesQuantity(product.quantity)} terjual</small></div><span><strong>{salesMoney(product.revenue)}</strong><small>{product.contribution}% kontribusi</small></span></div>)}</div> : <p className={styles.empty}>Belum ada transaksi pada periode ini.</p>}
          <p className={styles.note}>Kategori tidak ditampilkan karena detail penjualan belum menyimpan snapshot kategori.</p>
        </article>
        <article className={styles.card}>
          <div className={styles.cardHead}><div><h2>Sumber Penjualan</h2><p>Sumber dari bukti penjualan yang tersedia</p></div></div>
          {data.sales_sources.length ? <div className={styles.rows}>{data.sales_sources.map((source) => <div key={source.source}><span>{source.source}<small>{idNumber(source.transactions)} transaksi</small></span><strong>{salesMoney(source.revenue)}</strong></div>)}</div> : <p className={styles.empty}>Belum ada transaksi pada periode ini.</p>}
        </article>
      </section>

      <section className={styles.snapshotGrid}>
        <article className={styles.card}>
          <div className={styles.cardHead}><div><h2>Kondisi Persediaan Saat Ini</h2><p>Snapshot outlet per {businessDate(data.current_inventory.as_of)} · bukan periode laporan</p></div><Link href="/stok">Lihat stok →</Link></div>
          <div className={styles.snapshotKpis}><div><span>SKU aktif</span><strong>{idNumber(data.current_inventory.sku_count)}</strong></div><div><span>Stok habis</span><strong>{idNumber(data.current_inventory.out_of_stock)}</strong></div><div><span>Mencapai minimum</span><strong>{idNumber(data.current_inventory.at_minimum)}</strong></div></div>
          <div className={styles.snapshotValue}><span>Nilai persediaan saat ini</span><strong>{data.current_inventory.inventory_value === null ? "Belum tersedia" : salesMoney(data.current_inventory.inventory_value)}</strong><small>{data.current_inventory.inventory_value === null ? "Costing belum aktif atau proyeksi belum lengkap" : `Fisik ${salesQuantity(data.current_inventory.physical_quantity)} · belum dinilai ${salesQuantity(data.current_inventory.unvalued_quantity)}`}</small></div>
        </article>
        <article className={styles.card}>
          <div className={styles.cardHead}><div><h2>Tempo Supplier Saat Ini</h2><p>Kewajiban final yang masih terbuka · kondisi saat ini</p></div><Link href="/tempo-supplier">Lihat Tempo →</Link></div>
          <div className={styles.snapshotKpis}><div><span>Outstanding</span><strong>{salesMoney(data.current_tempo.outstanding)}</strong></div><div><span>Nota belum lunas</span><strong>{idNumber(data.current_tempo.unpaid_invoices)}</strong></div><div><span>Jatuh tempo segera</span><strong>{idNumber(data.current_tempo.due_soon_count)}</strong></div><div><span>Terlambat</span><strong>{idNumber(data.current_tempo.overdue_count)}</strong></div></div>
          {!data.current_tempo.unpaid_invoices && <p className={styles.empty}>Tidak ada tempo yang perlu diperhatikan.</p>}
        </article>
      </section>
    </>}
  </main>;
}
