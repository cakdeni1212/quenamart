import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { isUserRole, type Profile } from "@/lib/auth/roles";

export async function getProfile(): Promise<Profile | null> {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return null;

  const { data, error } = await supabase
    .from("profiles")
    .select("id, full_name, role, is_active")
    .eq("id", user.id)
    .maybeSingle();

  if (error || !data || !data.is_active || !isUserRole(data.role)) return null;
  return data as Profile;
}

export async function requireProfile() {
  const profile = await getProfile();
  if (!profile) redirect("/login");
  return profile;
}
