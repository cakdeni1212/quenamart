import Link from "next/link";
import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import styles from "@/components/settings/settings.module.css";

const futureSections = [
  ["Member & Poin", "Aturan loyalty dan reward."],
  ["Keuangan", "Pengaturan operasional keuangan."],
  ["Sistem", "Informasi aplikasi dan konfigurasi sistem."],
] as const;

export default async function SettingsPage() {
  const profile = await requireProfile();
  if (profile.role !== "OWNER" && profile.role !== "ADMIN") redirect("/dashboard");

  return <main className="page-content">
    <header className={styles.heading}>
      <div><div className="eyebrow">PENGATURAN</div><h1>Pengaturan</h1><p>Konfigurasi ruang kerja dan operasional Quena Mart.</p></div>
    </header>
    <nav className={styles.directory} aria-label="Bagian Pengaturan">
      <Link className={styles.directoryRow} href="/pengaturan/toko-outlet">
        <span className={styles.directoryCopy}><strong>Toko &amp; Outlet</strong><span>Identitas dan informasi outlet.</span></span>
        <span className={styles.directoryAction}><span>Aktif</span><span aria-hidden="true">›</span></span>
      </Link>
      <Link className={styles.directoryRow} href="/pengaturan/kasir-penjualan">
        <span className={styles.directoryCopy}><strong>Kasir &amp; Penjualan</strong><span>Atur perilaku kasir dan tampilan struk.</span></span>
        <span className={styles.directoryAction}><span>Aktif</span><span aria-hidden="true">›</span></span>
      </Link>
      {profile.role === "OWNER" ? <Link className={styles.directoryRow} href="/pengaturan/akun">
        <span className={styles.directoryCopy}><strong>Pengguna &amp; Akses</strong><span>Kelola akun, role, dan status pengguna.</span></span>
        <span className={styles.directoryAction}><span aria-hidden="true">›</span></span>
      </Link> : <div className={`${styles.directoryRow} ${styles.comingSoon}`} aria-disabled="true">
        <span className={styles.directoryCopy}><strong>Pengguna &amp; Akses</strong><span>Kelola akun, role, dan status pengguna.</span></span>
        <span className={styles.badge}>Khusus Owner</span>
      </div>}
      {futureSections.map(([title, description]) => <div key={title} className={`${styles.directoryRow} ${styles.comingSoon}`} aria-disabled="true">
        <span className={styles.directoryCopy}><strong>{title}</strong><span>{description}</span></span>
        <span className={styles.badge}>Segera</span>
      </div>)}
    </nav>
  </main>;
}
