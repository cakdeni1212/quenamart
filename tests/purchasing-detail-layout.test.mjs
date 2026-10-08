import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const [component, styles] = await Promise.all([
  readFile(new URL("../src/components/purchasing/purchase-invoice-editor.tsx", import.meta.url), "utf8"),
  readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
]);

test("nota, payment, and document content share one finance section", () => {
  const finance = component.slice(component.indexOf("purchase-finance-section purchase-finance-workspace"), component.indexOf("{!embedded && <section className=\"purchase-finance-section\""));
  assert.match(finance, /Nota &amp; Pembayaran/);
  assert.match(finance, /PEMBAYARAN/);
  assert.match(finance, /FOTO NOTA/);
  assert.doesNotMatch(component, /<section className="purchase-finance-section"><h2>Foto nota/);
});

test("invoice activity history is secondary and collapsed by default", () => {
  assert.match(component, /<details className="purchase-timeline purchase-activity-details"><summary>Lihat riwayat aktivitas<\/summary>/);
  assert.match(component, /invoice\.events\.map/);
});

test("finance layout shares the receipt content boundary and uses stacked mobile invoice rows", () => {
  assert.match(styles, /\.purchase-finance-workspace\{[^}]*margin:0 20px/);
  assert.match(styles, /\.purchase-finance-workspace\{margin-right:14px;margin-left:14px\}/);
  assert.match(styles, /\.purchase-invoice-lines \.purchase-receipt-table tr\{display:grid/);
  assert.match(styles, /\.purchase-invoice-lines \.purchase-receipt-table td input\{width:100%/);
});
