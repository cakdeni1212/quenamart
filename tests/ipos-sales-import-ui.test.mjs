import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const page = readFileSync(new URL("../app/(workspace)/transaksi/import-ipos/page.tsx", import.meta.url), "utf8");
const actions = readFileSync(new URL("../src/app/actions/ipos-sales-import.ts", import.meta.url), "utf8");
const workspace = readFileSync(new URL("../src/components/sales/ipos-sales-import-workspace.tsx", import.meta.url), "utf8");
const sidebar = readFileSync(new URL("../src/components/app/sidebar.tsx", import.meta.url), "utf8");
const payload = readFileSync(new URL("../src/lib/ipos-sales/ui-payload.ts", import.meta.url), "utf8");
const validation = readFileSync(new URL("../src/lib/ipos-sales/upload-validation.ts", import.meta.url), "utf8");

test("iPos sales import route and every server operation restrict access to OWNER/ADMIN", () => {
  assert.match(page, /profile\.role !== "OWNER" && profile\.role !== "ADMIN"/);
  assert.match(actions, /profile\.role === "OWNER" \|\| profile\.role === "ADMIN"/);
  assert.match(actions, /ipos_sales_import_recheck/);
  assert.match(actions, /ipos_sales_import_commit/);
  assert.match(sidebar, /role === "OWNER" \|\| role === "ADMIN"/);
});

test("upload validates supported workbook, parses and hashes it on server, then persists before explicit commit", () => {
  assert.match(validation, /\(xls\|xlsx\)/);
  assert.match(actions, /parseIposSalesWorkbook/);
  assert.match(actions, /validateIposSalesUpload\(entry\.name, entry\.size\)/);
  assert.match(actions, /createHash\("sha256"\)/);
  assert.match(actions, /createAdminClient\(\)/);
  assert.match(actions, /ipos_sales_import_upload/);
  assert.doesNotMatch(actions.slice(actions.indexOf("export async function uploadIposSales"), actions.indexOf("export async function recheckIposSales")), /ipos_sales_import_commit/);
  assert.match(actions, /p_payload: parsed/);
});

test("workspace presents review, blocker resolution, explicit confirmation, and success without exposing backend internals", () => {
  for (const label of ["Upload Laporan Penjualan", "Periksa File", "Ringkasan Laporan", "Tanggal Penjualan", "Baris Penjualan", "SKU Ditemukan", "Rekonsiliasi Laporan", "SKU belum terdaftar", "Stok produk belum siap", "Transaksi sudah pernah diimport", "Konflik dengan opname", "Cek Ulang", "Import Penjualan", "Import Penjualan iPos?", "Import Sekarang", "Penjualan berhasil diimport", "Data metode pembayaran dan laba transaksi iPos tidak tersedia"]) {
    assert.ok(workspace.includes(label), `missing UI copy: ${label}`);
  }
  assert.match(workspace, /recheckIposSales\(batchId\)/);
  assert.match(workspace, /commitIposSales\(batchId, num\(batch\?\.revision\)\)/);
  assert.match(workspace, /disabled={!isReady \|\| busy}/);
  assert.match(workspace, /href="\/import-ipos"/);
  assert.match(workspace, /href="\/pembelian\/barang-masuk"/);
  assert.match(workspace, /formatIposSalesRevenue\(batch\.total_amount\)/);
  assert.doesNotMatch(workspace, /formatRupiah\(text\(batch\.total_amount, "0"\)\)/);
  assert.doesNotMatch(workspace, /SHA-256|source layer|WAC writer|request ID|raw SQL/i);
});

test("recent list is bounded and page remains usable with responsive stacked cards", () => {
  assert.match(page, /p_limit: 8/);
  const css = readFileSync(new URL("../src/components/sales/ipos-sales-import.module.css", import.meta.url), "utf8");
  assert.match(css, /@media\(max-width:640px\)/);
  assert.match(css, /grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/);
  assert.match(css, /text-overflow:ellipsis/);
  assert.match(payload, /unresolvedCount > 500/);
  assert.match(payload, /sentDuplicateCount < 100/);
  assert.match(payload, /unique_sku_count: uniqueSkuCount/);
});

test("batch search-param navigation remounts workspace for selection changes and handles inaccessible batches", () => {
  assert.match(page, /key=\{batchParam \?\? "upload"\}/);
  assert.match(page, /initialError=\{initialError\}/);
  assert.match(page, /!validBatchParam \|\| batchResult\.error \|\| !batchResult\.data/);
  assert.match(workspace, /initialError\?: string \| null/);
  assert.match(workspace, /useState<string \| null>\(initialError\)/);
  assert.match(workspace, /href=\{`\/transaksi\/import-ipos\?batch=\$\{encodeURIComponent\(row\.id\)\}`\}/);

  // The key follows the selected query value: upload → A → B → A → upload
  // creates a new workspace for each navigation, while server actions keep
  // the same key and therefore preserve their locally refreshed batch state.
  const workspaceKey = (batch) => batch ?? "upload";
  assert.notEqual(workspaceKey(undefined), workspaceKey("batch-a"));
  assert.notEqual(workspaceKey("batch-a"), workspaceKey("batch-b"));
  assert.equal(workspaceKey("batch-a"), workspaceKey("batch-a"));
  assert.equal(workspaceKey(undefined), "upload");
});
