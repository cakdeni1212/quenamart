export type ReportPreset = "hari-ini" | "kemarin" | "7-hari" | "30-hari" | "bulan-ini" | "bulan-lalu" | "custom";

export function jakartaToday(now = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Jakarta", year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
}

export function addDays(date: string, amount: number): string {
  const value = new Date(`${date}T12:00:00Z`);
  value.setUTCDate(value.getUTCDate() + amount);
  return value.toISOString().slice(0, 10);
}

function monthStart(date: string): string { return `${date.slice(0, 7)}-01`; }
function daysInMonth(year: number, monthIndex: number): number { return new Date(Date.UTC(year, monthIndex + 1, 0)).getUTCDate(); }

export function reportPeriod(preset: ReportPreset, today: string, from?: string, to?: string) {
  let start: string;
  let end: string;
  switch (preset) {
    case "hari-ini": start = today; end = today; break;
    case "kemarin": start = addDays(today, -1); end = start; break;
    case "7-hari": start = addDays(today, -6); end = today; break;
    case "30-hari": start = addDays(today, -29); end = today; break;
    case "bulan-lalu": {
      const previousMonthLast = addDays(monthStart(today), -1);
      start = monthStart(previousMonthLast); end = previousMonthLast; break;
    }
    case "custom":
      start = validDate(from) ? from : `${today.slice(0, 7)}-01`;
      end = validDate(to) ? to : today;
      break;
    default: start = monthStart(today); end = today;
  }
  if (end < start || Date.parse(`${end}T00:00:00Z`) - Date.parse(`${start}T00:00:00Z`) > 365 * 86_400_000) {
    start = monthStart(today); end = today;
  }
  let compareFrom: string;
  let compareTo: string;
  if (preset === "bulan-ini") {
    const [year, month, day] = today.split("-").map(Number);
    const previousMonthIndex = month - 2;
    const previousYear = previousMonthIndex < 0 ? year - 1 : year;
    const normalizedMonth = (previousMonthIndex + 12) % 12;
    const previousMonthDays = daysInMonth(previousYear, normalizedMonth);
    compareFrom = `${previousYear}-${String(normalizedMonth + 1).padStart(2, "0")}-01`;
    compareTo = `${previousYear}-${String(normalizedMonth + 1).padStart(2, "0")}-${String(Math.min(day, previousMonthDays)).padStart(2, "0")}`;
  } else if (preset === "bulan-lalu") {
    const priorMonthLast = addDays(start, -1);
    compareFrom = monthStart(priorMonthLast); compareTo = priorMonthLast;
  } else {
    const duration = Math.round((Date.parse(`${end}T00:00:00Z`) - Date.parse(`${start}T00:00:00Z`)) / 86_400_000) + 1;
    compareTo = addDays(start, -1); compareFrom = addDays(compareTo, -(duration - 1));
  }
  return { from: start, to: end, compareFrom, compareTo };
}

function validDate(value: string | undefined): value is string {
  if (!value || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(parsed.valueOf()) && parsed.toISOString().slice(0, 10) === value;
}

export function isValidReportRange(from: string | undefined, to: string | undefined): boolean {
  if (!validDate(from) || !validDate(to) || to < from) return false;
  return Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`) <= 365 * 86_400_000;
}

export function percentChange(current: string, previous: string): string | null {
  const now = Number(current); const before = Number(previous);
  if (!Number.isFinite(now) || !Number.isFinite(before) || before === 0) return null;
  return (((now - before) / before) * 100).toFixed(1);
}

export function formatReportMoney(value: string | null | undefined, formatMagnitude: (amount: string) => string): string {
  if (value === null || value === undefined || value === "") return "—";
  if (value.startsWith("-") && /^-\d+(?:\.\d+)?$/.test(value)) return `-${formatMagnitude(value.slice(1))}`;
  return formatMagnitude(value);
}

export function idNumber(value: number): string { return new Intl.NumberFormat("id-ID", { maximumFractionDigits: 2 }).format(value); }
