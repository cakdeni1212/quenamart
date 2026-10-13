import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { sidebarTreeForPath } from "../src/lib/navigation/sidebar-tree.ts";

const sidebar = await readFile(new URL("../src/components/app/sidebar.tsx", import.meta.url), "utf8");
const css = await readFile(new URL("../app/globals.css", import.meta.url), "utf8");
const roles = await readFile(new URL("../src/lib/auth/roles.ts", import.meta.url), "utf8");

test("only actual transaction and purchasing child routes identify a tree", () => {
  for (const route of ["/transaksi", "/transaksi/riwayat", "/transaksi/import-ipos", "/transaksi/import-ipos?batch=x"]) {
    assert.equal(sidebarTreeForPath(route.split("?")[0]), "transaksi");
  }
  for (const route of ["/pembelian", "/pembelian/barang-masuk", "/pembelian/retur-supplier", "/pembelian/supplier/abc", "/tempo-supplier"]) {
    assert.equal(sidebarTreeForPath(route), "pembelian");
  }
  for (const route of ["/dashboard", "/produk", "/import-ipos", "/tempo-supplier-lama"]) {
    assert.equal(sidebarTreeForPath(route), null);
  }
});

test("tree defaults to current route, toggles by button, and resynchronizes on route navigation", () => {
  assert.match(sidebar, /useState\(sidebarTreeForPath\(pathname\) === id\)/);
  assert.match(sidebar, /key=\{`transaksi:\$\{pathname\}`\}/);
  assert.match(sidebar, /key=\{`pembelian:\$\{pathname\}`\}/);
  assert.match(sidebar, /setExpanded\(\(current\) => !current\)/);
  assert.match(sidebar, /aria-expanded=\{expanded\}/);
  assert.match(sidebar, /nav-chevron-open/);
  assert.match(sidebar, /Riwayat Transaksi/);
  assert.match(sidebar, /Import Penjualan iPos/);
  assert.match(sidebar, /Retur Supplier/);
  assert.match(sidebar, /Tempo Supplier/);
});

test("active links and role-scoped child visibility remain tied to existing permissions", () => {
  assert.match(sidebar, /role === "OWNER" \|\| role === "ADMIN"/);
  assert.match(sidebar, /canAccessSection\(role, "tempo-supplier"\)/);
  assert.match(sidebar, /canAccessSection\(role, "pembelian"\)/);
  assert.match(sidebar, /aria-current=\{link\.active \? "page" : undefined\}/);
  assert.match(roles, /transaksi: \["OWNER", "ADMIN", "KASIR"\]/);
  assert.match(roles, /"tempo-supplier": \["OWNER", "ADMIN"\]/);
  assert.match(sidebar, /isTransactionTree = item\.label === "Transaksi" && \(role === "OWNER" \|\| role === "ADMIN"\)/);
});

test("desktop shell and compact viewport keep navigation independently reachable", () => {
  assert.match(css, /\.sidebar\{height:100dvh/);
  assert.match(css, /\.nav-list\{display:flex;flex:1;min-height:0/);
  assert.match(css, /overflow-y:auto/);
  assert.match(css, /\.sidebar>\.sidebar-bottom\{flex:none\}/);
  assert.match(css, /@media\(max-width:760px\)\{\s*\.sidebar\{height:auto/);
  assert.match(css, /max-height:min\(58dvh,440px\)/);
  assert.match(css, /\.nav-tree-group\{width:100%;flex:none\}/);
});
