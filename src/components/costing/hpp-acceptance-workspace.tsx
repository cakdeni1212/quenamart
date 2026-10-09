"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useRef, useState, type FormEvent } from "react";
import {
  approveInitialHppAcceptance,
  prepareInitialHppAcceptance,
  resolveInitialHppAcceptanceException,
} from "@/app/actions/hpp-acceptance";
import type { HppAcceptanceRow, HppAcceptanceWorkspaceData, HppAcceptanceView } from "@/lib/costing/hpp-acceptance-read";
import { blockerLabels, formatCompactRupiah, formatRupiah, visibleHppActionError, warningLabel } from "@/lib/costing/hpp-acceptance-presentation";
import type { UserRole } from "@/lib/auth/roles";

const VIEW_LABEL: Record<HppAcceptanceView, string> = {
  EXCEPTIONS: "Perlu Ditinjau", CANDIDATES: "Siap", WARNINGS: "Peringatan",
};
const PAGE_TITLES: Record<HppAcceptanceView, string> = {
  EXCEPTIONS: "Produk yang perlu ditinjau", CANDIDATES: "Produk siap digunakan", WARNINGS: "Peringatan informasi",
};
type Disposition = "ACCEPT_CURRENT_HPP" | "OPENING_HPP_OVERRIDE" | "LEAVE_UNVALUED" | "AUTHORITATIVE_ZERO";
const fallbackRequestIds = new Map<string, string>();

function numberLabel(value: string | number | null) {
  if (value === null || !Number.isFinite(Number(value))) return "—";
  return new Intl.NumberFormat("id-ID").format(Number(value));
}
function requestId(key: string) {
  try {
    const existing = window.sessionStorage.getItem(key);
    if (existing) return existing;
    const fallback = fallbackRequestIds.get(key);
    if (fallback) return fallback;
    const created = crypto.randomUUID();
    window.sessionStorage.setItem(key, created);
    return created;
  } catch {
    const existing = fallbackRequestIds.get(key);
    if (existing) return existing;
    const created = crypto.randomUUID();
    fallbackRequestIds.set(key, created);
    return created;
  }
}
function clearRequestId(key: string) {
  fallbackRequestIds.delete(key);
  try { window.sessionStorage.removeItem(key); } catch { /* storage is optional */ }
}

function StatusBadge({ status, unresolved }: { status: string | null; unresolved: number }) {
  if (status === "APPROVED" || status === "CONSUMED") return <span className="hpp-status hpp-status-approved">Sudah disetujui</span>;
  if (status === "INVALIDATED") return <span className="hpp-status hpp-status-stale">Perlu diperbarui</span>;
  if (status === "PREPARED" && unresolved === 0) return <span className="hpp-status hpp-status-ready">Siap disetujui</span>;
  if (status === "PREPARED") return <span className="hpp-status hpp-status-prepared">Sedang disiapkan</span>;
  return <span className="hpp-status hpp-status-idle">Belum disiapkan</span>;
}

function HppTableRow({ row, view, canResolve, onReview }: {
  row: HppAcceptanceRow; view: HppAcceptanceView; canResolve: boolean; onReview: (row: HppAcceptanceRow) => void;
}) {
  const blockers = blockerLabels(row);
  const warnings = row.warnings.map(warningLabel);
  const status = view === "WARNINGS" ? "Informasi" : row.resolved ? "Selesai" : "Perlu ditinjau";
  const product = <><strong className="hpp-product-name">{row.name}</strong><span className="hpp-sku">{row.sku}</span></>;
  if (view === "CANDIDATES") return <tr>
    <td>{product}</td><td className="hpp-number">{numberLabel(row.stock)}</td>
    <td className="hpp-number">{formatRupiah(row.currentHpp)}</td><td className="hpp-number">{formatRupiah(row.sellingPrice)}</td>
    <td><span className="hpp-status hpp-status-ready">Siap</span></td>
  </tr>;
  return <tr>
      <td>{product}</td>
      <td className="hpp-number">{numberLabel(row.stock)}</td>
      <td className="hpp-number">{formatRupiah(row.currentHpp)}</td>
      <td className="hpp-number">{formatRupiah(row.sellingPrice)}</td>
      <td>{view === "EXCEPTIONS" ? <div className="hpp-reasons">{blockers.map((label) => <span key={label}>{label}</span>)}</div>
        : view === "WARNINGS" ? <div className="hpp-reasons hpp-warning-tags">{warnings.map((label) => <span key={label}>{label}</span>)}</div>
          : <span className="hpp-status hpp-status-ready">Siap</span>}</td>
      <td><span className={`hpp-status ${view === "WARNINGS" ? "hpp-status-idle" : row.resolved ? "hpp-status-ready" : "hpp-status-prepared"}`}>{status}</span></td>
      <td>{view === "EXCEPTIONS" && canResolve && <button className="hpp-secondary-button" type="button" onClick={() => onReview(row)}>{row.resolved ? "Lihat / Ubah" : "Tinjau"}</button>}</td>
  </tr>;
}

