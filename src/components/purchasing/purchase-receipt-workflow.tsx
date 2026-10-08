"use client";

import { useEffect, useRef, useState } from "react";
import { PurchaseReceiptEditor } from "@/components/purchasing/purchase-receipt-editor";
import { PurchaseInvoiceEditor, type ReceiptInvoicePostHooks } from "@/components/purchasing/purchase-invoice-editor";
import { ReceiptInvoiceStart } from "@/components/purchasing/receipt-invoice-start";
import type { InvoiceDetailData } from "@/lib/purchasing/finance-read";
import type { ReceiptDetail } from "@/lib/purchasing/receipt-read";
import { ReceiptFinanceContext } from "@/components/purchasing/receipt-finance-context";
import type { ReceiptInvoiceLine } from "@/lib/purchasing/receipt-model";

export function PurchaseReceiptWorkflow({ receipt, manager, invoice, linkableReceipts, viewOnly = false }: {
  receipt: ReceiptDetail;
  manager: boolean;
  invoice: InvoiceDetailData | null;
  linkableReceipts: Array<{ id: string; reference: string; status: "DRAFT" | "POSTED"; receivedAt: string }>;
  viewOnly?: boolean;
}) {
  const postHooks = useRef<ReceiptInvoicePostHooks | null>(null);
  const invoiceDraftSaver = useRef<(() => Promise<string | null>) | null>(null);
  const [notaUnavailable, setNotaUnavailable] = useState(!invoice && receipt.status === "POSTED");
  const [lines, setLines] = useState<ReceiptInvoiceLine[]>(() => {
    const current = new Map((invoice?.items ?? []).map((item) => [item.productId, item]));
    const seeded = receipt.items.map((item) => {
      const prior = current.get(item.product_id);
      return { productId: item.product_id, name: item.product?.name ?? prior?.name ?? "Produk tidak tersedia",
        sku: item.product?.sku ?? prior?.sku ?? "—", quantity: String(prior?.quantity ?? item.accepted_quantity),
        unitPrice: prior ? String(prior.unitPrice) : "", priceSource: null } as ReceiptInvoiceLine;
    });
    const receiptIds = new Set(seeded.map((item) => item.productId));
    return [...seeded, ...(invoice?.items ?? []).filter((item) => !receiptIds.has(item.productId)).map((item) => ({
      productId: item.productId, name: item.name, sku: item.sku, quantity: String(item.quantity),
      unitPrice: String(item.unitPrice), priceSource: null,
    }))];
  });
  useEffect(() => {
    const timer = window.setTimeout(() => {
    try {
      const saved = JSON.parse(sessionStorage.getItem(`quena:purchasing:PRICE_HINTS:${receipt.id}`) ?? "{}") as Record<string, { price?: string; source?: ReceiptInvoiceLine["priceSource"] }>;
      setLines((current) => current.map((line) => !line.unitPrice && saved[line.productId]?.price
        ? { ...line, unitPrice: saved[line.productId]!.price!, priceSource: saved[line.productId]!.source ?? null } : line));
    } catch { /* Ignore malformed, non-authoritative UI hints. */ }
    }, 0);
    return () => window.clearTimeout(timer);
  }, [receipt.id]);
  const seedItems = receipt.items.map((item) => ({
    productId: item.product_id,
    name: item.product?.name ?? "Produk tidak tersedia",
    sku: item.product?.sku ?? "—",
    acceptedQuantity: Number(item.accepted_quantity),
  }));

  const financeSection = manager && receipt.status !== "CANCELLED" && (invoice
      ? <PurchaseInvoiceEditor key={invoice.header.id} invoice={invoice} linkableReceipts={linkableReceipts}
          initialReceiptId={receipt.id} receiptId={receipt.id} embedded allowStandaloneFinalize={receipt.status === "POSTED"} seedItems={seedItems} defaultInvoiceDate={receipt.received_at.slice(0, 10)}
          onRegisterPostHooks={(hooks) => { postHooks.current = hooks; }} />
      : <ReceiptInvoiceStart receiptId={receipt.id} hasItems={receipt.items.length > 0} autoStart={receipt.status === "DRAFT"} />);

  return <ReceiptFinanceContext.Provider value={{ lines, setLines, notaUnavailable, setNotaUnavailable,
    saveInvoiceDraft: () => invoiceDraftSaver.current?.() ?? Promise.resolve(null),
    registerInvoiceDraftSaver: (save) => { invoiceDraftSaver.current = save; } }}>
    <PurchaseReceiptEditor receipt={receipt} manager={manager} financeSection={financeSection} viewOnly={viewOnly}
      beforePost={() => postHooks.current?.beforePost() ?? Promise.resolve(true)}
      afterPost={() => postHooks.current?.afterPost() ?? Promise.resolve("SKIPPED")} />
  </ReceiptFinanceContext.Provider>;
}
