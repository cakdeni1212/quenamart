import Link from "next/link";
import styles from "./public-member.module.css";

export default function PublicMemberHome() {
  return <main className={styles.shell}>
    <section className={styles.card}>
      <div className={styles.brand}><span className={styles.mark}>Q</span><span>QUENA MART</span></div>
      <span className={styles.eyebrow}>MEMBER QUENA MART</span>
      <h1>Belanja makin untung.</h1>
      <p className={styles.lead}>Kumpulkan poin setiap transaksi dan gunakan kembali saat berbelanja.</p>
      <div className={styles.actions}><Link className={styles.primary} href="/member-quena/daftar">Daftar Member</Link><Link className={styles.secondary} href="/member-quena/cek">Cek Poin</Link></div>
      <p className={styles.note}>Tidak perlu download aplikasi. Gunakan nomor WhatsApp Anda untuk layanan Member Quena Mart.</p>
    </section>
  </main>;
}
