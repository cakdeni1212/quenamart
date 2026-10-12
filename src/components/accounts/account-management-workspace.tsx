"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { createManagedAccount, updateManagedAccount, type AccountActionResult } from "@/app/actions/account-management";
import { ACCOUNT_ROLE_DESCRIPTIONS, ACCOUNT_ROLES, accountDateTime } from "@/lib/accounts/model";
import type { ManagedAccount } from "@/lib/accounts/read";
import styles from "./accounts.module.css";

const roleLabels = { OWNER: "OWNER", ADMIN: "ADMIN", KASIR: "KASIR", GUDANG: "GUDANG" } as const;
const safeResult = (result: AccountActionResult) => result.message;

export function CreateAccountButton() {
  const [open, setOpen] = useState(false);
  const [fullName, setFullName] = useState("");
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<(typeof ACCOUNT_ROLES)[number]>("KASIR");
  const [requestId, setRequestId] = useState("");
  const [notice, setNotice] = useState<{ ok: boolean; text: string } | null>(null);
  const [busy, startTransition] = useTransition();
  const router = useRouter();

  function show() {
    setNotice(null);
    setRequestId(crypto.randomUUID());
    setOpen(true);
  }

  function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    startTransition(async () => {
      const result = await createManagedAccount({ requestId, fullName, email, role });
      setNotice({ ok: result.ok, text: safeResult(result) });
      if (result.ok) {
        setFullName(""); setEmail(""); setRole("KASIR");
        router.refresh();
      }
    });
  }

  return <>
    <button className="button-primary" type="button" onClick={show}>＋ Tambah Akun</button>
    {open && <div className={styles.backdrop} role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && !busy) setOpen(false); }}>
      <section className={styles.dialog} role="dialog" aria-modal="true" aria-labelledby="account-create-title">
        <div className={styles.dialogHead}><div><span className="eyebrow">UNDANG ANGGOTA TIM</span><h2 id="account-create-title">Tambah Akun</h2></div><button type="button" className={styles.close} onClick={() => setOpen(false)} disabled={busy} aria-label="Tutup">×</button></div>
        <p className={styles.dialogLead}>Supabase Auth akan mengirim tautan untuk menyiapkan kata sandi. Kata sandi tidak disimpan oleh Quena Mart.</p>
        <form onSubmit={submit} className={styles.form}>
          <label>Nama lengkap *<input required maxLength={120} autoComplete="name" value={fullName} onChange={(event) => setFullName(event.target.value)} /></label>
          <label>Email / login *<input required maxLength={254} type="email" autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} /></label>
          <label>Hak akses *<select value={role} onChange={(event) => setRole(event.target.value as (typeof ACCOUNT_ROLES)[number])}>{ACCOUNT_ROLES.map((item) => <option key={item} value={item}>{item}</option>)}</select><small>{ACCOUNT_ROLE_DESCRIPTIONS[role]}</small></label>
          <div className={styles.formActions}><button type="button" className="button-secondary" disabled={busy} onClick={() => setOpen(false)}>Batal</button><button type="submit" className="button-primary" disabled={busy}>{busy ? "Mengirim undangan…" : "Kirim Undangan"}</button></div>
          {notice && <p className={notice.ok ? styles.success : styles.error} role={notice.ok ? "status" : "alert"}>{notice.text}</p>}
        </form>
      </section>
    </div>}
  </>;
}

function AccountEdit({ row, self }: { row: ManagedAccount; self: boolean }) {
  const [fullName, setFullName] = useState(row.full_name ?? "");
  const [role, setRole] = useState<(typeof ACCOUNT_ROLES)[number]>(row.role === "OWNER" ? "ADMIN" : row.role);
  const [active, setActive] = useState(row.is_active);
  const [notice, setNotice] = useState<{ ok: boolean; text: string } | null>(null);
  const [busy, startTransition] = useTransition();
  const router = useRouter();

  function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (self) return;
    if (row.is_active && !active && !window.confirm("Pengguna tidak dapat mengakses Quena Mart setelah akun dinonaktifkan. Riwayat transaksi dan aktivitas tetap tersimpan.")) return;
    startTransition(async () => {
      const result = await updateManagedAccount({ targetUserId: row.id, fullName, role, isActive: active });
      setNotice({ ok: result.ok, text: safeResult(result) });
      if (result.ok) router.refresh();
    });
  }

  if (self || row.role === "OWNER") return <span className={styles.protected}>Akun Owner dilindungi</span>;
  return <details className={styles.editDetails}><summary>Ubah</summary><form className={styles.editForm} onSubmit={submit}>
    <label>Nama lengkap<input required maxLength={120} value={fullName} onChange={(event) => setFullName(event.target.value)} /></label>
    <label>Hak akses<select value={role} onChange={(event) => setRole(event.target.value as (typeof ACCOUNT_ROLES)[number])}>{ACCOUNT_ROLES.map((item) => <option key={item} value={item}>{item}</option>)}</select><small>{ACCOUNT_ROLE_DESCRIPTIONS[role]}</small></label>
    <label className={styles.activeChoice}><input type="checkbox" checked={active} onChange={(event) => setActive(event.target.checked)} /> Akun aktif</label>
    <button className="button-primary" disabled={busy}>{busy ? "Menyimpan…" : "Simpan Perubahan"}</button>
    {notice && <p className={notice.ok ? styles.success : styles.error} role={notice.ok ? "status" : "alert"}>{notice.text}</p>}
  </form></details>;
}

