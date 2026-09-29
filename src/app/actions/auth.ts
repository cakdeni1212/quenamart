"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { landingPathForRole, isUserRole } from "@/lib/auth/roles";

export type LoginState = { error?: string };

export async function login(_: LoginState, formData: FormData): Promise<LoginState> {
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");
  if (!email || !password) return { error: "Masukkan email dan kata sandi." };

  const supabase = await createClient();
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error || !data.user) return { error: "Email atau kata sandi tidak valid." };

  const { data: profile } = await supabase
    .from("profiles")
    .select("role, is_active")
    .eq("id", data.user.id)
    .maybeSingle();

  if (!profile?.is_active || !isUserRole(profile.role)) {
    await supabase.auth.signOut();
    return { error: "Akun ini belum memiliki akses aktif. Hubungi pemilik toko." };
  }

  redirect(landingPathForRole(profile.role));
}

export async function logout() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login");
}
