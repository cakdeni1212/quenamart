import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readMemberPointsSettings } from "@/lib/settings/member-points.server";
import { MemberPointsSettingsForm } from "@/components/settings/member-points-settings-form";
import { MemberPublicQr } from "@/components/settings/member-public-qr";
import styles from "@/components/settings/settings.module.css";
import QRCode from "qrcode";

export default async function MemberPointsSettingsPage() {
  const profile = await requireProfile();
  if (profile.role !== "OWNER" && profile.role !== "ADMIN") redirect("/dashboard");
  const result = await readMemberPointsSettings();
  const configuredBase = process.env.NEXT_PUBLIC_APP_URL?.trim();
  let registrationUrl: string | null = null;
  let registrationQr: string | null = null;
  if (profile.role === "OWNER" && configuredBase) {
    try {
      const base = new URL(configuredBase);
      if (base.protocol === "https:" || base.hostname === "localhost" || base.hostname === "127.0.0.1") {
        registrationUrl = new URL("/member-quena", base).toString();
        registrationQr = await QRCode.toDataURL(registrationUrl, { errorCorrectionLevel: "M", margin: 2, width: 240, color: { dark: "#25472e", light: "#ffffff" } });
      }
    } catch { /* Invalid/missing public URL is shown as an explicit configuration requirement. */ }
  }
  return <main className="page-content">
    <header className={styles.heading}><div><div className="eyebrow">PENGATURAN</div><h1>Member &amp; Poin</h1><p>Atur cara pelanggan mendapatkan dan menggunakan poin.</p></div></header>
    {result.settings ? <MemberPointsSettingsForm settings={result.settings} canEdit={profile.role === "OWNER"} />
      : <div className={styles.readError} role="alert">{result.error ?? "Pengaturan belum dapat dimuat."}</div>}
    {profile.role === "OWNER" && <MemberPublicQr url={registrationUrl} image={registrationQr} />}
  </main>;
}
