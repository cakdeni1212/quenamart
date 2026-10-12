import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { readPosSaleReceipt } from "@/app/actions/pos-cart";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { salesDateTime, salesMoney, salesPaymentLabel, salesQuantity } from "@/lib/sales/presentation";
import type { PosReceiptData } from "@/components/pos/pos-receipt";
import { ReceiptReprint } from "@/components/sales/receipt-reprint";
import styles from "@/components/sales/sales-history.module.css";

export default async function TransactionDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "transaksi")) redirect("/dashboard");
  const { id } = await params;
  const result = await readPosSaleReceipt(id);
  if (!result.ok || !result.value || !Array.isArray(result.value.items) || !Array.isArray(result.value.payments)) notFound();
  const receipt = result.value as unknown as PosReceiptData;

  return <main className={`page-content ${styles.page}`}>
    <header className={styles.heading}>
      <div><div className="eyebrow">DETAIL TRANSAKSI</div><h1>Transaksi</h1><p>Rincian penjualan selesai berdasarkan bukti transaksi.</p></div>
      <Link className={styles.secondary} href="/transaksi">Kembali</Link>
    </header>
    <section className={styles.detailCard}>
      <div className={styles.detailHeader}><div><h2>{receipt.sale_number}</h2><span className={styles.subtle}>{salesDateTime(receipt.completed_at)}</span></div><span className={`${styles.badge} ${styles.status}`}>Selesai</span></div>
      <div className={styles.metaGrid}>
        <div className={styles.meta}><span>Kasir</span><strong>{receipt.cashier_label}</strong></div>
        <div className={styles.meta}><span>No. Transaksi</span><strong>{receipt.sale_number}</strong></div>
        <div className={styles.meta}><span>Status</span><strong>Selesai</strong></div>
      </div>
      <div>
        <div className="eyebrow">BARANG</div>
        <table className={styles.items}><thead><tr><th>PRODUK</th><th>QTY</th><th>HARGA</th><th>JUMLAH</th></tr></thead><tbody>
          {receipt.items.map((item, index) => <tr key={`${String(item.sku ?? "item")}-${index}`}>
            <td><span className={styles.itemName}>{String(item.name ?? "Barang")}</span>{item.sku !== null && item.sku !== undefined && <span className={styles.subtle}>{String(item.sku)}</span>}</td>
            <td>{salesQuantity(item.quantity)}{item.unit !== null && item.unit !== undefined ? ` ${String(item.unit)}` : ""}</td>
            <td>{salesMoney(item.unit_selling_price)}</td><td>{salesMoney(item.line_subtotal)}</td>
          </tr>)}
        </tbody></table>
      </div>
      <div className={styles.meta}><span>PEMBAYARAN</span><div className={styles.paymentList}>
        {receipt.payments.map((payment, index) => <div key={`${String(payment.method)}-${index}`}>
          <div className={styles.payment}><span>{salesPaymentLabel(payment.method)}</span><strong>{salesMoney(payment.applied_amount)}</strong></div>
          {payment.method === "CASH" && <>
            <div className={styles.payment}><span>Uang diterima</span><strong>{salesMoney(payment.received_amount)}</strong></div>
            <div className={styles.payment}><span>Kembalian</span><strong>{salesMoney(payment.change_amount)}</strong></div>
          </>}
          {payment.reference_text !== null && payment.reference_text !== undefined && <span className={styles.reference}>Referensi: {String(payment.reference_text)}</span>}
        </div>)}
      </div></div>
      <div className={styles.totals}>
        <div className={styles.totalRow}><span>Subtotal</span><strong>{salesMoney(receipt.subtotal)}</strong></div>
        {Number(receipt.discount_total) > 0 && <div className={styles.totalRow}><span>Diskon</span><strong>{salesMoney(receipt.discount_total)}</strong></div>}
        <div className={`${styles.totalRow} ${styles.grandTotal}`}><span>Total</span><strong>{salesMoney(receipt.grand_total)}</strong></div>
      </div>
    </section>
    <ReceiptReprint receipt={receipt} />
  </main>;
}