function HppMobileCard({ row, view, canResolve, onReview }: {
  row: HppAcceptanceRow; view: HppAcceptanceView; canResolve: boolean; onReview: (row: HppAcceptanceRow) => void;
}) {
  const blockers = blockerLabels(row);
  const warnings = row.warnings.map(warningLabel);
  const status = view === "CANDIDATES" ? "Siap" : view === "WARNINGS" ? "Informasi" : row.resolved ? "Selesai" : "Perlu ditinjau";
  return <li className="hpp-mobile-card">
      <div className="hpp-mobile-card-head"><div><strong>{row.name}</strong><span>{row.sku}</span></div><span className={`hpp-status ${view === "WARNINGS" ? "hpp-status-idle" : row.resolved || view === "CANDIDATES" ? "hpp-status-ready" : "hpp-status-prepared"}`}>{status}</span></div>
      <div className="hpp-mobile-grid"><div><span>Stok saat ini</span><strong>{numberLabel(row.stock)}</strong></div><div><span>{row.preparedEvidence ? "HPP saat persiapan" : "HPP saat ini"}</span><strong>{formatRupiah(row.currentHpp)}</strong></div><div><span>{row.preparedEvidence ? "Harga jual saat persiapan" : "Harga jual"}</span><strong>{formatRupiah(row.sellingPrice)}</strong></div></div>
      {view === "EXCEPTIONS" && blockers.length > 0 && <div className="hpp-reasons">{blockers.map((label) => <span key={label}>{label}</span>)}</div>}
      {view === "WARNINGS" && warnings.length > 0 && <div className="hpp-reasons hpp-warning-tags">{warnings.map((label) => <span key={label}>{label}</span>)}</div>}
      {view === "EXCEPTIONS" && canResolve && <button className="hpp-secondary-button hpp-mobile-action" type="button" onClick={() => onReview(row)}>{row.resolved ? "Lihat / Ubah keputusan" : "Tinjau"}</button>}
  </li>;
}

