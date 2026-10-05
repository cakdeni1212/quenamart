import { redirect } from "next/navigation";
import Link from "next/link";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readSuppliers } from "@/lib/purchasing/receipt-read";
import { SupplierManagement } from "@/components/purchasing/supplier-management";

export default async function SupplierPage({ searchParams }: { searchParams: Promise<Record<string,string|string[]|undefined>> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role,"pembelian")) redirect("/dashboard");
  const params = await searchParams;
  const search = typeof params.q === "string" ? params.q.slice(0,80) : "";
  const suppliers = await readSuppliers(profile, profile.role !== "GUDANG", search);
  return <main className="page-content purchasing-page"><Link className="purchase-back" href="/pembelian">← Pembelian</Link><div className="eyebrow">PEMBELIAN · DATA OPERASIONAL</div><div className="page-heading"><div><h1>Supplier</h1><p>Daftar supplier untuk pencatatan barang masuk.</p></div></div>
    <SupplierManagement suppliers={suppliers} canManage={profile.role === "OWNER" || profile.role === "ADMIN"} search={search}/>
  </main>;
}
