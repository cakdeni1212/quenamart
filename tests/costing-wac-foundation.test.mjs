import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migration = await read("../supabase/migrations/20260929250000_costing_wac_foundation_v1.sql");
const runner = await read("./staging/apply-costing-wac-foundation.sh");
const matrix = await read("./staging/runtime-costing-wac-foundation.sql");

test("cost foundation keeps quantity and legacy HPP separate from WAC valuation", () => {
  assert.match(migration, /CREATE TABLE public\.inventory_cost_projections/);
  assert.match(migration, /stock_balance_version bigint NOT NULL CHECK/);
  assert.match(migration, /CREATE TABLE public\.inventory_cost_events/);
  assert.match(migration, /source_entity_type text NOT NULL/);
  assert.match(migration, /current_wac numeric\(20,8\)/);
  assert.match(migration, /inventory_value numeric\(32,8\)/);
  assert.doesNotMatch(migration, /products p ON p\.id=cp\.product_id AND p\.is_active/);
  assert.doesNotMatch(migration, /UPDATE public\.product_inventory|UPDATE public\.product_costs|UPDATE public\.stock_balance_projection\s+SET/i);
});

test("bootstrap is explicit, manager-only, review-provenanced, and never invents zero cost", () => {
  assert.match(migration, /CREATE FUNCTION public\.inventory_cost_bootstrap_outlet\(p_outlet_id uuid, p_request_id uuid\)/);
  assert.match(migration, /v_role NOT IN \('OWNER'::public\.user_role,'ADMIN'::public\.user_role\)/);
  assert.match(migration, /r\.status='SUDAH_DIVERIFIKASI'/);
  assert.match(migration, /v_status := 'UNVALUED'/);
  assert.match(migration, /v_value := 0; v_wac := NULL/);
  assert.match(migration, /ALREADY_BOOTSTRAPPED/);
  assert.match(migration, /BOOTSTRAP_READY/);
});

test("cost tables are manager-read-only and applied ledger rows are immutable", () => {
  assert.match(migration, /REVOKE ALL ON public\.inventory_cost_operation_requests[\s\S]*?FROM PUBLIC,anon,authenticated,service_role/);
  assert.match(migration, /CREATE POLICY inventory_cost_projection_read_managers[\s\S]*?OWNER'::public\.user_role,'ADMIN'::public\.user_role/);
  assert.match(migration, /CREATE TRIGGER inventory_cost_events_immutable/);
  assert.match(migration, /CREATE TRIGGER inventory_cost_batches_immutable/);
  assert.match(migration, /SECURITY INVOKER SET search_path = pg_catalog/);
  assert.match(migration, /p_page_size integer DEFAULT 50/);
  assert.match(migration, /v_size integer := least\(greatest\(coalesce\(p_page_size,50\),1\),100\)/);
});

test("local-only harness verifies replay, roles, source integrity, precision, and rollback", () => {
  assert.match(runner, /assert_local_staging_marker/);
  assert.match(runner, /20260929250000/);
  assert.match(matrix, /current_database\(\)<>'quena_stock_staging'/);
  assert.match(matrix, /BOOTSTRAP_REPLAY_CHANGED_RESULT/);
  assert.match(matrix, /MISSING_HPP_WAS_NOT_LEFT_UNVALUED/);
  assert.match(matrix, /GUDANG_COST_DATA_EXPOSED/);
  assert.match(matrix, /KASIR_COST_DATA_EXPOSED/);
  assert.match(matrix, /BOOTSTRAP_CHANGED_STOCK_PROJECTION/);
  assert.match(matrix, /BOOTSTRAP_CHANGED_PRODUCT_INVENTORY/);
  assert.match(matrix, /BOOTSTRAP_CHANGED_HPP_SOURCE/);
  assert.match(matrix, /BOOTSTRAP_CHANGED_PRODUCT_INVENTORY/);
  assert.match(matrix, /ROLLBACK;/);
});
