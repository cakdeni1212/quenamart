import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readReceiptDetail } from "@/lib/purchasing/receipt-read";
import { PurchaseReceiptWorkflow } from "@/components/purchasing/purchase-receipt-workflow";
import { isUuid } from "@/lib/purchasing/receipt-model";
import { readInvoiceDetail, readReceiptInvoiceId } from "@/lib/purchasing/finance-read";

export default async function ReceiptDetailPage({ params, searchParams }: { params: Promise<{id:string}>; searchParams: Promise<{ mode?: string }> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role,"pembelian")) redirect("/dashboard");
  const {id}=await params;
  const query=await searchParams;
  if(!isUuid(id)) notFound();
  const receipt=await readReceiptDetail(profile,id);
  if(!receipt) notFound();
  const isManager = profile.role === "OWNER" || profile.role === "ADMIN";
  const invoiceId = isManager && receipt.status !== "CANCELLED" ? await readReceiptInvoiceId(profile, id) : null;
  const invoice = isManager && invoiceId ? await readInvoiceDetail(profile, invoiceId) : null;
  return <main className="page-content purchasing-page"><Link className="purchase-back" href="/pembelian/barang-masuk">← Daftar barang masuk</Link>
    <PurchaseReceiptWorkflow key={`${receipt.id}:${invoice?.header.id ?? "no-invoice"}`} receipt={receipt} manager={isManager} invoice={invoice} linkableReceipts={[]} viewOnly={query.mode === "view"}/>
  </main>;
}
