"use client";

import Link from "next/link";
import { useActionState, useEffect, useState } from "react";
import { usePathname, useRouter } from "next/navigation";
import { saveSupplier, type ActionState } from "@/lib/purchasing/actions";
import { formatRupiah } from "@/lib/money";
import type { SupplierWorkspaceRow } from "@/lib/purchasing/supplier-workspace-read";
import primaryAction from "@/components/ui/workspace-primary-action.module.css";
import styles from "./supplier-workspace.module.css";

function shortDate(value: string | null | undefined) {
  if (!value) return "—";
  return new Intl.DateTimeFormat("id-ID", { day: "numeric", month: "short", year: "numeric", timeZone: "Asia/Jakarta" }).format(new Date(value));
}

export function SupplierForm({ supplier }: { supplier?: SupplierWorkspaceRow & { notes?: string | null } }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(saveSupplier, { error: null });
  return <form action={action} className={styles.form} onSubmit={(event) => {
    if (!supplier?.is_active || new FormData(event.currentTarget).getAll("is_active").includes("true")) return;
    if (!window.confirm("Supplier ini tidak lagi dapat dipilih untuk dokumen baru. Riwayat barang masuk, nota, pembayaran, retur, dan costing tetap tersimpan. Nonaktifkan supplier?")) event.preventDefault();
  }}>
    {supplier && <input type="hidden" name="supplier_id" value={supplier.id} />}
    <label>Nama Supplier *<input name="display_name" required maxLength={160} defaultValue={supplier?.display_name ?? ""} /></label>
    <label>Kontak<input name="contact_name" maxLength={120} defaultValue={supplier?.contact_name ?? ""} /></label>
    <label>Nomor HP / WhatsApp<input name="phone" maxLength={40} defaultValue={supplier?.phone ?? ""} /></label>
    <label className={styles.wide}>Alamat<input name="address" maxLength={500} defaultValue={supplier?.address ?? ""} /></label>
    <label className={styles.wide}>Catatan<textarea name="notes" maxLength={1000} rows={3} defaultValue={supplier?.notes ?? ""} /></label>
    {supplier && <label className={styles.toggle}><input type="hidden" name="is_active" value="false"/><input type="checkbox" name="is_active" value="true" defaultChecked={supplier.is_active}/> Supplier aktif<span>Supplier nonaktif tidak dapat dipilih untuk dokumen baru; riwayat tetap tersimpan.</span></label>}
    {state.error && <p className={styles.error} role="alert">{state.error}</p>}
    {state.success && <p className={styles.success} role="status">{state.success}</p>}
    <button className={primaryAction.primary} disabled={pending}>{pending ? "Menyimpan…" : supplier ? "Simpan Perubahan" : "Simpan Supplier"}</button>
  </form>;
}

