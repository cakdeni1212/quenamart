import "server-only";
import { createClient } from "@/lib/supabase/server";
import type { MemberPointsSettings } from "./member-points-shared";

function parse(value: unknown): MemberPointsSettings | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  if (typeof row.outlet_id !== "string" || typeof row.program_enabled !== "boolean" || typeof row.redeem_enabled !== "boolean") return null;
  const optionalInteger = (item: unknown) => item == null ? null : typeof item === "string" && /^[1-9][0-9]{0,8}$/.test(item) ? item : undefined;
  const earn = optionalInteger(row.rupiah_per_point);
  const redeem = optionalInteger(row.rupiah_per_redeem_point);
  const minimum = optionalInteger(row.minimum_redeem_points);
  if (earn === undefined || redeem === undefined || minimum === undefined) return null;
  return {
    outlet_id: row.outlet_id,
    program_enabled: row.program_enabled,
    rupiah_per_point: earn,
    redeem_enabled: row.redeem_enabled,
    rupiah_per_redeem_point: redeem,
    minimum_redeem_points: minimum,
    updated_at: typeof row.updated_at === "string" ? row.updated_at : null,
  };
}

export async function readMemberPointsSettings(): Promise<{ settings: MemberPointsSettings | null; error: string | null }> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("member_loyalty_settings_read");
  if (error) return { settings: null, error: "Pengaturan member dan poin belum dapat dimuat." };
  const settings = parse(data);
  return settings ? { settings, error: null } : { settings: null, error: "Data pengaturan member dan poin belum dapat dibaca." };
}
