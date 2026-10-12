import { salesDateTime, salesMoney, salesPaymentLabel, salesQuantity } from "@/lib/sales/presentation";
import { Fragment } from "react";

type ReceiptItem = {
  name?: unknown;
  sku?: unknown;
  unit?: unknown;
  quantity?: unknown;
  unit_selling_price?: unknown;
  line_subtotal?: unknown;
};

type ReceiptPayment = {
  method?: unknown;
  applied_amount?: unknown;
  received_amount?: unknown;
  change_amount?: unknown;
  reference_text?: unknown;
};

export type PosReceiptData = {
  sale_id: string;
  sale_number: string;
  completed_at: string;
  cashier_label: string;
  items: ReceiptItem[];
  subtotal: number | string;
  discount_total: number | string;
  grand_total: number | string;
  payments: ReceiptPayment[];
};

export function PosReceipt({ receipt, size }: { receipt: PosReceiptData; size: "58" | "80" }) {
  return <article className={`pos-receipt pos-receipt-${size}`} data-print-receipt>
    <header className="pos-receipt-brand"><strong>QUENA MART</strong><small>Belanja kebutuhan harian</small></header>
    <div className="pos-receipt-rule" />
    <dl className="pos-receipt-meta">
      <div><dt>No</dt><dd>{receipt.sale_number}</dd></div>
      <div><dt>Tanggal</dt><dd>{salesDateTime(receipt.completed_at)}</dd></div>
      <div><dt>Kasir</dt><dd>{receipt.cashier_label}</dd></div>
    </dl>
    <div className="pos-receipt-rule" />
    <div className="pos-receipt-items">{receipt.items.map((item, index) => <section className="pos-receipt-item" key={`${String(item.sku ?? "item")}-${index}`}>
      <strong>{String(item.name ?? "Barang")}</strong>
      <div><span>{salesQuantity(item.quantity)}{item.unit ? ` ${String(item.unit)}` : ""} × {salesMoney(item.unit_selling_price)}</span><b>{salesMoney(item.line_subtotal)}</b></div>
    </section>)}</div>
    <div className="pos-receipt-rule" />
    <div className="pos-receipt-total"><span>TOTAL</span><strong>{salesMoney(receipt.grand_total)}</strong></div>
    {receipt.payments.length > 0 && <div className="pos-receipt-payment">
      {receipt.payments.map((payment, index) => <div key={`${String(payment.method)}-${index}`}>
        <span>{salesPaymentLabel(payment.method)}</span><b>{salesMoney(payment.applied_amount)}</b>
      </div>)}
      {receipt.payments.filter((payment) => payment.method === "CASH").map((payment, index) => <Fragment key={`cash-${index}`}>
        <div><span>Diterima</span><b>{salesMoney(payment.received_amount)}</b></div>
        <div><span>Kembali</span><b>{salesMoney(payment.change_amount)}</b></div>
      </Fragment>)}
    </div>}
    <div className="pos-receipt-rule" />
    <footer>Terima kasih<br />Belanja hemat di Quena Mart</footer>
  </article>;
}