export function SupplierWorkspace({ data, search, status, tempo, canManage, canSeeFinance }: {
  data: { rows: SupplierWorkspaceRow[]; total: number; page: number; pages: number; summary: { activeSuppliers: number; tempoCount: number; outstanding: string; nearestDue: string | null } | null; error: string | null };
  search: string; status: string; tempo: string; canManage: boolean; canSeeFinance: boolean;
}) {
  const [showCreate, setShowCreate] = useState(false);
  const [queryText, setQueryText] = useState(search);
  const router = useRouter();
  const pathname = usePathname();
  const query = new URLSearchParams();
  if (search) query.set("q", search); if (status) query.set("status", status); if (tempo) query.set("tempo", tempo);
  const pageLink = (next: number) => { const q = new URLSearchParams(query); q.set("page", String(next)); return `/pembelian/supplier?${q}`; };
  useEffect(() => {
    if (queryText === search) return;
    const timer = window.setTimeout(() => {
      const next = new URLSearchParams();
      if (queryText.trim()) next.set("q", queryText.trim());
      if (status) next.set("status", status);
      if (tempo) next.set("tempo", tempo);
      router.replace(`${pathname}${next.size ? `?${next}` : ""}`, { scroll: false });
    }, 350);
    return () => window.clearTimeout(timer);
  }, [pathname, queryText, router, search, status, tempo]);
  return <div className={styles.page}>
    <header className={styles.heading}><div><span className="eyebrow">PEMBELIAN</span><h1>Supplier</h1><p>Kelola pemasok dan lihat aktivitas pembelian Quena Mart.</p></div>{canManage && <button className={primaryAction.primary} onClick={() => setShowCreate((v) => !v)}>+ Tambah Supplier</button>}</header>
    {showCreate && <section className={`surface-card ${styles.formCard}`}><div className={styles.sectionTitle}><div><h2>Supplier baru</h2><p>Periksa nama supplier serupa sebelum menyimpan. Data tidak pernah digabung otomatis.</p></div><button type="button" className={primaryAction.secondary} onClick={() => setShowCreate(false)}>Tutup</button></div><SupplierForm /></section>}
    {canSeeFinance && data.summary && <section className={styles.summary} aria-label="Ringkasan supplier">
      <article className="surface-card"><span>Supplier Aktif</span><strong>{data.summary.activeSuppliers}</strong></article>
      <article className="surface-card"><span>Tempo Berjalan</span><strong>{data.summary.tempoCount} nota</strong></article>
      <article className="surface-card"><span>Total Outstanding</span><strong>{formatRupiah(data.summary.outstanding)}</strong></article>
      <article className="surface-card"><span>Jatuh Tempo Terdekat</span><strong>{shortDate(data.summary.nearestDue)}</strong></article>
    </section>}
    <form method="get" className={`surface-card ${styles.filters}`}>
      <label className={styles.search}>Cari Supplier<input name="q" value={queryText} onChange={(event) => setQueryText(event.target.value)} placeholder="Nama, kode, kontak, atau telepon" /></label>
      {canManage && <><label>Status<select name="status" defaultValue={status}><option value="">Semua</option><option value="ACTIVE">Aktif</option><option value="INACTIVE">Nonaktif</option></select></label>
        <label>Tempo<select name="tempo" defaultValue={tempo}><option value="">Semua</option><option value="HAS_TEMPO">Ada Tempo</option><option value="NO_TEMPO">Tidak Ada Tempo</option></select></label></>}
      <button className={primaryAction.secondary} type="submit">Terapkan</button><Link className={primaryAction.ghost} href="/pembelian/supplier" onClick={() => setQueryText("")}>Reset</Link>
    </form>
    {data.error ? <section className={`surface-card ${styles.errorBox}`} role="alert">{data.error}</section> : data.rows.length === 0 ? <section className={`surface-card ${styles.empty}`}><strong>{search || status || tempo ? "Supplier tidak ditemukan." : "Belum ada supplier."}</strong>{canManage && <p>Tambahkan supplier agar dapat dipilih saat membuat Barang Masuk.</p>}{!canManage && <p>Supplier aktif akan muncul saat pencatatan barang masuk.</p>}</section> : <section className={`surface-card ${styles.list}`}>
      <div className={styles.listHeading}><div><h2>Daftar Supplier</h2><p>{data.total} supplier · halaman {data.page} dari {Math.max(data.pages,1)}</p></div></div>
      <div className={styles.tableWrap}><table><thead><tr><th>Supplier</th><th>Kontak</th><th>Telepon / WhatsApp</th><th>Pembelian Terakhir</th>{canSeeFinance && <><th>Tempo</th><th>Outstanding</th></>}<th>Status</th><th>Aksi</th></tr></thead><tbody>{data.rows.map((s) => <tr key={s.id}>
        <td><Link className={styles.supplierName} href={canManage ? `/pembelian/supplier/${s.id}` : "/pembelian/barang-masuk/baru"}>{s.display_name}<small>{s.supplier_code}</small></Link></td><td>{s.contact_name || "—"}</td><td>{s.phone || "—"}</td><td>{shortDate(s.last_purchase)}</td>
        {canSeeFinance && <><td>{s.open_count ? `${s.open_count} nota` : "Tidak ada tempo"}</td><td>{formatRupiah(s.outstanding)}</td></>}
        <td><span className={`${styles.badge} ${s.is_active ? styles.active : styles.inactive}`}>{s.is_active ? "Aktif" : "Nonaktif"}</span></td><td>{canManage ? <Link className={styles.detailLink} href={`/pembelian/supplier/${s.id}`}>Lihat Detail</Link> : <Link className={styles.detailLink} href="/pembelian/barang-masuk/baru">Pilih</Link>}</td>
      </tr>)}</tbody></table></div>
      <ul className={styles.mobileList}>{data.rows.map((s) => <li key={s.id}><Link href={canManage ? `/pembelian/supplier/${s.id}` : "/pembelian/barang-masuk/baru"}><div><strong>{s.display_name}</strong><small>{s.phone || s.supplier_code} · {shortDate(s.last_purchase)}</small></div><div className={styles.mobileBottom}>{canSeeFinance && <b>{formatRupiah(s.outstanding)}</b>}<span className={`${styles.badge} ${s.is_active ? styles.active : styles.inactive}`}>{s.is_active ? "Aktif" : "Nonaktif"}</span></div></Link></li>)}</ul>
      {data.pages > 1 && <nav className={styles.pagination} aria-label="Halaman supplier"><Link aria-disabled={data.page<=1} href={pageLink(data.page-1)}>Sebelumnya</Link><span>Halaman {data.page} / {data.pages}</span><Link aria-disabled={data.page>=data.pages} href={pageLink(data.page+1)}>Berikutnya</Link></nav>}
    </section>}
  </div>;
}
