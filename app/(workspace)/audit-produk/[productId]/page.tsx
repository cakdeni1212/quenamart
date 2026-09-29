import Link from "next/link";
import { notFound } from "next/navigation";
import { AUDIT_FIELDS, AUDIT_FINDINGS, parseAuditContext } from "@/lib/product-audit/context";
import { readProductFieldAudit } from "@/lib/product-audit/read";
import type { FieldAuditRecord } from "@/lib/product-audit/read";

type SearchParams = Promise<{ finding?: string | string[]; field?: string | string[] }>;

const reviewLabels: Record<string, string> = {
  BELUM_DICEK: "Belum dicek",
  SEDANG_DICEK: "Sedang diperiksa",
  SUDAH_DIVERIFIKASI: "Sudah diverifikasi",
};
const reconciliationLabels: Record<string, string> = {
  SOURCE_CONFLICT: "Sumber iPos masih berbeda",
  SOURCE_SYNCED: "Sumber iPos sudah sesuai",
  HUMAN_ACCEPTED_SOURCE: "Nilai sumber diterima oleh pengelola",
};
const money = (value: string | number | null) => value == null
  ? "—"
  : new Intl.NumberFormat("id-ID", { style: "currency", currency: "IDR", maximumFractionDigits: 2 }).format(Number(value));

function display(value: string | number | null) {
  return value == null ? "—" : String(value);
}

function sourceDisplay(record: FieldAuditRecord) {
  if (record.sourceValue != null) return display(record.sourceValue);
  return record.sourceRowId ? "Kosong pada snapshot iPos" : "Nilai sumber tidak tersedia";
}

function LocalizedTime({ value }: { value: string }) {
  return <time dateTime={value}>{new Date(value).toLocaleString("id-ID", { timeZone: "Asia/Jakarta" })} WIB</time>;
}

function FieldCard({
  title,
  record,
  financial = false,
}: {
  title: string;
  record: FieldAuditRecord;
  financial?: boolean;
}) {
  const formatValue = financial ? money : display;
  return <section className="surface-card audit-field-card">
    <div className="audit-field-title"><h2>{title}</h2>{record.review && <span className="audit-status-pill">{reviewLabels[record.review.status] ?? "Status pemeriksaan tercatat"}</span>}</div>
    <dl className="audit-value-grid">
      <div><dt>Nilai dari iPos</dt><dd>{financial ? formatValue(record.sourceValue) : sourceDisplay(record)}</dd></div>
      <div><dt>Nilai Quena Mart saat ini</dt><dd>{formatValue(record.currentValue)}</dd></div>
      {record.override && <div className="audit-override-value"><dt>Koreksi manual aktif</dt><dd>{formatValue(record.override.value)}</dd><small>{record.override.reason}</small><small>Koreksi tercatat · <LocalizedTime value={record.override.correctedAt} /></small></div>}
    </dl>
    <div className="audit-field-meta">
      {record.review && <span>Petugas tercatat · <LocalizedTime value={record.review.reviewedAt} /></span>}
      {!record.review && <span>Belum ada pemeriksaan untuk sumber ini</span>}
      {record.reconciliation && <span className={record.reconciliation.eventType === "SOURCE_CONFLICT" ? "audit-reconciliation-conflict" : "audit-reconciliation-ok"}>
        {reconciliationLabels[record.reconciliation.eventType] ?? "Pembaruan sumber tercatat"}
      </span>}
      {record.sourceRowId && <span className="audit-provenance-note">Sumber terikat pada snapshot produk saat ini.</span>}
    </div>
  </section>;
}

