import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const [invoice, receipt] = await Promise.all([
  read("../src/components/purchasing/purchase-invoice-editor.tsx"),
  read("../src/components/purchasing/purchase-receipt-editor.tsx"),
]);

test("complete dirty nota is saved automatically before a new receipt post intent", () => {
  const prepare = invoice.slice(invoice.indexOf("async function beforeReceiptPost"), invoice.indexOf("async function finalizeAfterReceipt"));
  const posting = receipt.slice(receipt.indexOf("async function postReceipt"), receipt.indexOf("async function applyRequest"));

  assert.doesNotMatch(invoice, /Simpan perubahan nota sebelum posting/);
  assert.match(prepare, /if \(dirty\)[\s\S]*?await saveInvoiceDraftNow\(false\)/);
  assert.match(prepare, /if \(!invoiceNumber\.trim\(\)[\s\S]*?return false/);
  assert.ok(posting.indexOf("await beforePost()") < posting.indexOf("issueReceiptPost(receipt.id)"));
  assert.match(posting, /actionLock\.current = true[\s\S]*?await beforePost\(\)/);
});

test("uncertain receipt retry applies the stored request without saving or issuing another intent first", () => {
  const posting = receipt.slice(receipt.indexOf("async function postReceipt"), receipt.indexOf("async function applyRequest"));
  assert.match(posting, /const retryRequest = pendingRequest \?\? storedRequest/);
  assert.ok(posting.indexOf("if (retryRequest)") < posting.indexOf("await beforePost()"));
  assert.match(posting, /if \(retryRequest\)[\s\S]*?await applyRequest\(retryRequest\)/);
  assert.match(posting, /window\.sessionStorage\.setItem\(retryKey, issued\.requestId\)/);
});

test("invoice finalization retains its exact request identity and uploaded documents remain independently attached", () => {
  assert.match(invoice, /quena:purchasing:FINALIZE_INVOICE:\$\{header\.id\}/);
  assert.match(invoice, /finalizePurchaseInvoice\(header\.id, stored\.requestId/);
  assert.match(invoice, /attachPurchaseInvoiceDocument\(header\.id, path\)/);
  const upload = invoice.slice(invoice.indexOf("async function upload"), invoice.indexOf("async function openDocument"));
  assert.doesNotMatch(upload, /setDirty\(true\)/);
});
