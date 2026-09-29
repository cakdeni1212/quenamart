import { redirect } from "next/navigation";
import Link from "next/link";
import { LoginForm } from "@/components/auth/login-form";
import { getProfile } from "@/lib/auth/session";
import { landingPathForRole } from "@/lib/auth/roles";

export default async function LoginPage() {
  const profile = await getProfile();
  if (profile) redirect(landingPathForRole(profile.role));
  return <main className="login-page"><section className="login-panel"><Link className="brand login-brand" href="/"><span className="brand-mark">Q</span><span>quena<span className="brand-light">mart</span><small>RETAIL MANAGEMENT</small></span></Link><div className="login-copy"><div className="eyebrow"><span className="live-dot" /> RUANG KERJA TOKO</div><h1>Selamat datang<br />kembali.</h1><p>Masuk untuk mengelola operasional Quena Mart dengan lebih mudah.</p><LoginForm /></div><div className="login-foot">© 2026 Quena Mart <span>•</span> Sistem operasional internal</div></section><aside className="login-art"><div className="art-glow" /><div className="art-top"><span>QUENA MART</span><span>RETAIL · PEOPLE · GROWTH</span></div><div className="art-message"><div className="art-symbol">Q</div><p>Operasional toko,<br /><em>lebih tertata.</em></p><span>Satu ruang kerja untuk tim dan toko yang terus bertumbuh.</span></div><div className="art-bottom"><span>01 — 04</span><span>BUILT FOR EVERYDAY RETAIL</span></div></aside></main>;
}
