import "server-only";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

let adminClient: SupabaseClient | null = null;

export function createAdminClient() {
  if (adminClient) return adminClient;
  const url = process.env.SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url) throw new Error("Missing server configuration: project URL (SUPABASE_URL or NEXT_PUBLIC_SUPABASE_URL).");
  if (!serviceRoleKey) throw new Error("Missing server configuration: SUPABASE_SERVICE_ROLE_KEY.");

  adminClient = createClient(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
  });
  return adminClient;
}
