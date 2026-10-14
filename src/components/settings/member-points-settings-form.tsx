"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { updateMemberPointsSettings } from "@/app/actions/member-points-settings";
import { QuenaSwitch } from "@/components/ui/quena-switch";
import { RupiahInput } from "@/components/ui/rupiah-input";
import buttons from "@/components/ui/workspace-primary-action.module.css";
import { formatRupiah } from "@/lib/money";
import type { MemberPointsSettings } from "@/lib/settings/member-points-shared";
import styles from "@/components/settings/settings.module.css";

type FormState = { program_enabled: boolean; rupiah_per_point: string; redeem_enabled: boolean; rupiah_per_redeem_point: string; minimum_redeem_points: string };
const stateFrom = (value: MemberPointsSettings): FormState => ({
  program_enabled: value.program_enabled,
  rupiah_per_point: value.rupiah_per_point ?? "",
  redeem_enabled: value.redeem_enabled,
  rupiah_per_redeem_point: value.rupiah_per_redeem_point ?? "",
  minimum_redeem_points: value.minimum_redeem_points ?? "",
});
const money = (value: string) => value ? formatRupiah(value) : "—";

export function MemberPointsSettingsForm({ settings, canEdit }: { settings: MemberPointsSettings; canEdit: boolean }) {
  const router = useRouter();
  const [form, setForm] = useState(() => stateFrom(settings));
  const [notice, setNotice] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, startTransition] = useTransition();
  const initial = stateFrom(settings);
  const changed = JSON.stringify(form) !== JSON.stringify(initial);
  const valid = (!form.program_enabled || /^[1-9][0-9]{0,8}$/.test(form.rupiah_per_point))
    && (!form.redeem_enabled || (/^[1-9][0-9]{0,8}$/.test(form.rupiah_per_redeem_point)
      && /^[1-9][0-9]{0,8}$/.test(form.minimum_redeem_points)));

  function update<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((current) => ({ ...current, [key]: value }));
    setNotice(null);
  }

  function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!canEdit || pending || !changed || !valid) return;
    startTransition(async () => {
      const result = await updateMemberPointsSettings(form);
      setNotice({ ok: result.ok, text: result.message });
      if (result.ok) router.refresh();
    });
  }

  const earnPreview = form.rupiah_per_point && /^[1-9][0-9]{0,8}$/.test(form.rupiah_per_point)
    ? Math.floor(100_000 / Number(form.rupiah_per_point)) : null;
  const redeemPreview = form.rupiah_per_redeem_point && form.minimum_redeem_points
    && /^[1-9][0-9]{0,8}$/.test(form.rupiah_per_redeem_point) && /^[1-9][0-9]{0,8}$/.test(form.minimum_redeem_points)
    ? (BigInt(form.rupiah_per_redeem_point) * BigInt(form.minimum_redeem_points)).toString() : null;

  return <form className={styles.form} onSubmit={submit}>
    <section className={styles.formSection}>
      <header><h2>Program Member</h2><p>Pengaturan baru berlaku untuk transaksi berikutnya. Riwayat dan saldo poin tetap tersimpan.</p></header>
      <div className={styles.posSettingRows}>
        <div className={styles.posSettingRow}><span><strong>Program Poin Member</strong><small>{form.program_enabled ? "Poin berlaku sesuai aturan yang disimpan." : "Program nonaktif. Member tetap dapat dipilih di kasir."}</small></span><QuenaSwitch label="Program Poin Member" checked={form.program_enabled} onCheckedChange={(checked) => update("program_enabled", checked)} disabled={!canEdit || pending} /></div>
      </div>
    </section>

    <section className={styles.formSection}>
      <header><h2>Perolehan Poin</h2><p>Poin dihitung dari nilai belanja barang setelah potongan penukaran poin.</p></header>
      <label className={styles.posFooterField}>Dapat 1 poin setiap belanja
        <RupiahInput aria-label="Rupiah untuk mendapatkan satu poin" value={form.rupiah_per_point} onValueChange={(value) => update("rupiah_per_point", value)} currencyPrefix={false} readOnly={!canEdit || pending} placeholder="10.000" />
        <small>Contoh pratinjau untuk belanja Rp 100.000: {earnPreview === null ? "isi nilai belanja per poin" : `${new Intl.NumberFormat("id-ID").format(earnPreview)} poin`}. Pratinjau memakai nilai yang sedang diisi.</small>
      </label>
    </section>

    <section className={styles.formSection}>
      <header><h2>Penukaran Poin</h2><p>Potongan poin mengurangi jumlah yang dibayar dan tidak dapat menghasilkan uang kembalian.</p></header>
      <div className={styles.posSettingRows}>
        <div className={styles.posSettingRow}><span><strong>Izinkan Tukar Poin</strong><small>Penukaran hanya tersedia jika program poin aktif.</small></span><QuenaSwitch label="Izinkan Tukar Poin" checked={form.redeem_enabled} onCheckedChange={(checked) => update("redeem_enabled", checked)} disabled={!canEdit || pending} /></div>
      </div>
      <div className={styles.fields}>
        <label>Nilai 1 poin<RupiahInput aria-label="Nilai rupiah satu poin" value={form.rupiah_per_redeem_point} onValueChange={(value) => update("rupiah_per_redeem_point", value)} currencyPrefix={false} readOnly={!canEdit || pending} placeholder="100" /></label>
        <label>Minimum penukaran<input type="text" inputMode="numeric" value={form.minimum_redeem_points} onChange={(event) => update("minimum_redeem_points", event.target.value.replace(/\D/g, "").slice(0, 9))} readOnly={!canEdit || pending} placeholder="100" /><small>poin</small></label>
      </div>
      <p className={styles.posSectionHint}>{redeemPreview === null ? "Isi nilai dan minimum penukaran untuk melihat pratinjau." : `${new Intl.NumberFormat("id-ID").format(Number(form.minimum_redeem_points))} poin → ${money(String(redeemPreview))}. Pratinjau memakai nilai yang sedang diisi.`}</p>
    </section>

    {form.program_enabled && !form.rupiah_per_point && <p className={styles.posValidation} role="alert">Isi nilai belanja per poin sebelum menyimpan.</p>}
    {form.redeem_enabled && (!form.rupiah_per_redeem_point || !form.minimum_redeem_points) && <p className={styles.posValidation} role="alert">Isi nilai dan minimum penukaran sebelum menyimpan.</p>}
    <div className={styles.formFooter}>
      <span>{settings.updated_at ? `Terakhir diperbarui ${new Date(settings.updated_at).toLocaleString("id-ID", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Jakarta" })}` : "Belum pernah diperbarui"}</span>
      {canEdit && <button className={buttons.primary} type="submit" disabled={pending || !changed || !valid}>{pending ? "Menyimpan..." : "Simpan Perubahan"}</button>}
    </div>
    {notice && <p role={notice.ok ? "status" : "alert"} className={`${styles.notice} ${notice.ok ? styles.success : styles.error}`}>{notice.text}</p>}
  </form>;
}
