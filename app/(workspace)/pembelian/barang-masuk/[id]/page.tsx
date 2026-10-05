import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readReceiptDetail } from "@/lib/purchasing/receipt-read";
import { PurchaseReceiptEditor } from "@/components/purchasing/purchase-receipt-editor";
import { isUuid } from "@/lib/purchasing/receipt-model";
import { readInvoiceDetail, readLinkableReceipts, readReceiptInvoiceId } from "@/lib/purchasing/finance-read";
import { PurchaseInvoiceEditor } from "@/components/purchasing/purchase-invoice-editor";

export default async function ReceiptDetailPage({ params }: { params: Promise<{id:string}> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role,"pembelian")) redirect("/dashboard");
  const {id}=await params;
  if(!isUuid(id)) notFound();
  const receipt=await readReceiptDetail(profile,id);
  if(!receipt) notFound();
  const isManager = profile.role === "OWNER" || profile.role === "ADMIN";
  const invoiceId = isManager ? await readReceiptInvoiceId(profile, id) : null;
  const invoice = isManager && invoiceId ? await readInvoiceDetail(profile, invoiceId) : null;
  const linkableReceipts = invoice ? await readLinkableReceipts(profile, invoice) : [];
  return <main className="page-content purchasing-page"><Link className="purchase-back" href="/pembelian/barang-masuk">← Daftar barang masuk</Link><PurchaseReceiptEditor key={receipt.id} receipt={receipt}/>
    {isManager && (invoice ? <PurchaseInvoiceEditor invoice={invoice} linkableReceipts={linkableReceipts} initialReceiptId={receipt.id}/> : <section className="surface-card purchase-finance-section"><h2>Nota & pembayaran</h2><p>{receipt.status === "POSTED" ? "Stok sudah diposting. Nota dapat dilengkapi kapan saja dan tidak akan memposting stok kembali." : "Catat nilai nota terpisah dari stok. Barang masuk tetap dapat diposting tanpa nota."}</p><Link className="purchase-secondary purchase-link-button" href={`/pembelian/nota/baru?receipt=${receipt.id}`}>Lengkapi nota</Link></section>)}
  </main>;
}
