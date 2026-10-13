import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const [home, detail, form, action, migration, receipt, architecture, styles, buttons] = await Promise.all([
  read("../app/(workspace)/pengaturan/page.tsx"),
  read("../app/(workspace)/pengaturan/toko-outlet/page.tsx"),
  read("../src/components/settings/outlet-settings-form.tsx"),
  read("../src/app/actions/outlet-settings.ts"),
  read("../supabase/migrations/20260929474000_store_outlet_settings_v1.sql"),
  read("../src/components/pos/pos-receipt.tsx"),
  read("../docs/ARCHITECTURE.md"),
  read("../src/components/settings/settings.module.css"),
  read("../src/components/ui/workspace-primary-action.module.css"),
]);

test("Settings directory links implemented sections and leaves future sections non-navigable", () => {
  assert.match(home, /href="\/pengaturan\/toko-outlet"/);
  assert.match(home, /href="\/pengaturan\/kasir-penjualan"/);
  assert.match(home, /href="\/pengaturan\/akun"/);
  assert.match(home, /Kasir &amp; Penjualan/);
  assert.match(home, /Member & Poin/);
  assert.match(home, /Segera/);
  assert.match(home, /profile\.role !== "OWNER" && profile\.role !== "ADMIN"/);
  assert.match(home, /aria-disabled="true"/);
  assert.doesNotMatch(home, /href=.*(?:Member|Keuangan|Sistem)/);
});

test("outlet route gives OWNER edit controls and ADMIN read-only access", () => {
  assert.match(detail, /profile\.role !== "OWNER" && profile\.role !== "ADMIN"/);
  assert.match(detail, /canEdit=\{profile\.role === "OWNER"\}/);
  assert.match(detail, /readOutletSettings\(\)/);
  assert.match(action, /profile\.role !== "OWNER"/);
  assert.match(action, /supabase\.rpc\("outlet_settings_update"/);
  assert.match(migration, /v_role IS DISTINCT FROM 'OWNER'::public\.user_role/);
  assert.match(migration, /v_role NOT IN \('OWNER'::public\.user_role,'ADMIN'::public\.user_role\)/);
  assert.match(migration, /REVOKE INSERT,UPDATE,DELETE ON public\.outlets FROM PUBLIC,anon,authenticated/);
});

test("form validates identity, preserves phone strings, avoids duplicate/no-op saves, and keeps timezone read-only", () => {
  assert.match(form, /Nama Outlet <span className=\{styles\.required\} aria-hidden="true">\*<\/span>/);
  assert.match(form, /Nama yang tampil ke pelanggan<\/span><input/);
  assert.match(form, /required maxLength=\{120\}/);
  assert.match(action, /if \(!values\.name\)/);
  assert.match(action, /if \(values\.email && !\/\^\[\^\\s@\]/);
  assert.match(form, /type="tel" maxLength=\{40\}/);
  assert.doesNotMatch(form, /parseInt\([^)]*phone|Number\([^)]*phone/);
  assert.match(form, /className=\{primaryAction\.primary\} type="submit" disabled=\{pending \|\| !changed\}/);
  assert.match(form, /pending \? "Menyimpan\.\.\." : "Simpan Perubahan"/);
  assert.match(form, /setNotice\(\{ kind: result\.ok \? "success" : "error", text: result\.message \}\)/);
  assert.match(form, /if \(result\.ok\) router\.refresh\(\)/);
  assert.match(styles, /\.labelText\{display:block;min-height:1\.4em/);
  assert.match(styles, /\.formFooter\{[^}]*padding:14px 2px 22px/);
  assert.match(styles, /@media\(max-width:700px\)[\s\S]*\.formFooter\{align-items:stretch;flex-direction:column\}[\s\S]*\.formFooter button\{width:100%\}/);
  assert.match(buttons, /\.primary:disabled\s*\{\s*border-color: #dce6d8;\s*background: #eaf0e7;\s*color: #84927f;\s*cursor: not-allowed;/);
  assert.match(form, /Asia\/Jakarta/);
  assert.match(form, /readOnly aria-readonly="true"/);
  assert.match(migration, /updated_by=v_actor,updated_at=now\(\)/);
  assert.match(migration, /OUTLET_SETTINGS_UPDATED/);
  assert.match(migration, /changed_fields text\[\]/);
});

test("outlet identity and history are protected, active outlet deactivation is guarded", () => {
  assert.match(migration, /NEW\.code IS DISTINCT FROM OLD\.code/);
  assert.match(migration, /OUTLET_DELETE_NOT_ALLOWED/);
  assert.match(migration, /OUTLET_SETTINGS_DEACTIVATION_BLOCKED/);
  assert.match(migration, /stock_authority_periods p WHERE p\.outlet_id=v_outlet\.id AND p\.ended_at IS NULL/);
  assert.match(migration, /ON DELETE RESTRICT/);
  assert.match(migration, /outlet_settings_current_id\(\)/);
  assert.match(migration, /p_outlet_id IS DISTINCT FROM public\.outlet_settings_current_id\(\)/);
});

test("native receipt reads current canonical outlet identity without changing sale snapshots", () => {
  assert.match(migration, /'outlet_display_name',coalesce\(nullif\(btrim\(o\.customer_display_name\),''\),o\.name\)/);
  assert.match(migration, /'outlet_address'/);
  assert.match(receipt, /receipt\.outlet_display_name/);
  assert.match(receipt, /receipt\.outlet_address/);
  assert.match(migration, /product_name_snapshot/);
  assert.match(architecture, /Native receipt rendering reads the current outlet display identity/);
});

test("Settings remains under the existing sidebar item and responsive utility styles", async () => {
  const sidebar = await read("../src/components/app/sidebar.tsx");
  const css = await read("../src/components/settings/settings.module.css");
  assert.match(sidebar, /href: "\/pengaturan"/);
  assert.match(sidebar, /pathname\.startsWith\("\/pengaturan\/akun"\)/);
  assert.match(sidebar, /pathname\.startsWith\(\`\$\{item\.href\}\/\`\)/);
  assert.match(css, /@media\(max-width:700px\)/);
  assert.match(css, /grid-template-columns:1fr/);
});
