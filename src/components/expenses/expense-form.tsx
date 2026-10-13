"use client";

import { useActionState, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createExpense, saveExpenseDraft, type ExpenseActionState } from "@/app/actions/expenses";
import { RupiahInput } from "@/components/ui/rupiah-input";
import { EXPENSE_CATEGORIES, EXPENSE_CATEGORY_LABELS, EXPENSE_METHODS, EXPENSE_METHOD_LABELS } from "@/lib/expenses/model";
import type { ExpenseDetail } from "@/lib/expenses/read";
import styles from "@/components/expenses/expenses.module.css";
import buttons from "@/components/ui/workspace-primary-action.module.css";

const empty: ExpenseActionState = { error: null };
export function ExpenseForm({ date, expense, requestId }: { date: string; expense?: ExpenseDetail; requestId: string }) {
  const action = expense ? saveExpenseDraft : createExpense;
  const [state, formAction, pending] = useActionState(action, empty);
  const [amount, setAmount] = useState(expense?.amount ?? "");
  const router = useRouter();
  useEffect(() => { if (state.navigate && state.expenseId) router.push(`/pengeluaran/${state.expenseId}`); }, [state, router]);
  return <form action={formAction} className={styles.expenseForm}>
    <input type="hidden" name="request_id" value={requestId} />
    {expense && <><input type="hidden" name="expense_id" value={expense.id} /><input type="hidden" name="revision" value={expense.draft_revision} /></>}
    <label>Tanggal *<input name="expense_date" type="date" required defaultValue={expense?.expense_date ?? date} /></label>
    <label>Kategori *<select name="category" required defaultValue={expense?.category ?? "LISTRIK"}>{EXPENSE_CATEGORIES.map((value) => <option key={value} value={value}>{EXPENSE_CATEGORY_LABELS[value]}</option>)}</select></label>
    <label className={styles.full}>Keterangan *<input name="description" required maxLength={500} defaultValue={expense?.description ?? ""} placeholder="Contoh: Tagihan listrik toko" /></label>
    <label>Jumlah *<RupiahInput name="amount" value={amount} onValueChange={setAmount} required aria-label="Jumlah pengeluaran" /></label>
    <label>Metode pembayaran *<select name="payment_method" required defaultValue={expense?.payment_method ?? "CASH"}>{EXPENSE_METHODS.map((value) => <option key={value} value={value}>{EXPENSE_METHOD_LABELS[value]}</option>)}</select></label>
    <label className={styles.full}>Referensi / catatan<input name="reference_note" maxLength={500} defaultValue={expense?.reference_note ?? ""} placeholder="Opsional" /></label>
    {state.error && <p className={styles.formError} role="alert">{state.error}</p>}{state.success && <p className={styles.formSuccess} role="status">{state.success}</p>}
    <div className={`${styles.formActions} ${styles.full}`}>
      {!expense && <button className={buttons.secondary} name="intent" value="DRAFT" disabled={pending}>Simpan Draft</button>}
      <button className={buttons.primary} name="intent" value="POSTED" disabled={pending || amount === ""}>{pending ? "Menyimpan…" : expense ? "Simpan Perubahan" : "Simpan & Catat"}</button>
    </div>
  </form>;
}
