import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readOutletSettings } from "@/lib/settings/outlet";
import { OutletSettingsForm } from "@/components/settings/outlet-settings-form";
import styles from "@/components/settings/settings.module.css";

export default async function StoreOutletSettingsPage() {
  const profile = await requireProfile();
  if (profile.role !== "OWNER" && profile.role !== "ADMIN") redirect("/dashboard");
  const result = await readOutletSettings();

  return <main className="page-content">
    <header className={styles.heading}>
      <div><div className="eyebrow">PENGATURAN</div><h1>Toko &amp; Outlet</h1><p>Identitas dan informasi operasional toko.</p></div>
    </header>
    {result.outlet
      ? <OutletSettingsForm outlet={result.outlet} canEdit={profile.role === "OWNER"} />
      : <div className={styles.readError} role="status">{result.error ?? "Informasi outlet belum tersedia."}</div>}
  </main>;
}
