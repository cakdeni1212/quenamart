"use client";

import Link from "next/link";
import Image from "next/image";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { saveMember, setMemberStatus } from "@/app/actions/members";
import styles from "./members.module.css";

type Row = Record<string, unknown>;
const value = (row: Row, key: string) => row[key] == null ? "—" : String(row[key]);
const money = (v: unknown) => `Rp ${Number(v ?? 0).toLocaleString("id-ID")}`;
const pointEventLabel = (value: unknown) => ({ SALE_EARN: "Poin dari belanja", SALE_REDEEM: "Tukar poin", SALE_EARN_REVERSAL: "Pembatalan poin belanja", SALE_REDEEM_REVERSAL: "Pengembalian poin" } as Record<string, string>)[String(value)] ?? String(value);
const pointDeltaLabel = (value: unknown) => { const amount = Number(value ?? 0); return `${amount > 0 ? "+" : ""}${amount.toLocaleString("id-ID")}`; };

export function MemberDetailWorkspace({ data, memberCodeImage, canEdit }: { data: Row; memberCodeImage: string | null; canEdit: boolean }) {
  const member = data.member as Row;
  const transactions = Array.isArray(data.transactions) ? data.transactions as Row[] : [];
  const ledger = Array.isArray(data.pointsHistory) ? data.pointsHistory as Row[] : [];
  const router = useRouter();
  const [editing, setEditing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");

  async function update(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (busy) return;
    const form = new FormData(event.currentTarget); setBusy(true);
    const result = await saveMember({ id: String(member.id), name: String(form.get("name") ?? ""), phone: String(form.get("phone") ?? ""), email: String(form.get("email") ?? "") });
    setBusy(false);
    if (!result.ok) { setNotice(result.message); return; }
    setNotice("Data member berhasil diperbarui."); setEditing(false); router.refresh();
  }

  async function changeStatus() {
    if (busy) return;
    const reason = window.prompt(member.status === "ACTIVE" ? "Alasan menonaktifkan member:" : "Alasan mengaktifkan member:")?.trim();
    if (!reason) return;
    setBusy(true);
    const result = await setMemberStatus(String(member.id), member.status === "ACTIVE" ? "INACTIVE" : "ACTIVE", reason);
    setBusy(false);
    if (!result.ok) { setNotice(result.message); return; }
    router.refresh();
  }

  return <div className={styles.page}>
    <Link className={styles.back} href="/member">← Kembali ke Member</Link>
    <header className={styles.heading}><div><span className="eyebrow">MEMBER</span><h1>{value(member,"full_name")}</h1><p>{value(member,"member_number")} · {value(member,"phone")} · {member.status === "ACTIVE" ? "Aktif" : "Nonaktif"}</p></div>{canEdit && <div className={styles.headerActions}><button className={styles.secondary} onClick={() => setEditing((open) => !open)}>{editing ? "Tutup Edit" : "Edit Member"}</button><button className={styles.secondary} disabled={busy} onClick={() => void changeStatus()}>{member.status === "ACTIVE" ? "Nonaktifkan" : "Aktifkan"}</button></div>}</header>
    {notice && <p className={styles.notice} role="status">{notice}</p>}
    {editing && <form className={styles.editForm} onSubmit={update}><label>Nama *<input name="name" required maxLength={160} defaultValue={String(member.full_name ?? "")} /></label><label>Nomor HP *<input name="phone" required type="tel" maxLength={40} defaultValue={String(member.phone ?? "")} /></label><label>Email<input name="email" type="email" maxLength={254} defaultValue={String(member.email ?? "")} /></label><button className={styles.primary} disabled={busy}>{busy ? "Menyimpan…" : "Simpan Perubahan"}</button></form>}
    <section className={styles.summary}><article><span>Saldo Poin</span><strong>{Number(member.point_balance ?? 0).toLocaleString("id-ID")}</strong><small>Riwayat poin tercatat di ledger.</small></article><article><span>Jumlah Transaksi</span><strong>{Number(member.transaction_count ?? 0).toLocaleString("id-ID")}</strong><small>Penjualan native Quena POS.</small></article><article><span>Total Belanja</span><strong>{money(member.total_spend)}</strong><small>Dari transaksi selesai yang terhubung ke member.</small></article></section>
    {memberCodeImage && <section className={styles.memberCode}><div><h2>Kartu Member</h2><p>Kode ini untuk pencarian cepat oleh kasir. Kode tidak memberi akses ke saldo atau riwayat melalui web.</p><strong>{value(member,"full_name")}</strong><span>{value(member,"member_number")}</span><b>Saldo {Number(member.point_balance ?? 0).toLocaleString("id-ID")} poin</b></div><Image src={memberCodeImage} width={160} height={160} unoptimized alt={`Kode Member POS ${value(member,"member_number")}`} /></section>}
    <section className={styles.detailCard}><header><h2>Informasi Member</h2></header><dl><div><dt>Nama</dt><dd>{value(member,"full_name")}</dd></div><div><dt>ID Member</dt><dd>{value(member,"member_number")}</dd></div><div><dt>Nomor HP</dt><dd>{value(member,"phone")}</dd></div><div><dt>Email</dt><dd>{value(member,"email")}</dd></div><div><dt>Tanggal Bergabung</dt><dd>{new Date(String(member.joined_at)).toLocaleDateString("id-ID",{dateStyle:"long",timeZone:"Asia/Jakarta"})}</dd></div></dl></section>
    <section className={styles.detailCard}><header><h2>Riwayat Transaksi</h2><p>Hanya penjualan Quena POS dengan hubungan member yang tersimpan.</p></header>{transactions.length ? <><div className={styles.tableWrap}><table><thead><tr><th>Tanggal</th><th>No. Transaksi</th><th>Jumlah Item</th><th>Total</th></tr></thead><tbody>{transactions.map((tx) => <tr key={value(tx,"id")}><td>{new Date(String(tx.completed_at)).toLocaleString("id-ID",{dateStyle:"medium",timeStyle:"short",timeZone:"Asia/Jakarta"})}</td><td><Link href={`/transaksi/${value(tx,"id")}`}>{value(tx,"sale_number")}</Link></td><td>{value(tx,"item_count")}</td><td>{money(tx.grand_total)}</td></tr>)}</tbody></table></div><div className={styles.mobileRows}>{transactions.map((tx) => <Link key={value(tx,"id")} href={`/transaksi/${value(tx,"id")}`}><strong>{value(tx,"sale_number")}</strong><span>{new Date(String(tx.completed_at)).toLocaleString("id-ID",{dateStyle:"medium",timeStyle:"short",timeZone:"Asia/Jakarta"})} · {value(tx,"item_count")} item</span><b>{money(tx.grand_total)}</b></Link>)}</div></> : <p className={styles.emptyInline}>Belum ada transaksi member.</p>}</section>
    <section className={styles.detailCard}><header><h2>Riwayat Poin</h2><p>Saldo dihitung dari jumlah perubahan poin yang tercatat.</p></header>{ledger.length ? <><div className={styles.tableWrap}><table><thead><tr><th>Tanggal</th><th>Jenis</th><th>Poin</th><th>Catatan</th></tr></thead><tbody>{ledger.map((entry) => <tr key={value(entry,"id")}><td>{new Date(String(entry.occurred_at)).toLocaleString("id-ID",{dateStyle:"medium",timeStyle:"short",timeZone:"Asia/Jakarta"})}</td><td>{pointEventLabel(entry.event_type)}</td><td>{pointDeltaLabel(entry.points_delta)}</td><td>{value(entry,"note")}</td></tr>)}</tbody></table></div><div className={styles.mobileRows}>{ledger.map((entry) => <article key={value(entry,"id")}><strong>{pointDeltaLabel(entry.points_delta)} poin · {pointEventLabel(entry.event_type)}</strong><span>{new Date(String(entry.occurred_at)).toLocaleString("id-ID",{dateStyle:"medium",timeStyle:"short",timeZone:"Asia/Jakarta"})}</span><small>{value(entry,"note")}</small></article>)}</div></> : <p className={styles.emptyInline}>Belum ada riwayat poin. Saldo awal member adalah 0.</p>}</section>
  </div>;
}
