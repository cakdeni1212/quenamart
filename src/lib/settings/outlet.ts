import { createClient } from "@/lib/supabase/server";

export type OutletSettings = {
  id: string;
  name: string;
  customer_display_name: string | null;
  code: string;
  address: string | null;
  city: string | null;
  province: string | null;
  postal_code: string | null;
  phone: string | null;
  whatsapp: string | null;
  email: string | null;
  is_active: boolean;
  can_deactivate: boolean;
  updated_at: string;
  updated_by: string | null;
};

export async function readOutletSettings(): Promise<{ outlet: OutletSettings | null; error: string | null }> {
  try {
    const supabase = await createClient();
    const { data, error } = await supabase.rpc("outlet_settings_read");
    if (!error && data && typeof data === "object") return { outlet: data as OutletSettings, error: null };
  } catch {
    // Keep database details server-side and render a recoverable page state.
  }
  return { outlet: null, error: "Informasi outlet belum dapat dibaca. Silakan coba kembali." };
}
