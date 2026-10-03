import { redirect } from "next/navigation";
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
    <div className="eyebrow">PERSEDIAAN OUTLET · BACA SAJA</div>
    <div className="page-heading stock-heading">
      <div><h1>Stok</h1><p>Saldo efektif dari proyeksi stok Quena Mart{data.outletName ? ` · ${data.outletName}` : ""}.</p></div>
      <span className="stock-readonly-badge">Baca saja</span>
    </div>
    <StockWorkspace data={data} />
  </main>;
}
