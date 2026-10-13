export const EXPENSE_CATEGORIES = ["GAJI", "SEWA", "LISTRIK", "INTERNET", "KEBERSIHAN", "ATK", "MAINTENANCE", "TRANSPORT", "MARKETING", "BIAYA_ADMIN", "KONSUMSI", "LAIN_LAIN"] as const;
export type ExpenseCategory = (typeof EXPENSE_CATEGORIES)[number];
export const EXPENSE_CATEGORY_LABELS: Record<ExpenseCategory, string> = {
  GAJI: "Gaji", SEWA: "Sewa", LISTRIK: "Listrik", INTERNET: "Internet", KEBERSIHAN: "Kebersihan",
  ATK: "ATK", MAINTENANCE: "Maintenance", TRANSPORT: "Transport", MARKETING: "Marketing",
  BIAYA_ADMIN: "Biaya admin", KONSUMSI: "Konsumsi", LAIN_LAIN: "Lain-lain",
};
export const EXPENSE_METHODS = ["CASH", "QRIS", "BANK_TRANSFER", "CARD", "OTHER"] as const;
export type ExpenseMethod = (typeof EXPENSE_METHODS)[number];
export const EXPENSE_METHOD_LABELS: Record<ExpenseMethod, string> = {
  CASH: "Tunai", QRIS: "QRIS", BANK_TRANSFER: "Transfer Bank", CARD: "Kartu", OTHER: "Lainnya",
};
export type ExpenseStatus = "DRAFT" | "POSTED" | "CANCELLED";
export const EXPENSE_STATUS_LABELS: Record<ExpenseStatus, string> = { DRAFT: "Draft", POSTED: "Tercatat", CANCELLED: "Dibatalkan" };

export function jakartaToday(): string {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Jakarta", year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date());
  const part = (type: string) => parts.find((item) => item.type === type)?.value ?? "";
  return `${part("year")}-${part("month")}-${part("day")}`;
}

export function shiftDate(date: string, days: number): string {
  const value = new Date(`${date}T12:00:00Z`);
  value.setUTCDate(value.getUTCDate() + days);
  return value.toISOString().slice(0, 10);
}

export function formatExpenseDate(value: string | null | undefined): string {
  if (!value) return "—";
  const date = new Date(`${value.slice(0, 10)}T12:00:00Z`);
  return new Intl.DateTimeFormat("id-ID", { day: "2-digit", month: "short", year: "numeric", timeZone: "Asia/Jakarta" }).format(date);
}

export function formatExpenseDateTime(value: string | null | undefined): string {
  if (!value) return "—";
  return new Intl.DateTimeFormat("id-ID", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Jakarta" }).format(new Date(value));
}

export function expenseCategoryLabel(value: string): string { return EXPENSE_CATEGORY_LABELS[value as ExpenseCategory] ?? value; }
export function expenseMethodLabel(value: string): string { return EXPENSE_METHOD_LABELS[value as ExpenseMethod] ?? value; }
