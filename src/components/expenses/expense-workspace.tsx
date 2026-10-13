import Link from "next/link";
import { formatRupiah } from "@/lib/money";
import { expenseCategoryLabel, expenseMethodLabel, EXPENSE_STATUS_LABELS, formatExpenseDate } from "@/lib/expenses/model";
import type { ExpenseRow } from "@/lib/expenses/read";
import type { ExpenseCategory, ExpenseMethod } from "@/lib/expenses/model";
import styles from "@/components/expenses/expenses.module.css";
import buttons from "@/components/ui/workspace-primary-action.module.css";

type Result = { rows: ExpenseRow[]; total: number; page: number; pages: number; summary: { total: string; count: number; average: string; largestCategory: string | null } | null; error: string | null };
type Props = { result: Result; params: Record<string, string | string[] | undefined>; categories: readonly ExpenseCategory[]; methods: readonly ExpenseMethod[] };
const val = (params: Props["params"], key: string) => { const value = params[key]; return Array.isArray(value) ? value[0] ?? "" : value ?? ""; };

function Row({ row }: { row: ExpenseRow }) {
  return <Link className={styles.expenseRow} href={`/pengeluaran/${row.id}`}>
    <span>{formatExpenseDate(row.expense_date)}</span><strong>{row.expense_number}</strong><span>{expenseCategoryLabel(row.category)}</span><span>{row.description}</span><span>{expenseMethodLabel(row.payment_method)}</span><strong>{formatRupiah(row.amount)}</strong><span className={`${styles.status} ${styles[row.status.toLowerCase()]}`}>{EXPENSE_STATUS_LABELS[row.status]}</span><span className={styles.rowAction}>Detail →</span>
  </Link>;
}

export function ExpenseWorkspace({ result, params, categories, methods }: Props) {
  const summary = result.summary;
  return <div className={styles.workspace}>
    <section className={styles.summary} aria-label="Ringkasan pengeluaran">
      <article><span>Total Pengeluaran</span><strong>{formatRupiah(summary?.total ?? "0")}</strong><small>Pengeluaran tercatat</small></article>
      <article><span>Jumlah Transaksi</span><strong>{summary?.count ?? 0}</strong><small>Pengeluaran tercatat</small></article>
      <article><span>Kategori Terbesar</span><strong className={styles.summaryText}>{summary?.largestCategory ? expenseCategoryLabel(summary.largestCategory) : "—"}</strong><small>Menurut total tercatat</small></article>
      <article><span>Rata-rata Pengeluaran</span><strong>{formatRupiah(summary?.average ?? "0")}</strong><small>Per transaksi tercatat</small></article>
    </section>
    <form method="get" className={`surface-card ${styles.filters}`}>
      <label>Cari<input name="cari" defaultValue={val(params,"cari")} placeholder="No. pengeluaran, keterangan…" /></label>
      <label>Periode<select name="periode" defaultValue={val(params,"periode") || "bulan"}><option value="hari">Hari ini</option><option value="7hari">7 hari</option><option value="bulan">Bulan ini</option><option value="custom">Rentang tanggal</option></select></label>
      <label>Dari<input type="date" name="dari" defaultValue={val(params,"dari")} /></label><label>Sampai<input type="date" name="sampai" defaultValue={val(params,"sampai")} /></label>
      <label>Kategori<select name="kategori" defaultValue={val(params,"kategori")}><option value="">Semua kategori</option>{categories.map((value) => <option key={value} value={value}>{expenseCategoryLabel(value)}</option>)}</select></label>
      <label>Metode<select name="metode" defaultValue={val(params,"metode")}><option value="">Semua metode</option>{methods.map((value) => <option key={value} value={value}>{expenseMethodLabel(value)}</option>)}</select></label>
      <label>Status<select name="status" defaultValue={val(params,"status")}><option value="">Semua status</option><option value="DRAFT">Draft</option><option value="POSTED">Tercatat</option><option value="CANCELLED">Dibatalkan</option></select></label>
      <div className={styles.filterActions}><button className={buttons.secondary}>Terapkan</button><Link className={buttons.ghost} href="/pengeluaran">Reset</Link></div>
    </form>
    <section className={`surface-card ${styles.list}`}>
      <div className={styles.listMeta}><strong>Riwayat Pengeluaran</strong><span>{result.total} catatan</span></div>
      {result.rows.length ? <><div className={styles.tableHead}><span>Tanggal</span><span>No. Pengeluaran</span><span>Kategori</span><span>Keterangan</span><span>Metode</span><span>Jumlah</span><span>Status</span><span>Aksi</span></div><div className={styles.rows}>{result.rows.map((row) => <Row key={row.id} row={row} />)}</div>
        <div className={styles.mobileRows}>{result.rows.map((row) => <Link href={`/pengeluaran/${row.id}`} key={row.id} className={styles.mobileRow}><div><strong>{expenseCategoryLabel(row.category)}</strong><span className={`${styles.status} ${styles[row.status.toLowerCase()]}`}>{EXPENSE_STATUS_LABELS[row.status]}</span></div><p>{row.description}</p><div><small>{formatExpenseDate(row.expense_date)} · {expenseMethodLabel(row.payment_method)}</small><strong>{formatRupiah(row.amount)}</strong></div><small>{row.expense_number} →</small></Link>)}</div></>
        : <div className={styles.empty}><strong>Belum ada pengeluaran pada periode ini.</strong><p>Pengeluaran operasional yang dicatat akan muncul di sini.</p></div>}
      <nav className={styles.pagination} aria-label="Halaman pengeluaran"><span>Halaman {result.page}{result.pages ? ` dari ${result.pages}` : ""}</span><div>{result.page > 1 && <Link className={buttons.secondary} href={pageHref(params,result.page-1)}>Sebelumnya</Link>}{result.page < result.pages && <Link className={buttons.secondary} href={pageHref(params,result.page+1)}>Berikutnya</Link>}</div></nav>
    </section>
  </div>;
}

function pageHref(params: Props["params"], page: number) {
  const values = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) if (typeof value === "string" && value) values.set(key, value);
  values.set("halaman", String(page));
  return `/pengeluaran?${values.toString()}`;
}
