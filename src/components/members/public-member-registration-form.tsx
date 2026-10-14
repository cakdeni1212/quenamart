"use client";

import Link from "next/link";
import { useState } from "react";
import { registerPublicMember } from "@/app/actions/public-members";
import styles from "@/components/members/public-member-form.module.css";

export function PublicMemberRegistrationForm() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [memberNumber, setMemberNumber] = useState("");

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy || memberNumber) return;
    const form = new FormData(event.currentTarget);
    setBusy(true); setError("");
    const result = await registerPublicMember({
      name: String(form.get("name") ?? ""),
      phone: String(form.get("phone") ?? ""),
      email: String(form.get("email") ?? ""),
      serviceConsent: form.get("serviceConsent") === "on",
      promotionalConsent: form.get("promotionalConsent") === "on",
    });
    setBusy(false);
    if (!result.ok) { setError(result.message); return; }
    setMemberNumber(result.memberNumber);
  }

  if (memberNumber) return <section className={styles.success} aria-live="polite">
    <strong>Berhasil menjadi Member Quena Mart</strong>
    <span>ID Member</span><b>{memberNumber}</b>
    <p>Simpan ID Member ini. Anda dapat menggunakannya di kasir. Saldo poin dan kartu digital memerlukan verifikasi WhatsApp yang belum tersedia.</p>
    <Link href="/member-quena">Kembali ke Member Quena Mart</Link>
  </section>;

  return <form className={styles.form} onSubmit={submit}>
    <label>Nama *<input name="name" required maxLength={160} autoComplete="name" /></label>
    <label>Nomor WhatsApp *<input name="phone" required maxLength={40} type="tel" inputMode="tel" autoComplete="tel" placeholder="08..." /></label>
    <label>Email (opsional)<input name="email" maxLength={254} type="email" autoComplete="email" /></label>
    <label className={styles.consent}><input name="serviceConsent" type="checkbox" required /><span>Saya menyetujui data ini digunakan untuk layanan Membership dan komunikasi transaksi Quena Mart.</span></label>
    <label className={styles.consent}><input name="promotionalConsent" type="checkbox" /><span>Saya bersedia menerima informasi promo Quena Mart melalui WhatsApp (opsional).</span></label>
    {error && <p className={styles.error} role="alert">{error}</p>}
    <button className={styles.submit} disabled={busy}>{busy ? "Mendaftarkan…" : "Daftar Member"}</button>
  </form>;
}
