import Link from "next/link";
import { PublicMemberRegistrationForm } from "@/components/members/public-member-registration-form";
import styles from "../public-member.module.css";

export default function PublicMemberRegistrationPage() {
  return <main className={styles.shell}>
    <section className={styles.card}>
      <Link className={styles.back} href="/member-quena">← Quena Mart</Link>
      <span className={styles.eyebrow}>MEMBER QUENA MART</span>
      <h1>Daftar Member</h1>
      <p className={styles.lead}>Isi nama dan nomor WhatsApp untuk bergabung. Tidak perlu membuat akun atau kata sandi.</p>
      <PublicMemberRegistrationForm />
    </section>
  </main>;
}
