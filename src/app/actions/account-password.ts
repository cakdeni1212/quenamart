"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { isUserRole, landingPathForRole } from "@/lib/auth/roles";

export type PasswordSetupResult = { error?: string };

export async function setInitialPassword(_: PasswordSetupResult, formData: FormData): Promise<PasswordSetupResult> {
  const password = String(formData.get("password") ?? "");
  const confirmation = String(formData.get("confirmation") ?? "");
  if (password.length < 8) return { error: "Kata sandi harus terdiri dari minimal 8 karakter." };
  if (password !== confirmation) return { error: "Konfirmasi kata sandi tidak sama." };

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Tautan undangan tidak aktif. Minta Owner mengirim undangan baru." };
  const { data: profile, error: profileError } = await supabase.from("profiles").select("role,is_active").eq("id", user.id).maybeSingle();
  if (profileError || !profile?.is_active || !isUserRole(profile.role)) {
    await supabase.auth.signOut();
    return { error: "Akun ini belum memiliki akses aktif. Hubungi Owner." };
  }
  const { error } = await supabase.auth.updateUser({ password });
  if (error) return { error: "Kata sandi belum dapat disimpan. Periksa ketentuan kata sandi lalu coba kembali." };
  redirect(landingPathForRole(profile.role));
}
