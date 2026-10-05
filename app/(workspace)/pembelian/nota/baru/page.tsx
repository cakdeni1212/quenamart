import Link from "next/link";
import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readInvoiceCreateOptions } from "@/lib/purchasing/finance-read";
import { InvoiceCreateForm } from "@/components/purchasing/invoice-create-form";

export default async function NewInvoicePage({ searchParams }: { searchParams: Promise<{ receipt?: string }> }) {
  const profile = await requireProfile();
  if (!profile.is_active || !["OWNER", "ADMIN"].includes(profile.role)) redirect("/dashboard");
  const { receipt: receiptId } = await searchParams;
  const options = await readInvoiceCreateOptions(profile, receiptId);
  return <main className="page-content purchasing-page"><Link className="purchase-back" href={receiptId ? `/pembelian/barang-masuk/${receiptId}` : "/pembelian/nota"}>← Kembali</Link>
    <div className="eyebrow">PEMBELIAN · NOTA</div><div className="page-heading"><div><h1>Nota supplier</h1><p>Nota dapat dicatat sebelum atau sesudah barang diterima. Ini tidak mengubah stok.</p></div></div>
    {options.suppliers.length ? <InvoiceCreateForm suppliers={options.suppliers} outletId={options.outletId} initialSupplierId={options.receipt?.supplier_id} receiptId={options.receipt?.id} receipts={options.receipt ? [{ id: options.receipt.id, reference: options.receipt.receipt_reference, status: "", receivedAt: "" }] : []} /> : <div className="surface-card purchase-empty">Supplier aktif belum tersedia.</div>}
  </main>;
}
