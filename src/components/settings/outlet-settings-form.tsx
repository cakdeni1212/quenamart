"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition, type FormEvent } from "react";
import { updateOutletSettings, type OutletSettingsInput } from "@/app/actions/outlet-settings";
import type { OutletSettings } from "@/lib/settings/outlet";
import styles from "@/components/settings/settings.module.css";

type EditableFields = Omit<OutletSettingsInput, "id" | "is_active">;

function fieldsFrom(outlet: OutletSettings): EditableFields {
  return {
    name: outlet.name ?? "",
    customer_display_name: outlet.customer_display_name ?? "",
    address: outlet.address ?? "",
    city: outlet.city ?? "",
    province: outlet.province ?? "",
    postal_code: outlet.postal_code ?? "",
    phone: outlet.phone ?? "",
    whatsapp: outlet.whatsapp ?? "",
    email: outlet.email ?? "",
  };
}

export function OutletSettingsForm({ outlet, canEdit }: { outlet: OutletSettings; canEdit: boolean }) {
  const router = useRouter();
  const [fields, setFields] = useState(() => fieldsFrom(outlet));
  const [isActive, setIsActive] = useState(outlet.is_active);
  const [notice, setNotice] = useState<{ kind: "success" | "error"; text: string } | null>(null);
  const [pending, startTransition] = useTransition();
  const initial = fieldsFrom(outlet);
  const changed = isActive !== outlet.is_active || Object.keys(initial).some((key) => {
    const field = key as keyof EditableFields;
    return fields[field].trim() !== initial[field].trim();
  });
  const statusLocked = outlet.is_active && !outlet.can_deactivate;

  function setField(field: keyof EditableFields, value: string) {
    setFields((current) => ({ ...current, [field]: value }));
    setNotice(null);
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!canEdit || pending || !changed) return;
    const payload: OutletSettingsInput = { id: outlet.id, ...fields, is_active: isActive };
    startTransition(async () => {
      const result = await updateOutletSettings(payload);
      setNotice({ kind: result.ok ? "success" : "error", text: result.message });
      if (result.ok) router.refresh();
    });
  }

  return <form className={styles.form} onSubmit={submit}>
    <section className={styles.formSection}>
      <header><h2>Informasi Toko</h2><p>Identitas utama yang digunakan pada ruang kerja.</p></header>
      <div className={styles.fields}>
        <label>Nama Outlet <span>*</span><input required maxLength={120} value={fields.name} onChange={(event) => setField("name", event.target.value)} readOnly={!canEdit} /></label>
        <label>Nama yang tampil ke pelanggan<input maxLength={160} value={fields.customer_display_name} onChange={(event) => setField("customer_display_name", event.target.value)} readOnly={!canEdit} placeholder="Mengikuti nama outlet bila dikosongkan" /></label>
        <label>Kode Outlet<input value={outlet.code} readOnly aria-readonly="true" /><small>Kode outlet merupakan identitas tetap dan tidak dapat diubah.</small></label>
      </div>
    </section>

    <section className={styles.formSection}>
      <header><h2>Kontak</h2><p>Informasi ini dapat ditampilkan pada struk.</p></header>
      <div className={styles.fields}>
        <label>Nomor Telepon<input type="tel" maxLength={40} value={fields.phone} onChange={(event) => setField("phone", event.target.value)} readOnly={!canEdit} /></label>
        <label>WhatsApp<input type="tel" maxLength={40} value={fields.whatsapp} onChange={(event) => setField("whatsapp", event.target.value)} readOnly={!canEdit} /></label>
        <label>Email<input type="email" maxLength={254} value={fields.email} onChange={(event) => setField("email", event.target.value)} readOnly={!canEdit} /></label>
      </div>
    </section>

    <section className={styles.formSection}>
      <header><h2>Lokasi</h2><p>Alamat tidak wajib diisi jika belum tersedia.</p></header>
      <div className={styles.fields}>
        <label className={styles.wide}>Alamat<input maxLength={300} value={fields.address} onChange={(event) => setField("address", event.target.value)} readOnly={!canEdit} /></label>
        <label>Kota/Kabupaten<input maxLength={100} value={fields.city} onChange={(event) => setField("city", event.target.value)} readOnly={!canEdit} /></label>
        <label>Provinsi<input maxLength={100} value={fields.province} onChange={(event) => setField("province", event.target.value)} readOnly={!canEdit} /></label>
        <label>Kode Pos<input maxLength={20} value={fields.postal_code} onChange={(event) => setField("postal_code", event.target.value)} readOnly={!canEdit} /></label>
      </div>
    </section>

    <section className={styles.formSection}>
      <header><h2>Operasional</h2><p>Zona waktu mengikuti batas hari operasional Quena Mart.</p></header>
      <div className={styles.fields}>
        <label>Zona Waktu<input value="Asia/Jakarta" readOnly aria-readonly="true" /><small>Zona waktu tidak dapat diubah agar tanggal historis tetap konsisten.</small></label>
        <label>Status Outlet<select value={isActive ? "ACTIVE" : "INACTIVE"} disabled={!canEdit || statusLocked} onChange={(event) => { setIsActive(event.target.value === "ACTIVE"); setNotice(null); }}><option value="ACTIVE">Aktif</option><option value="INACTIVE">Nonaktif</option></select>{statusLocked && <small>Outlet ini sedang digunakan untuk operasional aktif.</small>}</label>
      </div>
    </section>

    <div className={styles.formFooter}>
      {outlet.updated_at && <span>Terakhir diperbarui {new Date(outlet.updated_at).toLocaleString("id-ID", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Jakarta" })}</span>}
      {canEdit && <button className="button-primary" type="submit" disabled={pending || !changed}>{pending ? "Menyimpan…" : "Simpan Perubahan"}</button>}
    </div>
    {notice && <p role="status" className={`${styles.notice} ${notice.kind === "success" ? styles.success : styles.error}`}>{notice.text}</p>}
  </form>;
}
