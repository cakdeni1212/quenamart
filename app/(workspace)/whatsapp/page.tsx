import Link from "next/link";
import { redirect } from "next/navigation";
import { canAccessSection } from "@/lib/auth/roles";
import { requireProfile } from "@/lib/auth/session";
import { readWhatsAppSettings, readWhatsAppSummary } from "@/lib/notifications/whatsapp.server";
import { readWhatsAppProviderStatus } from "@/app/actions/whatsapp-provider";
import { WhatsAppConnectionControls } from "@/components/notifications/whatsapp-connection-controls";
import { RefreshButton, WhatsAppCenterControls } from "@/components/notifications/whatsapp-center-controls";
import styles from "@/components/notifications/whatsapp-center.module.css";

function dateTime(value: string | null) {
  if (!value) return "—";
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "—" : date.toLocaleString("id-ID", { dateStyle: "medium", timeStyle: "short" });
}

function statusLabel(value: string) {
  return ({
    PENDING: "Menunggu",
    PROCESSING: "Diproses",
    RETRY: "Percobaan ulang",
    SENT: "Terkirim",
    FAILED: "Gagal",
    CANCELLED: "Dibatalkan",
    BLOCKED: "Ditahan",
  } as Record<string, string>)[value] ?? "Belum tersedia";
}

function publicHttpsConfigured() {
  try {
    const url = new URL(process.env.NEXT_PUBLIC_APP_URL ?? "");
    const host = url.hostname.toLowerCase();
    return url.protocol === "https:"
      && !url.username
      && !url.password
      && host !== "localhost"
      && host !== "127.0.0.1"
      && host !== "::1"
      && !host.endsWith(".local")
      && !/^10\./.test(host)
      && !/^192\.168\./.test(host)
      && !/^172\.(1[6-9]|2\d|3[01])\./.test(host);
  } catch {
    return false;
  }
}

function MetricIcon({ kind }: { kind: "sent" | "queue" | "failed" | "oldest" }) {
  if (kind === "sent") return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12 4.2 4.2L19 6.5"/></svg>;
  if (kind === "queue") return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 6h14M5 12h14M5 18h9"/><circle cx="3" cy="6" r=".5"/><circle cx="3" cy="12" r=".5"/><circle cx="3" cy="18" r=".5"/></svg>;
  if (kind === "failed") return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3 2.8 19h18.4L12 3Z"/><path d="M12 9v4m0 3h.01"/></svg>;
  return <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>;
}

function CardIcon({ kind }: { kind: "receipt" | "settings" | "empty" }) {
  if (kind === "settings") return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7Z"/><path d="m19.4 15 .1.1a1.7 1.7 0 1 1-2.4 2.4l-.1-.1a1.7 1.7 0 0 0-2.9 1.2v.2a1.7 1.7 0 1 1-3.4 0v-.2a1.7 1.7 0 0 0-2.9-1.2l-.1.1a1.7 1.7 0 1 1-2.4-2.4l.1-.1a1.7 1.7 0 0 0-1.2-2.9H4a1.7 1.7 0 1 1 0-3.4h.2a1.7 1.7 0 0 0 1.2-2.9l-.1-.1a1.7 1.7 0 1 1 2.4-2.4l.1.1a1.7 1.7 0 0 0 2.9-1.2V2a1.7 1.7 0 1 1 3.4 0v.2a1.7 1.7 0 0 0 2.9 1.2l.1-.1a1.7 1.7 0 1 1 2.4 2.4l-.1.1a1.7 1.7 0 0 0 1.2 2.9h.2a1.7 1.7 0 1 1 0 3.4h-.2a1.7 1.7 0 0 0-1.2 2.9Z"/></svg>;
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 3h12a2 2 0 0 1 2 2v16l-3-2-3 2-3-2-3 2-3-2V5a2 2 0 0 1 2-2Z"/><path d="M8 8h8M8 12h8M8 16h4"/></svg>;
}

