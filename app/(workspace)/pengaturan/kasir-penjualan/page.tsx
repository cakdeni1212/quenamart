import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readPosSettings } from "@/lib/settings/pos";
import { PosSettingsForm } from "@/components/settings/pos-settings-form";
import styles from "@/components/settings/settings.module.css";

export default async function CashierSalesSettingsPage() {
  const profile = await requireProfile();
  if (profile.role !== "OWNER" && profile.role !== "ADMIN") redirect("/dashboard");
  const result = await readPosSettings();

  return <main className="page-content">
    <header className={styles.heading}>
      <div><div className="eyebrow">PENGATURAN</div><h1>Kasir &amp; Penjualan</h1><p>Atur perilaku kasir dan tampilan struk.</p></div>
    </header>
    {result.settings
      ? <PosSettingsForm settings={result.settings} canEdit={profile.role === "OWNER"} />
      : <div className={styles.readError} role="status">{result.error ?? "Pengaturan kasir belum tersedia."}</div>}
  </main>;
}
