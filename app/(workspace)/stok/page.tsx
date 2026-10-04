import { redirect } from "next/navigation";
import Link from "next/link";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readStockWorkspace } from "@/lib/stock/read";
import { StockWorkspace } from "@/components/stock/stock-workspace";

type SearchParams = Record<string, string | string[] | undefined>;

export default async function StockPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "stok")) redirect("/dashboard");
  const data = await readStockWorkspace(profile, await searchParams);

  return <main className="page-content stock-page">
    <div className="eyebrow">PERSEDIAAN OUTLET</div>
    <div className="page-heading stock-heading">
      <div><h1>Stok</h1><p>Saldo efektif dari proyeksi stok Quena Mart. Perubahan stok dilakukan melalui alur terkontrol seperti Stock Opname{data.outletName ? ` · ${data.outletName}` : ""}.</p></div>
      <div className="stock-heading-actions"><Link className="stock-opname-link" href="/stok/opname">Daftar opname</Link></div>
    </div>
    <StockWorkspace data={data} />
  </main>;
}
