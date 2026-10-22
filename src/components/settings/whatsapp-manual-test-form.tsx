"use client";

import { useState, type FormEvent } from "react";
import { sendManualWhatsAppTestMessage } from "@/app/actions/whatsapp-provider";
import styles from "@/components/settings/settings.module.css";

const DEFAULT_MESSAGE = "Tes koneksi WhatsApp Quena Mart. Pesan ini dikirim manual dari sistem Quena.";

export function WhatsAppManualTestForm() {
  const [destination, setDestination] = useState("");
  const [message, setMessage] = useState(DEFAULT_MESSAGE);
  const [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<{ ok: boolean; message: string } | null>(null);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy || !confirmed) return;
    setBusy(true);
    setResult(null);
    try {
      setResult(await sendManualWhatsAppTestMessage(destination, message));
    } catch {
      setResult({ ok: false, message: "Pesan tes belum dapat diproses. Coba kembali." });
    } finally {
      setBusy(false);
    }
  }

  return <section className={styles.formSection}>
    <header><h2>UJI KONEKSI MANUAL</h2><p>Kirim satu pesan tes ke nomor yang Anda masukkan. Fitur ini tidak memakai transaksi atau antrean pelanggan.</p></header>
    <form className={styles.whatsappTestForm} onSubmit={(event) => void submit(event)}>
      <label>Nomor WhatsApp tujuan
        <input type="tel" inputMode="tel" autoComplete="tel" maxLength={40} placeholder="081234567890" value={destination} onChange={(event) => setDestination(event.target.value)} required />
      </label>
      <label>Pesan tes
        <textarea maxLength={500} rows={3} value={message} onChange={(event) => setMessage(event.target.value)} required />
        <small>{message.length}/500 karakter</small>
      </label>
      <label className={styles.whatsappTestConfirm}>
        <input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} />
        Saya memastikan nomor ini milik saya atau penerima menyetujui pesan tes.
      </label>
      <button className={styles.saveButton} type="submit" disabled={busy || !confirmed || !destination.trim() || !message.trim()}>
        {busy ? "Mengirim…" : "Kirim Pesan Tes"}
      </button>
      {result && <p className={`${styles.notice} ${result.ok ? styles.success : styles.error}`} role={result.ok ? "status" : "alert"}>{result.message}</p>}
    </form>
    <p className={styles.whatsappTestNote}>Manual saja: tidak mengaktifkan otomatisasi, membuat notifikasi, atau mengirim pesan pelanggan.</p>
  </section>;
}
