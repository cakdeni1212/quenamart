import { redirect } from "next/navigation";
import Link from "next/link";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readStockOpnameCreateInfo } from "@/lib/stock/opname-create-read";
import { StockOpnameCreateForm } from "@/components/stock/stock-opname-create-form";

export default async function NewStockOpnamePage() {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "stok")) redirect("/dashboard");

  const info = await readStockOpnameCreateInfo(profile);
  return <main className="page-content stock-opname-page">
    <Link className="stock-opname-back" href="/stok/opname">← Kembali ke daftar opname</Link>
    <div className="eyebrow">PERSEDIAAN OUTLET · BUAT SESI</div>
    <div className="page-heading stock-opname-heading">
      <div><h1>Opname Baru</h1><p>Buat sesi pencatatan fisik. Saldo stok tidak berubah saat sesi dibuat.</p></div>
    </div>
    <StockOpnameCreateForm info={info} />
  </main>;
}
