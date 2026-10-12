import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/20260929430000_go_live_costing_controls_v1.sql', import.meta.url),
  'utf8',
);
const functionBody = (signature, nextSignature) => {
  const start = migration.indexOf(`CREATE FUNCTION public.${signature}`);
  assert.notEqual(start, -1, `missing function ${signature}`);
  const end = migration.indexOf(`CREATE FUNCTION public.${nextSignature}`, start + 1);
  return migration.slice(start, end === -1 ? undefined : end);
};

test('bootstrap requires a completed cutover and an approved matching HPP batch', () => {
  const body = functionBody('inventory_cost_bootstrap_outlet(', 'inventory_cost_activate_wac(');
  assert.match(body, /h\.status\s*<>\s*'APPROVED'/);
  assert.match(body, /stock_opening_cutover_requests/);
  assert.match(body, /GO_LIVE_STOCK_PERIOD_MISMATCH/);
  assert.match(body, /quantity_at_approval/);
  assert.match(body, /opening_hpp_acceptance_batch_id/);
  assert.match(body, /accepted_opening_hpp/);
  assert.match(body, /LEAVE_UNVALUED/);
  assert.match(body, /BOOTSTRAP_CONSUME/);
  assert.match(body, /SET status='CONSUMED'/);
  assert.doesNotMatch(body, /SET status\s*=\s*'WAC_ACTIVE'/);
});

test('bootstrap uses only frozen acceptance evidence for unit cost', () => {
  const body = functionBody('inventory_cost_bootstrap_outlet(', 'inventory_cost_activate_wac(');
  assert.match(body, /hpp_item\.accepted_opening_hpp/);
  assert.match(body, /hpp_item\.disposition/);
  assert.doesNotMatch(body, /product_costs|product_cost_history|SUDAH_DIVERIFIKASI/);
});

test('WAC activation is authenticated OWNER-only and reconciles before transition', () => {
  const body = functionBody('inventory_cost_activate_wac(', 'CREATE FUNCTION public.go_live_readiness(');
  assert.match(body, /auth\.uid\(\)/);
  assert.match(body, /role\s+IS DISTINCT FROM 'OWNER'/);
  assert.match(body, /COST_BOOTSTRAP_OUTLET:/);
  assert.match(body, /GO_LIVE_COSTING_RECONCILIATION_FAILED/);
  assert.match(body, /BOOTSTRAP_READY/);
  assert.match(body, /go_live_wac_activation_confirmation/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.inventory_cost_activate_wac\(uuid,uuid,text\) TO authenticated/);
});

test('HPP invalidation is a reasoned PREPARED-only transition with immutable evidence', () => {
  const body = functionBody('inventory_cost_hpp_invalidate_prepared(', 'CREATE FUNCTION public.inventory_cost_bootstrap_outlet(');
  assert.match(body, /role IS DISTINCT FROM 'OWNER'/);
  assert.match(body, /why IS NULL/);
  assert.match(body, /b\.status<>'PREPARED'/);
  assert.match(body, /'INVALIDATED'/);
  assert.match(body, /inventory_cost_hpp_acceptance_events/);
  assert.match(body, /GO_LIVE_HPP_BATCH_ALREADY_CONSUMED/);
});

test('reset preparation cancels reversible drafts without deleting history or identities', () => {
  const start = migration.indexOf('CREATE FUNCTION public.go_live_reset_preparation(');
  assert.notEqual(start, -1);
  const body = migration.slice(start, migration.lastIndexOf('\nCOMMIT;'));
  assert.match(body, /role IS DISTINCT FROM 'OWNER'/);
  assert.match(body, /PREPARE-GO-LIVE:/);
  assert.match(body, /CANCELLED/);
  assert.match(body, /manualReviewItems/);
  assert.match(body, /preservedAuthProfilesOutletsSuppliersAndPostedEvidence/);
  assert.doesNotMatch(body, /\b(TRUNCATE|DELETE FROM)\b/i);
  assert.doesNotMatch(body, /auth\.users|public\.profiles|public\.suppliers/);
});

test('readiness never calls final import ready while an active HPP batch exists', () => {
  const body = functionBody('go_live_readiness(', 'CREATE FUNCTION public.go_live_reset_preparation(');
  assert.match(body, /'readyForFinalImport',[\s\S]*?hpp_state='NONE'/);
});

test('client roles cannot mutate costing authority or invoke operator functions anonymously', () => {
  assert.match(migration, /REVOKE ALL ON FUNCTION public\.inventory_cost_bootstrap_outlet\(uuid,uuid,uuid,text\) FROM PUBLIC,anon,service_role/);
  assert.match(migration, /REVOKE ALL ON FUNCTION public\.inventory_cost_activate_wac\(uuid,uuid,text\) FROM PUBLIC,anon,service_role/);
  assert.match(migration, /REVOKE ALL ON FUNCTION public\.go_live_reset_preparation\(uuid,uuid,text,text\) FROM PUBLIC,anon,service_role/);
  assert.match(migration, /REVOKE ALL ON FUNCTION public\.inventory_cost_hpp_invalidate_prepared\(uuid,uuid,text\) FROM PUBLIC,anon,service_role/);
  assert.match(migration, /SET search_path=pg_catalog/);
});
