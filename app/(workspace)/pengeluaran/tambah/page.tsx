import { redirect } from "next/navigation";
import Link from "next/link";
import { requireProfile } from "@/lib/auth/session";
import { jakartaToday } from "@/lib/expenses/model";
import { ExpenseForm } from "@/components/expenses/expense-form";
import styles from "@/components/expenses/expenses.module.css";

export default async function TambahPengeluaranPage() {
  const profile = await requireProfile();
  if (!profile.is_active || !["OWNER", "ADMIN"].includes(profile.role)) redirect("/dashboard");
  return <main className="page-content"><div className="eyebrow">KEUANGAN</div><h1>Tambah Pengeluaran</h1><p className="page-lead">Catat biaya operasional yang sudah dibayarkan.</p><section className={`surface-card ${styles.formCard}`}><ExpenseForm date={jakartaToday()} requestId={crypto.randomUUID()} /><Link href="/pengeluaran" className={styles.backLink}>Kembali ke pengeluaran</Link></section></main>;
}
