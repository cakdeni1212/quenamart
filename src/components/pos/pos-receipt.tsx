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

const money = (value: unknown) => new Intl.NumberFormat("id-ID", {
  style: "currency", currency: "IDR", maximumFractionDigits: 2,
}).format(Number(value ?? 0));

const quantity = (value: unknown) => new Intl.NumberFormat("id-ID", {
  maximumFractionDigits: 3,
}).format(Number(value ?? 0));

const methods: Record<string, string> = {
  CASH: "Tunai", QRIS: "QRIS", CARD: "Kartu", E_WALLET: "E-Wallet",
};

export function PosReceipt({ receipt, size }: { receipt: PosReceiptData; size: "58" | "80" }) {
  const payment = receipt.payments[0];
  const isCash = payment?.method === "CASH";
  return <article className={`pos-receipt pos-receipt-${size}`} data-print-receipt>
    <header className="pos-receipt-brand"><strong>QUENA MART</strong><small>Belanja kebutuhan harian</small></header>
    <div className="pos-receipt-rule" />
    <dl className="pos-receipt-meta">
      <div><dt>No</dt><dd>{receipt.sale_number}</dd></div>
      <div><dt>Tanggal</dt><dd>{new Intl.DateTimeFormat("id-ID", { dateStyle: "short", timeStyle: "short" }).format(new Date(receipt.completed_at))}</dd></div>
      <div><dt>Kasir</dt><dd>{receipt.cashier_label}</dd></div>
    </dl>
    <div className="pos-receipt-rule" />
    <div className="pos-receipt-items">{receipt.items.map((item, index) => <section className="pos-receipt-item" key={`${String(item.sku ?? "item")}-${index}`}>
      <strong>{String(item.name ?? "Barang")}</strong>
      <div><span>{quantity(item.quantity)}{item.unit ? ` ${String(item.unit)}` : ""} × {money(item.unit_selling_price)}</span><b>{money(item.line_subtotal)}</b></div>
    </section>)}</div>
    <div className="pos-receipt-rule" />
    <div className="pos-receipt-total"><span>TOTAL</span><strong>{money(receipt.grand_total)}</strong></div>
    {payment && <div className="pos-receipt-payment">
      <div><span>{methods[String(payment.method)] ?? "Pembayaran"}</span><b>{money(payment.applied_amount)}</b></div>
      {isCash && <>
        <div><span>Diterima</span><b>{money(payment.received_amount)}</b></div>
        <div><span>Kembali</span><b>{money(payment.change_amount)}</b></div>
      </>}
    </div>}
    <div className="pos-receipt-rule" />
    <footer>Terima kasih<br />Belanja hemat di Quena Mart</footer>
  </article>;
}
