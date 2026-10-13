import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import test from "node:test";
import { createRequire } from "node:module";
import { parseIposSalesWorkbook } from "../src/lib/ipos-sales/parser.ts";

const require = createRequire(import.meta.url);
const XLSX = require("xlsx");
const workbookPath = new URL("../fixtures/ipos/QUENAEX.xls", import.meta.url);

test("real QUENAEX report parses and reconciles every transaction against footer", { skip: !existsSync(workbookPath) }, () => {
  const parsed = parseIposSalesWorkbook(readFileSync(workbookPath));
  assert.deepEqual(parsed.summary, {
    transactionCount: 217,
    saleLineCount: 489,
    totalQuantity: "633",
    totalAmount: "7077400",
    uniqueSkuCount: 379,
    firstOccurredAt: "2026-10-11T23:08:08.000Z",
    lastOccurredAt: "2026-10-12T14:56:55.000Z",
  });
  assert.deepEqual(parsed.footer, {
    quantity: "633", subtotal: "7077400", discount: "0", tax: "0", fee: "0", grandTotal: "7077400",
  });
  assert.equal(parsed.reconciliation.isReconciled, true);
  assert.deepEqual(parsed.reconciliation.differences, []);
});

test("legacy BIFF XLS is accepted and fake/malformed report containers are rejected", () => {
  assert.throws(() => parseIposSalesWorkbook(new Uint8Array([1, 2, 3])), /Excel iPos/);
  if (!existsSync(workbookPath)) return;
  const data = readFileSync(workbookPath);
  const parsed = parseIposSalesWorkbook(data);
  assert.equal(parsed.sheetName, "Sheet");
  assert.equal(parsed.reportFrom, "2026-10-12");
  assert.equal(parsed.reportTo, "2026-10-12");
});

test("changing one SKU in a real-format copy preserves all other sale evidence", { skip: !existsSync(workbookPath) }, () => {
  const data = readFileSync(workbookPath);
  const book = XLSX.read(data, { type: "buffer", raw: true, cellDates: false });
  const sheet = book.Sheets.Sheet;
  const starts = [];
  for (let row = 0; row < 3370; row += 1) {
    const value = sheet[XLSX.utils.encode_cell({ r: row, c: 1 })]?.v;
    if (typeof value === "string" && /^\d{6}\//.test(value)) starts.push(row);
  }
  const lineCell = XLSX.utils.encode_cell({ r: starts[0] + 5, c: 2 });
  const original = sheet[lineCell].v;
  const originalParsed = parseIposSalesWorkbook(data);
  assert.equal(originalParsed.transactions[0].sourceTransactionNumber, "047314/KSR/UTM/1026");
  assert.equal(originalParsed.transactions[0].lines[0].sourceRowNumber, 25);
  assert.equal(originalParsed.transactions[0].lines[0].rawSku, "QMR571");
  assert.equal(originalParsed.transactions[0].lines[0].rawQuantity, "2");
  assert.equal(originalParsed.transactions[0].lines[0].rawUnitPrice, "10500");
  assert.equal(originalParsed.transactions[0].lines[0].rawLineTotal, "21000");
  sheet[lineCell].v = "TEST-SKU-BARU-001";
  const copy = XLSX.write(book, { type: "buffer", bookType: "biff8" });
  const changed = parseIposSalesWorkbook(copy);
  assert.equal(changed.transactions[0].sourceTransactionNumber, "047314/KSR/UTM/1026");
  assert.equal(changed.transactions[0].lines[0].sourceRowNumber, 25);
  assert.equal(changed.transactions[0].lines[0].rawSku, "TEST-SKU-BARU-001");
  assert.equal(changed.transactions[0].lines[0].rawQuantity, originalParsed.transactions[0].lines[0].rawQuantity);
  assert.equal(changed.transactions[0].lines[0].rawUnitPrice, originalParsed.transactions[0].lines[0].rawUnitPrice);
  assert.equal(changed.transactions[0].lines[0].rawLineTotal, originalParsed.transactions[0].lines[0].rawLineTotal);
  assert.equal(changed.summary.transactionCount, 217);
  assert.equal(changed.summary.saleLineCount, 489);
  assert.equal(changed.reconciliation.isReconciled, true);
  assert.equal(changed.transactions[0].lines[0].rawSku === original, false);
});
