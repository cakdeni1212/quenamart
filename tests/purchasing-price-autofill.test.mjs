import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { receiptInvoiceSubtotal } from "../src/lib/purchasing/receipt-model.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const [actions, receiptEditor, workflow, invoiceEditor, migration, receiptMigration] = await Promise.all([
  read("../src/lib/purchasing/actions.ts"),
  read("../src/components/purchasing/purchase-receipt-editor.tsx"),
  read("../src/components/purchasing/purchase-receipt-workflow.tsx"),
  read("../src/components/purchasing/purchase-invoice-editor.tsx"),
  read("../supabase/migrations/20260929230000_purchasing_invoice_payables_v1.sql"),
  read("../supabase/migrations/20260929220000_purchasing_receipts_v1.sql"),
]);

test("purchase price reference is manager-authorized and prioritizes finalized Quena invoice price before outlet iPos HPP", () => {
  const body = actions.slice(actions.indexOf("async function readPurchasePriceReference"), actions.indexOf("export async function applyReceiptPost"));
  assert.match(body, /authorized\(true\)/);
  assert.match(body, /purchase_invoice_items/);
  assert.match(body, /invoice\.status", "FINALIZED"/);
  assert.match(body, /limit\(1\)\.maybeSingle\(\)/);
  assert.ok(body.indexOf("PEMBELIAN_TERAKHIR") < body.indexOf("product_costs"));
  assert.match(body, /eq\("outlet_id", outletId\)/);
  assert.match(body, /Number\(hpp\) > 0/);
  assert.doesNotMatch(body, /service_role|update\(|insert\(|delete\(/i);
  assert.match(migration, /purchasing_finance_items_read[\s\S]*?current_active_user_role\(\) IN \('OWNER'::public\.user_role,'ADMIN'::public\.user_role\)/);
});

test("receipt search remains operational-only and GUDANG does not request financial references", () => {
  assert.match(receiptEditor, /if \(manager && finance\)/);
  assert.match(receiptEditor, /manager && finance && !finance\.notaUnavailable/);
  assert.match(receiptEditor, /readPurchasePriceReference\(product\.id\)/);
  assert.match(actions, /purchase_receipt_product_search/);
  assert.match(receiptMigration, /SELECT p\.id,p\.name,p\.sku/);
  assert.doesNotMatch(receiptMigration.slice(receiptMigration.indexOf("CREATE FUNCTION public.purchase_receipt_product_search"), receiptMigration.indexOf("CREATE FUNCTION public.purchase_receipt_resolve_barcode")), /hpp|purchase_unit_price|line_subtotal/i);
});

test("receipt product row is the shared editable purchase line and invoice embedded view has no second product editor", () => {
  assert.match(workflow, /ReceiptFinanceContext\.Provider/);
  assert.match(receiptEditor, /purchase-inline-finance/);
  assert.match(receiptEditor, /priceSource: null/);
  assert.match(invoiceEditor, /const activeLines = embedded && receiptFinance \? receiptFinance\.lines : lines/);
  assert.match(invoiceEditor, /invoiceSystemTotal\(activeLines\.map/);
  assert.match(invoiceEditor, /\(!embedded \|\| allowStandaloneFinalize\) && <div className="purchase-invoice-lines"/);
  assert.match(invoiceEditor, /!embedded && <div className="purchase-product-search"/);
});

test("purchase unit price stays editable and subtotal rounds to invoice cent semantics", () => {
  assert.match(receiptEditor, /type="number" min="0" step="0\.01" value=\{line\.unitPrice\}/);
  assert.match(receiptEditor, /priceSource: null/);
  assert.equal(receiptInvoiceSubtotal("5", "13000"), 65000);
  assert.equal(receiptInvoiceSubtotal("1.125", "100.01"), 112.51);
  assert.equal(receiptInvoiceSubtotal("", ""), null);
  assert.doesNotMatch(receiptEditor, /product_costs|stock_balance_projection|product_inventory/);
});

test("nota-missing suppresses price card and date defaults to received date", () => {
  assert.match(workflow, /useState\(!invoice && receipt\.status === "POSTED"\)/);
  assert.match(receiptEditor, /!finance\.notaUnavailable/);
  assert.match(workflow, /defaultInvoiceDate=\{receipt\.received_at\.slice\(0, 10\)\}/);
  assert.match(invoiceEditor, /header\.invoice_date \?\? defaultInvoiceDate \?\? day\(\)/);
  assert.match(invoiceEditor, /MENUNGGU NOTA/);
});
