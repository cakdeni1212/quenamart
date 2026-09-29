import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";

export default async function KasirPage() {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "kasir")) redirect("/dashboard");
  return <main className="page-content"><div className="eyebrow">OPERASIONAL</div><h1>Kasir</h1><p className="page-lead">Ruang kasir akan tersedia saat modul POS mulai dibangun.</p><div className="surface-card module-placeholder"><span>▣</span><strong>Modul kasir sedang disiapkan</strong><p>Fondasi akses sudah mengikuti peran akun Anda.</p></div></main>;
}
