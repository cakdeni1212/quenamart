import { redirect } from "next/navigation";
import Link from "next/link";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readStockOpnameList } from "@/lib/stock/opname-list-read";
import { StockOpnameList } from "@/components/stock/stock-opname-list";

type SearchParams = Record<string, string | string[] | undefined>;

export default async function StockOpnamePage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "stok")) redirect("/dashboard");

  const data = await readStockOpnameList(profile, await searchParams);
  return <main className="page-content stock-opname-page">
    <Link className="stock-opname-back" href="/stok">← Kembali ke Stok</Link>
    <div className="eyebrow">PERSEDIAAN OUTLET · BACA SAJA</div>
    <div className="page-heading stock-opname-heading">
      <div><h1>Stock Opname</h1><p>Daftar sesi opname dan statusnya. Tindakan opname belum tersedia di halaman ini.</p></div>
      <div className="stock-heading-actions"><Link className="stock-opname-link" href="/stok/opname/baru">Buat sesi</Link><span className="stock-readonly-badge">Baca saja</span></div>
    </div>
    <StockOpnameList data={data} />
  </main>;
}
