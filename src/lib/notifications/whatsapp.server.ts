import "server-only";
import { createClient } from "@/lib/supabase/server";

export type WhatsAppSettings = {
  outlet_id: string;
  whatsapp_transactions_enabled: boolean;
  automatic_receipt_enabled: boolean;
  include_points_earned: boolean;
  include_points_redeemed: boolean;
  include_points_balance: boolean;
  provider_state: string;
  public_url_ready: boolean;
  updated_at: string | null;
};
export type WhatsAppNotificationRow = {
  id: string; customer_name: string; destination_masked: string; sale_number: string;
  notification_type: string; status: string; created_at: string; sent_at: string | null;
};
export type WhatsAppSummary = {
  provider_state: string; automation_enabled: boolean; today_sent: number; pending: number;
  failed: number; oldest_pending_at: string | null; recent: WhatsAppNotificationRow[];
};
function row(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
function parseSettings(value: unknown): WhatsAppSettings | null {
  if (!row(value) || typeof value.outlet_id !== "string" || typeof value.whatsapp_transactions_enabled !== "boolean"
    || typeof value.automatic_receipt_enabled !== "boolean" || typeof value.include_points_earned !== "boolean"
    || typeof value.include_points_redeemed !== "boolean" || typeof value.include_points_balance !== "boolean") return null;
  return { outlet_id: value.outlet_id, whatsapp_transactions_enabled: value.whatsapp_transactions_enabled,
    automatic_receipt_enabled: value.automatic_receipt_enabled, include_points_earned: value.include_points_earned,
    include_points_redeemed: value.include_points_redeemed, include_points_balance: value.include_points_balance,
    provider_state: typeof value.provider_state === "string" ? value.provider_state : "NOT_CONFIGURED",
    public_url_ready: value.public_url_ready === true, updated_at: typeof value.updated_at === "string" ? value.updated_at : null };
}
export async function readWhatsAppSettings() {
  try {
    const { data, error } = await (await createClient()).rpc("whatsapp_settings_read");
    return error ? { settings: null, error: "Pengaturan WhatsApp belum dapat dimuat." }
      : { settings: parseSettings(data), error: parseSettings(data) ? null : "Data pengaturan WhatsApp belum dapat dibaca." };
  } catch { return { settings: null, error: "Pengaturan WhatsApp belum dapat dimuat." }; }
}
function parseSummary(value: unknown): WhatsAppSummary | null {
  if (!row(value) || !Array.isArray(value.recent)) return null;
  const recent = value.recent.filter(row).map((item) => ({ id: String(item.id ?? ""), customer_name: String(item.customer_name ?? "Pelanggan"),
    destination_masked: String(item.destination_masked ?? "••••"), sale_number: String(item.sale_number ?? "—"),
    notification_type: String(item.notification_type ?? "DIGITAL_RECEIPT"), status: String(item.status ?? "BLOCKED"),
    created_at: String(item.created_at ?? ""), sent_at: typeof item.sent_at === "string" ? item.sent_at : null }));
  return { provider_state: String(value.provider_state ?? "NOT_CONFIGURED"), automation_enabled: value.automation_enabled === true,
    today_sent: Number(value.today_sent) || 0, pending: Number(value.pending) || 0, failed: Number(value.failed) || 0,
    oldest_pending_at: typeof value.oldest_pending_at === "string" ? value.oldest_pending_at : null, recent };
}
export async function readWhatsAppSummary() {
  try {
    const { data, error } = await (await createClient()).rpc("whatsapp_center_summary");
    return error ? { summary: null, error: "Ringkasan WhatsApp belum dapat dimuat." }
      : { summary: parseSummary(data), error: parseSummary(data) ? null : "Data ringkasan WhatsApp belum dapat dibaca." };
  } catch { return { summary: null, error: "Ringkasan WhatsApp belum dapat dimuat." }; }
}
