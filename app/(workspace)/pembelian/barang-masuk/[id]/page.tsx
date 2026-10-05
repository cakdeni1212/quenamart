import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readReceiptDetail } from "@/lib/purchasing/receipt-read";
import { PurchaseReceiptEditor } from "@/components/purchasing/purchase-receipt-editor";
import { isUuid } from "@/lib/purchasing/receipt-model";

export default async function ReceiptDetailPage({ params }: { params: Promise<{id:string}> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role,"pembelian")) redirect("/dashboard");
  const {id}=await params;
  if(!isUuid(id)) notFound();
  const receipt=await readReceiptDetail(profile,id);
  if(!receipt) notFound();
  return <main className="page-content purchasing-page"><Link className="purchase-back" href="/pembelian/barang-masuk">← Daftar barang masuk</Link><PurchaseReceiptEditor key={receipt.id} receipt={receipt}/></main>;
}
