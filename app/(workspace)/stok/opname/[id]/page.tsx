import { notFound, redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readStockOpnameCounting } from "@/lib/stock/opname-count-read";
import { StockOpnameCounting } from "@/components/stock/stock-opname-counting";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export default async function StockOpnameDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "stok")) redirect("/dashboard");
  const { id } = await params;
  if (!UUID_PATTERN.test(id)) notFound();
  const query = await searchParams;
  const data = await readStockOpnameCounting(profile, id, query);
  return <main className="page-content stock-opname-page">
    <StockOpnameCounting data={data} />
  </main>;
}