export function AccountManagementWorkspace(props: {
  rows: ManagedAccount[]; error: boolean; total: number; page: number; pageCount: number;
  search: string; roleFilter: string; statusFilter: string; currentUserId: string;
}) {
  const { rows, error, total, page, pageCount, search, roleFilter, statusFilter, currentUserId } = props;
  const activeCount = rows.filter((row) => row.is_active).length;
  const baseQuery = new URLSearchParams();
  if (search) baseQuery.set("q", search);
  if (roleFilter) baseQuery.set("role", roleFilter);
  if (statusFilter) baseQuery.set("status", statusFilter);
  const pageHref = (next: number) => {
    const query = new URLSearchParams(baseQuery);
    if (next > 1) query.set("halaman", String(next));
    const suffix = query.toString();
    return `/pengaturan/akun${suffix ? `?${suffix}` : ""}`;
  };

  return <>
    <section className={styles.stats}><div><span>Pengguna</span><strong>{total.toLocaleString("id-ID")}</strong></div><div><span>Aktif di halaman ini</span><strong>{activeCount.toLocaleString("id-ID")}</strong></div><p>Akun menggunakan identitas Supabase Auth yang sama untuk web/PWA dan aplikasi Android mendatang.</p></section>
    <form className={styles.filters} method="get">
      <label className={styles.search}>Cari pengguna<input name="q" type="search" defaultValue={search} placeholder="Nama atau email" /></label>
      <label>Role<select name="role" defaultValue={roleFilter}><option value="">Semua role</option>{["OWNER", ...ACCOUNT_ROLES].map((item) => <option key={item}>{item}</option>)}</select></label>
      <label>Status<select name="status" defaultValue={statusFilter}><option value="">Semua status</option><option value="ACTIVE">Aktif</option><option value="INACTIVE">Nonaktif</option></select></label>
      <button className="button-secondary">Terapkan</button>
    </form>
    {error ? <section className={`surface-card ${styles.state}`} role="alert"><strong>Daftar akun belum dapat dimuat.</strong><span>Periksa migration akses akun lalu muat ulang halaman.</span></section>
      : rows.length === 0 ? <section className={`surface-card ${styles.state}`}><strong>{total === 0 ? "Belum ada akun yang cocok." : "Tidak ada akun pada halaman ini."}</strong><span>Ubah pencarian atau filter untuk melihat pengguna.</span></section>
        : <>
          <div className={`surface-card ${styles.tableCard}`}><div className={styles.tableWrap}><table><thead><tr><th>Nama</th><th>Email / Login</th><th>Role</th><th>Status</th><th>Akses Terakhir</th><th>Aksi</th></tr></thead><tbody>{rows.map((row) => <tr key={row.id}>
            <td><strong>{row.full_name || "Nama belum tersedia"}</strong>{row.id === currentUserId && <small className={styles.me}>Anda</small>}</td><td>{row.email}</td><td><span className={`${styles.role} ${styles[`role${row.role}`]}`}>{roleLabels[row.role]}</span></td><td><span className={`${styles.status} ${row.is_active ? styles.active : styles.inactive}`}><i />{row.is_active ? "Aktif" : "Nonaktif"}</span></td><td>{accountDateTime(row.last_sign_in_at)}</td><td><AccountEdit row={row} self={row.id === currentUserId} /></td>
          </tr>)}</tbody></table></div>
          <div className={styles.mobileList}>{rows.map((row) => <article className={styles.mobileCard} key={row.id}><div className={styles.mobileName}><strong>{row.full_name || "Nama belum tersedia"}</strong><span className={`${styles.role} ${styles[`role${row.role}`]}`}>{roleLabels[row.role]}</span></div><span>{row.email}</span><div className={styles.mobileMeta}><span className={`${styles.status} ${row.is_active ? styles.active : styles.inactive}`}><i />{row.is_active ? "Aktif" : "Nonaktif"}</span><small>Akses terakhir · {accountDateTime(row.last_sign_in_at)}</small></div><AccountEdit row={row} self={row.id === currentUserId} /></article>)}</div>
          </div>
          <nav className={styles.pagination} aria-label="Halaman akun"><span>{total.toLocaleString("id-ID")} pengguna · Halaman {page} dari {pageCount}</span><div><a aria-disabled={page <= 1} href={pageHref(Math.max(1, page - 1))}>Sebelumnya</a><a aria-disabled={page >= pageCount} href={pageHref(Math.min(pageCount, page + 1))}>Berikutnya</a></div></nav>
        </>}
  </>;
}
