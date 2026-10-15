import "server-only";
import { createAdminClient } from "@/lib/supabase/admin";

export type WhatsAppConnectionState = "NOT_CONFIGURED" | "DISCONNECTED" | "CONNECTING" | "CONNECTED" | "DEGRADED" | "ERROR";
export type ProviderSendResult = { ok: true; providerMessageId: string | null } | { ok: false; code: string; retryable: boolean };

export interface WhatsAppProviderAdapter {
  getConnectionStatus(): Promise<WhatsAppConnectionState>;
  sendTransactionalMessage(input: { destination: string; message: string; idempotencyKey: string }): Promise<ProviderSendResult>;
  normalizeProviderError(error: unknown): { code: string; retryable: boolean };
}

/** V1 deliberately has no network transport or account connection. */
export const unconfiguredWhatsAppAdapter: WhatsAppProviderAdapter = {
  async getConnectionStatus() { return "NOT_CONFIGURED"; },
  async sendTransactionalMessage() { return { ok: false, code: "PROVIDER_NOT_CONFIGURED", retryable: false }; },
  normalizeProviderError() { return { code: "PROVIDER_NOT_CONFIGURED", retryable: false }; },
};

export function retryDelayMinutes(attempt: number): number | null {
  return [1, 5, 30, 120][attempt - 1] ?? null;
}

export type WhatsAppDeliverySnapshot = {
  customer_name: string; sale_number: string; sale_total: string | number;
  points_earned?: string | number | null; points_redeemed?: string | number | null;
  points_balance_after?: string | number | null; receipt_reference: string;
};

/** Deterministic template renderer. The bearer receipt URL is supplied ephemerally by a future worker. */
export function renderDigitalReceiptV1(snapshot: WhatsAppDeliverySnapshot, receiptUrl: string): string {
  const lines = ["QUENA MART", "", `Terima kasih, ${snapshot.customer_name}.`, "", "Total Belanja", `Rp${Number(snapshot.sale_total).toLocaleString("id-ID")}`];
  if (Number(snapshot.points_earned) > 0) lines.push("", "Poin Didapat", `+${Number(snapshot.points_earned).toLocaleString("id-ID")} poin`);
  if (Number(snapshot.points_redeemed) > 0) lines.push("", "Poin Digunakan", `-${Number(snapshot.points_redeemed).toLocaleString("id-ID")} poin`);
  if (snapshot.points_balance_after !== null && snapshot.points_balance_after !== undefined)
    lines.push("", "Saldo Poin", `${Number(snapshot.points_balance_after).toLocaleString("id-ID")} poin`);
  lines.push("", "Lihat Struk:", receiptUrl);
  return lines.join("\n");
}

/** A provider that is not configured must not claim or retry queued jobs. */
export async function claimDueWhatsAppNotifications(limit = 10): Promise<unknown[]> {
  if (await unconfiguredWhatsAppAdapter.getConnectionStatus() !== "CONNECTED") return [];
  if (!Number.isInteger(limit) || limit < 1 || limit > 50) return [];
  const { data, error } = await createAdminClient().rpc("notification_outbox_claim", { p_limit: limit });
  if (error) { console.error("[notification_outbox_claim] claim failed", { code: error.code }); return []; }
  return Array.isArray(data) ? data : [];
}
