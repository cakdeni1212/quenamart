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

test("POS settings shared definitions stay client-safe and reads stay server-only", async () => {
  const [shared, server, form, workspace, settingsPage, cashierPage, action] = await Promise.all([
    read("src/lib/settings/pos-shared.ts"),
    read("src/lib/settings/pos.server.ts"),
    read("src/components/settings/pos-settings-form.tsx"),
    read("src/components/pos/pos-workspace.tsx"),
    read("app/(workspace)/pengaturan/kasir-penjualan/page.tsx"),
    read("app/(workspace)/kasir/page.tsx"),
    read("src/app/actions/pos-settings.ts"),
  ]);
  assert.doesNotMatch(shared, /supabase\/server|next\/headers|server-only|createClient/);
  assert.match(server, /^import "server-only";/);
  assert.match(server, /@\/lib\/supabase\/server/);
  assert.match(form, /@\/lib\/settings\/pos-shared/);
  assert.match(workspace, /@\/lib\/settings\/pos-shared/);
  assert.doesNotMatch(form, /@\/lib\/settings\/pos\.server|@\/lib\/supabase\/server/);
  assert.doesNotMatch(workspace, /@\/lib\/settings\/pos\.server|@\/lib\/supabase\/server/);
  assert.match(settingsPage, /readPosSettings\(\)/);
  assert.match(cashierPage, /readEffectivePosSettings\(\)/);
  assert.match(action, /supabase\.rpc\("pos_settings_update"/);
});

test("POS setting booleans use accessible Quena switches rather than native checkboxes", async () => {
  const [form, component, css, settingsCss] = await Promise.all([
    read("src/components/settings/pos-settings-form.tsx"),
    read("src/components/ui/quena-switch.tsx"),
    read("src/components/ui/quena-switch.module.css"),
    read("src/components/settings/settings.module.css"),
  ]);
  assert.equal((form.match(/<QuenaSwitch\b/g) ?? []).length, 5);
  assert.equal((form.match(/\{ method: "(?:CASH|QRIS|CARD|E_WALLET)", label:/g) ?? []).length, 4);
  assert.doesNotMatch(form, /type="checkbox"/);
  assert.match(component, /role="switch"/);
  assert.match(component, /aria-checked=\{checked\}/);
  assert.match(component, /aria-label=\{label\}/);
  assert.match(component, /type="button"/);
  assert.match(css, /data-state="on"\]\{background:#315d3b\}/);
  assert.match(css, /transform:translateX\(16px\)/);
  assert.doesNotMatch(settingsCss, /posSettingRow input\[type=checkbox\]/);
  assert.match(form, /enabled_payment_methods\.length > 0/);
  assert.match(form, /disabled=\{pending \|\| !changed \|\| !valid\}/);
});