export default async function ProductFieldAuditPage({
  params,
  searchParams,
}: {
  params: Promise<{ productId: string }>;
  searchParams: SearchParams;
}) {
  const [{ productId }, query] = await Promise.all([params, searchParams]);
  const result = await readProductFieldAudit(productId);
  if (result.kind === "not-found") notFound();
  if (result.kind === "error") {
    return <main className="page-content"><Link className="quiet-button" href="/audit-produk">← Kembali ke Audit Produk</Link><div className="surface-card product-state product-error"><strong>Data audit belum dapat dimuat.</strong><span>Coba muat ulang halaman. Data sumber dan pemeriksaan tetap mengikuti snapshot yang tercatat.</span></div></main>;
  }

  const { data } = result;
  const context = parseAuditContext(query.finding, query.field, data.product.findingCodes);
  const findingLabel = context.finding ? AUDIT_FINDINGS[context.finding] : null;
  const selectedField = context.field;
  const backHref = context.finding ? `/produk?issue=${encodeURIComponent(context.finding)}` : "/audit-produk";
  const manager = data.role === "OWNER" || data.role === "ADMIN";
  const fieldOrder = manager
    ? ["barcode", "rack_label", "hpp", "selling_price"] as const
    : ["barcode", "rack_label"] as const;

  return <main className="page-content audit-detail-page">
    <Link className="quiet-button audit-back-link" href={backHref}>← Kembali ke antrean audit</Link>
    <div className="eyebrow audit-detail-eyebrow">PEMERIKSAAN PRODUK · BACA SAJA</div>
    <div className="audit-detail-heading"><div><h1>{data.product.name}</h1><p>SKU {data.product.sku}{data.product.category ? ` · ${data.product.category}` : ""}</p></div><span className="audit-readonly-pill">Belum ada aksi perubahan</span></div>

    {context.invalid && <div className="audit-context-notice" role="status">Konteks audit pada tautan tidak cocok atau tidak tersedia. Temuan aktif di bawah tetap berasal dari snapshot tersimpan.</div>}

    <section className="surface-card audit-source-findings">
      <div className="audit-section-heading"><div><span className="eyebrow">1 · SUMBER TEMUAN</span><h2>Masalah dari iPos</h2></div><span className="audit-snapshot-note">Temuan sumber tidak berubah karena pemeriksaan manual.</span></div>
      {findingLabel && <p className="audit-selected-finding">Fokus audit: <strong>{findingLabel}</strong></p>}
      {data.product.findingCodes.length ? <div className="audit-detail-tags">{data.product.findingCodes.map((code) => <span key={code} className={`audit-badge${code === context.finding ? " audit-badge-selected" : ""}`}>{AUDIT_FINDINGS[code as keyof typeof AUDIT_FINDINGS] ?? "Temuan tersimpan"}</span>)}</div> : <p className="audit-no-findings">Tidak ada temuan OPEN pada snapshot terbaru.</p>}
    </section>

    <section className="audit-field-section">
      <div className="audit-section-heading"><div><span className="eyebrow">2–6 · NILAI & RIWAYAT</span><h2>Rincian pemeriksaan</h2></div></div>
      {selectedField === "name" && <div className="surface-card audit-field-card"><h2>Nama produk</h2><p>Nilai iPos khusus untuk pemeriksaan nama tidak tersedia melalui proyeksi sumber field yang aman. Nilai Quena Mart saat ini: <strong>{data.product.name}</strong>.</p><p className="audit-field-meta">Pencatatan review untuk nama produk belum didukung RPC Phase 3B.1A.</p></div>}
      {fieldOrder.map((field) => {
        const record = data.fields[field];
        if (!record) return null;
        if (field === "barcode") {
          return <section className="surface-card audit-field-card" key={field}>
            <div className="audit-field-title"><h2>Barcode</h2>{record.review && <span className="audit-status-pill">{reviewLabels[record.review.status] ?? "Status pemeriksaan tercatat"}</span>}</div>
            <dl className="audit-value-grid"><div><dt>Nilai dari iPos</dt><dd>{sourceDisplay(record)}</dd></div><div><dt>Nilai aktif di Quena Mart</dt><dd>{data.activeBarcodes.length ? <ul className="audit-barcode-list">{data.activeBarcodes.map((barcode, index) => <li key={`${barcode.value}-${index}`}><code>{barcode.value}</code><small>{barcode.sourceRowId ? "Sumber iPos" : "Tambahan manual"}</small></li>)}</ul> : "Belum ada barcode aktif"}</dd></div>
              {record.override && <div className="audit-override-value"><dt>Penggantian sumber aktif</dt><dd>{display(record.override.value)}</dd><small>{record.override.reason}</small><small>Koreksi tercatat · <LocalizedTime value={record.override.correctedAt} /></small></div>}
            </dl>
            <div className="audit-field-meta">{record.review ? <>Petugas tercatat · <LocalizedTime value={record.review.reviewedAt} /></> : "Belum ada pemeriksaan untuk sumber ini"}{record.reconciliation && <span className={record.reconciliation.eventType === "SOURCE_CONFLICT" ? "audit-reconciliation-conflict" : "audit-reconciliation-ok"}>{reconciliationLabels[record.reconciliation.eventType] ?? "Pembaruan sumber tercatat"}</span>}</div>
          </section>;
        }
        return <FieldCard key={field} title={AUDIT_FIELDS[field]} record={record} financial={field === "hpp" || field === "selling_price"} />;
      })}
      {selectedField && ![...fieldOrder, "name"].includes(selectedField as never) && <div className="surface-card audit-field-card"><h2>{AUDIT_FIELDS[selectedField]}</h2><p>Nilai audit untuk bidang ini tidak tersedia melalui pembacaan aman Phase 3B.1A.</p></div>}
      {selectedField === "quantity" || selectedField === "minimum_quantity" || data.product.findingCodes.some((code) => code === "ZERO_STOCK" || code === "STOCK_AT_OR_BELOW_MINIMUM") ? <section className="surface-card audit-stock-card"><span className="eyebrow">INFORMASI SAJA</span><h2>Stok & stok minimum</h2><dl className="audit-value-grid"><div><dt>Jumlah stok ternormalisasi</dt><dd>{display(data.stock.quantity)}</dd></div><div><dt>Minimum stok ternormalisasi</dt><dd>{display(data.stock.minimumQuantity)}</dd></div></dl><p>Nilai ini merupakan catatan snapshot iPos. Perubahan stok belum tersedia di alur audit ini.</p></section> : null}
    </section>
    <p className="audit-detail-footnote">Status verifikasi manusia, temuan snapshot iPos, koreksi aktif, dan rekonsiliasi sumber adalah catatan terpisah. Verifikasi tidak menutup temuan sumber.</p>
  </main>;
}
