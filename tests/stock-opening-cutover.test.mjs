import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(
  new URL('../supabase/migrations/20260929370000_stock_opening_cutover_v1.sql', import.meta.url),
  'utf8',
);

test('cutover records immutable source, authority, actor, and request evidence', () => {
  for (const token of [
    'stock_opening_cutover_requests',
    'stock_opening_cutover_items',
    'normalization_commit_id',
    'source_import_row_id',
    'previous_authority_period_id',
    'new_authority_period_id',
    'accepted_by',
    'accepted_at',
    'opening_cutover_request_id',
    'AUTHORITY_BASELINE_ACCEPTED',
  ]) assert.ok(migration.includes(token), `missing cutover evidence: ${token}`);
  assert.match(migration, /UNIQUE\s*\(outlet_id\)/);
  assert.match(migration, /PRIMARY KEY\(request_id,product_id\)/);
});

test('cutover is OWNER-only, confirmed, outlet-serialized, and replay-safe', () => {
  assert.match(migration, /p_confirmation\s+text/);
  assert.match(migration, /OPENING-STOCK-CUTOVER:/);
  assert.match(migration, /v_role\s+IS DISTINCT FROM 'OWNER'::public\.user_role/);
  assert.match(migration, /COST_BOOTSTRAP_OUTLET:/);
  assert.match(migration, /STOCK_OPENING_CUTOVER_REQUEST:/);
  assert.match(migration, /RETURN v_existing\.result/);
  assert.match(migration, /STOCK_CUTOVER_REQUEST_CONFLICT/);
  assert.match(migration, /SHARE ROW EXCLUSIVE MODE/);
  assert.match(migration, /FOR UPDATE/);
});

test('cutover gates WAC and operational drafts without activating costing', () => {
  assert.match(migration, /STOCK_CUTOVER_COSTING_ALREADY_STARTED/);
  assert.match(migration, /v_authority IN \('WAC_ACTIVE','BOOTSTRAP_READY'\)/);
  assert.match(migration, /STOCK_CUTOVER_OPERATIONAL_DRAFTS_OPEN/);
  assert.match(migration, /stock_operation_requests r WHERE r\.state='PENDING'/);
  assert.doesNotMatch(migration, /INSERT\s+INTO\s+public\.inventory_costing_outlet_authority/i);
  assert.doesNotMatch(migration, /inventory_cost_bootstrap_outlet\s*\(/i);
  assert.doesNotMatch(migration, /INSERT\s+INTO\s+public\.sales/i);
});

test('cutover rebases the baseline and clears only the current projection delta', () => {
  assert.match(migration, /baseline_quantity=v_after/);
  assert.match(migration, /unreconciled_movement_delta=0/);
  assert.match(migration, /authority_period_id=v_new_period/);
  assert.match(migration, /INSERT INTO public\.stock_authority_periods/);
  assert.match(migration, /UPDATE public\.stock_authority_periods SET ended_at=v_now/);
  assert.match(migration, /LOCK TABLE public\.inventory_cost_event_batches[\s\S]*SHARE ROW EXCLUSIVE MODE/);
});

test('cutover evidence is RLS-protected, immutable, and not directly writable', () => {
  assert.match(migration, /ENABLE ROW LEVEL SECURITY/);
  assert.match(migration, /REVOKE ALL ON public\.stock_opening_cutover_requests,public\.stock_opening_cutover_items/);
  assert.match(migration, /GRANT SELECT ON public\.stock_opening_cutover_requests,public\.stock_opening_cutover_items TO authenticated/);
  assert.match(migration, /BEFORE UPDATE OR DELETE ON public\.stock_opening_cutover_requests/);
  assert.match(migration, /BEFORE UPDATE OR DELETE ON public\.stock_opening_cutover_items/);
  assert.match(migration, /SECURITY DEFINER SET search_path=pg_catalog/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.stock_opening_cutover[\s\S]*TO authenticated/);
});
