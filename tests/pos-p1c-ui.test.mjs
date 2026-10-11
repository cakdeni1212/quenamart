import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const route = await readFile(new URL("../app/(workspace)/kasir/page.tsx", import.meta.url), "utf8");
const ui = await readFile(new URL("../src/components/pos/pos-workspace.tsx", import.meta.url), "utf8");
const actions = await readFile(new URL("../src/app/actions/pos-cart.ts", import.meta.url), "utf8");
const roles = await readFile(new URL("../src/lib/auth/roles.ts", import.meta.url), "utf8");
const css = await readFile(new URL("../app/globals.css", import.meta.url), "utf8");

test("canonical Kasir route is role gated and recovers a persisted active cart", () => {
  assert.match(route, /canAccessSection\(profile\.role, "kasir"\)/);
  assert.match(route, /redirect\("\/dashboard"\)/);
  assert.match(roles, /kasir: \["OWNER", "ADMIN", "KASIR"\]/);
  assert.match(route, /readPosCartWorkspace\(\)/);
  assert.match(route, /!workspace\.carts\.some\(\(cart\) => cart\.status === "ACTIVE"\)/);
  assert.match(route, /createPosCart\(crypto\.randomUUID\(\)\)/);
});

test("Enter does exact barcode lookup without debounce and success restores scanner focus", () => {
  assert.match(ui, /onKeyDown=\{\(event\).*event\.key === "Enter"[\s\S]*void scan\(\)/);
  assert.match(ui, /resolvePosBarcode\(code\)/);
  assert.match(ui, /BARCODE_NOT_FOUND: "Barcode belum terdaftar"/);
  assert.match(ui, /BARCODE_AMBIGUOUS: "Barcode terdaftar pada lebih dari satu produk"/);
  assert.match(ui, /input\.current\?\.focus\(\)/);
  assert.match(actions, /resolvePosBarcode/);
  assert.match(ui, /scannerAlreadyBusy = false/);
  assert.match(ui, /product_id\), true\)/);
  assert.match(ui, /searchSequence\.current \+= 1/);
});

test("manual product lookup is debounced, bounded, and adds selected results", () => {
  assert.match(ui, /window\.setTimeout\(async \(\) =>/);
  assert.match(ui, /\}, 230\)/);
  assert.match(ui, /onClick=\{\(\) => void add\(String\(item\.product_id\)\)\}/);
  assert.match(actions, /p_limit: 25/);
  assert.match(actions, /trim\(\)\.length < 2/);
});

test("persisted customer carts survive hold, new-cart service, and resume", () => {
  assert.match(ui, /transition\(cart, "park"\)/);
  assert.match(ui, /ensureActivePosCart\(\)/);
  assert.match(ui, /transition\(item, "resume"\)/);
  assert.match(ui, /initialCarts\.map\(asCart\)/);
  assert.match(ui, /router\.refresh\(\)/);
});

test("cart changes use fresh request identities and read-model revision guards", () => {
  for (const operation of ["addPosCartItem", "setPosCartItemQuantity", "acknowledgePosCartPrice", "parkPosCart", "resumePosCart", "cancelPosCart"]) assert.match(ui, new RegExp(`${operation}\\(`));
  assert.match(ui, /expectedRevision: cart\.revision/);
  assert.match(ui, /requestId: uuid\(\)/);
  assert.match(actions, /Transaksi berubah di perangkat lain\. Data telah diperbarui\./);
  assert.match(actions, /expectedRevision/);
  assert.match(actions, /requestId/);
});

test("cashier UI surfaces quantities, safe price states, totals, parked carts, and disabled payment", () => {
  for (const phrase of ["Harga berubah", "Harga saat dimasukkan", "Harga terbaru", "Gunakan harga terbaru", "UNAVAILABLE", "TOTAL", "Tahan Transaksi", "Transaksi Ditahan", "Lanjutkan", "Batalkan Transaksi", "Pembayaran akan tersedia setelah modul checkout aktif."]) assert.ok(ui.includes(phrase), `missing ${phrase}`);
  assert.match(ui, /className="pos-pay" disabled aria-disabled="true"/);
  assert.match(ui, /observed_total/);
  assert.match(ui, /observed_line_total/);
  assert.match(ui, /className="pos-remove-line"/);
  assert.doesNotMatch(ui, /hpp|wac|cogs|margin|inventory value/i);
});

test("cashier polish hides internal cart ids and keeps cart actions outside the scrolling item list", () => {
  assert.match(ui, /<h2>Transaksi Aktif<\/h2>/);
  assert.doesNotMatch(ui, /Keranjang \$\{cart\.id|item\.id\.slice\(0, 8\)/);
  assert.match(ui, /className="pos-items"/);
  assert.match(ui, /<div className="pos-total">/);
  assert.match(ui, /className="pos-cart-actions"/);
  assert.match(css, /max-height:calc\(100dvh - 28px\)/);
  assert.match(css, /min-height:0;max-height:none;overscroll-behavior:contain/);
});

test("empty and parked states are compact and parked rows show operational summaries", () => {
  assert.match(ui, /Belum ada barang/);
  assert.match(ui, /Scan barcode atau cari produk untuk mulai transaksi\./);
  assert.match(ui, /pos-parked-empty-state/);
  assert.match(ui, /dateStyle: "short", timeStyle: "short"/);
  assert.match(ui, /\{item\.items\.length\} barang/);
  assert.match(ui, /\{rupiah\(item\.observed_total\)\}/);
  assert.doesNotMatch(ui, /Keranjang \$\{item\.id|item\.id\.slice/);
});

test("success feedback expires while error feedback remains visible", () => {
  assert.match(ui, /setTimeout\(\(\) => setNotice\(""\), 2400\)/);
  assert.match(ui, /if \(!isSuccessNotice\) return/);
  assert.match(ui, /pos-notice-success/);
});

test("P1C UI and actions contain no checkout or stock/costing writer", () => {
  assert.doesNotMatch(ui + actions, /complete_sale|checkout\(|sale_payments|SALE_COGS|SALE.*stock|stock_balance_projection.*UPDATE|activate_wac|bootstrap/i);
  assert.match(ui, /className="pos-pay" disabled/);
});
