import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("Member Core reuses customer identity, stable numbers, phone lookup, and append-only point evidence", async () => {
  const sql = await read("supabase/migrations/20260929476000_member_core_v1.sql");
  assert.match(sql, /CREATE TABLE public\.members/);
  assert.match(sql, /CREATE SEQUENCE public\.member_number_seq/);
  assert.match(sql, /'QMEM-'\|\|lpad\(nextval\('public\.member_number_seq'\)::text,8,'0'\)/);
  assert.match(sql, /phone_normalized text GENERATED ALWAYS AS/);
  assert.match(sql, /members_active_phone_once/);
  assert.match(sql, /member_token uuid NOT NULL DEFAULT gen_random_uuid\(\)/);
  assert.match(sql, /CREATE TABLE public\.member_point_ledger/);
  assert.match(sql, /CREATE TRIGGER member_point_ledger_immutable BEFORE UPDATE OR DELETE/);
  assert.match(sql, /REVOKE ALL ON public\.members,public\.member_audit_events,public\.member_point_ledger FROM PUBLIC,anon,authenticated,service_role/);
  assert.match(sql, /member_upsert/);
  assert.match(sql, /member_status_set/);
});

test("Member workspace is bounded and role limited; POS lookup exposes only active member essentials", async () => {
  const [sql, roles, listPage, detailPage, reader, workspace] = await Promise.all([
    read("supabase/migrations/20260929476000_member_core_v1.sql"),
    read("src/lib/auth/roles.ts"),
    read("app/(workspace)/member/page.tsx"),
    read("app/(workspace)/member/[id]/page.tsx"),
    read("src/lib/members/read.server.ts"),
    read("src/components/members/member-workspace.tsx"),
  ]);
  assert.match(sql, /least\(greatest\(coalesce\(p_page_size,20\),1\),30\)/);
  assert.match(sql, /MEMBER_POS_LOOKUP_DENIED/);
  assert.match(sql, /member_pos_search/);
  assert.match(sql, /status='ACTIVE' AND q<>''/);
  assert.match(roles, /member: \["OWNER", "ADMIN"\]/);
  assert.match(listPage, /canAccessSection\(profile\.role, "member"\)/);
  assert.match(detailPage, /readMemberDetail/);
  assert.match(reader, /member_detail_read/);
  assert.match(workspace, /Cari nama, nomor HP, ID Member, atau kode member/);
  assert.match(workspace, /setTimeout\(async \(\) =>/);
  assert.match(workspace, /Simpan Member/);
  assert.match(workspace, /loadError \? null : rows\.length \?/);
  assert.match(reader, /Supabase RPC failed.*error\.code.*error\.message/s);
  assert.match(reader, /Invalid response contract/);
});

test("POS stores canonical active member and checkout rejects stale inactive member atomically", async () => {
  const [sql, posAction, posUi, checkout] = await Promise.all([
    read("supabase/migrations/20260929476000_member_core_v1.sql"),
    read("src/app/actions/pos-cart.ts"),
    read("src/components/pos/pos-workspace.tsx"),
    read("supabase/migrations/20260929350000_pos_atomic_checkout_v1.sql"),
  ]);
  assert.match(sql, /ALTER TABLE public\.pos_carts ADD COLUMN member_id uuid/);
  assert.match(sql, /ALTER TABLE public\.sales ADD COLUMN member_id uuid/);
  assert.match(sql, /NEW\.source_system<>'QUENA_POS'/);
  assert.match(sql, /FOR SHARE/);
  assert.match(sql, /POS_MEMBER_INACTIVE_OR_NOT_FOUND/);
  assert.match(posAction, /member_pos_search/);
  assert.match(posAction, /pos_cart_member_set/);
  assert.match(posUi, /Member \(opsional\)/);
  assert.match(posUi, /setPosCartMember/);
  assert.match(checkout, /INSERT INTO public\.sales/);
});

test("Member transaction and point reads do not fabricate iPos attribution or earning rules", async () => {
  const [sql, docs] = await Promise.all([
    read("supabase/migrations/20260929476000_member_core_v1.sql"),
    read("docs/LOYALTY.md"),
  ]);
  assert.match(sql, /s\.source_system='QUENA_POS'/);
  assert.match(sql, /NEW\.member_id:=NULL/);
  assert.match(sql, /sum\(l\.points_delta\)/);
  assert.doesNotMatch(sql, /INSERT INTO public\.member_point_ledger[\s\S]{0,200}SALE_EARN/);
  assert.match(docs, /No earning events are generated yet/);
  assert.match(docs, /Not implemented yet/);
  assert.match(docs, /iPos member attribution/);
});
