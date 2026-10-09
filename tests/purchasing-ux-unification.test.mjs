import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const [landing, receiptPage, newReceipt, workflow, receiptEditor, invoiceEditor, invoiceStart, receiptList, migration, newReceiptStart, sidebar] = await Promise.all([
  read("../app/(workspace)/pembelian/page.tsx"),
  read("../app/(workspace)/pembelian/barang-masuk/[id]/page.tsx"),
  read("../app/(workspace)/pembelian/barang-masuk/baru/page.tsx"),
  read("../src/components/purchasing/purchase-receipt-workflow.tsx"),
  read("../src/components/purchasing/purchase-receipt-editor.tsx"),
  read("../src/components/purchasing/purchase-invoice-editor.tsx"),
  read("../src/components/purchasing/receipt-invoice-start.tsx"),
  read("../app/(workspace)/pembelian/barang-masuk/page.tsx"),
  read("../supabase/migrations/20260929230000_purchasing_invoice_payables_v1.sql"),
  read("../src/components/purchasing/new-receipt-start.tsx"),
  read("../src/components/app/sidebar.tsx"),
]);
const actions = await read("../src/lib/purchasing/actions.ts");

test("Purchasing sidebar opens Barang Masuk and provides role-scoped destinations", () => {
  assert.match(landing, /canAccessSection\(profile\.role, "pembelian"\)/);
  assert.match(landing, /redirect\("\/pembelian\/barang-masuk"\)/);
  assert.match(sidebar, /label: "Pembelian", href: "\/pembelian\/barang-masuk"/);
  assert.match(sidebar, /label: "Barang Masuk", href: "\/pembelian\/barang-masuk"/);
  assert.match(sidebar, /label: "Tempo Supplier", href: "\/tempo-supplier", visible: canAccessSection\(role, "tempo-supplier"\)/);
  assert.match(sidebar, /label: "Supplier", href: "\/pembelian\/supplier"/);
  assert.doesNotMatch(receiptList, /purchase-manager-shortcuts|Tempo Supplier →|Kelola supplier →/);
  assert.match(receiptList, /Pembelian Baru/);
});

test("receipt detail composes physical and manager finance sections in one route", () => {
  assert.match(receiptPage, /PurchaseReceiptWorkflow/);
  assert.doesNotMatch(receiptPage, /\/pembelian\/nota\/baru/);
  assert.match(workflow, /<PurchaseReceiptEditor/);
  assert.match(workflow, /manager && receipt\.status !== "CANCELLED" && \(invoice/);
  assert.match(newReceipt, /actorName = profile\.full_name/);
  assert.match(newReceiptStart, /Diinput oleh <strong>\{actorName\}<\/strong>/);
});

test("invoice draft is created idempotently and linked to this receipt without navigating away", () => {
  assert.match(invoiceStart, /CREATE_INVOICE:\$\{receiptId\}/);
  assert.match(invoiceStart, /createPurchaseInvoiceDraftForReceipt\(receiptId, requestId\)/);
  assert.match(invoiceStart, /linkPurchaseReceipt\(created\.id, receiptId\)/);
  assert.match(invoiceStart, /router\.refresh\(\)/);
  assert.match(workflow, /seedItems = receipt\.items\.map/);
  assert.match(invoiceEditor, /seedItems\.map/);
  assert.match(invoiceEditor, /!embedded && <div className="purchase-product-search"/);
});

test("receipt product rows and invoice lines share one editable price state", () => {
  assert.match(workflow, /const \[lines, setLines\] = useState/);
  assert.match(workflow, /ReceiptFinanceContext\.Provider/);
  assert.match(receiptEditor, /purchase-inline-finance/);
  assert.match(receiptEditor, /readPurchasePriceReference\(product\.id\)/);
  assert.match(invoiceEditor, /invoiceSystemTotal\(activeLines\.map/);
  assert.match(invoiceEditor, /\(!embedded \|\| allowStandaloneFinalize\) && <div className="purchase-invoice-lines"/);
  assert.match(invoiceEditor, /!embedded && <div className="purchase-product-search"/);
  assert.match(invoiceEditor, /Isi harga beli setiap produk pada daftar barang/);
});

test("one receipt post invokes the existing finance finalizer afterward, with nota-missing escape hatch", () => {
  assert.match(receiptEditor, /applyReceiptPost\(requestId\)/);
  assert.match(receiptEditor, /await afterPost\(\)/);
  assert.match(receiptEditor, /issueReceiptPost\(receipt\.id\)/);
  assert.match(invoiceEditor, /beforeReceiptPost/);
  assert.match(invoiceEditor, /isNotaUnavailable\(\)\) return "SKIPPED"/);
  assert.match(invoiceEditor, /finalizePurchaseInvoice\(header\.id, stored\.requestId/);
  assert.match(invoiceEditor, /quena:purchasing:FINALIZE_INVOICE:\$\{header\.id\}/);
  assert.match(receiptEditor, /quena:purchasing:POST_SUCCESS:\$\{receipt\.id\}/);
  assert.match(migration, /CREATE FUNCTION public\.purchase_invoice_finalize/);
});

test("financial values stay behind manager server reads and GUDANG list stays operational-only", () => {
  assert.match(receiptPage, /profile\.role === "OWNER" \|\| profile\.role === "ADMIN"/);
  assert.match(receiptList, /isManager &&/);
  assert.match(migration, /current_active_user_role\(\) IN \('OWNER'::public\.user_role,'ADMIN'::public\.user_role\)/);
  assert.match(invoiceEditor, /quena-purchasing-invoices/);
  assert.match(receiptEditor, /manager && finance && !finance\.notaUnavailable[\s\S]*?Harga beli/);
  assert.doesNotMatch(receiptEditor, /Total Sistem|Total Nota Supplier|Pembayaran/);
  assert.match(actions, /async function readPurchasePriceReference[\s\S]*?authorized\(true\)/);
});

test("financial actions do not introduce a second stock mutation path", () => {
  const finalize = invoiceEditor.slice(invoiceEditor.indexOf("async function finalizeAfterReceipt"), invoiceEditor.indexOf("useEffect(() =>", invoiceEditor.indexOf("async function finalizeAfterReceipt")));
  assert.doesNotMatch(finalize, /issueReceiptPost|applyReceiptPost|stock_balance_projection|product_inventory/);
  assert.match(receiptEditor, /router\.replace\(`\/pembelian\/barang-masuk\?posted=/);
});
