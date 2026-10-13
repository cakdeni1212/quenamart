import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { parseIposSalesWorkbook } from "../src/lib/ipos-sales/parser.ts";
import { formatIposSalesRevenue } from "../src/lib/ipos-sales/presentation.ts";

const fixture = new URL("../fixtures/ipos/QUENAEX.xls", import.meta.url);

test("authoritative QUENAEX report revenue renders identically for READY and blocked preflight", () => {
  const parsed = parseIposSalesWorkbook(readFileSync(fixture));
  assert.equal(parsed.summary.transactionCount, 217);
  assert.equal(parsed.summary.saleLineCount, 489);
  assert.equal(parsed.summary.totalQuantity, "633");
  assert.equal(parsed.summary.totalAmount, "7077400");
  assert.equal(parsed.reconciliation.isReconciled, true);

  const readyBatch = { status: "READY", total_amount: Number(parsed.summary.totalAmount) };
  const blockedBatch = {
    status: "PREFLIGHT_BLOCKED", total_amount: Number(parsed.summary.totalAmount),
    preflight: { missingSkuCount: 9, stockBlockerCount: 32 },
  };
  assert.equal(formatIposSalesRevenue(readyBatch.total_amount), "Rp 7.077.400");
  assert.equal(formatIposSalesRevenue(blockedBatch.total_amount), "Rp 7.077.400");
  assert.equal(blockedBatch.preflight.missingSkuCount, 9);
  assert.equal(blockedBatch.preflight.stockBlockerCount, 32);
  assert.equal(parsed.footer.grandTotal, "7077400");
});

test("database numeric values and decimal-string values use the canonical Rupiah formatter", () => {
  assert.equal(formatIposSalesRevenue(7077400), "Rp 7.077.400");
  assert.equal(formatIposSalesRevenue("7077400"), "Rp 7.077.400");
  assert.equal(formatIposSalesRevenue(null), "—");
});