function ResolutionDialog({ row, batchId, onClose, onSaved }: {
  row: HppAcceptanceRow | null; batchId: string; onClose: () => void; onSaved: (message: string) => void;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [disposition, setDisposition] = useState<Disposition>(row?.resolved ? row.disposition as Disposition : "ACCEPT_CURRENT_HPP");
  const [openingHpp, setOpeningHpp] = useState(row?.disposition === "OPENING_HPP_OVERRIDE" ? String(row.acceptedHpp ?? "") : "");
  const [reason, setReason] = useState(row?.reason ?? "");
  const [message, setMessage] = useState("");
  const [pending, setPending] = useState(false);
  useEffect(() => {
    if (row && dialog.current && !dialog.current.open) dialog.current.showModal();
    if (!row && dialog.current?.open) dialog.current.close();
  }, [row]);
  if (!row) return <dialog ref={dialog} className="hpp-dialog" onClose={onClose} />;
  const labels = blockerLabels(row);
  const currentHppText = row.currentHpp === null ? null : String(row.currentHpp);
  const canAcceptCurrent = currentHppText !== null && /^\d+(?:\.\d+)?$/.test(currentHppText) && /[1-9]/.test(currentHppText);
  const isZeroHpp = currentHppText !== null && /^0+(?:\.0+)?$/.test(currentHppText);
  const productId = row.productId;
  const requestKey = `hpp-awal:resolve:${batchId}:${row.productId}:${disposition}:${openingHpp}:${reason.trim()}`;
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!reason.trim()) { setMessage("Isi alasan keputusan terlebih dahulu."); return; }
    setPending(true);
    try {
      const result = await resolveInitialHppAcceptanceException({
        batchId, productId, disposition,
        openingHpp: disposition === "OPENING_HPP_OVERRIDE" ? openingHpp : null,
        reason, requestId: requestId(requestKey),
      });
      if (result.ok) {
        clearRequestId(requestKey);
        onSaved("Keputusan HPP berhasil disimpan.");
      } else {
        setMessage(result.message);
      }
    } catch {
      setMessage("Keputusan belum dapat dipastikan. Coba lagi dengan tombol yang sama.");
    } finally {
      setPending(false);
    }
  }
  return <dialog ref={dialog} className="hpp-dialog" onClose={onClose} onClick={(event) => { if (event.target === dialog.current) dialog.current?.close(); }}>
    <form onSubmit={submit}>
      <div className="hpp-dialog-head"><div><span className="hpp-eyebrow">TINJAU PRODUK</span><h2>{row.name}</h2><p>{row.sku}</p></div><button type="button" className="hpp-close" aria-label="Tutup" onClick={() => dialog.current?.close()}>×</button></div>
      <div className="hpp-detail-values"><div><span>Stok saat ini</span><strong>{numberLabel(row.stock)}</strong></div><div><span>{row.preparedEvidence ? "HPP saat persiapan" : "HPP saat ini"}</span><strong>{formatRupiah(row.currentHpp)}</strong></div><div><span>{row.preparedEvidence ? "Harga jual saat persiapan" : "Harga jual"}</span><strong>{formatRupiah(row.sellingPrice)}</strong></div></div>
      <div className="hpp-explanation"><strong>{labels[0] ?? "HPP perlu ditinjau"}</strong>{labels.length > 1 && <p>{labels.slice(1).join(" · ")}</p>}</div>
      {row.warnings.length > 0 && <p className="hpp-dialog-warning">Informasi: {row.warnings.map(warningLabel).join(" · ")}. Peringatan ini tidak menghalangi keputusan.</p>}
      <fieldset className="hpp-options"><legend>Pilih keputusan</legend>
        {canAcceptCurrent && <label><input type="radio" name="disposition" checked={disposition === "ACCEPT_CURRENT_HPP"} onChange={() => setDisposition("ACCEPT_CURRENT_HPP")} /><span><strong>Gunakan HPP saat ini</strong><small>HPP saat ini memang benar dan akan digunakan sebagai nilai awal.</small></span></label>}
        <label><input type="radio" name="disposition" checked={disposition === "OPENING_HPP_OVERRIDE"} onChange={() => setDisposition("OPENING_HPP_OVERRIDE")} /><span><strong>Masukkan HPP awal</strong><small>Nilai ini hanya digunakan sebagai HPP awal sistem baru dan tidak mengubah riwayat HPP iPos.</small></span></label>
        {disposition === "OPENING_HPP_OVERRIDE" && <label className="hpp-override-field">HPP awal<input inputMode="decimal" autoComplete="off" value={openingHpp} onChange={(event) => setOpeningHpp(event.target.value)} placeholder="Contoh: 3500.50" aria-label="HPP awal" /></label>}
        <label><input type="radio" name="disposition" checked={disposition === "LEAVE_UNVALUED"} onChange={() => setDisposition("LEAVE_UNVALUED")} /><span><strong>Biarkan belum dinilai</strong><small>Produk tetap memiliki stok, tetapi nilai modal awal belum ditentukan.</small></span></label>
        {isZeroHpp && <label><input type="radio" name="disposition" checked={disposition === "AUTHORITATIVE_ZERO"} onChange={() => setDisposition("AUTHORITATIVE_ZERO")} /><span><strong>HPP memang Rp0</strong><small>Gunakan Rp0 sebagai nilai awal karena memang benar.</small></span></label>}
      </fieldset>
      <label className="hpp-reason-field">Alasan keputusan<textarea required minLength={1} maxLength={500} value={reason} onChange={(event) => setReason(event.target.value)} placeholder="Contoh: harga beli dari supplier terakhir memang Rp3.500." /></label>
      {message && <p className="hpp-inline-message" role="alert">{message}</p>}
      <div className="hpp-dialog-actions"><button type="button" className="hpp-secondary-button" onClick={() => dialog.current?.close()}>Batal</button><button type="submit" className="hpp-primary-button" disabled={pending}>{pending ? "Menyimpan…" : "Simpan Keputusan"}</button></div>
    </form>
  </dialog>;
}

