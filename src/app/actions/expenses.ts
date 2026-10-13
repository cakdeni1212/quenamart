"use server";

import { revalidatePath } from "next/cache";
import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { parseCanonicalRupiah } from "@/lib/money";

export type ExpenseActionState = { error: string | null; success?: string; expenseId?: string; navigate?: boolean };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CATEGORIES = new Set(["GAJI", "SEWA", "LISTRIK", "INTERNET", "KEBERSIHAN", "ATK", "MAINTENANCE", "TRANSPORT", "MARKETING", "BIAYA_ADMIN", "KONSUMSI", "LAIN_LAIN"]);
const METHODS = new Set(["CASH", "QRIS", "BANK_TRANSFER", "CARD", "OTHER"]);

function messageFor(error: { code?: string | null; message?: string | null }) {
  const message = error.message ?? "";
  if (error.code === "42501" || message.includes("EXPENSE_UNAUTHORIZED")) return "Hanya OWNER atau ADMIN yang dapat mengelola pengeluaran.";
  if (message.includes("EXPENSE_REQUEST_CONFLICT")) return "Permintaan ini sudah digunakan dengan data berbeda. Muat ulang halaman.";
  if (message.includes("EXPENSE_STALE")) return "Draf berubah di sesi lain. Muat ulang sebelum melanjutkan.";
  if (message.includes("EXPENSE_NOT_EDITABLE")) return "Pengeluaran ini sudah tercatat dan tidak dapat diedit.";
  if (message.includes("EXPENSE_ALREADY_CANCELLED")) return "Pengeluaran ini sudah dibatalkan.";
  if (message.includes("EXPENSE_OUTLET_UNAVAILABLE")) return "Outlet aktif belum tersedia.";
  if (message.includes("EXPENSE_NOT_FOUND")) return "Pengeluaran tidak ditemukan.";
  return "Pengeluaran belum dapat disimpan. Periksa data dan coba lagi.";
}

async function manager() {
  const profile = await getProfile();
  return profile?.is_active && (profile.role === "OWNER" || profile.role === "ADMIN") ? profile : null;
}

function fields(formData: FormData) {
  const expenseDate = formData.get("expense_date");
  const category = formData.get("category");
  const description = formData.get("description");
  const amountValue = formData.get("amount");
  const method = formData.get("payment_method");
  const reference = formData.get("reference_note");
  const amount = typeof amountValue === "string" ? parseCanonicalRupiah(amountValue) : null;
  if (typeof expenseDate !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(expenseDate)
    || typeof category !== "string" || !CATEGORIES.has(category)
    || typeof description !== "string" || !description.trim() || description.trim().length > 500
    || amount === null || amount === "" || BigInt(amount.split(".")[0]) > BigInt("999999999999")
    || (typeof method !== "string" || !METHODS.has(method))
    || (typeof reference === "string" && reference.trim().length > 500)) return null;
  const amountCents = (() => { const [whole, fraction = ""] = amount.split("."); return BigInt(whole) * BigInt("100") + BigInt(fraction.padEnd(2, "0")); })();
  if (amountCents <= BigInt("0")) return null;
  return { expenseDate, category, description: description.trim(), amount, method, reference: typeof reference === "string" && reference.trim() ? reference.trim() : null };
}

function revalidateExpenseViews(id?: string) {
  revalidatePath("/pengeluaran");
  revalidatePath("/dashboard");
  if (id) revalidatePath(`/pengeluaran/${id}`);
}

export async function createExpense(_previous: ExpenseActionState, formData: FormData): Promise<ExpenseActionState> {
  if (!await manager()) return { error: "Hanya OWNER atau ADMIN yang dapat mengelola pengeluaran." };
  const requestId = formData.get("request_id");
  const input = fields(formData);
  const intent = formData.get("intent");
  if (typeof requestId !== "string" || !UUID.test(requestId) || !input || (intent !== "DRAFT" && intent !== "POSTED")) return { error: "Lengkapi tanggal, kategori, keterangan, jumlah, dan metode pembayaran." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("operational_expense_create", {
    p_request_id: requestId, p_expense_date: input.expenseDate, p_category: input.category,
    p_description: input.description, p_amount: input.amount, p_payment_method: input.method,
    p_reference_note: input.reference, p_post: intent === "POSTED",
  });
  if (error || !data || typeof data !== "object" || typeof (data as { id?: unknown }).id !== "string") return { error: messageFor(error ?? {}) };
  const id = (data as { id: string }).id;
  revalidateExpenseViews(id);
  return { error: null, success: intent === "POSTED" ? "Pengeluaran berhasil dicatat." : "Draf pengeluaran tersimpan.", expenseId: id, navigate: true };
}

export async function saveExpenseDraft(_previous: ExpenseActionState, formData: FormData): Promise<ExpenseActionState> {
  if (!await manager()) return { error: "Hanya OWNER atau ADMIN yang dapat mengelola pengeluaran." };
  const id = formData.get("expense_id");
  const revision = formData.get("revision");
  const input = fields(formData);
  if (typeof id !== "string" || !UUID.test(id) || typeof revision !== "string" || !/^\d+$/.test(revision) || !input) return { error: "Data draf pengeluaran tidak valid." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("operational_expense_update_draft", {
    p_expense_id: id, p_expected_revision: Number(revision), p_expense_date: input.expenseDate,
    p_category: input.category, p_description: input.description, p_amount: input.amount,
    p_payment_method: input.method, p_reference_note: input.reference,
  });
  if (error || !data || typeof data !== "object" || (data as { ok?: boolean }).ok !== true) return { error: messageFor(error ?? { message: "EXPENSE_STALE" }) };
  revalidateExpenseViews(id);
  return { error: null, success: "Draf pengeluaran tersimpan.", expenseId: id };
}

export async function postExpense(input: { id: string; requestId: string; revision: number }) {
  if (!await manager() || !UUID.test(input.id) || !UUID.test(input.requestId) || !Number.isSafeInteger(input.revision) || input.revision < 1) return { error: "Akses atau data pengeluaran tidak valid." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("operational_expense_post", { p_expense_id: input.id, p_request_id: input.requestId, p_expected_revision: input.revision });
  if (error || !data || typeof data !== "object") return { error: messageFor(error ?? {}) };
  revalidateExpenseViews(input.id);
  return { error: null, success: "Pengeluaran berhasil dicatat." };
}

export async function cancelExpense(formData: FormData) {
  if (!await manager()) return { error: "Hanya OWNER atau ADMIN yang dapat mengelola pengeluaran." };
  const id = formData.get("expense_id"); const requestId = formData.get("request_id"); const reason = formData.get("reason");
  if (typeof id !== "string" || !UUID.test(id) || typeof requestId !== "string" || !UUID.test(requestId)
    || typeof reason !== "string" || !reason.trim() || reason.trim().length > 500) return { error: "Alasan pembatalan wajib diisi." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("operational_expense_cancel", { p_expense_id: id, p_request_id: requestId, p_reason: reason.trim() });
  if (error || !data || typeof data !== "object") return { error: messageFor(error ?? {}) };
  revalidateExpenseViews(id);
  return { error: null, success: "Pengeluaran dibatalkan. Riwayat tetap tersimpan." };
}
