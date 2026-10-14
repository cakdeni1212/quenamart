import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readMemberPointsSettings } from "@/lib/settings/member-points.server";
import { MemberPointsSettingsForm } from "@/components/settings/member-points-settings-form";
import styles from "@/components/settings/settings.module.css";

export default async function MemberPointsSettingsPage() {
  const profile = await requireProfile();
  if (profile.role !== "OWNER" && profile.role !== "ADMIN") redirect("/dashboard");
  const result = await readMemberPointsSettings();
  return <main className="page-content">
    <header className={styles.heading}><div><div className="eyebrow">PENGATURAN</div><h1>Member &amp; Poin</h1><p>Atur cara pelanggan mendapatkan dan menggunakan poin.</p></div></header>
    {result.settings ? <MemberPointsSettingsForm settings={result.settings} canEdit={profile.role === "OWNER"} />
      : <div className={styles.readError} role="alert">{result.error ?? "Pengaturan belum dapat dimuat."}</div>}
  </main>;
}
