import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readWhatsAppSettings } from "@/lib/notifications/whatsapp.server";
import { WhatsAppSettingsForm } from "@/components/settings/whatsapp-settings-form";
import styles from "@/components/settings/settings.module.css";
function hasPublicHttpsUrl() { try { const url = new URL(process.env.NEXT_PUBLIC_APP_URL ?? ""); return url.protocol === "https:" && !url.username && !url.password; } catch { return false; } }
export default async function WhatsAppSettingsPage() {
  const profile = await requireProfile(); if (profile.role !== "OWNER" && profile.role !== "ADMIN") redirect("/dashboard");
  const result = await readWhatsAppSettings();
  return <main className="page-content"><header className={styles.heading}><div><div className="eyebrow">PENGATURAN</div><h1>WhatsApp</h1><p>Atur notifikasi layanan transaksi Quena Mart.</p></div></header>
    {result.settings ? <WhatsAppSettingsForm settings={result.settings} canEdit={profile.role === "OWNER"} publicUrlReady={hasPublicHttpsUrl() && result.settings.public_url_ready} />
      : <div className={styles.readError} role="alert">{result.error}</div>}
  </main>;
}
