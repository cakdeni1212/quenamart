import Link from "next/link";
import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readSuppliers } from "@/lib/purchasing/receipt-read";
import { createReceiptDraft } from "@/lib/purchasing/actions";

export default async function NewReceiptPage({ searchParams }: { searchParams: Promise<Record<string,string|string[]|undefined>> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role,"pembelian")) redirect("/dashboard");
  const suppliers = await readSuppliers(profile,false);
  const params = await searchParams;
  const error = typeof params.error === "string" ? params.error : "";
  const now = new Date(); const localNow = new Date(now.getTime()-now.getTimezoneOffset()*60000).toISOString().slice(0,16);
  return <main className="page-content purchasing-page"><Link className="purchase-back" href="/pembelian/barang-masuk">← Barang masuk</Link><div className="eyebrow">PEMBELIAN · PENERIMAAN BARU</div><div className="page-heading"><div><h1>Barang masuk baru</h1><p>Catat supplier dan waktu barang diterima secara fisik.</p></div></div>
    {error && <p className="purchase-action-error" role="alert">Draf belum dapat dibuat. Periksa supplier dan outlet aktif.</p>}
    {suppliers.length === 0 ? <div className="surface-card purchase-empty">Belum ada supplier aktif. Minta OWNER atau ADMIN menambahkan supplier terlebih dahulu.</div> : <form action={createReceiptDraft} className="surface-card purchase-create-form">
      <label>Supplier<select name="supplier_id" required defaultValue=""><option value="" disabled>Pilih supplier</option>{suppliers.map((supplier)=><option key={supplier.id} value={supplier.id}>{supplier.display_name} · {supplier.supplier_code}</option>)}</select></label>
      <label>Tanggal barang diterima<input name="received_at" type="datetime-local" required defaultValue={localNow}/></label>
      <label>Catatan operasional <span>(opsional)</span><textarea name="operational_note" maxLength={1000}/></label>
      <button className="purchase-primary">Lanjutkan ke barang</button>
    </form>}
  </main>;
}
