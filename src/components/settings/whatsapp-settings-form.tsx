"use client";
import { useState } from "react";
import { updateWhatsAppSettings, type WhatsAppSettingsInput } from "@/app/actions/whatsapp-settings";
import { QuenaSwitch as Switch } from "@/components/ui/quena-switch";
import { WhatsAppManualTestForm } from "@/components/settings/whatsapp-manual-test-form";
import styles from "@/components/settings/settings.module.css";
type Settings = WhatsAppSettingsInput & { outlet_id: string; updated_at: string | null; provider_state: string; public_url_ready: boolean };
function values(settings: Settings): WhatsAppSettingsInput { return {
  whatsapp_transactions_enabled: settings.whatsapp_transactions_enabled, automatic_receipt_enabled: settings.automatic_receipt_enabled,
  include_points_earned: settings.include_points_earned, include_points_redeemed: settings.include_points_redeemed,
  include_points_balance: settings.include_points_balance,
}; }
export function WhatsAppSettingsForm({ settings, canEdit, publicUrlReady, effectiveProviderState }: { settings: Settings; canEdit: boolean; publicUrlReady: boolean; effectiveProviderState: string }) {
  const [initial, setInitial] = useState(() => values(settings)); const [form, setForm] = useState(() => values(settings));
  const [busy, setBusy] = useState(false); const [notice, setNotice] = useState<{ ok: boolean; text: string } | null>(null);
  const dirty = JSON.stringify(initial) !== JSON.stringify(form);
  function toggle(key: keyof WhatsAppSettingsInput, value: boolean) { setForm((current) => ({ ...current, [key]: value })); setNotice(null); }
  async function save() { if (!dirty || busy || !canEdit) return; setBusy(true); setNotice(null);
    try { const result = await updateWhatsAppSettings(settings.outlet_id, form); setNotice({ ok: result.ok, text: result.message }); if (result.ok) setInitial(form); }
    catch { setNotice({ ok: false, text: "Pengaturan belum tersimpan. Silakan coba kembali." }); } finally { setBusy(false); }
  }
  return <div className={styles.form}>
    <section className={styles.formSection}><header><h2>WHATSAPP TRANSAKSI</h2><p>Preferensi tersimpan terpisah dari kesiapan pengiriman aktual.</p></header><div className={styles.posSettingRows}>
      <div className={styles.posSettingRow}><span><strong>Aktifkan WhatsApp Transaksi</strong><small>Mengizinkan notifikasi layanan transaksi diproses setelah koneksi tersedia.</small></span><Switch label="Aktifkan WhatsApp Transaksi" checked={form.whatsapp_transactions_enabled} disabled={!canEdit || busy} onCheckedChange={(value) => { toggle("whatsapp_transactions_enabled", value); if (!value) setForm((current) => ({ ...current, automatic_receipt_enabled: false })); }} /></div>
      <div className={styles.posSettingRow}><span><strong>Kirim struk otomatis</strong><small>Struk otomatis hanya berjalan saat provider terhubung dan URL publik HTTPS siap.</small>{form.automatic_receipt_enabled && <small className={styles.effectiveNotice}>Preferensi ON · {effectiveProviderState === "CONNECTED" && publicUrlReady ? "Siap diproses sesuai persetujuan pelanggan." : `Menunggu ${effectiveProviderState !== "CONNECTED" ? "koneksi WhatsApp" : "URL publik HTTPS"}.`}</small>}</span><Switch label="Kirim struk otomatis" checked={form.automatic_receipt_enabled} disabled={!canEdit || busy || !form.whatsapp_transactions_enabled} onCheckedChange={(value) => toggle("automatic_receipt_enabled", value)} /></div>
    </div></section>
    <section className={styles.formSection}><header><h2>ISI STRUK</h2><p>Pilih ringkasan yang dapat disertakan pada pesan transaksi.</p></header><div className={styles.posSettingRows}>
      {([["include_points_earned","Poin didapat"],["include_points_redeemed","Poin digunakan"],["include_points_balance","Saldo poin"]] as const).map(([key,label]) => <div key={key} className={styles.posSettingRow}><span><strong>Sertakan {label.toLowerCase()}</strong></span><Switch label={`Sertakan ${label}`} checked={form[key]} disabled={!canEdit || busy} onCheckedChange={(value) => toggle(key,value)} /></div>)}
    </div></section>
    <section className={styles.formSection}><header><h2>KONEKSI PROVIDER</h2><p>Status koneksi dibaca langsung dari layanan WAHA.</p></header><div className={styles.providerNotice}><strong>{effectiveProviderState === "CONNECTED" ? "WhatsApp terhubung · QR Session" : effectiveProviderState === "WAITING_QR" ? "Menunggu scan QR" : effectiveProviderState === "CONNECTING" ? "Menghubungkan WhatsApp" : effectiveProviderState === "ERROR" ? "Koneksi WhatsApp perlu diperiksa" : "WhatsApp belum terhubung"}</strong><span>{effectiveProviderState === "CONNECTED" ? "Koneksi siap. Pesan transaksi pelanggan tetap tidak diproses otomatis." : "Hubungkan layanan WAHA melalui WhatsApp Center. Pengiriman otomatis tetap tidak aktif."}</span><span>Preferensi tersimpan: {form.whatsapp_transactions_enabled ? "WhatsApp Transaksi ON" : "WhatsApp Transaksi OFF"} · {form.automatic_receipt_enabled ? "Struk otomatis ON" : "Struk otomatis OFF"}</span><span>URL publik: {publicUrlReady ? "HTTPS terkonfigurasi" : "belum dikonfigurasi · pengiriman otomatis tetap tidak efektif"}</span></div></section>
    {canEdit && <WhatsAppManualTestForm />}
    {!canEdit && <p className={styles.posSectionHint}>Hanya Owner yang dapat mengubah pengaturan.</p>}
    <div className={styles.formFooter}><span>Terakhir diperbarui {settings.updated_at ? new Date(settings.updated_at).toLocaleString("id-ID") : "belum pernah"}</span><button type="button" className={styles.saveButton} disabled={!dirty || busy || !canEdit} onClick={() => void save()}>{busy ? "Menyimpan…" : "Simpan Perubahan"}</button></div>
    {notice && <p className={`${styles.notice} ${notice.ok ? styles.success : styles.error}`} role={notice.ok ? "status" : "alert"}>{notice.text}</p>}
  </div>;
}
