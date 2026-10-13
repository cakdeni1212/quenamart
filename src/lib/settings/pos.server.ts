import "server-only";
import { createClient } from "@/lib/supabase/server";
import { DEFAULT_POS_SETTINGS, POS_PAYMENT_METHODS, type PosPaymentMethod, type PosSettings } from "@/lib/settings/pos-shared";

function parseSettings(data: unknown): PosSettings | null {
  if (!data || typeof data !== "object" || Array.isArray(data)) return null;
  const row = data as Record<string, unknown>;
  if (typeof row.outlet_id !== "string" || !Array.isArray(row.enabled_payment_methods)) return null;
  const methods = row.enabled_payment_methods.filter((value): value is PosPaymentMethod =>
    typeof value === "string" && POS_PAYMENT_METHODS.includes(value as PosPaymentMethod));
  if (methods.length === 0) return null;
  return {
    outlet_id: row.outlet_id,
    receipt_footer_note: typeof row.receipt_footer_note === "string" ? row.receipt_footer_note : null,
    receipt_show_address: row.receipt_show_address === true,
    receipt_show_phone: row.receipt_show_phone === true,
    enabled_payment_methods: methods,
    allow_hold_transactions: row.allow_hold_transactions === true,
    confirm_cart_cancellation: row.confirm_cart_cancellation === true,
    updated_at: typeof row.updated_at === "string" ? row.updated_at : null,
  };
}

export async function readPosSettings(): Promise<{ settings: PosSettings | null; error: string | null }> {
  try {
    const supabase = await createClient();
    const { data, error } = await supabase.rpc("pos_settings_read");
    if (!error) {
      const settings = parseSettings(data);
      if (settings) return { settings, error: null };
    }
  } catch {
    // Render a recoverable state without exposing database diagnostics.
  }
  return { settings: null, error: "Pengaturan kasir belum dapat dibaca. Silakan coba kembali." };
}

export async function readEffectivePosSettings(): Promise<Omit<PosSettings, "outlet_id">> {
  try {
    const supabase = await createClient();
    const { data, error } = await supabase.rpc("pos_effective_settings_read");
    const settings = error ? null : parseSettings(data);
    if (settings) {
      return {
        receipt_footer_note: settings.receipt_footer_note,
        receipt_show_address: settings.receipt_show_address,
        receipt_show_phone: settings.receipt_show_phone,
        enabled_payment_methods: settings.enabled_payment_methods,
        allow_hold_transactions: settings.allow_hold_transactions,
        confirm_cart_cancellation: settings.confirm_cart_cancellation,
        updated_at: settings.updated_at,
      };
    }
  } catch {
    // The server defaults preserve today's POS behavior if settings are unavailable.
  }
  return { ...DEFAULT_POS_SETTINGS, updated_at: null };
}
