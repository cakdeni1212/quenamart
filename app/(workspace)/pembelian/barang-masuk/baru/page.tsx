import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readReceiptDetail, readSuppliers } from "@/lib/purchasing/receipt-read";
import { isUuid } from "@/lib/purchasing/receipt-model";
import { readInvoiceDetail, readReceiptInvoiceId } from "@/lib/purchasing/finance-read";
import { PurchaseReceiptWorkflow } from "@/components/purchasing/purchase-receipt-workflow";
import { NewReceiptStart } from "@/components/purchasing/new-receipt-start";

export default async function NewReceiptPage({ searchParams }: { searchParams: Promise<Record<string,string|string[]|undefined>> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role,"pembelian")) redirect("/dashboard");
  const params = await searchParams;
  const requestedReceipt = typeof params.receipt === "string" ? params.receipt : "";
  const requestedSupplier = typeof params.supplier === "string" ? params.supplier : "";

  if (requestedReceipt) {
    if (!isUuid(requestedReceipt)) notFound();
    const receipt = await readReceiptDetail(profile, requestedReceipt);
    if (!receipt) notFound();
    if (receipt.status === "POSTED") redirect(`/pembelian/barang-masuk/${receipt.id}`);
    const manager = profile.role === "OWNER" || profile.role === "ADMIN";
    const invoiceId = manager ? await readReceiptInvoiceId(profile, receipt.id) : null;
    const invoice = manager && invoiceId ? await readInvoiceDetail(profile, invoiceId) : null;
    return <main className="page-content purchasing-page"><Link className="purchase-back" href="/pembelian/barang-masuk">← Barang masuk</Link>
      <PurchaseReceiptWorkflow key={receipt.id} receipt={receipt} manager={manager} invoice={invoice} linkableReceipts={[]}/>
    </main>;
  }

  const suppliers = await readSuppliers(profile,false);
  const actorName = profile.full_name?.trim() || "Pengguna aktif";
  return <main className="page-content purchasing-page"><Link className="purchase-back" href="/pembelian/barang-masuk">← Barang masuk</Link><div className="eyebrow">PEMBELIAN · PENERIMAAN BARU</div><div className="page-heading"><div><h1>Barang Masuk Baru</h1><p>Pilih supplier untuk langsung membuka formulir penerimaan dan pemindaian barang.</p></div></div>
    {suppliers.length === 0 ? <div className="surface-card purchase-empty">Belum ada supplier aktif. Minta OWNER atau ADMIN menambahkan supplier terlebih dahulu.</div> : <NewReceiptStart suppliers={suppliers} actorName={actorName} preselectedSupplierId={requestedSupplier}/>}
  </main>;
}
