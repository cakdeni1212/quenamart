import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("Member & Poin is an active outlet-scoped settings page with safe OFF defaults", async () => {
  const [home, page, form, migration, reader, action] = await Promise.all([
    read("app/(workspace)/pengaturan/page.tsx"),
    read("app/(workspace)/pengaturan/member-poin/page.tsx"),
    read("src/components/settings/member-points-settings-form.tsx"),
    read("supabase/migrations/20260929477000_member_loyalty_policy_v1.sql"),
    read("src/lib/settings/member-points.server.ts"),
    read("src/app/actions/member-points-settings.ts"),
  ]);
  assert.match(home, /href="\/pengaturan\/member-poin"/);
  assert.doesNotMatch(home, /\["Member & Poin"/);
  assert.match(page, /profile\.role !== "OWNER" && profile\.role !== "ADMIN"/);
  assert.match(page, /canEdit=\{profile\.role === "OWNER"\}/);
  assert.match(migration, /program_enabled boolean NOT NULL DEFAULT false/);
  assert.match(migration, /coalesce\(s\.program_enabled,false\)/);
  assert.match(migration, /REVOKE ALL ON public\.outlet_loyalty_settings FROM PUBLIC,anon,authenticated,service_role/);
  assert.match(migration, /LOYALTY_SETTINGS_UPDATED/);
  assert.match(migration, /LOYALTY_SETTINGS_UPDATE_DENIED/);
  assert.match(reader, /^import "server-only";/);
  assert.match(action, /profile\.role !== "OWNER"/);
  assert.match(form, /QuenaSwitch/);
  assert.match(form, /RupiahInput/);
  assert.match(form, /Dihitung|Pratinjau memakai nilai yang sedang diisi/);
});

test("checkout uses atomic earn-after-redemption math and snapshots immutable policy evidence", async () => {
  const migration = await read("supabase/migrations/20260929477000_member_loyalty_policy_v1.sql");
  const checkout = migration.slice(migration.indexOf("CREATE OR REPLACE FUNCTION public.pos_checkout_complete"), migration.indexOf("CREATE OR REPLACE FUNCTION public.pos_sale_receipt_read"));
  assert.match(checkout, /FOR UPDATE;[\s\S]*FROM public\.member_point_ledger WHERE member_id=c\.member_id/);
  assert.match(checkout, /v_discount:=v_requested_points::numeric\*v_redeem_rate/);
  assert.match(checkout, /v_payable:=total-v_discount/);
  assert.match(checkout, /floor\(v_payable\/v_earn_rate\)::bigint/);
  assert.match(checkout, /'SALE_REDEEM',-v_requested_points/);
  assert.match(checkout, /'SALE_EARN',v_earned_points/);
  assert.match(checkout, /'rupiah_per_redeem_point',v_redeem_rate/);
  assert.match(checkout, /'rupiah_per_point',v_earn_rate/);
  assert.match(checkout, /'eligible_spend',v_payable::text/);
  assert.match(checkout, /inventory_cost_apply_pos_sale/);
  assert.match(checkout, /'grand_total',v_payable/);
  assert.match(migration, /IF v_discount>total THEN RAISE EXCEPTION[\s\S]*POS_LOYALTY_EXCEEDS_PAYABLE/);
  assert.match(migration, /CREATE UNIQUE INDEX member_point_sale_event_once/);
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.pos_sale_receipt_read/);
  assert.match(migration, /'loyalty',CASE WHEN EXISTS/);
});

test("POS applies persisted partial redemption and leaves authoritative validation to checkout", async () => {
  const [workspace, action, loader, detail, memberDetail] = await Promise.all([
    read("src/components/pos/pos-workspace.tsx"),
    read("src/app/actions/pos-cart.ts"),
    read("src/lib/members/read.server.ts"),
    read("app/(workspace)/transaksi/[id]/page.tsx"),
    read("src/components/members/member-detail-workspace.tsx"),
  ]);
  assert.match(loader, /pos_member_loyalty_read/);
  assert.match(action, /setPosCartRedeemPoints/);
  assert.match(workspace, /setPosCartRedeemPoints/);
  assert.match(workspace, /setRedeemDraft\(String\(points\)\)/);
  assert.match(workspace, /POS_LOYALTY/);
  assert.match(workspace, /TOTAL BAYAR/);
  assert.match(workspace, /payableTotal/);
  assert.match(detail, /receipt\.loyalty/);
  assert.match(memberDetail, /Poin dari belanja/);
  assert.match(memberDetail, /Tukar poin/);
});
