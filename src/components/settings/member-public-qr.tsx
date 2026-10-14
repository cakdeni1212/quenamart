"use client";

import styles from "./member-public-qr.module.css";
import Image from "next/image";

export function MemberPublicQr({ url, image }: { url: string | null; image: string | null }) {
  if (!url || !image) return <section className={styles.card}>
    <span className="eyebrow">PENDAFTARAN MEMBER</span><h2>QR Pendaftaran</h2>
    <p>Atur <code>NEXT_PUBLIC_APP_URL</code> ke alamat HTTPS aplikasi publik agar QR pendaftaran dapat dibuat.</p>
  </section>;
  return <section className={`${styles.card} ${styles.printable}`}>
    <div><span className="eyebrow">PENDAFTARAN MEMBER</span><h2>Member Quena Mart</h2><p>Scan untuk membuka halaman Member Quena Mart.</p><a href={url} target="_blank" rel="noreferrer">{url}</a></div>
    <Image src={image} width={220} height={220} unoptimized alt="QR umum menuju halaman Member Quena Mart" />
    <button className={styles.print} type="button" onClick={() => window.print()}>Cetak QR</button>
  </section>;
}