export function HppAcceptanceWorkspace({ data, role }: {
  data: HppAcceptanceWorkspaceData; role: UserRole;
}) {
  const routeKey = `${data.view}:${data.page}:${data.search}`;
  return <HppAcceptanceWorkspaceRoute key={routeKey} data={data} role={role} />;
}

function HppAcceptanceWorkspaceRoute({ data, role }: {
  data: HppAcceptanceWorkspaceData; role: UserRole;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const routeKey = `${data.view}:${data.page}:${data.search}`;
  const [search, setSearch] = useState(data.search);
  const [selected, setSelected] = useState<HppAcceptanceRow | null>(null);
  const [feedback, setFeedback] = useState("");
  const [actionError, setActionError] = useState<{ message: string; routeKey: string } | null>(null);
  const [pending, setPending] = useState(false);
  const [approvalOpen, setApprovalOpen] = useState(false);
  const approvalDialog = useRef<HTMLDialogElement>(null);
  const manager = role === "OWNER" || role === "ADMIN";
  const owner = role === "OWNER";
  const batch = data.batch;
  const error = visibleHppActionError(actionError, routeKey);
  const summary = data.summary;
  const prepared = batch?.status === "PREPARED";
  const approved = batch?.status === "APPROVED" || batch?.status === "CONSUMED";
  const stale = batch?.status === "INVALIDATED";
  const canResolve = manager && prepared;

  useEffect(() => {
    if (!approvalOpen && approvalDialog.current?.open) approvalDialog.current.close();
    if (approvalOpen && approvalDialog.current && !approvalDialog.current.open) approvalDialog.current.showModal();
  }, [approvalOpen]);
  useEffect(() => {
    if (search === data.search) return;
    const timer = window.setTimeout(() => {
      const params = new URLSearchParams();
      params.set("view", data.view);
      if (search.trim()) params.set("q", search.trim());
      router.replace(`${pathname}?${params.toString()}`, { scroll: false });
    }, 350);
    return () => window.clearTimeout(timer);
  }, [data.search, data.view, pathname, router, search]);

  const prepareKey = `hpp-awal:prepare:${data.outletId ?? "none"}`;
  async function prepare() {
    if (!data.outletId) return;
    setPending(true); setActionError(null); setFeedback("");
    try {
      const result = await prepareInitialHppAcceptance(data.outletId, requestId(prepareKey));
      if (result.ok) { clearRequestId(prepareKey); setFeedback("Persiapan HPP awal berhasil dibuat."); router.refresh(); }
      else setActionError({ message: result.message, routeKey });
    } catch {
      setActionError({ message: "Persiapan belum dapat dipastikan. Coba lagi dengan tombol yang sama.", routeKey });
    } finally { setPending(false); }
  }
  const canApprove = owner && prepared && batch.unresolved === 0;
  const approvalKey = `hpp-awal:approve:${batch?.id ?? "none"}`;
  async function approve() {
    if (!batch || !owner) return;
    setPending(true); setActionError(null); setFeedback("");
    try {
      const result = await approveInitialHppAcceptance(batch.id, requestId(approvalKey));
      setApprovalOpen(false);
      if (result.ok) { clearRequestId(approvalKey); setFeedback("HPP Awal Sudah Disetujui."); router.refresh(); }
      else { setActionError({ message: result.message, routeKey }); router.refresh(); }
    } catch {
      setActionError({ message: "Persetujuan belum dapat dipastikan. Coba lagi dengan tombol yang sama.", routeKey });
      router.refresh();
    } finally { setPending(false); }
  }
  function navigateView(view: HppAcceptanceView) {
    const params = new URLSearchParams(); params.set("view", view); if (search.trim()) params.set("q", search.trim());
    return `?${params.toString()}`;
  }
  const pages = Math.max(1, Math.ceil(data.total / data.pageSize));
  const pageUrl = (page: number) => {
    const params = new URLSearchParams(); params.set("view", data.view); params.set("page", String(page));
    if (search.trim()) params.set("q", search.trim());
    return `?${params.toString()}`;
  };
  const summaryCards = summary ? [
    ["Produk dengan Stok", numberLabel(summary.positiveStock), "hpp-card-stock"],
    ["Siap Digunakan", numberLabel(summary.candidates), "hpp-card-ready"],
    ["Perlu Ditinjau", numberLabel(batch?.status === "PREPARED" ? batch.unresolved : batch?.status === "APPROVED" || batch?.status === "CONSUMED" ? 0 : summary.exceptions), (batch?.status === "PREPARED" ? batch.unresolved : summary.exceptions) > 0 ? "hpp-card-attention" : "hpp-card-ready"],
    ["Estimasi Modal Awal", formatCompactRupiah(batch?.approvedValue ?? summary.openingValue), "hpp-card-value"],
  ] as const : [];
  const approvedOpenValue = formatCompactRupiah(batch?.approvedValue ?? summary?.openingValue ?? null);

  return <main className="page-content hpp-page">
    <div className="eyebrow">COSTING PERSEDIAAN</div>
    <div className="page-heading hpp-heading"><div><h1>Persiapan HPP Awal</h1><p>Siapkan nilai modal awal persediaan sebelum sistem costing mulai digunakan.</p></div><StatusBadge status={batch?.status ?? null} unresolved={batch?.unresolved ?? 0} /></div>
    {feedback && <div className="hpp-notice hpp-notice-success" role="status">{feedback}</div>}
    {error && <div className="hpp-notice hpp-notice-error" role="alert">{error}</div>}
    {data.error && <div className="hpp-notice hpp-notice-error" role="alert">{data.error}</div>}
    {stale && <div className="hpp-notice hpp-notice-stale"><strong>Data HPP berubah</strong><span>Beberapa data HPP berubah setelah persiapan dibuat. Perbarui persiapan sebelum melanjutkan.</span><button type="button" className="hpp-primary-button" onClick={prepare} disabled={pending}>{pending ? "Memperbarui…" : "Perbarui Persiapan"}</button></div>}
    {approved && <div className="hpp-approved-banner"><span aria-hidden="true">✓</span><div><strong>HPP Awal Sudah Disetujui</strong><p>HPP awal sudah dikunci dan siap digunakan pada tahap aktivasi costing.</p></div></div>}
    {summary && <section className="hpp-summary-grid" aria-label="Ringkasan persiapan HPP">{summaryCards.map(([label, value, className]) => <article key={label} className={`hpp-summary-card ${className}`}><span>{label}</span><strong>{value}</strong></article>)}</section>}

    {!batch && summary && <section className="surface-card hpp-prepare-panel"><div><span className="hpp-eyebrow">LANGKAH PERSIAPAN</span><h2>Siapkan HPP awal</h2><p>Sistem akan menyimpan kondisi HPP saat ini agar produk yang perlu ditinjau dapat diselesaikan.</p><small>Persiapan ini belum mengubah stok.</small></div><button type="button" className="hpp-primary-button" onClick={prepare} disabled={pending || !data.outletId}>{pending ? "Menyiapkan…" : "Siapkan HPP Awal"}</button></section>}

    {batch?.status === "PREPARED" && <section className="hpp-progress-panel"><div><strong>{numberLabel(batch.exceptions)} perlu ditinjau</strong><span>{numberLabel(batch.exceptions - batch.unresolved)} selesai</span></div><div className="hpp-progress-track"><span style={{ width: `${batch.exceptions ? ((batch.exceptions - batch.unresolved) / batch.exceptions) * 100 : 100}%` }} /></div><small>Persiapan tersimpan untuk ditinjau.</small></section>}
    {approved && <section className="hpp-approved-summary"><span>Estimasi nilai yang disetujui</span><strong>{approvedOpenValue}</strong></section>}

    {summary && !data.error && <section className="hpp-list-section">
      <div className="hpp-list-heading"><div><span className="hpp-eyebrow">DAFTAR PRODUK</span><h2>{PAGE_TITLES[data.view]}</h2></div><label className="hpp-search"><span className="sr-only">Cari nama atau SKU</span><input type="search" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Cari nama atau SKU" /></label></div>
      <nav className="hpp-tabs" aria-label="Filter produk HPP">{(["EXCEPTIONS", "CANDIDATES", "WARNINGS"] as const).map((view) => {
        const count = view === "EXCEPTIONS" ? (batch ? batch.unresolved : summary.exceptions) : view === "CANDIDATES" ? summary.candidates : summary.warningProducts;
        return <Link key={view} href={navigateView(view)} className={data.view === view ? "hpp-tab hpp-tab-active" : "hpp-tab"} aria-current={data.view === view ? "page" : undefined}>{VIEW_LABEL[view]}<span>{numberLabel(count)}</span></Link>;
      })}</nav>
      {data.rows.length === 0 ? <div className="hpp-empty"><strong>{data.search ? "Produk tidak ditemukan" : data.view === "EXCEPTIONS" ? "Tidak ada produk yang perlu ditinjau" : data.view === "WARNINGS" ? "Tidak ada peringatan" : "Belum ada produk siap ditampilkan"}</strong><span>{data.search ? "Coba kata pencarian lain." : data.view === "EXCEPTIONS" ? "Semua produk stok aktif sudah memiliki keputusan." : "Data akan tampil saat tersedia."}</span></div> : <>
        <div className="hpp-table-wrap"><table className="hpp-table"><thead><tr><th>Produk</th><th>Stok Saat Ini</th><th>{batch ? "HPP saat persiapan" : "HPP Saat Ini"}</th><th>{batch ? "Harga jual saat persiapan" : "Harga Jual"}</th>{data.view === "CANDIDATES" ? <th>Status</th> : <><th>{data.view === "EXCEPTIONS" ? "Masalah" : "Peringatan"}</th><th>Status</th><th>Aksi</th></>}</tr></thead><tbody>{data.rows.map((row) => <HppTableRow key={row.productId} row={row} view={data.view} canResolve={canResolve && data.view === "EXCEPTIONS"} onReview={setSelected} />)}</tbody></table></div>
        <ul className="hpp-mobile-list">{data.rows.map((row) => <HppMobileCard key={`${row.productId}-mobile`} row={row} view={data.view} canResolve={canResolve && data.view === "EXCEPTIONS"} onReview={setSelected} />)}</ul>
        <div className="hpp-pagination"><span>{numberLabel(data.total)} produk · Halaman {data.page} dari {pages}</span><div>{data.page > 1 && <Link href={pageUrl(data.page - 1)}>← Sebelumnya</Link>}{data.page < pages && <Link href={pageUrl(data.page + 1)}>Berikutnya →</Link>}</div></div>
      </>}
    </section>}

    {canApprove && <section className="hpp-approval-bar"><div><strong>Semua keputusan sudah lengkap</strong><span>Persetujuan akan mengunci HPP awal, tanpa mengubah stok.</span></div><button type="button" className="hpp-primary-button" onClick={() => setApprovalOpen(true)}>Setujui HPP Awal</button></section>}
    {batch?.status === "PREPARED" && owner && batch.unresolved > 0 && <p className="hpp-owner-note">Selesaikan {numberLabel(batch.unresolved)} keputusan sebelum persetujuan akhir.</p>}
    {batch?.status === "PREPARED" && !owner && <p className="hpp-owner-note">Persetujuan akhir dilakukan oleh Owner setelah seluruh keputusan selesai.</p>}

    <ResolutionDialog key={selected?.productId ?? "closed"} row={selected} batchId={batch?.id ?? ""} onClose={() => setSelected(null)} onSaved={(message) => { setSelected(null); setFeedback(message); router.refresh(); }} />
    <dialog ref={approvalDialog} className="hpp-dialog hpp-confirm-dialog" onClose={() => setApprovalOpen(false)}>
      <span className="hpp-eyebrow">PERSETUJUAN AKHIR</span><h2>Setujui HPP awal?</h2><p>Keputusan ini mengunci HPP awal yang sudah disiapkan. Proses ini belum menjalankan WAC dan tidak mengubah stok.</p>
      <div className="hpp-dialog-actions"><button type="button" className="hpp-secondary-button" onClick={() => setApprovalOpen(false)}>Batal</button><button type="button" className="hpp-primary-button" disabled={pending} onClick={approve}>{pending ? "Menyetujui…" : "Setujui HPP Awal"}</button></div>
    </dialog>
  </main>;
}
