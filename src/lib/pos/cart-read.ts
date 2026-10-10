import "server-only";
import { createClient } from "@/lib/supabase/server";

export type PosCartWorkspaceResult = {
  carts: Array<Record<string, unknown>>;
  error: string | null;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function readPosCartWorkspace(cartId?: string): Promise<PosCartWorkspaceResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("pos_cart_workspace_read", {
    p_cart_id: cartId ?? null,
    p_limit: 20,
  });
  if (error || !isRecord(data) || !Array.isArray(data.carts)) {
    return { carts: [], error: "Keranjang POS belum dapat dimuat." };
  }
  return { carts: data.carts.filter(isRecord), error: null };
}
