"use client";

import { useActionState } from "react";
import { saveSupplier, type ActionState } from "@/lib/purchasing/actions";
import type { Supplier } from "@/lib/purchasing/receipt-read";

function SupplierForm({ supplier }: { supplier?: Supplier }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(saveSupplier, { error: null });
  return <form action={action} className="purchase-supplier-form">
    {supplier && <input type="hidden" name="supplier_id" value={supplier.id} />}
    <label>Nama supplier<input name="display_name" required maxLength={160} defaultValue={supplier?.display_name ?? ""} /></label>
    <label>Nama legal <span>(opsional)</span><input name="legal_name" maxLength={200} defaultValue={supplier?.legal_name ?? ""} /></label>
    <label>Kontak <span>(opsional)</span><input name="contact_name" maxLength={120} defaultValue={supplier?.contact_name ?? ""} /></label>
    <label>Telepon <span>(opsional)</span><input name="phone" maxLength={40} defaultValue={supplier?.phone ?? ""} /></label>
    {supplier && <label className="purchase-active-toggle"><input type="hidden" name="is_active" value="false" /><input type="checkbox" name="is_active" value="true" defaultChecked={supplier.is_active} /> Supplier aktif</label>}
    {state.error && <p className="purchase-action-error" role="alert">{state.error}</p>}
    {state.success && <p className="purchase-action-success" role="status">{state.success}</p>}
    <button className="purchase-primary" disabled={pending}>{supplier ? "Simpan perubahan" : "Tambah supplier"}</button>
  </form>;
}

export function SupplierManagement({ suppliers, canManage, search }: { suppliers: Supplier[]; canManage: boolean; search: string }) {
  return <div className="purchase-layout">
    {canManage && <section className="surface-card purchase-panel"><div className="purchase-section-heading"><div><h2>Supplier baru</h2><p>Tambahkan identitas supplier untuk barang masuk.</p></div></div><SupplierForm /></section>}
    <section className="surface-card purchase-panel"><div className="purchase-section-heading"><div><h2>Daftar supplier</h2><p>{suppliers.length} supplier ditampilkan · maksimal 100 hasil</p></div></div>
      <form className="purchase-search-row purchase-supplier-search" method="get"><input name="q" defaultValue={search} placeholder="Cari nama supplier" /><button type="submit">Cari</button></form>
      {suppliers.length === 0 ? <div className="purchase-empty">Supplier belum ditemukan.</div> : <ul className="purchase-supplier-list">{suppliers.map((supplier) => <li key={supplier.id}>
        <div><strong>{supplier.display_name}</strong><span>{supplier.supplier_code}{supplier.contact_name ? ` · ${supplier.contact_name}` : ""}{supplier.phone ? ` · ${supplier.phone}` : ""}</span></div>
        <span className={`purchase-status ${supplier.is_active ? "purchase-status-posted" : "purchase-status-draft"}`}>{supplier.is_active ? "Aktif" : "Nonaktif"}</span>
        {canManage && <details><summary>Edit</summary><SupplierForm supplier={supplier} /></details>}
      </li>)}</ul>}
    </section>
  </div>;
}
