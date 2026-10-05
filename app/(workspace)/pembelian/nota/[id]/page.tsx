import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readInvoiceDetail, readLinkableReceipts } from "@/lib/purchasing/finance-read";
import { isUuid } from "@/lib/purchasing/receipt-model";
import { PurchaseInvoiceEditor } from "@/components/purchasing/purchase-invoice-editor";

export default async function InvoiceDetailPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ receipt?: string }> }) {
  const profile = await requireProfile();
  if (!profile.is_active || !["OWNER", "ADMIN"].includes(profile.role)) redirect("/dashboard");
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const invoice = await readInvoiceDetail(profile, id);
  if (!invoice) notFound();
  const linkableReceipts = await readLinkableReceipts(profile, invoice);
  const query = await searchParams;
  const initialReceiptId = typeof query.receipt === "string" && linkableReceipts.some((receipt) => receipt.id === query.receipt) ? query.receipt : undefined;
  return <main className="page-content purchasing-page"><Link className="purchase-back" href="/pembelian/nota">← Nota & pembayaran</Link><PurchaseInvoiceEditor key={id} invoice={invoice} linkableReceipts={linkableReceipts} initialReceiptId={initialReceiptId}/></main>;
}
