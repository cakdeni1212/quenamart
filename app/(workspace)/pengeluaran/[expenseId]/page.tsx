import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readExpenseDetail } from "@/lib/expenses/read";
import { expenseCategoryLabel, expenseMethodLabel, EXPENSE_STATUS_LABELS, formatExpenseDate, formatExpenseDateTime } from "@/lib/expenses/model";
import { formatRupiah } from "@/lib/money";
import { ExpenseForm } from "@/components/expenses/expense-form";
import { ExpenseDetailActions } from "@/components/expenses/expense-detail-actions";
import styles from "@/components/expenses/expenses.module.css";

export default async function ExpenseDetailPage({ params }: { params: Promise<{ expenseId: string }> }) {
  const profile = await requireProfile();
  if (!profile.is_active || !["OWNER", "ADMIN"].includes(profile.role)) redirect("/dashboard");
  const { expenseId } = await params;
  const expense = await readExpenseDetail(profile, expenseId);
  if (!expense) notFound();
  return <main className="page-content"><div className="eyebrow">KEUANGAN</div><div className={styles.detailHeading}><div><h1>{expense.expense_number}</h1><p className="page-lead">Detail pengeluaran operasional.</p></div><span className={`${styles.status} ${styles[expense.status.toLowerCase()]}`}>{EXPENSE_STATUS_LABELS[expense.status]}</span></div>
    <section className={`surface-card ${styles.detailCard}`}>
      {expense.status === "DRAFT" ? <ExpenseForm date={expense.expense_date} expense={expense} requestId={crypto.randomUUID()} /> : <dl className={styles.detailGrid}>
        <div><dt>Tanggal</dt><dd>{formatExpenseDate(expense.expense_date)}</dd></div><div><dt>Kategori</dt><dd>{expenseCategoryLabel(expense.category)}</dd></div>
        <div><dt>Jumlah</dt><dd className={styles.amount}>{formatRupiah(expense.amount)}</dd></div><div><dt>Metode pembayaran</dt><dd>{expenseMethodLabel(expense.payment_method)}</dd></div>
        <div className={styles.full}><dt>Keterangan</dt><dd>{expense.description}</dd></div><div className={styles.full}><dt>Referensi / catatan</dt><dd>{expense.reference_note || "—"}</dd></div>
        <div><dt>Dibuat oleh</dt><dd>{expense.created_by}</dd></div><div><dt>Dibuat</dt><dd>{formatExpenseDateTime(expense.created_at)}</dd></div>
        {expense.posted_at && <div><dt>Dicatat oleh</dt><dd>{expense.posted_by} · {formatExpenseDateTime(expense.posted_at)}</dd></div>}
        {expense.cancellation_reason && <div className={styles.full}><dt>Alasan pembatalan</dt><dd>{expense.cancellation_reason}</dd></div>}
      </dl>}
      <div className={styles.events}><h2>Riwayat</h2>{expense.events.map((event, index) => <p key={`${event.type}-${index}`}><strong>{event.type === "POSTED" ? "Dicatat" : event.type === "CANCELLED" ? "Dibatalkan" : event.type === "UPDATED" ? "Draf diperbarui" : "Dibuat"}</strong> · {event.actor} · {formatExpenseDateTime(event.at)}{event.note ? ` · ${event.note}` : ""}</p>)}</div>
      {expense.status !== "CANCELLED" && <ExpenseDetailActions expense={expense} />}
    </section><Link href="/pengeluaran" className={styles.backLink}>Kembali ke daftar</Link></main>;
}
