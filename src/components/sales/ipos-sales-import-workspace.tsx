"use client";

import Link from "next/link";
import { useState, useTransition, type FormEvent, type ReactNode } from "react";
import { commitIposSales, recheckIposSales, uploadIposSales } from "@/app/actions/ipos-sales-import";
import { formatRupiah } from "@/lib/money";
import { formatIposSalesRevenue } from "@/lib/ipos-sales/presentation";
import buttons from "@/components/ui/workspace-primary-action.module.css";
import styles from "@/components/sales/ipos-sales-import.module.css";

type Dict = Record<string, unknown>;
type BatchView = { batch: Dict; transactions: Dict[] };
type RecentRow = { id: string; reportFrom: string; reportTo: string; filename: string; transactions: number; lines: number; amount: string; status: string };
const record = (value: unknown): Dict => value && typeof value === "object" && !Array.isArray(value) ? value as Dict : {};
const text = (value: unknown, fallback = "") => typeof value === "string" ? value : fallback;
const num = (value: unknown) => Number(value ?? 0);
const formatNumber = (value: unknown, digits = 3) => num(value).toLocaleString("id-ID", { maximumFractionDigits: digits });
const dateLabel = (value: string) => {
  if (!value) return "—";
  const date = /^\d{4}-\d{2}-\d{2}$/.test(value) ? new Date(`${value}T12:00:00+07:00`) : new Date(value);
  return new Intl.DateTimeFormat("id-ID", { dateStyle: "long", ...(value.includes("T") ? { timeStyle: "short" as const } : {}), timeZone: "Asia/Jakarta" }).format(date);
};
const statusText = (status: string) => ({ READY: "Siap diimport", COMMITTED: "Sudah diimport", UPLOADED: "Perlu diperiksa", PREFLIGHT_BLOCKED: "Perlu diperiksa", CANCELLED: "Dibatalkan" }[status] ?? "Perlu diperiksa");

function unwrap(value: unknown): BatchView | null {
  const root = record(value);
  if (!root.batch || typeof root.batch !== "object") return null;
  return { batch: record(root.batch), transactions: Array.isArray(root.transactions) ? root.transactions.map(record) : [] };
}

