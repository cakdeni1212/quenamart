import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readWhatsAppSummary } from "@/lib/notifications/whatsapp.server";
import styles from "@/components/settings/settings.module.css";
import Link from "next/link";
function dateTime(value: string | null) { return value ? new Date(value).toLocaleString("id-ID") : "—"; }
function statusLabel(value: string) { return ({ PENDING: "Menunggu", PROCESSING: "Sedang diproses", RETRY: "Menunggu percobaan ulang", SENT: "Terkirim", FAILED: "Gagal", CANCELLED: "Dibatalkan", BLOCKED: "Ditahan" } as Record<string,string>)[value] ?? "Belum tersedia"; }
function providerLabel(value: string) { return ({ NOT_CONFIGURED: "Belum dikonfigurasi", DISCONNECTED: "Terputus", CONNECTING: "Menghubungkan", CONNECTED: "Terhubung", DEGRADED: "Gangguan", ERROR: "Perlu diperiksa" } as Record<string,string>)[value] ?? "Belum tersedia"; }
export default async function WhatsAppCenterPage() {
  const profile = await requireProfile(); if (!canAccessSection(profile.role,"whatsapp")) redirect("/dashboard");
  const result = await readWhatsAppSummary(); const summary = result.summary;
  return <main className="page-content"><header className={styles.heading}><div><div className="eyebrow">OPERASIONAL</div><h1>WhatsApp Center</h1><p>Pantau kesiapan dan riwayat pesan transaksi.</p></div>{profile.role === "OWNER" && <Link className={styles.directoryAction} href="/pengaturan/whatsapp">Pengaturan ›</Link>}</header>
    {result.error && <div className={styles.readError} role="alert">{result.error}</div>}
    {summary && <section className={styles.whatsappConnection}><div><span className={styles.whatsappLabel}>KONEKSI</span><h2>{summary.provider_state === "CONNECTED" ? "WhatsApp terhubung" : "WhatsApp belum terhubung"}</h2><p>{summary.provider_state === "NOT_CONFIGURED" ? "Provider belum dikonfigurasi. Tidak ada pesan keluar." : `Status provider: ${providerLabel(summary.provider_state)}.`}</p><p>Otomatisasi: {summary.automation_enabled ? "aktif, menunggu kesiapan pengiriman" : "nonaktif"}</p></div><span className={styles.whatsappBadge}>{providerLabel(summary.provider_state)}</span></section>}
    {summary && <><section className={styles.whatsappMetrics} aria-label="Ringkasan pesan"><article><span>Terkirim hari ini</span><strong>{summary.today_sent}</strong></article><article><span>Antrean</span><strong>{summary.pending}</strong></article><article><span>Gagal</span><strong>{summary.failed}</strong></article><article><span>Antrean tertua</span><strong>{dateTime(summary.oldest_pending_at)}</strong></article></section>
      <section className={styles.formSection}><header><h2>RIWAYAT PESAN</h2><p>Menampilkan hingga 50 notifikasi terbaru.</p></header>{summary.recent.length ? <div className={styles.whatsappTableWrap}><table className={styles.whatsappTable}><thead><tr><th>Customer</th><th>WhatsApp</th><th>Transaksi</th><th>Jenis</th><th>Status</th><th>Waktu</th></tr></thead><tbody>{summary.recent.map((item) => <tr key={item.id}><td>{item.customer_name}</td><td>{item.destination_masked}</td><td>{item.sale_number}</td><td>Struk digital</td><td>{statusLabel(item.status)}</td><td>{dateTime(item.sent_at ?? item.created_at)}</td></tr>)}</tbody></table></div> : <p className={styles.whatsappEmpty}>Belum ada notifikasi WhatsApp.</p>}</section></>}
  </main>;
}
