import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = await readFile(new URL("../supabase/migrations/20260929480000_whatsapp_center_foundation_v1.sql", import.meta.url), "utf8");
const settings = await readFile(new URL("../src/components/settings/whatsapp-settings-form.tsx", import.meta.url), "utf8");
const adapter = await readFile(new URL("../src/lib/notifications/whatsapp-adapter.server.ts", import.meta.url), "utf8");

test("WhatsApp delivery defaults fail closed and create no historical jobs", () => {
  assert.match(migration, /whatsapp_transactions_enabled boolean NOT NULL DEFAULT false/);
  assert.match(migration, /automatic_receipt_enabled boolean NOT NULL DEFAULT false/);
  assert.match(migration, /provider_state text NOT NULL DEFAULT 'NOT_CONFIGURED'/);
  assert.equal((migration.match(/INSERT INTO public\.notification_outbox\(/g) ?? []).length, 1);
});

test("outbox eligibility is native, consent-gated, configuration-gated, and idempotent", () => {
  assert.match(migration, /source_system='QUENA_POS'/);
  assert.match(migration, /automatic_receipt_enabled/);
  assert.match(migration, /provider_state<>'CONNECTED'/);
  assert.match(migration, /public_url_ready/);
  assert.match(migration, /consent_type='MEMBERSHIP_SERVICE'/);
  assert.match(migration, /UNIQUE\(channel,notification_type,aggregate_type,aggregate_id\)/);
});

test("outbox snapshots a receipt reference without storing bearer material", () => {
  assert.match(migration, /'receipt_reference',receipt_id/);
  assert.doesNotMatch(migration, /'receipt_url'\s*,/);
  assert.doesNotMatch(migration, /'receipt_token'\s*,/);
  assert.match(migration, /destination_snapshot text NOT NULL/);
});

test("browser roles cannot directly read or mutate outbox and worker RPCs are service-only", () => {
  assert.match(migration, /REVOKE ALL ON public\.notification_outbox FROM PUBLIC,anon,authenticated,service_role/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.notification_outbox_claim\(integer\) TO service_role/);
  assert.match(migration, /FOR UPDATE SKIP LOCKED/);
});

test("settings update is owner-only and emits bounded field audit evidence", () => {
  assert.match(migration, /r IS DISTINCT FROM 'OWNER'::public\.user_role/);
  assert.match(migration, /WHATSAPP_SETTINGS_UPDATED/);
  assert.match(migration, /changed_fields,old_config,new_config/);
});

test("server action and settings form enforce the owner mutation boundary", () => {
  assert.match(settings, /canEdit/);
  assert.match(settings, /Simpan Perubahan/);
  assert.match(settings, /effectiveProviderState === "CONNECTED"/);
});

test("unconfigured provider makes no network calls and never requests queued work", () => {
  assert.match(adapter, /async getConnectionStatus\(\) \{ return "NOT_CONFIGURED"/);
  assert.match(adapter, /PROVIDER_NOT_CONFIGURED/);
  assert.match(adapter, /getConnectionStatus\(\) !== "CONNECTED"\) return \[\]/);
});

test("retry schedule is bounded and deterministic", () => {
  assert.match(adapter, /\[1, 5, 30, 120\]\[attempt - 1\] \?\? null/);
  assert.match(migration, /n\.attempt_count<5/);
  assert.match(migration, /MAX_ATTEMPTS/);
});

test("transaction detail and management pages use role-gated bounded contracts", async () => {
  const roles = await readFile(new URL("../src/lib/auth/roles.ts", import.meta.url), "utf8");
  const tx = await readFile(new URL("../src/components/sales/whatsapp-delivery-status.tsx", import.meta.url), "utf8");
  const summary = await readFile(new URL("../app/(workspace)/whatsapp/page.tsx", import.meta.url), "utf8");
  assert.match(roles, /whatsapp: \["OWNER", "ADMIN"\]/);
  assert.match(tx, /readWhatsAppSaleDeliveryStatus/);
  assert.match(summary, /readWhatsAppSummary/);
  assert.match(migration, /destination_masked/);
});

test("WhatsApp Center uses the existing summary/settings contracts and retains role access", async () => {
  const summary = await readFile(new URL("../app/(workspace)/whatsapp/page.tsx", import.meta.url), "utf8");
  const controls = await readFile(new URL("../src/components/notifications/whatsapp-center-controls.tsx", import.meta.url), "utf8");
  const roles = await readFile(new URL("../src/lib/auth/roles.ts", import.meta.url), "utf8");
  assert.match(summary, /readWhatsAppSummary\(\)/);
  assert.match(summary, /readWhatsAppSettings\(\)/);
  assert.match(summary, /canAccessSection\(profile\.role,\s*"whatsapp"\)/);
  assert.match(summary, /Riwayat Pengiriman/);
  assert.match(summary, /Belum ada notifikasi WhatsApp\./);
  assert.match(roles, /whatsapp: \["OWNER", "ADMIN"\]/);
  assert.match(summary, /canEdit={profile\.role === "OWNER"}/);
  assert.match(controls, /disabled={!canEdit \|\| saving/);
  assert.match(controls, /ADMIN dapat melihat pengaturan/);
  assert.match(controls, /updateWhatsAppSettings/);
  assert.match(controls, /<QuenaSwitch/);
  assert.match(controls, /router\.refresh\(\)/);
});

test("WhatsApp Center dashboard has responsive two-column and mobile ordering", async () => {
  const css = await readFile(new URL("../src/components/notifications/whatsapp-center.module.css", import.meta.url), "utf8");
  assert.match(css, /grid-template-columns:minmax\(0,3fr\) minmax\(300px,1fr\)/);
  assert.match(css, /\.dashboardMain,\.dashboardSidebar\{[\s\S]*?display:flex;[\s\S]*?flex-direction:column;[\s\S]*?gap:18px/);
  assert.match(css, /"status" "metrics" "quick" "info" "history"/);
  assert.match(css, /overflow-x:auto/);
  assert.match(css, /\.settingsLink\{[^}]*width:100%[^}]*min-height:42px/);
});