export function IposSalesImportWorkspace({ initialBatch, recent }: { initialBatch: unknown; recent: RecentRow[] }) {
  const [batchView, setBatchView] = useState<BatchView | null>(() => unwrap(initialBatch));
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [filename, setFilename] = useState("");
  const [duplicateFile, setDuplicateFile] = useState(() => text(unwrap(initialBatch)?.batch.status) === "COMMITTED");
  const [confirm, setConfirm] = useState(false);
  const [busy, startTransition] = useTransition();

  const batch = batchView?.batch;
  const batchId = text(batch?.id);
  const status = text(batch?.status);
  const preflight = record(batch?.preflight_result);
  const reconciliation = record(batch?.reconciliation);
  const transactions = batchView?.transactions ?? [];
  const lineRows: Dict[] = transactions.flatMap((transaction) => (Array.isArray(transaction.lines) ? transaction.lines : []).map((line): Dict => ({ ...record(line), sourceTransactionNumber: transaction.sourceTransactionNumber, sourceOccurredAt: transaction.sourceOccurredAt, transactionTotal: transaction.total })));
  const uniqueSkuCount = num(batch?.unique_sku_count);
  const isReady = status === "READY" && preflight.ready === true && reconciliation.isReconciled === true;
  const isCommitted = status === "COMMITTED";
  const missing = lineRows.filter((line) => line.resolution === "MISSING");
  const invalid = lineRows.filter((line) => line.resolution === "INVALID");
  const unresolvedProducts = [...missing, ...invalid].reduce((groups, line) => {
    const sku = text(line.sku);
    const current = groups.get(sku) ?? { sku, name: text(line.name), quantity: 0, rows: 0 };
    current.quantity += num(line.quantity); current.rows += 1; groups.set(sku, current);
    return groups;
  }, new Map<string, { sku: string; name: string; quantity: number; rows: number }>());
  const duplicateTransactions = transactions.filter((transaction) => transaction.duplicate === true);
  const stockBlockers = num(preflight.stockBlockerCount);
  const opnameConflicts = num(preflight.postedOpnameConflictCount);
  const receiptConflicts = num(preflight.receiptChronologyConflictCount);
  const costingBlockers = num(preflight.costingBlockerCount);
  const reconciliationOk = reconciliation.isReconciled === true;

  function onUpload(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setError(null); setNotice(null);
    const formData = new FormData(event.currentTarget);
    const selected = formData.get("file");
    if (selected instanceof File) setFilename(selected.name);
    startTransition(async () => {
      const result = await uploadIposSales(formData);
      if (result.error) { setError(result.error); return; }
      setBatchView(unwrap(result.batch));
      setFilename("");
      setDuplicateFile(Boolean(result.duplicateFile));
      setNotice(result.duplicateFile ? "Laporan ini sudah pernah diperiksa. Ringkasan laporan yang tersimpan ditampilkan." : "File berhasil diperiksa.");
    });
  }

  function recheck() {
    if (!batchId) return;
    setError(null); setNotice(null);
    startTransition(async () => {
      const result = await recheckIposSales(batchId);
      if (result.error) { setError(result.error); return; }
      setBatchView(unwrap(result.batch)); setNotice("Pemeriksaan diperbarui.");
    });
  }

  function commit() {
    if (!batchId) return;
    setError(null); setConfirm(false);
    startTransition(async () => {
      const result = await commitIposSales(batchId, num(batch?.revision));
      if (result.error) { setError(result.error); return; }
      setBatchView(unwrap(result.batch) ?? (batch ? { batch: { ...batch, status: "COMMITTED" }, transactions } : null)); setNotice(null);
    });
  }

  const clear = () => { setBatchView(null); setError(null); setNotice(null); setFilename(""); setConfirm(false); setDuplicateFile(false); };

  return <div className={styles.page}>
    <header className={styles.heading}><div><div className="eyebrow">TRANSAKSI</div><h1>Import Penjualan iPos</h1><p>Upload laporan penjualan iPos untuk memperbarui transaksi dan stok Quena Mart.</p><div className={styles.note}>Gunakan laporan Penjualan Detail dari iPos setelah kasir selesai.</div></div></header>

    {!batchView && <form className={`${styles.card} ${styles.upload}`} onSubmit={onUpload}>
      <div className={styles.cardTitle}><h2>Upload Laporan Penjualan</h2><p>File Excel .xls atau .xlsx · maksimal 25 MB. File akan diperiksa sebelum diimport.</p></div>
      <div className={styles.uploadRow}><label className={styles.fileLabel} htmlFor="ipos-sales-file">Pilih File</label><input className={styles.fileInput} id="ipos-sales-file" name="file" type="file" accept=".xls,.xlsx,application/vnd.ms-excel,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" required onChange={(event) => setFilename(event.currentTarget.files?.[0]?.name ?? "")} /><span className={styles.filename} title={filename}>{filename || "Belum ada file dipilih"}</span><button type="submit" className={buttons.primary} disabled={busy || !filename}>{busy ? "Memeriksa…" : "Periksa File"}</button></div>
    </form>}

    {error && <div className={styles.error} role="alert">{error}{batchId && error.includes("Cek Ulang") && <div className={styles.actions} style={{ marginTop: 9 }}><button type="button" className={buttons.secondary} onClick={recheck} disabled={busy}>Cek Ulang</button></div>}</div>}
    {notice && <div className={styles.successNotice} role="status">{notice}</div>}

    {batchView && batch && isCommitted ? <section className={`${styles.card} ${styles.success}`}>
      <span className={styles.successMark} aria-hidden="true">✓</span><h2>{duplicateFile ? "Laporan ini sudah pernah diimport" : "Penjualan berhasil diimport"}</h2>
      <div className={styles.successDetails}><span>{dateLabel(text(batch.report_from))}</span><span>{num(batch.transaction_count).toLocaleString("id-ID")} transaksi</span><span>{formatNumber(batch.total_quantity)} item</span><strong>{formatIposSalesRevenue(batch.total_amount)}</strong></div>
      <p>{duplicateFile ? "Laporan ini sudah tercatat sebelumnya." : "Transaksi dan stok Quena Mart sudah diperbarui."} Data metode pembayaran dan laba transaksi iPos tidak tersedia dari laporan ini.</p>
      <div className={styles.actions}><Link className={buttons.primary} href="/transaksi">Lihat Riwayat Transaksi</Link><button type="button" className={buttons.secondary} onClick={clear}>Upload Laporan Lain</button></div>
    </section> : batchView && batch && <>
      <section className={styles.card}>
        <div className={styles.summaryHead}><div className={styles.cardTitle}><h2>Ringkasan Laporan</h2><p title={text(batch.original_filename)}>{text(batch.original_filename)}</p></div><span className={`${styles.status}${isReady ? ` ${styles.ready}` : ""}`}>{statusText(status)}</span></div>
        <div className={styles.summary}>
          <Metric label="Tanggal Penjualan" value={text(batch.report_from) === text(batch.report_to) ? dateLabel(text(batch.report_from)) : `${dateLabel(text(batch.report_from))} – ${dateLabel(text(batch.report_to))}`} />
          <Metric label="Transaksi" value={num(batch.transaction_count).toLocaleString("id-ID")} />
          <Metric label="Baris Penjualan" value={num(batch.sale_line_count).toLocaleString("id-ID")} />
          <Metric label="Jumlah Item" value={formatNumber(batch.total_quantity)} />
          <Metric label="Omzet" value={formatIposSalesRevenue(batch.total_amount)} money />
          <Metric label="SKU Ditemukan" value={uniqueSkuCount.toLocaleString("id-ID")} />
        </div>
        <div className={`${styles.reconciliation}${reconciliationOk ? "" : ` ${styles.reconciliationBlocked}`}`} role="status"><span aria-hidden="true">{reconciliationOk ? "✓" : "!"}</span><span>Rekonsiliasi Laporan · {reconciliationOk ? "Sesuai" : "Perlu diperiksa"}</span></div>
        {!reconciliationOk && <p className={styles.cardTitle}><span>Total laporan tidak sesuai. Penjualan belum dapat diimport.</span></p>}
      </section>

      {(missing.length > 0 || invalid.length > 0 || duplicateTransactions.length > 0 || stockBlockers > 0 || opnameConflicts > 0 || receiptConflicts > 0 || costingBlockers > 0 || !reconciliationOk) && <section className={styles.issues} aria-label="Hal yang perlu diselesaikan">
        <div className={styles.cardTitle}><h2>Perlu Diselesaikan</h2><p>Selesaikan hal berikut sebelum penjualan dapat diimport.</p></div>
        {(missing.length > 0 || invalid.length > 0) && <article className={styles.issue}><h3>{missing.length ? "SKU belum terdaftar" : "SKU perlu diperiksa"} · {num(preflight.missingSkuCount) + num(preflight.ambiguousSkuCount)} produk</h3><p>Produk berikut ada di laporan penjualan, tetapi belum dapat dicocokkan dengan data produk Quena Mart. Upload data produk iPos terbaru, lalu kembali ke halaman ini dan tekan Cek Ulang.</p><div className={styles.issueTable}><table><thead><tr><th>SKU</th><th>Nama Produk dari iPos</th><th>Qty Terjual</th></tr></thead><tbody>{[...unresolvedProducts.values()].slice(0, 30).map((product) => <tr key={product.sku}><td>{product.sku}</td><td>{product.name}</td><td>{formatNumber(product.quantity)}</td></tr>)}</tbody></table></div>{Boolean(batch.unresolved_details_truncated) && <p>Menampilkan sebagian SKU yang perlu diperiksa. Perbarui data produk lalu gunakan Cek Ulang.</p>}<Link className={styles.helpLink} href="/import-ipos">Update Data Produk →</Link></article>}
        {stockBlockers > 0 && <Issue title={`Stok produk belum siap · ${stockBlockers} produk`}><p>Produk sudah terdaftar, tetapi stoknya belum dikonfirmasi di Quena Mart. Catat penerimaan melalui Barang Masuk atau selesaikan konfirmasi stok yang sesuai, lalu tekan Cek Ulang.</p><Link className={styles.helpLink} href="/pembelian/barang-masuk">Buka Barang Masuk →</Link></Issue>}
        {costingBlockers > 0 && <Issue title="Kesiapan stok perlu diperiksa"><p>Pengaturan stok belum siap menerima laporan penjualan ini. Periksa kesiapan data stok sebelum melanjutkan.</p></Issue>}
        {duplicateTransactions.length > 0 && <Issue title={`Transaksi sudah pernah diimport · ${num(preflight.duplicateTransactionCount) || num(batch.duplicate_transaction_count)} transaksi`}><p>Laporan ini berisi transaksi yang sudah masuk ke Quena Mart. Seluruh laporan ditahan untuk mencegah transaksi ganda.</p><div className={styles.transactionList}>{duplicateTransactions.slice(0, 20).map((transaction, index) => <span key={`${text(transaction.sourceTransactionNumber)}-${index}`}><strong>{text(transaction.sourceTransactionNumber)}</strong> · {dateLabel(text(transaction.sourceOccurredAt))} · {formatIposSalesRevenue(transaction.total)}</span>)}</div>{num(preflight.duplicateTransactionCount) > duplicateTransactions.length && <p>Daftar menampilkan sebagian transaksi yang terdeteksi.</p>}</Issue>}
        {opnameConflicts > 0 && <Issue title={`Konflik dengan opname · ${opnameConflicts} produk`}><p>Ada penjualan iPos yang waktunya beririsan dengan opname yang sudah diposting. Laporan belum dapat diimport agar stok tidak berubah secara salah. Periksa sesi opname terkait sebelum melanjutkan.</p></Issue>}
        {receiptConflicts > 0 && <Issue title={`Waktu penerimaan perlu diperiksa · ${receiptConflicts} produk`}><p>Waktu penjualan beririsan dengan penerimaan stok yang tercatat. Laporan ditahan sampai urutan stok dapat dipastikan.</p></Issue>}
        {!reconciliationOk && <Issue title="Rekonsiliasi laporan belum sesuai"><p>Total laporan tidak sesuai. Penjualan belum dapat diimport. Periksa kembali ekspor Penjualan Detail dari iPos.</p></Issue>}
      </section>}

      <section className={`${styles.card} ${styles.actionsPanel}`}><p>{isReady ? "Laporan telah diperiksa dan siap diimport." : "Laporan belum siap diimport. Setelah memperbarui data terkait, lakukan pemeriksaan ulang."}</p><div className={styles.actions}>{status !== "COMMITTED" && <button type="button" className={buttons.secondary} onClick={recheck} disabled={busy}>{busy ? "Memeriksa…" : "Cek Ulang"}</button>}<button type="button" className={buttons.primary} onClick={() => setConfirm(true)} disabled={!isReady || busy}>Import Penjualan</button><button type="button" className={buttons.secondary} onClick={clear}>Upload Laporan Lain</button></div></section>
    </>}

    {!batchView && recent.length > 0 && <section className={`${styles.card} ${styles.recent}`}><h2>Import Terakhir</h2><ul className={styles.recentList}>{recent.map((row) => <li key={row.id}><Link href={`/transaksi/import-ipos?batch=${encodeURIComponent(row.id)}`}><strong title={row.filename}>{row.filename}</strong><small>{dateLabel(row.reportFrom)} · {row.transactions} transaksi · {statusText(row.status)}</small><b>{formatRupiah(row.amount)}</b></Link></li>)}</ul></section>}

    {confirm && batch && <div className={styles.modalBackdrop} role="presentation"><section className={styles.dialog} role="dialog" aria-modal="true" aria-labelledby="ipos-confirm-title"><h2 id="ipos-confirm-title">Import Penjualan iPos?</h2><p>Transaksi dan stok akan diperbarui berdasarkan laporan ini.</p><div className={styles.dialogSummary}><strong>{num(batch.transaction_count).toLocaleString("id-ID")} transaksi</strong><span>{formatNumber(batch.total_quantity)} item</span><strong>{formatIposSalesRevenue(batch.total_amount)}</strong></div><div className={styles.dialogActions}><button type="button" className={buttons.secondary} onClick={() => setConfirm(false)} disabled={busy}>Batal</button><button type="button" className={buttons.primary} onClick={commit} disabled={busy}>{busy ? "Mengimport…" : "Import Sekarang"}</button></div></section></div>}
  </div>;
}

function Metric({ label, value, money = false }: { label: string; value: string; money?: boolean }) { return <div className={`${styles.metric}${money ? ` ${styles.money}` : ""}`}><span>{label}</span><strong>{value}</strong></div>; }
function Issue({ title, children }: { title: string; children: ReactNode }) { return <article className={styles.issue}><h3>{title}</h3>{children}</article>; }
