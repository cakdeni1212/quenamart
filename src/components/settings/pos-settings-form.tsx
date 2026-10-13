"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { updatePosSettings, type PosSettingsInput } from "@/app/actions/pos-settings";
import { POS_PAYMENT_METHODS, type PosPaymentMethod, type PosSettings } from "@/lib/settings/pos-shared";
import buttons from "@/components/ui/workspace-primary-action.module.css";
import styles from "@/components/settings/settings.module.css";

const methodOptions: { method: PosPaymentMethod; label: string }[] = [
  { method: "CASH", label: "Tunai" },
  { method: "QRIS", label: "QRIS" },
  { method: "CARD", label: "Kartu" },
  { method: "E_WALLET", label: "E-Wallet" },
];

type FormState = Omit<PosSettingsInput, "outlet_id">;
function stateFrom(settings: PosSettings): FormState {
  return {
    receipt_footer_note: settings.receipt_footer_note ?? "",
    receipt_show_address: settings.receipt_show_address,
    receipt_show_phone: settings.receipt_show_phone,
    enabled_payment_methods: settings.enabled_payment_methods,
    allow_hold_transactions: settings.allow_hold_transactions,
    confirm_cart_cancellation: settings.confirm_cart_cancellation,
  };
}

export function PosSettingsForm({ settings, canEdit }: { settings: PosSettings; canEdit: boolean }) {
  const router = useRouter();
  const [form, setForm] = useState(() => stateFrom(settings));
  const [notice, setNotice] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, startTransition] = useTransition();
  const initial = stateFrom(settings);
  const changed = JSON.stringify(form) !== JSON.stringify(initial);
  const valid = form.enabled_payment_methods.length > 0
    && form.enabled_payment_methods.every((method) => POS_PAYMENT_METHODS.includes(method));

  function update<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((current) => ({ ...current, [key]: value }));
    setNotice(null);
  }

  function togglePayment(method: PosPaymentMethod, checked: boolean) {
    const methods = checked
      ? methodOptions.map(({ method: value }) => value).filter((value) => value === method || form.enabled_payment_methods.includes(value))
      : form.enabled_payment_methods.filter((value) => value !== method);
    update("enabled_payment_methods", methods);
  }

  function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!canEdit || pending || !changed || !valid) return;
    const payload: PosSettingsInput = { outlet_id: settings.outlet_id, ...form };
    startTransition(async () => {
      const result = await updatePosSettings(payload);
      setNotice({ ok: result.ok, text: result.message });
      if (result.ok) router.refresh();
    });
  }

  return <form className={styles.form} onSubmit={submit}>
    <section className={`${styles.formSection} ${styles.posSettingsSection}`}>
      <header><h2>Struk</h2><p>Informasi tampilan pada struk Quena Mart.</p></header>
      <div className={styles.posSettingRows}>
        <label className={styles.posFooterField}>Catatan bawah struk<textarea maxLength={200} value={form.receipt_footer_note} onChange={(event) => update("receipt_footer_note", event.target.value)} readOnly={!canEdit} placeholder="Contoh: Terima kasih telah berbelanja" /><small>Kosongkan untuk memakai ucapan standar. Maksimal 200 karakter.</small></label>
        <label className={styles.posSettingRow}><span><strong>Tampilkan alamat outlet</strong><small>Alamat hanya tampil jika sudah diisi di Toko &amp; Outlet.</small></span><input type="checkbox" checked={form.receipt_show_address} onChange={(event) => update("receipt_show_address", event.target.checked)} disabled={!canEdit} /></label>
        <label className={styles.posSettingRow}><span><strong>Tampilkan nomor telepon outlet</strong><small>Jika nomor telepon kosong, WhatsApp outlet digunakan bila tersedia.</small></span><input type="checkbox" checked={form.receipt_show_phone} onChange={(event) => update("receipt_show_phone", event.target.checked)} disabled={!canEdit} /></label>
      </div>
    </section>

    <section className={`${styles.formSection} ${styles.posSettingsSection}`}>
      <header><h2>Pembayaran</h2><p>Metode yang tersedia untuk transaksi baru di kasir.</p></header>
      <div className={styles.posSettingRows}>
        {methodOptions.map(({ method, label }) => <label className={styles.posSettingRow} key={method}><span><strong>{label}</strong></span><input type="checkbox" checked={form.enabled_payment_methods.includes(method)} onChange={(event) => togglePayment(method, event.target.checked)} disabled={!canEdit} /></label>)}
      </div>
      {!valid && <p className={styles.posValidation} role="alert">Aktifkan sedikitnya satu metode pembayaran.</p>}
      <small className={styles.posSectionHint}>Perubahan berlaku untuk pembayaran baru. Riwayat pembayaran sebelumnya tetap tersimpan.</small>
    </section>

    <section className={`${styles.formSection} ${styles.posSettingsSection}`}>
      <header><h2>Transaksi</h2><p>Atur cara keranjang sementara digunakan kasir.</p></header>
      <div className={styles.posSettingRows}>
        <label className={styles.posSettingRow}><span><strong>Izinkan Hold Transaksi</strong><small>Keranjang yang sudah ditahan tetap dapat dilanjutkan atau dibatalkan.</small></span><input type="checkbox" checked={form.allow_hold_transactions} onChange={(event) => update("allow_hold_transactions", event.target.checked)} disabled={!canEdit} /></label>
        <label className={styles.posSettingRow}><span><strong>Konfirmasi sebelum membatalkan keranjang</strong><small>Berlaku untuk keranjang aktif atau yang sedang ditahan; transaksi selesai tetap tidak dapat dibatalkan dari sini.</small></span><input type="checkbox" checked={form.confirm_cart_cancellation} onChange={(event) => update("confirm_cart_cancellation", event.target.checked)} disabled={!canEdit} /></label>
      </div>
    </section>

    <div className={styles.formFooter}>
      <span>{settings.updated_at ? `Terakhir diperbarui ${new Date(settings.updated_at).toLocaleString("id-ID", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Jakarta" })}` : "Belum pernah diperbarui"}</span>
      {canEdit && <button className={buttons.primary} type="submit" disabled={pending || !changed || !valid}>{pending ? "Menyimpan..." : "Simpan Perubahan"}</button>}
    </div>
    {notice && <p role={notice.ok ? "status" : "alert"} className={`${styles.notice} ${notice.ok ? styles.success : styles.error}`}>{notice.text}</p>}
  </form>;
}
