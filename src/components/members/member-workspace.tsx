"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { saveMember, searchMembers } from "@/app/actions/members";
import styles from "./members.module.css";

type Row = Record<string, unknown>;
const value = (row: Row, key: string) => row[key] == null ? "—" : String(row[key]);
const money = (v: unknown) => `Rp ${Number(v ?? 0).toLocaleString("id-ID")}`;

export function MemberWorkspace({ initialRows, initialTotal, initialPage, initialError, canEdit }: { initialRows: Row[]; initialTotal: number; initialPage: number; initialError: string | null; canEdit: boolean }) {
  const router = useRouter();
  const [rows, setRows] = useState(initialRows);
  const [total, setTotal] = useState(initialTotal);
  const [page, setPage] = useState(initialPage);
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState(initialError ?? "");
  const [loadError, setLoadError] = useState(Boolean(initialError));
  const [duplicateId, setDuplicateId] = useState("");
  const sequence = useRef(0);

  useEffect(() => {
    const request = ++sequence.current;
    const timer = window.setTimeout(async () => {
      const result = await searchMembers(query, 1);
      if (request !== sequence.current) return;
      if (result.ok) {
        setRows(Array.isArray(result.value.rows) ? result.value.rows as Row[] : []);
        setTotal(Number(result.value.total ?? 0)); setPage(1); setLoadError(false); setNotice("");
      } else { setLoadError(true); setNotice(result.message); }
    }, 250);
    return () => window.clearTimeout(timer);
  }, [query]);

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy) return;
    const data = new FormData(event.currentTarget);
    const name = String(data.get("name") ?? "").trim();
    const phone = String(data.get("phone") ?? "").trim();
    const email = String(data.get("email") ?? "").trim();
    if (!name || !phone) { setNotice("Nama dan nomor HP wajib diisi."); return; }
    setBusy(true); setNotice(""); setDuplicateId("");
    const result = await saveMember({ name, phone, email });
    setBusy(false);
    if (!result.ok) { setNotice(result.message); setDuplicateId(String(result.existingMember?.id ?? "")); return; }
    setOpen(false); setQuery(""); setNotice(`Member ${String(result.value.member_number)} berhasil dibuat.`);
    router.push(`/member/${String(result.value.id)}`); router.refresh();
  }

  async function changePage(next: number) {
    setBusy(true);
    const result = await searchMembers(query, next);
    setBusy(false);
    if (!result.ok) { setNotice(result.message); return; }
    setRows(Array.isArray(result.value.rows) ? result.value.rows as Row[] : []);
    setTotal(Number(result.value.total ?? 0)); setPage(next);
  }

  return <div className={styles.page}>
    <header className={styles.heading}><div><span className="eyebrow">PELANGGAN</span><h1>Member</h1><p>Kelola pelanggan dan riwayat loyalitas Quena Mart.</p></div>{canEdit && <button type="button" className={styles.primary} onClick={() => setOpen(true)}>+ Tambah Member</button>}</header>
    <section className={styles.toolbar}><label htmlFor="member-search">Cari nama, nomor HP, ID Member, atau kode member</label><input id="member-search" type="search" maxLength={80} value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Contoh: 0812… atau QMEM-000001" /></section>
    {notice && <p className={styles.notice} role={loadError ? "alert" : "status"}>{notice}</p>}
    {loadError ? null : rows.length ? <>
      <div className={styles.tableWrap}><table><thead><tr><th>ID Member</th><th>Nama</th><th>Nomor HP</th><th>Poin</th><th>Transaksi</th><th>Total Belanja</th><th>Status</th><th></th></tr></thead><tbody>{rows.map((row) => <tr key={value(row,"id")}><td><Link href={`/member/${value(row,"id")}`}>{value(row,"member_number")}</Link></td><td>{value(row,"full_name")}</td><td>{value(row,"phone")}</td><td>{Number(row.point_balance ?? 0).toLocaleString("id-ID")}</td><td>{Number(row.transaction_count ?? 0).toLocaleString("id-ID")}</td><td>{money(row.total_spend)}</td><td><span className={`${styles.badge} ${row.status === "ACTIVE" ? styles.active : styles.inactive}`}>{row.status === "ACTIVE" ? "Aktif" : "Nonaktif"}</span></td><td><Link href={`/member/${value(row,"id")}`}>Detail</Link></td></tr>)}</tbody></table></div>
      <div className={styles.mobileList}>{rows.map((row) => <Link className={styles.mobileCard} href={`/member/${value(row,"id")}`} key={value(row,"id")}><div><strong>{value(row,"full_name")}</strong><span className={`${styles.badge} ${row.status === "ACTIVE" ? styles.active : styles.inactive}`}>{row.status === "ACTIVE" ? "Aktif" : "Nonaktif"}</span></div><small>{value(row,"member_number")} · {value(row,"phone")}</small><span>{Number(row.transaction_count ?? 0).toLocaleString("id-ID")} transaksi · {money(row.total_spend)}</span></Link>)}</div>
      <nav className={styles.pagination}><span>{total.toLocaleString("id-ID")} member · Halaman {page} dari {Math.max(1,Math.ceil(total/20))}</span><div><button disabled={busy || page<=1} onClick={() => void changePage(page-1)}>Sebelumnya</button><button disabled={busy || page*20>=total} onClick={() => void changePage(page+1)}>Berikutnya</button></div></nav>
    </> : <div className={styles.empty}><strong>{query ? "Member tidak ditemukan." : "Belum ada member."}</strong><p>{query ? "Coba kata kunci atau nomor HP lain." : "Tambahkan pelanggan untuk mulai membangun riwayat member."}</p></div>}
    {open && <div className={styles.backdrop} role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && !busy) setOpen(false); }}><form className={styles.dialog} onSubmit={submit}><header><div><span className="eyebrow">MEMBER BARU</span><h2>Tambah Member</h2></div><button type="button" aria-label="Tutup" onClick={() => setOpen(false)}>×</button></header><label>Nama *<input name="name" required maxLength={160} autoFocus /></label><label>Nomor HP *<input name="phone" required maxLength={40} type="tel" inputMode="tel" /></label><label>Email (opsional)<input name="email" maxLength={254} type="email" /></label><p>Saldo poin dimulai dari 0. Aturan poin belum diaktifkan.</p>{notice && <div role="alert">{notice}{duplicateId && <Link href={`/member/${duplicateId}`}>Buka member yang sudah ada</Link>}</div>}<footer><button type="button" className={styles.secondary} disabled={busy} onClick={() => setOpen(false)}>Batal</button><button className={styles.primary} disabled={busy}>{busy ? "Menyimpan…" : "Simpan Member"}</button></footer></form></div>}
  </div>;
}
