import Link from "next/link";
import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";

export default async function PurchasingHomePage() {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "pembelian")) redirect("/dashboard");
  return <main className="page-content purchasing-page"><div className="eyebrow">OPERASIONAL OUTLET</div><div className="page-heading"><div><h1>Pembelian</h1><p>Catat barang yang benar-benar diterima dan tambahkan ke stok efektif.</p></div></div>
    <div className="purchase-nav-grid"><Link className="surface-card purchase-nav-card" href="/pembelian/barang-masuk"><span aria-hidden="true">↓</span><strong>Barang masuk</strong><small>Buat, posting, dan lihat riwayat penerimaan barang.</small></Link>
      <Link className="surface-card purchase-nav-card" href="/pembelian/supplier"><span aria-hidden="true">♧</span><strong>Supplier</strong><small>Cari identitas supplier untuk proses penerimaan.</small></Link></div>
    <p className="purchase-operational-note">Stok bertambah saat penerimaan diposting. Informasi harga dan pembayaran tidak dikelola di alur ini.</p>
  </main>;
}
