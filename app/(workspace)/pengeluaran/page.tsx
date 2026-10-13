import Link from "next/link";
import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readExpenses } from "@/lib/expenses/read";
import { EXPENSE_CATEGORIES, EXPENSE_METHODS, jakartaToday, shiftDate } from "@/lib/expenses/model";
import { ExpenseWorkspace } from "@/components/expenses/expense-workspace";
import actions from "@/components/ui/workspace-primary-action.module.css";
import styles from "@/components/expenses/expenses.module.css";

type Params = Record<string, string | string[] | undefined>;
const first = (value: string | string[] | undefined) => Array.isArray(value) ? value[0] : value;

export default async function PengeluaranPage({ searchParams }: { searchParams: Promise<Params> }) {
  const profile = await requireProfile();
  if (!profile.is_active || !["OWNER", "ADMIN"].includes(profile.role)) redirect("/dashboard");
  const params = await searchParams;
  const today = jakartaToday();
  const preset = first(params.periode) ?? "bulan";
  const from = first(params.dari) ?? (preset === "hari" ? today : preset === "7hari" ? shiftDate(today, -6) : `${today.slice(0, 7)}-01`);
  const to = first(params.sampai) ?? today;
  const page = Math.max(1, Number.parseInt(first(params.halaman) ?? "1", 10) || 1);
  const result = await readExpenses(profile, { from, to, search: first(params.cari), category: first(params.kategori), method: first(params.metode), status: first(params.status), page });
  return <main className={`page-content ${styles.page}`}>
    <header className={styles.heading}><div><div className="eyebrow">KEUANGAN</div><h1>Pengeluaran</h1><p className="page-lead">Catat dan pantau biaya operasional Quena Mart.</p></div><Link className={actions.primary} href="/pengeluaran/tambah">+ Tambah Pengeluaran</Link></header>
    {result.error ? <section className="surface-card" role="alert">{result.error}</section> : <ExpenseWorkspace result={result} params={params} categories={EXPENSE_CATEGORIES} methods={EXPENSE_METHODS} />}
  </main>;
}
