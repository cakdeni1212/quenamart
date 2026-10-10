import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readSupplierReturnWorkspace } from "@/lib/stock/supplier-return-read";
import { SupplierReturnWorkspace } from "@/components/purchasing/supplier-return-workspace";

export default async function SupplierReturnPage() {
  const profile = await requireProfile();
  if (!["OWNER", "ADMIN", "GUDANG"].includes(profile.role)) redirect("/dashboard");
  const data = await readSupplierReturnWorkspace();
  return <main className="page-content supplier-return-page">
    <div className="page-heading"><div><span className="eyebrow">PEMBELIAN · RETUR FISIK</span><h1>Retur Supplier</h1>
      <p>Catat barang yang dikembalikan kepada supplier. Retur mengurangi stok; nota dan pembayaran supplier tetap dikelola terpisah.</p></div></div>
    {data.error || !data.outletId || !data.outletName
      ? <section className="surface-card" role="alert">{data.error ?? "Outlet stok belum tersedia."}</section>
      : <SupplierReturnWorkspace outletId={data.outletId} outletName={data.outletName} suppliers={data.suppliers} returns={data.returns} canPost={["OWNER", "ADMIN"].includes(profile.role)} />}
  </main>;
}
