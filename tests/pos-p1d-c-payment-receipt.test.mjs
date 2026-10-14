import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const ui = await readFile(new URL("../src/components/pos/pos-workspace.tsx", import.meta.url), "utf8");
const actions = await readFile(new URL("../src/app/actions/pos-cart.ts", import.meta.url), "utf8");
const receipt = await readFile(new URL("../src/components/pos/pos-receipt.tsx", import.meta.url), "utf8");
const presentation = await readFile(new URL("../src/lib/sales/presentation.ts", import.meta.url), "utf8");
const migration = await readFile(new URL("../supabase/migrations/20260929360000_pos_receipt_read_v1.sql", import.meta.url), "utf8");
const css = await readFile(new URL("../app/globals.css", import.meta.url), "utf8");

test("payment UI offers the four single-tender methods and blocks obvious checkout blockers", () => {
  for (const method of ["CASH", "QRIS", "CARD", "E_WALLET"]) assert.ok(ui.includes(`"${method}"`));
  assert.match(ui, /cart\.items\.length > 0[\s\S]*cart\.items\.every\(\(item\) => priceStatus\(item\) === "CURRENT"\) && !busy/);
  assert.match(ui, /compareRupiah\(cashReceived, payableTotal\) !== -1/);
  assert.match(ui, /paymentMethod === "CASH" && !cashSufficient/);
  assert.match(ui, /<RupiahInput id="pos-cash-received"[\s\S]*onValueChange=\{\(value\) =>/);
  assert.match(ui, /Uang Pas/);
  assert.match(ui, /KEMBALIAN/);
  assert.match(ui, /TOTAL BAYAR/);
  assert.match(ui, /checkoutInFlight\.current/);
  assert.match(ui, /checkoutRequestId\.current \?\?= uuid\(\)/);
  assert.match(ui, /Diterima \{rupiah\(completedPayment\?\.received_amount\)\} · Kembalian/);
});

test("checkout action delegates to the existing RPC with request identity and no client totals", () => {
  assert.match(actions, /invoke\("pos_checkout_complete"/);
  assert.match(actions, /p_expected_cart_revision: input\.expectedRevision/);
  assert.match(actions, /p_payment_method: input\.method/);
  assert.match(actions, /p_cash_received_amount:/);
  assert.doesNotMatch(actions.slice(actions.indexOf("export async function checkoutPos"), actions.indexOf("export async function readPosSaleReceipt")), /outlet_id|grand_total|unit_price|cogs|wac/i);
  assert.match(ui, /requestId: uuid\(\)/);
  assert.match(ui, /setBusy\(true\); setNotice\(""\)/);
});

test("checkout errors map to cashier-safe messages, including inactive costing", () => {
  for (const [code, message] of [
    ["POS_COSTING_NOT_ACTIVE", "Sistem kasir belum diaktifkan untuk transaksi penjualan."],
    ["POS_INSUFFICIENT_STOCK", "Stok barang tidak mencukupi."],
    ["POS_PRICE_CHANGED", "Harga berubah."],
    ["POS_PRICE_UNAVAILABLE", "Harga jual barang belum tersedia."],
    ["POS_CART_STALE", "Transaksi berubah di perangkat lain."],
    ["POS_ALREADY_COMPLETED", "Transaksi ini sudah selesai."],
    ["POS_UNAUTHORIZED", "Transaksi tidak dapat diakses"],
    ["POS_PAYMENT_INVALID", "Pembayaran tidak valid."],
  ]) {
    assert.ok(actions.includes(code));
    assert.ok(actions.includes(message));
  }
  assert.match(actions, /Permintaan POS belum dapat diproses/);
});

test("successful checkout loads bounded receipt data before displaying completion", () => {
  assert.match(ui, /const read = saleId \? await readPosSaleReceipt\(saleId\)/);
  assert.match(ui, /Transaksi Berhasil/);
  assert.match(ui, /Cetak Struk/);
  assert.match(ui, /Transaksi Baru/);
  assert.match(ui, /if \(!Array\.isArray\(data\.payments\)\)/);
});

test("receipt RPC is authenticated, outlet-bounded, cashier-owned for KASIR, and commercial only", () => {
  assert.match(migration, /SECURITY DEFINER[\s\S]*SET search_path=pg_catalog/);
  assert.match(migration, /auth\.uid\(\)/);
  assert.match(migration, /current_active_user_role\(\)/);
  assert.match(migration, /s\.outlet_id=v_outlet/);
  assert.match(migration, /s\.cashier_id=v_actor/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.pos_sale_receipt_read\(uuid\) TO authenticated/);
  assert.match(migration, /REVOKE ALL ON FUNCTION public\.pos_sale_receipt_read\(uuid\) FROM PUBLIC,anon,service_role/);
  assert.doesNotMatch(migration, /sale_item_cost_evidence|sale_item_cost_allocations|inventory_cost_events|wac|hpp|cogs|margin/i);
});

test("receipt renders commercial snapshots, decimal quantities, and cash-only tender facts", () => {
  for (const phrase of ["QUENA MART", "sale_number", "cashier_label", "line_subtotal", "Kembali", "Terima kasih"]) assert.ok(receipt.includes(phrase));
  assert.match(presentation, /maximumFractionDigits: 3/);
  assert.match(presentation, /formatRupiah/);
  assert.match(css, /\.pos-receipt-item>strong\{display:block;overflow-wrap:anywhere/);
  assert.match(receipt, /payment\.method === "CASH"/);
  assert.match(receipt, /receipt\.payments\.map/);
  assert.doesNotMatch(receipt, /hpp|wac|cogs|margin|profit|inventory value|source.layer/i);
});

test("58 mm and 80 mm print styles isolate the receipt region", () => {
  assert.match(ui, /value="58">58 mm/);
  assert.match(ui, /value="80">80 mm/);
  assert.match(ui, /window\.print\(\)/);
  assert.match(css, /@media print[\s\S]*body \*\{visibility:hidden!important\}[\s\S]*\.pos-print-root/);
  assert.match(css, /\.pos-receipt-58\{width:58mm!important/);
  assert.match(css, /\.pos-receipt-80\{width:80mm!important/);
});

test("transaction-new is an explicit action and does not reopen the completed cart", () => {
  assert.match(ui, /const startNewTransaction = async/);
  assert.match(ui, /await createPosCart\(uuid\(\)\)/);
  assert.match(ui, /setReceipt\(null\)/);
  assert.match(ui, /reload\(\)/);
});
