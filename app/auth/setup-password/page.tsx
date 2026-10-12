import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { isUserRole } from "@/lib/auth/roles";
import { SetupPasswordForm } from "@/components/auth/setup-password-form";

export default async function SetupPasswordPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data: profile } = await supabase.from("profiles").select("role,is_active").eq("id", user.id).maybeSingle();
  const eligible = Boolean(profile?.is_active && isUserRole(profile.role));
  const pending = !profile;
  return <main className="login-page"><section className="login-panel"><Link className="brand login-brand" href="/"><span className="brand-mark">Q</span><span>quena<span className="brand-light">mart</span><small>RETAIL MANAGEMENT</small></span></Link><div className="login-copy"><div className="eyebrow">AKUN QUENA MART</div>{eligible ? <><h1>Atur kata sandi.</h1><p>Buat kata sandi untuk akun kerja Anda.</p><SetupPasswordForm /></> : pending ? <><h1>Undangan diproses.</h1><p>Akun Anda sedang disiapkan. Tunggu sebentar lalu muat ulang halaman ini.</p><Link className="button-primary" href="/auth/setup-password">Coba lagi</Link></> : <><h1>Akun belum aktif.</h1><p>Hubungi Owner Quena Mart untuk memastikan akses akun Anda.</p></>}</div><div className="login-foot">Identitas yang sama digunakan untuk web/PWA dan aplikasi Quena Mart mendatang.</div></section><aside className="login-art"><div className="art-glow" /><div className="art-top"><span>QUENA MART</span><span>RETAIL · PEOPLE · GROWTH</span></div><div className="art-message"><div className="art-symbol">Q</div><p>Akses tim,<br /><em>tetap aman.</em></p><span>Satu akun untuk seluruh ruang kerja Quena Mart.</span></div><div className="art-bottom"><span>01 — 04</span><span>BUILT FOR EVERYDAY RETAIL</span></div></aside></main>;
}
