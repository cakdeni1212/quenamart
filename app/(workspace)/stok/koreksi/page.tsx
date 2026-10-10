import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readManualCorrectionWorkspace } from "@/lib/stock/manual-correction-read";
import { ManualStockCorrectionWorkspace } from "@/components/stock/manual-stock-correction-workspace";

export default async function ManualStockCorrectionPage() {
  const profile = await requireProfile();
  if (!['OWNER','ADMIN'].includes(profile.role)) redirect('/dashboard');
  const data = await readManualCorrectionWorkspace();
  return <main className="page-content stock-page manual-stock-correction-page">
    <div className="page-heading"><div><span className="eyebrow">PERSEDIAAN OUTLET</span><h1>Koreksi Stok</h1><p>Perubahan stok manual untuk pengecualian yang terdokumentasi. Koreksi tidak menetapkan nilai modal.</p></div></div>
    {data.error || !data.outletId || !data.outletName
      ? <section className="surface-card" role="alert">{data.error ?? "Outlet stok belum tersedia."}</section>
      : <ManualStockCorrectionWorkspace outletId={data.outletId} outletName={data.outletName} corrections={data.corrections} />}
  </main>;
}
