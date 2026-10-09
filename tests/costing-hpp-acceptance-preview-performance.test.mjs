import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const migration = readFileSync(new URL('../supabase/migrations/20260929270000_costing_hpp_acceptance_preview_performance_v1.sql', import.meta.url), 'utf8');
const foundation = readFileSync(new URL('../supabase/migrations/20260929260000_costing_initial_hpp_acceptance_v1.sql', import.meta.url), 'utf8');
const reader = readFileSync(new URL('../src/lib/costing/hpp-acceptance-read.ts', import.meta.url), 'utf8');
const actions = readFileSync(new URL('../src/app/actions/hpp-acceptance.ts', import.meta.url), 'utf8');

test('preview keeps its public signature, authorization, and JSON response contract', () => {
  assert.match(migration, /inventory_cost_initial_hpp_acceptance_preview\(\s*p_outlet_id uuid,\s*p_filter text DEFAULT 'ALL',\s*p_search text DEFAULT NULL,\s*p_page integer DEFAULT 1,\s*p_page_size integer DEFAULT 50\s*\) RETURNS jsonb/);
  assert.match(migration, /v_role NOT IN \('OWNER'::public\.user_role,'ADMIN'::public\.user_role\)/);
  assert.match(migration, /'positiveStockProducts',s\.positive_count/);
  assert.match(migration, /'autoCandidates',s\.candidate_count/);
  assert.match(migration, /'exceptions',s\.exception_count/);
  assert.match(migration, /'warningProducts',s\.warning_product_count/);
  assert.match(migration, /'estimatedAutoCandidateValue',s\.estimate/);
  assert.match(migration, /'exceptionCountsByReason',r\.counts/);
  assert.match(migration, /'warningCountsByCode',w\.counts/);
  assert.match(migration, /'filter',v_filter[\s\S]*'search',v_search[\s\S]*'page',v_page[\s\S]*'pageSize',v_size[\s\S]*'total',fc\.total[\s\S]*'rows',pr\.rows/);
  assert.match(reader, /p_filter: filter[\s\S]*p_search: search \|\| null[\s\S]*p_page: page[\s\S]*p_page_size: PAGE_SIZE/);
});

test('preview materializes one evaluator result and reuses it for all outputs', () => {
  const body = migration.slice(migration.indexOf('CREATE OR REPLACE FUNCTION public.inventory_cost_initial_hpp_acceptance_preview'));
  assert.equal((body.match(/inventory_cost_hpp_acceptance_evaluate\(p_outlet_id\)/g) ?? []).length, 1);
  assert.match(body, /evaluated AS MATERIALIZED/);
  assert.match(body, /positive AS MATERIALIZED/);
  assert.match(body, /filtered AS MATERIALIZED/);
  assert.match(body, /FROM positive/);
  assert.match(body, /FROM filtered/);
  assert.match(body, /ORDER BY product_name,sku,product_id\s+OFFSET \(\(v_page::bigint\)-1\)\*v_size LIMIT v_size/);
});

test('classification and fingerprint evaluator remain exactly in Checkpoint A', () => {
  assert.match(foundation, /CREATE FUNCTION public\.inventory_cost_hpp_acceptance_evaluate\(p_outlet_id uuid\)/);
  assert.match(foundation, /md5\(jsonb_build_array\([\s\S]*latest_selling_price_history_id/);
  assert.match(foundation, /'HPP_NOT_BELOW_SELLING_PRICE'/);
  assert.match(foundation, /'OPEN_COST_AUDIT_FINDING'/);
  assert.match(foundation, /'UNRESOLVED_OR_CONFLICTING_HPP_REVIEW'/);
  assert.match(foundation, /'GROSS_MARGIN_AT_OR_BELOW_5_PERCENT'/);
  assert.match(foundation, /'GROSS_MARGIN_ABOVE_80_PERCENT'/);
  assert.match(foundation, /'HIGH_ABSOLUTE_HPP_OUTLIER'/);
  assert.match(foundation, /'ONE_RUPIAH_HPP'/);
  assert.doesNotMatch(migration, /CREATE OR REPLACE FUNCTION public\.inventory_cost_hpp_acceptance_evaluate/);
});

test('preview replacement grants only the same read RPC and adds no data mutation path', () => {
  assert.match(migration, /REVOKE ALL ON FUNCTION public\.inventory_cost_initial_hpp_acceptance_preview[\s\S]*FROM PUBLIC,anon,service_role/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.inventory_cost_initial_hpp_acceptance_preview[\s\S]*TO authenticated/);
  assert.doesNotMatch(migration, /CREATE (?:TABLE|INDEX|TYPE|TRIGGER)|\b(?:INSERT INTO|UPDATE public\.|DELETE FROM|TRUNCATE)\b/i);
  assert.match(actions, /authorizedProfile\(true\)/);
  assert.match(actions, /prepare_initial_hpp_acceptance/);
  assert.match(actions, /resolve_initial_hpp_acceptance_exception/);
  assert.match(actions, /approve_initial_hpp_acceptance/);
});