export default async function WhatsAppCenterPage() {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "whatsapp")) redirect("/dashboard");

  const [summaryResult, settingsResult, providerResult] = await Promise.all([readWhatsAppSummary(), readWhatsAppSettings(), readWhatsAppProviderStatus()]);
  const summary = summaryResult.summary;
  const settings = settingsResult.settings;
  const providerStatus = providerResult.ok ? providerResult.status : null;
  const providerState = providerStatus?.connection_state ?? summary?.provider_state ?? "NOT_CONFIGURED";
  const publicUrlReady = publicHttpsConfigured() && settings?.public_url_ready === true;
  const automationReady = summary?.automation_enabled === true
    && providerState === "CONNECTED"
    && publicUrlReady;

  return (
    <main className="page-content">
      <header className={styles.pageHeading}>
        <div>
          <div className="eyebrow">OPERASIONAL</div>
          <h1>WhatsApp Center</h1>
          <p>Pantau dan kelola pengiriman notifikasi transaksi ke pelanggan.</p>
        </div>
      </header>

      <div className={styles.dashboardGrid}>
        <main className={styles.dashboardMain}>
          <WhatsAppConnectionControls initialStatus={providerStatus} canControl={profile.role === "OWNER"} />

          {summary ? <section className={styles.metricGrid} aria-label="Ringkasan pengiriman">
            <MetricCard kind="sent" label="Terkirim hari ini" value={summary.today_sent.toLocaleString("id-ID")} note={summary.today_sent ? "Pesan selesai hari ini" : "Tidak ada perubahan"} />
            <MetricCard kind="queue" label="Antrean" value={summary.pending.toLocaleString("id-ID")} note={summary.pending ? "Menunggu diproses" : "Tidak ada perubahan"} />
            <MetricCard kind="failed" label="Gagal" value={summary.failed.toLocaleString("id-ID")} note={summary.failed ? "Perlu ditinjau" : "Tidak ada perubahan"} />
            <MetricCard kind="oldest" label="Antrean tertua" value={dateTime(summary.oldest_pending_at)} note={summary.oldest_pending_at ? "Waktu dibuat" : "Belum ada antrean"} compact />
          </section> : <div className={styles.dataError} role="alert">{summaryResult.error}</div>}

          <section className={styles.historyCard} aria-labelledby="history-title">
            <header className={styles.historyHeader}>
              <div><h2 id="history-title">Riwayat Pengiriman</h2><p>Menampilkan hingga 50 notifikasi terbaru.</p></div>
              <RefreshButton />
            </header>
            <div className={styles.tableScroller}>
              <table className={styles.historyTable}>
                <thead><tr><th>WAKTU</th><th>PELANGGAN</th><th>TRANSAKSI</th><th>JENIS</th><th>STATUS</th><th>PESAN</th></tr></thead>
                <tbody>{summary?.recent.length ? summary.recent.map((item) => <tr key={item.id}>
                  <td>{dateTime(item.sent_at ?? item.created_at)}</td>
                  <td><span className={styles.customerCell}>{item.customer_name}</span><small>{item.destination_masked}</small></td>
                  <td>{item.sale_number}</td>
                  <td>WhatsApp</td>
                  <td><span className={styles.deliveryStatus + (item.status === "SENT" ? " " + styles.deliverySent : item.status === "FAILED" ? " " + styles.deliveryFailed : "")}>{statusLabel(item.status)}</span></td>
                  <td>Struk digital</td>
                </tr>) : <tr><td colSpan={6} className={styles.emptyCell}><div className={styles.emptyState}><span className={styles.emptyIcon}><CardIcon kind="empty" /></span><strong>{summary ? "Belum ada notifikasi WhatsApp." : "Riwayat belum dapat dimuat."}</strong><span>{summary ? "Notifikasi akan muncul di sini setelah transaksi memenuhi syarat dan pengiriman otomatis diaktifkan." : summaryResult.error}</span></div></td></tr>}</tbody>
              </table>
            </div>
          </section>
        </main>

        <aside className={styles.dashboardSidebar}>
          {settings ? <WhatsAppCenterControls key={[settings.outlet_id, settings.updated_at ?? "", settings.whatsapp_transactions_enabled, settings.automatic_receipt_enabled, settings.include_points_earned, settings.include_points_redeemed, settings.include_points_balance, settings.provider_state, settings.public_url_ready].join(":")} settings={settings} canEdit={profile.role === "OWNER"} /> : <section className={styles.quickCard} role="alert"><h2>Pengaturan Cepat</h2><p>{settingsResult.error}</p><Link href="/pengaturan/whatsapp" className={styles.secondaryLink}>Buka Pengaturan Lengkap</Link></section>}

          <section className={styles.connectionInfo} aria-labelledby="connection-info-title">
            <header><span className={styles.asideIcon}><CardIcon kind="receipt" /></span><h2 id="connection-info-title">Informasi Koneksi</h2></header>
            <InfoRow label="Provider" value={providerState === "NOT_CONFIGURED" ? "Belum dikonfigurasi" : "QR Session"} />
            <InfoRow label="Status" value={providerState} code />
            <InfoRow label="URL publik" value={settings ? publicUrlReady ? "Siap" : "Belum dikonfigurasi" : "Belum tersedia"} />
            <InfoRow label="Otomatisasi" value={summary ? automationReady ? "Aktif" : summary.automation_enabled ? "Menunggu kesiapan" : "Nonaktif" : "Belum tersedia"} />
            <Link href="/pengaturan/whatsapp" className={styles.settingsLink}><CardIcon kind="settings" />Buka Pengaturan Lengkap</Link>
          </section>
        </aside>
      </div>
    </main>
  );
}

function MetricCard({ kind, label, value, note, compact = false }: { kind: "sent" | "queue" | "failed" | "oldest"; label: string; value: string; note: string; compact?: boolean }) {
  const kindClass = kind === "sent" ? styles.metricSent : kind === "queue" ? styles.metricQueue : kind === "failed" ? styles.metricFailed : styles.metricOldest;
  return <article className={styles.metricCard}>
    <div className={styles.metricIcon + " " + kindClass}><MetricIcon kind={kind} /></div>
    <span>{label}</span>
    <strong className={compact ? styles.metricCompact : ""}>{value}</strong>
    <small>{note}</small>
  </article>;
}

function InfoRow({ label, value, code = false }: { label: string; value: string; code?: boolean }) {
  return <div className={styles.infoRow}><span>{label}</span><strong className={code ? styles.codeValue : ""}>{value}</strong></div>;
}
