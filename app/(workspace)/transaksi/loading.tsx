import styles from "@/components/sales/sales-history.module.css";

export default function TransactionsLoading() {
  return <main className={`page-content ${styles.page}`} aria-busy="true">
    <header className={styles.heading}><div><div className="eyebrow">TRANSAKSI PENJUALAN</div><h1>Transaksi</h1><p>Memuat riwayat transaksi…</p></div></header>
    <section className={styles.summary} aria-label="Memuat ringkasan">
      <article className={styles.summaryCard}><span>Total Penjualan</span><strong>—</strong></article>
      <article className={styles.summaryCard}><span>Jumlah Transaksi</span><strong>—</strong></article>
      <article className={styles.summaryCard}><span>Rata-rata Transaksi</span><strong>—</strong></article>
    </section>
  </main>;
}
