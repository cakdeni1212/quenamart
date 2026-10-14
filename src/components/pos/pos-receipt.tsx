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

type ReceiptLoyalty = { points_earned?: unknown; points_redeemed?: unknown; points_discount?: unknown };

export type PosReceiptData = {
  sale_id: string;
  sale_number: string;
  completed_at: string;
  cashier_label: string;
  outlet_display_name?: string | null;
  outlet_address?: string | null;
  outlet_phone?: string | null;
  outlet_whatsapp?: string | null;
  receipt_footer_note?: string | null;
  member?: { member_number?: unknown; full_name?: unknown } | null;
  loyalty?: ReceiptLoyalty | null;
  items: ReceiptItem[];
  subtotal: number | string;
  discount_total: number | string;
  grand_total: number | string;
  payments: ReceiptPayment[];
};

export function PosReceipt({ receipt, size }: { receipt: PosReceiptData; size: "58" | "80" }) {
  const outletName = receipt.outlet_display_name?.trim() || "QUENA MART";
  const contact = receipt.outlet_phone?.trim() || receipt.outlet_whatsapp?.trim();
  return <article className={`pos-receipt pos-receipt-${size}`} data-print-receipt>
    <header className="pos-receipt-brand"><strong>{outletName}</strong>{receipt.outlet_address && <small>{receipt.outlet_address}</small>}{contact && <small>{contact}</small>}</header>
    <div className="pos-receipt-rule" />
    <dl className="pos-receipt-meta">
      <div><dt>No</dt><dd>{receipt.sale_number}</dd></div>
      <div><dt>Tanggal</dt><dd>{salesDateTime(receipt.completed_at)}</dd></div>
      <div><dt>Kasir</dt><dd>{receipt.cashier_label}</dd></div>
      {receipt.member && <div><dt>Member</dt><dd>{String(receipt.member.full_name ?? "Member")} · {String(receipt.member.member_number ?? "")}</dd></div>}
    </dl>
    <div className="pos-receipt-rule" />
    <div className="pos-receipt-items">{receipt.items.map((item, index) => <section className="pos-receipt-item" key={`${String(item.sku ?? "item")}-${index}`}>
      <strong>{String(item.name ?? "Barang")}</strong>
      <div><span>{salesQuantity(item.quantity)}{item.unit ? ` ${String(item.unit)}` : ""} × {salesMoney(item.unit_selling_price)}</span><b>{salesMoney(item.line_subtotal)}</b></div>
    </section>)}</div>
    <div className="pos-receipt-rule" />
    <div className="pos-receipt-total"><span>TOTAL</span><strong>{salesMoney(receipt.grand_total)}</strong></div>
    {receipt.loyalty && <div className="pos-receipt-payment">
      {Number(receipt.loyalty.points_redeemed) > 0 && <div><span>Poin digunakan · potongan</span><b>{String(receipt.loyalty.points_redeemed)} · {salesMoney(receipt.loyalty.points_discount)}</b></div>}
      {Number(receipt.loyalty.points_earned) > 0 && <div><span>Poin diperoleh</span><b>+{String(receipt.loyalty.points_earned)}</b></div>}
    </div>}
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
    <footer>Terima kasih<br />Belanja hemat di {outletName}{receipt.receipt_footer_note?.trim() && <><br />{receipt.receipt_footer_note.trim()}</>}</footer>
  </article>;
}
