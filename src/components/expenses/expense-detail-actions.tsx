"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { cancelExpense, postExpense } from "@/app/actions/expenses";
import type { ExpenseDetail } from "@/lib/expenses/read";
import styles from "@/components/expenses/expenses.module.css";
import buttons from "@/components/ui/workspace-primary-action.module.css";

export function ExpenseDetailActions({ expense }: { expense: ExpenseDetail }) {
  const [reason, setReason] = useState(""); const [error, setError] = useState(""); const [pending, startTransition] = useTransition(); const router = useRouter();
  function post() { startTransition(async () => { const result = await postExpense({ id: expense.id, revision: expense.draft_revision, requestId: crypto.randomUUID() }); if (result.error) setError(result.error); else router.refresh(); }); }
  function cancel() { const form = new FormData(); form.set("expense_id", expense.id); form.set("request_id", crypto.randomUUID()); form.set("reason", reason); startTransition(async () => { const result = await cancelExpense(form); if (result.error) setError(result.error); else router.refresh(); }); }
  return <div className={styles.detailActions}>
    {expense.status === "DRAFT" && <button className={buttons.primary} disabled={pending} onClick={post}>{pending ? "Menyimpan…" : "Catat Pengeluaran"}</button>}
    <label>Alasan pembatalan<input value={reason} maxLength={500} onChange={(event) => setReason(event.target.value)} placeholder="Wajib diisi untuk membatalkan" /></label>
    <button className={buttons.danger} disabled={pending || !reason.trim()} onClick={cancel}>Batalkan</button>
    {error && <p className={styles.formError} role="alert">{error}</p>}
  </div>;
}
