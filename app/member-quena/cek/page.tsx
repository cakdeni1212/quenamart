import Link from "next/link";
import styles from "../public-member.module.css";

export default function PublicMemberPointsPage() {
  return <main className={styles.shell}>
    <section className={styles.card}>
      <Link className={styles.back} href="/member-quena">← Quena Mart</Link>
      <span className={styles.eyebrow}>MEMBER QUENA MART</span>
      <h1>Cek Poin</h1>
      <p className={styles.lead}>Untuk menjaga saldo dan riwayat poin tetap aman, akses Member memerlukan verifikasi nomor WhatsApp.</p>
      <div className={styles.info} role="status"><strong>Verifikasi WhatsApp belum tersedia.</strong><span>Halaman saldo akan dibuka setelah layanan verifikasi resmi diaktifkan. Nomor telepon saja tidak dapat digunakan untuk melihat data Member.</span></div>
      <Link className={styles.secondary} href="/member-quena/daftar">Daftar Member</Link>
    </section>
  </main>;
}
