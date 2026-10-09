import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/20260929290000_costing_purchase_receipt_acquisition_v1.sql", import.meta.url), "utf8");
const receiptBase = readFileSync(new URL("../supabase/migrations/20260929220000_purchasing_receipts_v1.sql", import.meta.url), "utf8");

test("C3A is a forward-only capability migration with no automatic costing activation", () => {
  assert.match(migration, /\bBEGIN;/);
  assert.match(migration, /COMMIT;\s*$/);
  assert.doesNotMatch(migration, /inventory_costing_outlet_authority\s*\([^;]*INSERT|UPDATE\s+public\.inventory_costing_outlet_authority/i);
  assert.doesNotMatch(migration, /(?:SELECT|PERFORM|CALL)\s+public\.inventory_cost_bootstrap_outlet\s*\(/i);
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.inventory_cost_bootstrap_outlet/);
  assert.match(migration, /This only defines future bootstrap behavior; this migration never invokes it/);
});

test("manager acquisition estimates are append-only, exact IDR evidence with protected reads", () => {
  assert.match(migration, /CREATE TABLE public\.purchase_receipt_acquisition_estimate_revisions/);
  assert.match(migration, /estimated_unit_price numeric\(20,2\)/);
  assert.match(migration, /currency text NOT NULL DEFAULT 'IDR' CHECK \(currency='IDR'\)/);
  assert.match(migration, /UNIQUE\(receipt_item_identity,revision\)/);
  assert.match(migration, /BEFORE UPDATE OR DELETE ON public\.purchase_receipt_acquisition_estimate_revisions/);
  assert.match(migration, /purchase_receipt_acquisition_estimate_manager_read[\s\S]*?OWNER[\s\S]*?ADMIN/);
  assert.match(migration, /purchase_receipt_acquisition_estimate_save\([\s\S]*?auth\.uid\(\)/);
  assert.match(migration, /p_unit_price<>trunc\(p_unit_price,2\)/);
  assert.match(migration, /AUTHORITATIVE_ZERO[\s\S]*?p_reason IS NULL OR btrim\(p_reason\)=''/);
  assert.match(migration, /'REMOVED'[\s\S]*?estimated_unit_price IS NULL/);
  assert.match(migration, /REVOKE ALL ON public\.purchase_receipt_acquisition_estimate_revisions FROM PUBLIC,anon,authenticated,service_role/);
  assert.match(migration, /GRANT SELECT ON public\.purchase_receipt_acquisition_estimate_revisions TO authenticated/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.purchase_receipt_acquisition_estimate_save/);
});

test("draft edits preserve item IDs and tombstone removed estimate evidence", () => {
  const save = migration.slice(migration.indexOf("CREATE OR REPLACE FUNCTION public.purchase_receipt_save_draft"), migration.indexOf("-- Include the current estimate revision"));
  assert.match(receiptBase, /DELETE FROM public\.purchase_receipt_items WHERE receipt_id = p_receipt_id/);
  assert.match(save, /ON CONFLICT\(receipt_id,product_id\) DO UPDATE/);
  assert.doesNotMatch(save, /DELETE FROM public\.purchase_receipt_items WHERE receipt_id\s*=/);
  assert.match(save, /append_purchase_receipt_estimate_revision[\s\S]*?'REMOVED'/);
  assert.match(save, /DELETE FROM public\.purchase_receipt_items WHERE id=v_removed\.id/);
});

test("partial valuation keeps physical, valued, provisional, and unvalued quantities explicit", () => {
  assert.match(migration, /physical_quantity numeric/);
  assert.match(migration, /ADD COLUMN valued_quantity_delta numeric/);
  assert.match(migration, /provisional_quantity numeric NOT NULL/);
  assert.match(migration, /unvalued_quantity numeric NOT NULL/);
  assert.match(migration, /physical_quantity=valued_quantity\+unvalued_quantity/);
  assert.match(migration, /inventory_cost_projection_status AS ENUM[\s\S]*?'PARTIALLY_UNVALUED'[\s\S]*?'UNVALUED'/);
  assert.match(migration, /current_wac=round\(inventory_value\/valued_quantity,8\)/);
  assert.match(migration, /IF v_valued=0 THEN v_value:=NULL;v_wac:=NULL/);
  assert.match(migration, /v_provisional:=v_cost\.provisional_quantity\+CASE WHEN v_basis IN \('MANAGER_ESTIMATE','CURRENT_WAC'\)/);
  assert.match(migration, /ELSIF v_item\.accepted_quantity>0 AND v_cost\.valued_quantity>0 AND v_cost\.inventory_value IS NOT NULL/);
});

test("purchase posting is cutover-gated and applies stock plus cost atomically", () => {
  const apply = migration.slice(migration.indexOf("CREATE OR REPLACE FUNCTION public.apply_purchase_receipt_post_intent"), migration.indexOf("GRANT USAGE ON TYPE"));
  assert.match(apply, /COST_BOOTSTRAP_OUTLET:/);
  assert.match(apply, /BOOTSTRAP_READY[\s\S]*?dijeda saat persiapan awal costing/);
  assert.match(apply, /ORDER BY i\.product_id/);
  assert.match(apply, /stock_authority_periods[\s\S]*?FOR UPDATE/);
  assert.match(apply, /IF v_authority='WAC_ACTIVE' THEN[\s\S]*?inventory_cost_apply_purchase_receipt/);
  assert.match(apply, /CREATE OR REPLACE FUNCTION public.apply_purchase_receipt_post_intent\(p_request_id uuid\)/);
  assert.match(apply, /SECURITY DEFINER SET search_path=pg_catalog/);
  assert.match(apply, /v_actor uuid:=auth\.uid\(\)/);
  assert.match(migration, /REVOKE ALL ON FUNCTION public\.inventory_cost_apply_purchase_receipt[\s\S]*?FROM PUBLIC,anon,authenticated,service_role/);
  assert.match(migration, /inventory_cost_purchase_receipt_item_once[\s\S]*?WHERE event_type='PURCHASE_RECEIPT'/);
  assert.match(migration, /RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='Costing and stock projections are out of sync'/);
});

test("receipt intent binds estimate revisions and fallback never trusts arbitrary product_costs HPP", () => {
  assert.match(migration, /'acquisition_evidence_hash'/);
  assert.match(migration, /evidenceRevision/);
  assert.match(migration, /v_basis:='UNVALUED'/);
  assert.match(migration, /ELSIF v_item\.accepted_quantity>0 AND v_cost\.valued_quantity>0 AND v_cost\.inventory_value IS NOT NULL\s+AND v_cost\.current_wac IS NOT NULL AND v_cost\.last_cost_event_id IS NOT NULL/);
  assert.match(migration, /No fallback to unverified product_costs\.hpp/);
  const writer = migration.slice(migration.indexOf("CREATE FUNCTION public.inventory_cost_apply_purchase_receipt"), migration.indexOf("ALTER FUNCTION public.inventory_cost_apply_purchase_receipt"));
  assert.doesNotMatch(writer, /SELECT\s+c\.hpp[\s\S]{0,160}FROM public\.product_costs/);
  assert.match(migration, /UNIQUE INDEX inventory_cost_purchase_receipt_item_once/);
  assert.match(writer, /basis_cost_event_id[\s\S]*?v_basis_cost_event_id/);
});

test("receipt issue, apply, and bootstrap follow the shared outlet-first lock hierarchy", () => {
  const issue = migration.slice(migration.indexOf("CREATE OR REPLACE FUNCTION public.issue_purchase_receipt_post_intent"), migration.indexOf("ALTER FUNCTION public.issue_purchase_receipt_post_intent"));
  const apply = migration.slice(migration.indexOf("CREATE OR REPLACE FUNCTION public.apply_purchase_receipt_post_intent"), migration.indexOf("ALTER FUNCTION public.apply_purchase_receipt_post_intent"));
  const bootstrap = migration.slice(migration.indexOf("CREATE OR REPLACE FUNCTION public.inventory_cost_bootstrap_outlet"), migration.indexOf("ALTER FUNCTION public.inventory_cost_bootstrap_outlet"));
  assert.ok(issue.indexOf("COST_BOOTSTRAP_OUTLET:") < issue.indexOf("FROM public.purchase_receipts WHERE id=p_receipt_id FOR UPDATE")
    && issue.indexOf("FROM public.purchase_receipts WHERE id=p_receipt_id FOR UPDATE") < issue.indexOf("FROM public.stock_operation_requests"));
  assert.ok(apply.indexOf("SELECT r.outlet_id") < apply.indexOf("COST_BOOTSTRAP_OUTLET:")
    && apply.indexOf("COST_BOOTSTRAP_OUTLET:") < apply.indexOf("FROM public.purchase_receipts WHERE id=v_receipt_id FOR UPDATE")
    && apply.indexOf("FROM public.purchase_receipts WHERE id=v_receipt_id FOR UPDATE") < apply.indexOf("FROM public.stock_operation_requests WHERE request_id=p_request_id AND actor_id=v_actor FOR UPDATE"));
  assert.ok(apply.indexOf("FROM public.stock_operation_requests WHERE request_id=p_request_id AND actor_id=v_actor FOR UPDATE")
    < apply.lastIndexOf("IF v_req.state IN ('COMPLETED','STALE','SUPERSEDED') THEN RETURN v_req.result")
    && apply.lastIndexOf("IF v_req.state IN ('COMPLETED','STALE','SUPERSEDED') THEN RETURN v_req.result")
    < apply.indexOf("IF v_receipt.status<>'DRAFT' THEN"));
  assert.ok(bootstrap.indexOf("COST_BOOTSTRAP_OUTLET:") < bootstrap.indexOf("FROM public.inventory_cost_operation_requests r WHERE r.request_id=p_request_id FOR UPDATE"));
});

test("OPENING events fully encode valued, unvalued, and zero-quantity transitions", () => {
  const bootstrap = migration.slice(migration.indexOf("CREATE OR REPLACE FUNCTION public.inventory_cost_bootstrap_outlet"), migration.indexOf("ALTER FUNCTION public.inventory_cost_bootstrap_outlet"));
  assert.match(bootstrap, /valued_quantity_before,valued_quantity_delta,valued_quantity_after/);
  assert.match(bootstrap, /inventory_value_before,inventory_value_delta,inventory_value_after/);
  assert.match(bootstrap, /VALUES\(v_batch,p_outlet_id,v_stock\.product_id,'OPENING'[\s\S]*?0,v_valued,v_valued[\s\S]*?0,v_value,v_value/);
  assert.match(bootstrap, /physical_quantity_delta,physical_quantity_before,physical_quantity_after,provisional_quantity_delta/);
  assert.match(bootstrap, /unvalued_quantity_delta,unvalued_quantity_before,\s*unvalued_quantity_after/);
});

test("GUDANG post result stays financial-free and costing tables remain manager-only", () => {
  const apply = migration.slice(migration.indexOf("CREATE OR REPLACE FUNCTION public.apply_purchase_receipt_post_intent"), migration.indexOf("GRANT USAGE ON TYPE"));
  assert.match(apply, /RETURN jsonb_build_object\('ok',true,'code','POSTED','receiptId',v_receipt\.id,'movementBatchId',v_batch,'movementCount',v_count\)/);
  assert.doesNotMatch(apply, /inventoryValue|currentWac|estimatedUnitPrice|frozen_unit_cost/i);
  assert.match(migration, /GRANT SELECT ON public\.purchase_receipt_acquisition_estimate_revisions TO authenticated/);
  assert.match(migration, /USING \(public\.current_active_user_role\(\) IN \('OWNER'::public\.user_role,'ADMIN'::public\.user_role\)\)/);
  assert.match(migration, /REVOKE ALL ON public\.purchase_receipt_acquisition_estimate_revisions FROM PUBLIC,anon,authenticated,service_role/);
});
