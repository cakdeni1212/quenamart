"use client";

import { useState } from "react";
import { issueDigitalReceiptLink } from "@/app/actions/pos-cart";
import styles from "./staff-digital-receipt-link.module.css";

export function StaffDigitalReceiptLink({ saleId }: { saleId: string }) {
  const [busy, setBusy] = useState(false);
  const [path, setPath] = useState<string | null>(null);
  const [publicUrl, setPublicUrl] = useState<string | null>(null);
  const [notice, setNotice] = useState("");

  const createLink = async () => {
    if (busy) return;
    setBusy(true);
    setNotice("");
    const result = await issueDigitalReceiptLink(saleId);
    setBusy(false);
    if (!result.ok) { setNotice(result.message); return; }
    setPath(result.path);
    setPublicUrl(result.publicUrl);
    setNotice(result.publicUrlConfigured
      ? "Tautan aktif dibuat. Pembuatan tautan baru akan mengganti tautan sebelumnya."
      : "URL publik aplikasi belum dikonfigurasi. Struk dapat dibuka dari perangkat ini melalui tautan relatif.");
  };

  const copyLink = async () => {
    if (!publicUrl) return;
    try {
      await navigator.clipboard.writeText(publicUrl);
      setNotice("Tautan struk disalin.");
    } catch {
      setNotice("Tautan tidak dapat disalin dari browser ini.");
    }
  };

  return <section className={styles.card} aria-labelledby="digital-receipt-title">
    <div><span className="eyebrow">STRUK DIGITAL</span><h2 id="digital-receipt-title">Tautan untuk pelanggan</h2>
      <p>Buat tautan aman untuk membuka struk transaksi ini.</p></div>
    <button type="button" onClick={() => void createLink()} disabled={busy}>{busy ? "Membuat tautan…" : path ? "Buat Tautan Baru" : "Buat Tautan Struk"}</button>
    {path && <div className={styles.linkActions}>
      <a href={path} target="_blank" rel="noopener noreferrer">Buka Struk</a>
      {publicUrl && <button type="button" onClick={() => void copyLink()}>Salin Link</button>}
    </div>}
    {notice && <p className={styles.notice} role="status">{notice}</p>}
  </section>;
}
