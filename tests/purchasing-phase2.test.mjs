import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { invoiceLineSubtotal, invoiceSystemTotal, invoiceTotalDifference } from "../src/lib/purchasing/finance-model.ts";

const migration = await readFile(new URL("../supabase/migrations/20260929230000_purchasing_invoice_payables_v1.sql", import.meta.url), "utf8");
const actions = await readFile(new URL("../src/lib/purchasing/actions.ts", import.meta.url), "utf8");
const detailUi = await readFile(new URL("../src/components/purchasing/purchase-invoice-editor.tsx", import.meta.url), "utf8");
const listUi = await readFile(new URL("../app/(workspace)/pembelian/barang-masuk/page.tsx", import.meta.url), "utf8");

test("invoice system totals round line subtotals to rupiah cents and keep supplier difference separate", () => {
  assert.equal(invoiceLineSubtotal(2.5, 120), 300);
  assert.equal(invoiceSystemTotal([{ quantity: 2.5, purchaseUnitPrice: 120 }, { quantity: 1, purchaseUnitPrice: 50 }]), 350);
  assert.equal(invoiceTotalDifference(350, 360), 10);
  assert.equal(invoiceTotalDifference(350, 340), -10);
  assert.equal(invoiceLineSubtotal(0, 5), null);
});

test("invoice/payable/payment schema is separate from Phase 1 receipts and stock ledger", () => {
  for (const table of ["purchase_invoices", "purchase_invoice_items", "purchase_invoice_receipts", "supplier_payables", "supplier_payments", "supplier_payment_allocations", "purchase_invoice_documents"]) assert.match(migration, new RegExp(`CREATE TABLE public\\.${table}`));
  assert.match(migration, /CREATE FUNCTION public\.purchase_invoice_finalize/);
  assert.match(migration, /CREATE FUNCTION public\.purchase_record_supplier_payment/);
  assert.doesNotMatch(migration, /UPDATE\s+public\.(?:product_inventory|stock_balance_projection|product_costs)/i);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.purchase_invoice_finalize[^;]* TO authenticated/);
});

test("financial database/API boundary is OWNER/ADMIN only and private invoice storage", () => {
  assert.match(migration, /v_role IS NULL OR v_role NOT IN \('OWNER'::public\.user_role,'ADMIN'::public\.user_role\)/);
  assert.match(migration, /purchasing_finance_invoices_read[\s\S]*?current_active_user_role\(\) IN \('OWNER'::public\.user_role,'ADMIN'::public\.user_role\)/);
  assert.match(migration, /CREATE POLICY purchasing_invoice_upload_manager[\s\S]*?current_active_user_role\(\) IN \('OWNER'::public\.user_role,'ADMIN'::public\.user_role\)/);
  assert.match(migration, /'quena-purchasing-invoices','quena-purchasing-invoices',false/);
  assert.match(migration, /CREATE POLICY purchasing_invoice_storage_select_auth_restrict[\s\S]*?current_active_user_role\(\) IN \('OWNER'::public\.user_role,'ADMIN'::public\.user_role\)/);
});

test("GUDANG receipt list receives operational aggregates while financial payload is manager-only", () => {
  assert.match(migration, /'financial',CASE WHEN v_role IN \('OWNER'::public\.user_role,'ADMIN'::public\.user_role\) THEN fin\.data ELSE NULL END/);
  assert.match(migration, /'stockAdded',coalesce\(items\.stock_added,0\)/);
  assert.match(listUi, /profile\.role === "OWNER" \|\| profile\.role === "ADMIN"/);
  assert.match(listUi, /row\.financial\?\.invoiceTotal/);
});

test("cash/tempo, supplier reconciliation, payments and uploads never issue receipt stock posting", () => {
  assert.match(detailUi, /Cash/);
  assert.match(detailUi, /Tempo/);
  assert.match(detailUi, /purchase_invoice_link_receipt|linkPurchaseReceipt/);
  assert.match(detailUi, /payment does not change stock|tidak mengubah stok/i);
  assert.match(detailUi, /quena-purchasing-invoices/);
  assert.match(actions, /purchase_invoice_finalize/);
  assert.match(actions, /purchase_record_supplier_payment/);
  assert.doesNotMatch(actions.slice(actions.indexOf("export async function finalizePurchaseInvoice")), /issue_purchase_receipt_post_intent|apply_purchase_receipt_post_intent/);
});

test("invoice finalization and payment actions retain request identity for retries", () => {
  assert.match(detailUi, /FINALIZE_INVOICE:\$\{header\.id\}/);
  assert.match(detailUi, /RECORD_PAYMENT:\$\{header\.id\}/);
  assert.match(detailUi, /Ulangi finalisasi dengan permintaan yang sama/);
  assert.match(detailUi, /Ulangi pembayaran dengan permintaan yang sama/);
  assert.match(migration, /v_req\.actor_id<>v_actor OR v_req\.operation<>'FINALIZE_INVOICE' OR v_req\.payload_hash<>md5\(v_payload\)/);
  assert.match(migration, /v_req\.actor_id<>v_actor OR v_req\.operation<>'RECORD_PAYMENT' OR v_req\.payload_hash<>md5\(v_payload\)/);
});
