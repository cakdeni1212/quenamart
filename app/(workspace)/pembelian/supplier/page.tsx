import { redirect } from "next/navigation";
import Link from "next/link";
import { requireProfile } from "@/lib/auth/session";
import { readSupplierWorkspace } from "@/lib/purchasing/supplier-workspace-read";
import { SupplierWorkspace } from "@/components/purchasing/supplier-workspace";

export default async function SupplierPage({ searchParams }: { searchParams: Promise<Record<string,string|string[]|undefined>> }) {
  const profile = await requireProfile();
  if (!["OWNER", "ADMIN", "GUDANG"].includes(profile.role)) redirect("/dashboard");
  const params = await searchParams;
  const search = typeof params.q === "string" ? params.q.slice(0,80) : "";
  const status = typeof params.status === "string" ? params.status : "";
  const tempo = typeof params.tempo === "string" ? params.tempo : "";
  const page = typeof params.page === "string" ? Number(params.page) : 1;
  const data = await readSupplierWorkspace(profile, { search, status, tempo, page });
  return <main className="page-content purchasing-page supplier-page">
    <Link className="purchase-back" href="/pembelian">← Pembelian</Link>
    <SupplierWorkspace data={data} search={search} status={status} tempo={tempo} canManage={profile.role === "OWNER" || profile.role === "ADMIN"} canSeeFinance={profile.role === "OWNER" || profile.role === "ADMIN"}/>
  </main>;
}
