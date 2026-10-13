import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("Kasir & Penjualan is active from Settings and uses the canonical POS settings form", async () => {
  const [home, page, form] = await Promise.all([
    read("app/(workspace)/pengaturan/page.tsx"),
    read("app/(workspace)/pengaturan/kasir-penjualan/page.tsx"),
    read("src/components/settings/pos-settings-form.tsx"),
  ]);
  assert.match(home, /href="\/pengaturan\/kasir-penjualan"/);
  assert.match(home, /Member & Poin/);
  assert.match(home, /Keuangan/);
  assert.match(home, /Sistem/);
  assert.match(page, /profile\.role !== "OWNER" && profile\.role !== "ADMIN"/);
  assert.match(page, /canEdit=\{profile\.role === "OWNER"\}/);
  assert.match(form, /workspace-primary-action\.module\.css/);
  assert.match(form, /enabled_payment_methods/);
  assert.match(form, /Izinkan Hold Transaksi/);
  assert.match(form, /receipt_footer_note/);
  assert.doesNotMatch(form, /Transfer Bank/);
});

test("POS consumes effective settings and backend maps stale-setting failures clearly", async () => {
  const [workspace, page, action, migration] = await Promise.all([
    read("src/components/pos/pos-workspace.tsx"),
    read("app/(workspace)/kasir/page.tsx"),
    read("src/app/actions/pos-cart.ts"),
    read("supabase/migrations/20260929475000_pos_settings_v1.sql"),
  ]);
  assert.match(page, /readEffectivePosSettings/);
  assert.match(workspace, /settings\.enabled_payment_methods/);
  assert.match(workspace, /settings\.allow_hold_transactions/);
  assert.match(workspace, /settings\.confirm_cart_cancellation/);
  assert.match(action, /POS_PAYMENT_METHOD_DISABLED/);
  assert.match(action, /POS_HOLD_DISABLED/);
  assert.match(migration, /sale_payments_enabled_method_guard/);
  assert.match(migration, /pos_cart_hold_enabled_guard/);
  assert.match(migration, /pg_advisory_xact_lock/);
});

test("receipt presentation uses outlet configuration without changing sale evidence", async () => {
  const [migration, receipt] = await Promise.all([
    read("supabase/migrations/20260929475000_pos_settings_v1.sql"),
    read("src/components/pos/pos-receipt.tsx"),
  ]);
  assert.match(migration, /CASE WHEN coalesce\(ps\.receipt_show_address,true\)/);
  assert.match(migration, /CASE WHEN coalesce\(ps\.receipt_show_phone,true\)/);
  assert.match(migration, /'receipt_footer_note',ps\.receipt_footer_note/);
  assert.match(receipt, /receipt_footer_note/);
  assert.match(receipt, /Terima kasih<br \/>Belanja hemat/);
  assert.match(receipt, /receipt\.receipt_footer_note\.trim\(\)/);
  assert.match(migration, /REVOKE ALL ON public\.outlet_pos_settings FROM PUBLIC,anon,authenticated,service_role/);
});

test("settings defaults keep existing payment, hold, and receipt behavior until OWNER saves", async () => {
  const migration = await read("supabase/migrations/20260929475000_pos_settings_v1.sql");
  assert.match(migration, /payment_cash_enabled boolean NOT NULL DEFAULT true/);
  assert.match(migration, /payment_qris_enabled boolean NOT NULL DEFAULT true/);
  assert.match(migration, /payment_card_enabled boolean NOT NULL DEFAULT true/);
  assert.match(migration, /payment_e_wallet_enabled boolean NOT NULL DEFAULT true/);
  assert.match(migration, /allow_hold_transactions boolean NOT NULL DEFAULT true/);
  assert.match(migration, /coalesce\(s\.receipt_show_address,true\)/);
  assert.match(migration, /coalesce\(s\.receipt_show_phone,true\)/);
  assert.match(migration, /LEFT JOIN public\.outlet_pos_settings s/);
});
