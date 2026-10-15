import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { readPublicCustomerReceipt } from "@/lib/receipts/public-receipt.server";
import { salesDateTime, salesMoney, salesPaymentLabel, salesQuantity } from "@/lib/sales/presentation";
import { DigitalReceiptActions } from "@/components/receipts/digital-receipt-actions";
import styles from "./receipt.module.css";

export const dynamic = "force-dynamic";
export const metadata: Metadata = { title: "Struk Digital — Quena Mart", robots: { index: false, follow: false, noarchive: true } };

export default async function DigitalReceiptPage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const receipt = await readPublicCustomerReceipt(token);
  if (!receipt) notFound();

  const redeemed = Number(receipt.loyalty?.points_redeemed ?? 0) > 0;
  return <main className={styles.shell}>
    <article className={styles.receipt}>
      <header className={styles.brand}>
        <strong>{receipt.store.name}</strong>
        {receipt.store.address && <span>{receipt.store.address}</span>}
        {receipt.store.phone && <span>{receipt.store.phone}</span>}
      </header>
      <div className={styles.rule} />
      <section className={styles.transaction}>
        <span className={styles.eyebrow}>STRUK DIGITAL</span>
        <h1>{receipt.sale.number}</h1>
        <p>{salesDateTime(receipt.sale.completed_at)}</p>
        <p>Kasir: {receipt.sale.cashier}</p>
      </section>
      <div className={styles.rule} />
      <section className={styles.items} aria-label="Barang yang dibeli">
        {receipt.items.map((item, index) => <div className={styles.item} key={index}>
          <strong>{item.name}</strong>
          <div><span>{salesQuantity(item.quantity)}{item.unit ? " " + item.unit : ""} × {salesMoney(item.unit_price)}</span><b>{salesMoney(item.line_total)}</b></div>
        </div>)}
      </section>
      <div className={styles.rule} />
      <section className={styles.totals}>
        <div><span>Subtotal</span><span>{salesMoney(receipt.totals.subtotal)}</span></div>
        {Number(receipt.totals.discount_total) > 0 && <div><span>{redeemed ? "Potongan poin" : "Diskon"}</span><span>{salesMoney(redeemed ? receipt.loyalty?.points_discount : receipt.totals.discount_total)}</span></div>}
        <div className={styles.grandTotal}><strong>TOTAL</strong><strong>{salesMoney(receipt.totals.grand_total)}</strong></div>
      </section>
      <section className={styles.payment}>
        <h2>Pembayaran</h2>
        {receipt.payments.length === 0 ? <div><span>Lunas dengan poin</span><b>{salesMoney(receipt.totals.grand_total)}</b></div> : receipt.payments.map((payment, index) => <div key={index}>
          <span>{salesPaymentLabel(payment.method)}</span><b>{salesMoney(payment.amount)}</b>
          {payment.method === "CASH" && payment.received !== null && <small>Uang diterima {salesMoney(payment.received)}</small>}
          {payment.method === "CASH" && payment.change !== null && Number(payment.change) > 0 && <small>Kembalian {salesMoney(payment.change)}</small>}
        </div>)}
      </section>
      {receipt.member && <>
        <div className={styles.rule} />
        <section className={styles.member}>
          <span className={styles.eyebrow}>MEMBER QUENA</span>
          <strong>{receipt.member.name}</strong><span>{receipt.member.member_number}</span>
          {receipt.loyalty && <div className={styles.loyalty}>
            {Number(receipt.loyalty.points_earned) > 0 && <div><span>Poin didapat</span><b>+{Number(receipt.loyalty.points_earned).toLocaleString("id-ID")} poin</b></div>}
            {Number(receipt.loyalty.points_redeemed) > 0 && <div><span>Poin digunakan</span><b>-{Number(receipt.loyalty.points_redeemed).toLocaleString("id-ID")} poin</b></div>}
            {Number(receipt.loyalty.points_redeemed) > 0 && <div><span>Nilai potongan poin</span><b>{salesMoney(receipt.loyalty.points_discount)}</b></div>}
            {receipt.loyalty.balance_after !== null && <div><span>Saldo poin setelah transaksi</span><b>{Number(receipt.loyalty.balance_after).toLocaleString("id-ID")} poin</b></div>}
          </div>}
        </section>
      </>}
      <div className={styles.rule} />
      <footer className={styles.footer}>Terima kasih telah berbelanja di {receipt.store.name}.{receipt.store.footer && <span>{receipt.store.footer}</span>}</footer>
    </article>
    <DigitalReceiptActions />
  </main>;
}
