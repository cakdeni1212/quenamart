"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { updateWhatsAppSettings, type WhatsAppSettingsInput } from "@/app/actions/whatsapp-settings";
import { QuenaSwitch } from "@/components/ui/quena-switch";
import styles from "./whatsapp-center.module.css";

type WhatsAppSettingsData = WhatsAppSettingsInput & {
  outlet_id: string;
  provider_state: string;
  public_url_ready: boolean;
  updated_at: string | null;
};

function values(settings: WhatsAppSettingsData): WhatsAppSettingsInput {
  return {
    whatsapp_transactions_enabled: settings.whatsapp_transactions_enabled,
    automatic_receipt_enabled: settings.automatic_receipt_enabled,
    include_points_earned: settings.include_points_earned,
    include_points_redeemed: settings.include_points_redeemed,
    include_points_balance: settings.include_points_balance,
  };
}

export function WhatsAppCenterControls({ settings, canEdit, effectiveProviderState }: { settings: WhatsAppSettingsData; canEdit: boolean; effectiveProviderState: string }) {
  const router = useRouter();
  const [initial, setInitial] = useState(() => values(settings));
  const [form, setForm] = useState(() => values(settings));
  const [saving, setSaving] = useState(false);
  const [notice, setNotice] = useState<{ ok: boolean; text: string } | null>(null);
  const dirty = JSON.stringify(initial) !== JSON.stringify(form);
  const providerReady = effectiveProviderState === "CONNECTED" && settings.public_url_ready;

  function update(key: keyof WhatsAppSettingsInput, checked: boolean) {
    setForm((current) => {
      const next = { ...current, [key]: checked };
      if (key === "whatsapp_transactions_enabled" && !checked) next.automatic_receipt_enabled = false;
      return next;
    });
    setNotice(null);
  }

  async function save() {
    if (!dirty || saving || !canEdit) return;
    setSaving(true);
    setNotice(null);
    try {
      const result = await updateWhatsAppSettings(settings.outlet_id, form);
      setNotice({ ok: result.ok, text: result.message });
      if (result.ok) {
        setInitial(form);
        router.refresh();
      }
    } catch {
      setNotice({ ok: false, text: "Pengaturan belum tersimpan. Silakan coba kembali." });
    } finally {
      setSaving(false);
    }
  }

  return (
    <section className={styles.quickCard} aria-labelledby="quick-settings-title">
      <header className={styles.sidebarHeading}>
        <span className={styles.asideIcon}><SettingsIcon /></span>
        <h2 id="quick-settings-title">Pengaturan Cepat</h2>
      </header>
      <section className={styles.quickGroup} aria-label="Pengaturan WhatsApp transaksi">
        <QuickSetting
          title="WhatsApp Transaksi"
          description="Mengizinkan notifikasi layanan transaksi diproses setelah koneksi tersedia."
          label="WhatsApp Transaksi"
          checked={form.whatsapp_transactions_enabled}
          disabled={!canEdit || saving}
          onChange={(checked) => update("whatsapp_transactions_enabled", checked)}
        />
        <QuickSetting
          title="Kirim struk otomatis"
          description="Struk otomatis berjalan saat provider terhubung dan URL publik siap."
          label="Kirim struk otomatis"
          checked={form.automatic_receipt_enabled}
          disabled={!canEdit || saving || (!form.automatic_receipt_enabled && (!form.whatsapp_transactions_enabled || !providerReady))}
          onChange={(checked) => update("automatic_receipt_enabled", checked)}
        />
        {!providerReady && <p className={styles.prerequisiteHint}>Otomatisasi belum dapat diaktifkan sebelum provider terhubung dan URL publik siap.</p>}
      </section>

      <div className={styles.sidebarDivider} />
      <section className={styles.quickGroup} aria-label="Isi struk">
        <div className={styles.groupHeading}><h3>Isi Struk</h3><p>Pilih ringkasan yang disertakan pada pesan transaksi.</p></div>
        <QuickSetting title="Sertakan poin didapat" label="Sertakan poin didapat" checked={form.include_points_earned} disabled={!canEdit || saving} onChange={(checked) => update("include_points_earned", checked)} compact />
        <QuickSetting title="Sertakan poin digunakan" label="Sertakan poin digunakan" checked={form.include_points_redeemed} disabled={!canEdit || saving} onChange={(checked) => update("include_points_redeemed", checked)} compact />
        <QuickSetting title="Sertakan saldo poin" label="Sertakan saldo poin" checked={form.include_points_balance} disabled={!canEdit || saving} onChange={(checked) => update("include_points_balance", checked)} compact />
      </section>
      {!canEdit && <p className={styles.readOnlyHint}>ADMIN dapat melihat pengaturan. Perubahan hanya dapat disimpan oleh OWNER.</p>}
      {notice && <p role={notice.ok ? "status" : "alert"} className={notice.ok ? styles.noticeSuccess : styles.noticeError}>{notice.text}</p>}
      {canEdit && <button type="button" className={styles.saveButton} disabled={!dirty || saving} onClick={() => void save()}>{saving ? "Menyimpan…" : "Simpan Perubahan"}</button>}
    </section>
  );
}

function QuickSetting({ title, description, label, checked, disabled, onChange, compact = false }: {
  title: string;
  description?: string;
  label: string;
  checked: boolean;
  disabled: boolean;
  onChange: (checked: boolean) => void;
  compact?: boolean;
}) {
  return (
    <div className={styles.quickSetting + (compact ? " " + styles.quickSettingCompact : "")}>
      <span className={styles.quickSettingCopy}>
        <strong>{title}</strong>
        {description && <small>{description}</small>}
      </span>
      <QuenaSwitch label={label} checked={checked} disabled={disabled} onCheckedChange={onChange} />
    </div>
  );
}

export function RefreshButton() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  return (
    <button type="button" className={styles.refreshButton} disabled={pending} onClick={() => startTransition(() => router.refresh())}>
      <RefreshIcon />{pending ? "Memuat…" : "Muat Ulang"}
    </button>
  );
}

function SettingsIcon() {
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7Z"/><path d="m19.4 15 .1.1a1.7 1.7 0 1 1-2.4 2.4l-.1-.1a1.7 1.7 0 0 0-2.9 1.2v.2a1.7 1.7 0 1 1-3.4 0v-.2a1.7 1.7 0 0 0-2.9-1.2l-.1.1a1.7 1.7 0 1 1-2.4-2.4l.1-.1a1.7 1.7 0 0 0-1.2-2.9H4a1.7 1.7 0 1 1 0-3.4h.2a1.7 1.7 0 0 0 1.2-2.9l-.1-.1a1.7 1.7 0 1 1 2.4-2.4l.1.1a1.7 1.7 0 0 0 2.9-1.2V2a1.7 1.7 0 1 1 3.4 0v.2a1.7 1.7 0 0 0 2.9 1.2l.1-.1a1.7 1.7 0 1 1 2.4 2.4l-.1.1a1.7 1.7 0 0 0 1.2 2.9h.2a1.7 1.7 0 1 1 0 3.4h-.2a1.7 1.7 0 0 0-1.2 2.9Z"/></svg>;
}

function RefreshIcon() {
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 7v5h-5"/><path d="M19 12a7 7 0 1 1-2-5l3 5"/></svg>;
}
