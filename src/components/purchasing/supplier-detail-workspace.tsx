"use client";

import Link from "next/link";
import { useState } from "react";
import { formatRupiah } from "@/lib/money";
import { SupplierForm } from "@/components/purchasing/supplier-workspace";
import styles from "./supplier-workspace.module.css";
import primaryAction from "@/components/ui/workspace-primary-action.module.css";

function date(value: string | null | undefined) {
  if (!value) return "—";
  return new Intl.DateTimeFormat("id-ID", { dateStyle: "medium", timeZone: "Asia/Jakarta" }).format(new Date(value));
}

export function SupplierDetailWorkspace({ data }: { data: {
  supplier: { id: string; supplier_code: string; display_name: string; legal_name: string | null; contact_name: string | null; phone: string | null; address: string | null; notes: string | null; is_active: boolean };
  purchases: Array<{ id: string; invoice_reference: string; invoice_number: string | null; invoice_date: string | null; due_date: string | null; total: string; paid: string; outstanding: string; payment_type: string; finalized_at: string; receipts: Array<{ id: string; reference: string; receivedAt: string }> }>;
  purchaseCount: number; page: number; pageSize: number; products: Array<{ id: string; name: string; sku: string; last_purchase: string; last_received_quantity: number }>;
  summary: { totalPurchases: string; outstanding: string; openInvoices: number; lastPurchase: string | null };
} }) {
  const [editing, setEditing] = useState(false);
  const s = data.supplier;
  const phoneDigits = (s.phone ?? "").replace(/\D/g, "");
  const waPhone = phoneDigits.length >= 10 && phoneDigits.startsWith("0") ? `62${phoneDigits.slice(1)}` : phoneDigits.length >= 10 && phoneDigits.startsWith("62") ? phoneDigits : "";
  const pages = Math.ceil(data.purchaseCount / data.pageSize);
  const dueStatus = (outstanding: string, total: string, dueDate: string | null) => {
    if (Number(outstanding) <= 0) return "Lunas";
    if (!dueDate) return "Belum Lunas";
    const todayText = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Jakarta", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
    if (dueDate < todayText) return "Terlambat";
    if (Number(outstanding) < Number(total)) return "Sebagian";
    const due = new Date(`${dueDate}T00:00:00+07:00`).getTime();
    const endOfWeek = new Date(`${todayText}T00:00:00+07:00`).getTime() + 7 * 86400000;
    if (due <= endOfWeek) return "Jatuh Tempo";
    return "Belum Lunas";
  };
  return <div className={styles.page}>
    <header className={`${styles.heading} ${styles.detailHeading}`}><div><span className="eyebrow">SUPPLIER · {s.supplier_code}</span><h1>{s.display_name}</h1><p>{s.contact_name || "Kontak belum diisi"}{s.phone ? ` · ${s.phone}` : ""}{s.address ? ` · ${s.address}` : ""}</p></div>
      <div className={styles.headerActions}><span className={`${styles.badge} ${s.is_active ? styles.active : styles.inactive}`}>{s.is_active ? "Aktif" : "Nonaktif"}</span>{waPhone && <a className={primaryAction.secondary} href={`https://wa.me/${waPhone}`} target="_blank" rel="noreferrer">WhatsApp</a>}<Link className={primaryAction.primary} href={`/pembelian/barang-masuk/baru?supplier=${s.id}`}>+ Barang Masuk</Link><button className={primaryAction.secondary} onClick={() => setEditing((v) => !v)}>{editing ? "Tutup Edit" : "Edit Supplier"}</button></div>
    </header>
    {editing && <section className={`surface-card ${styles.formCard}`}><h2>Edit Supplier</h2><SupplierForm supplier={s}/></section>}
    {s.notes && <p className={styles.notes}>{s.notes}</p>}
    <section className={styles.summary}>
      <article className="surface-card"><span>Total Pembelian</span><strong>{formatRupiah(data.summary.totalPurchases)}</strong><small>Total nota final, tanpa menjumlahkan penerimaan dua kali.</small></article>
      <article className="surface-card"><span>Outstanding Tempo</span><strong>{formatRupiah(data.summary.outstanding)}</strong></article>
      <article className="surface-card"><span>Nota Belum Lunas</span><strong>{data.summary.openInvoices} nota</strong></article>
      <article className="surface-card"><span>Pembelian Terakhir</span><strong>{date(data.summary.lastPurchase)}</strong></article>
    </section>
    <section className={`surface-card ${styles.list}`}><div className={styles.listHeading}><div><h2>Riwayat Pembelian &amp; Tempo</h2><p>Nota final dan alokasi pembayaran; pembayaran tidak dihitung ganda.</p></div><Link className={styles.detailLink} href="/tempo-supplier">Lihat Tempo</Link></div>
      {data.purchases.length === 0 ? <div className={styles.empty}>Belum ada pembelian dari supplier ini.</div> : <>
      <div className={styles.tableWrap}><table><thead><tr><th>Tanggal</th><th>No. Nota</th><th>Barang Masuk</th><th>Total</th><th>Dibayar</th><th>Sisa</th><th>Status</th></tr></thead><tbody>{data.purchases.map((p) => <tr key={p.id}><td>{date(p.invoice_date)}</td><td><Link href={`/pembelian/nota/${p.id}`}>{p.invoice_number || p.invoice_reference}</Link></td><td>{p.receipts.length ? p.receipts.map((r) => <Link className={styles.receiptLink} key={r.id} href={`/pembelian/barang-masuk/${r.id}`}>{r.reference}</Link>) : "—"}</td><td>{formatRupiah(p.total)}</td><td>{formatRupiah(p.paid)}</td><td>{formatRupiah(p.outstanding)}</td><td>{dueStatus(p.outstanding,p.total,p.due_date)}</td></tr>)}</tbody></table></div>
      <ul className={styles.mobileList}>{data.purchases.map((p) => <li key={p.id}><Link href={`/pembelian/nota/${p.id}`}><div><strong>{p.invoice_number || p.invoice_reference}</strong><small>{date(p.invoice_date)} · {p.payment_type === "TEMPO" ? dueStatus(p.outstanding,p.total,p.due_date) : "Tunai"}</small></div><b>{formatRupiah(p.outstanding === "0" ? p.total : p.outstanding)}</b></Link></li>)}</ul>
      {pages > 1 && <nav className={styles.pagination}><Link aria-disabled={data.page<=1} href={`?page=${data.page-1}`}>Sebelumnya</Link><span>{data.page} / {pages}</span><Link aria-disabled={data.page>=pages} href={`?page=${data.page+1}`}>Berikutnya</Link></nav>}
      </>}
    </section>
    <section className={`surface-card ${styles.list}`}><div className={styles.listHeading}><div><h2>Produk yang Pernah Dibeli</h2><p>Diambil dari riwayat Barang Masuk yang sudah diposting.</p></div></div>
      {data.products.length ? <div className={styles.productGrid}>{data.products.map((p) => <article key={p.id}><div><strong>{p.name}</strong><small>{p.sku} · terakhir {date(p.last_purchase)}</small></div><span>{p.last_received_quantity} terakhir diterima</span></article>)}</div> : <div className={styles.empty}>Belum ada riwayat barang masuk.</div>}
    </section>
  </div>;
}
