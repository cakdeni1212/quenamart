import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readSupplierDetail } from "@/lib/purchasing/supplier-workspace-read";
import { SupplierDetailWorkspace } from "@/components/purchasing/supplier-detail-workspace";

export default async function SupplierDetailPage({ params, searchParams }: { params: Promise<{ supplierId: string }>; searchParams: Promise<Record<string,string|string[]|undefined>> }) {
  const profile = await requireProfile();
  if (!["OWNER", "ADMIN"].includes(profile.role)) redirect("/pembelian/supplier");
  const [{ supplierId }, query] = await Promise.all([params, searchParams]);
  const page = typeof query.page === "string" ? Number(query.page) : 1;
  const data = await readSupplierDetail(profile, supplierId, page);
  if (!data) notFound();
  return <main className="page-content purchasing-page supplier-page"><Link className="purchase-back" href="/pembelian/supplier">← Supplier</Link><SupplierDetailWorkspace data={data}/></main>;
}
