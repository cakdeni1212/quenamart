import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const migration = readFileSync(new URL('../supabase/migrations/20260929310000_costing_manual_stock_correction_v1.sql', import.meta.url), 'utf8');
const action = readFileSync(new URL('../src/app/actions/manual-stock-correction.ts', import.meta.url), 'utf8');
const reader = readFileSync(new URL('../src/lib/stock/manual-correction-read.ts', import.meta.url), 'utf8');
const route = readFileSync(new URL('../app/(workspace)/stok/koreksi/page.tsx', import.meta.url), 'utf8');
const stockPage = readFileSync(new URL('../app/(workspace)/stok/page.tsx', import.meta.url), 'utf8');
const workspace = readFileSync(new URL('../src/components/stock/manual-stock-correction-workspace.tsx', import.meta.url), 'utf8');
const runtime = readFileSync(new URL('../tests/staging/runtime-costing-manual-stock-correction.sql', import.meta.url), 'utf8');

test('C3C migration is forward-only capability and does not bootstrap or activate costing', () => {
  assert.match(migration, /^-- C3C:[\s\S]*?BEGIN;/);
  assert.match(migration, /CREATE TYPE public\.manual_stock_correction_reason/);
  assert.match(migration, /CREATE TABLE public\.manual_stock_corrections/);
  assert.match(migration, /CREATE TABLE public\.manual_stock_correction_items/);
  assert.match(migration, /CREATE TABLE public\.manual_stock_correction_events/);
  assert.doesNotMatch(migration, /inventory_cost_bootstrap_outlet\([^;]+\);|UPDATE public\.inventory_costing_outlet_authority[\s\S]*WAC_ACTIVE/i);
  assert.doesNotMatch(migration, /UPDATE public\.stock_balance_projection\s+SET/i);
});

test('correction documents and lines are immutable after draft, revision guarded, and auditable', () => {
  assert.match(migration, /DRAFT[\s\S]*POSTED[\s\S]*CANCELLED/);
  assert.match(migration, /guard_manual_stock_correction_history/);
  assert.match(migration, /Only draft correction lines can change/);
  assert.match(migration, /v_doc\.revision<>p_expected_revision/);
  assert.match(migration, /manual_stock_correction_events\(correction_id,event_type,actor_id,revision,snapshot\)/);
  assert.match(migration, /OTHER' AND length\(btrim\(p_reason\)\)<10/);
  assert.match(migration, /quantity_delta<>trunc\(v_line\.quantity_delta,3\)/);
});

test('manager RPCs derive actor from auth, enforce OWNER/ADMIN, and keep direct writes revoked', () => {
  for (const name of ['create_manual_stock_correction', 'update_manual_stock_correction', 'cancel_manual_stock_correction', 'post_manual_stock_correction']) {
    const start = migration.indexOf(`CREATE FUNCTION public.${name}`);
    const end = migration.indexOf(`ALTER FUNCTION public.${name}`, start);
    const definition = migration.slice(start, end);
    assert.match(definition, /SECURITY DEFINER SET search_path=pg_catalog/);
    assert.match(definition, /manual_stock_correction_assert_manager/);
  }
  assert.match(migration, /v_actor uuid:=auth\.uid\(\)/);
  assert.match(migration, /OWNER'::public\.user_role,'ADMIN'::public\.user_role/);
  assert.match(migration, /REVOKE ALL ON public\.manual_stock_corrections[\s\S]*FROM PUBLIC,anon,authenticated,service_role/);
  assert.match(migration, /GRANT SELECT ON public\.manual_stock_corrections[\s\S]*TO authenticated/);
  assert.doesNotMatch(migration, /GRANT (?:INSERT|UPDATE|DELETE|ALL) ON public\.manual_stock_corrections/i);
});

test('posting takes the shared outlet cutover lock before row locks and blocks BOOTSTRAP_READY before writes', () => {
  const start = migration.indexOf('CREATE FUNCTION public.post_manual_stock_correction');
  const end = migration.indexOf('ALTER FUNCTION public.post_manual_stock_correction', start);
  const post = migration.slice(start, end);
  assert.ok(post.indexOf('pg_advisory_xact_lock') < post.indexOf('FOR UPDATE'));
  assert.ok(post.indexOf("authority='BOOTSTRAP_READY'") < post.indexOf('INSERT INTO public.stock_operation_requests'));
  assert.ok(post.indexOf('ORDER BY product_id LOOP') < post.indexOf('stock_apply_balance_delta'));
  assert.match(post, /effective_quantity\+i\.quantity_delta<0/);
  assert.match(post, /inventory_cost_apply_manual_correction/);
});

test('manual IN stays unvalued; manual OUT uses shared provenance depletion and aggregate WAC', () => {
  const start = migration.indexOf('CREATE FUNCTION public.inventory_cost_apply_manual_correction');
  const end = migration.indexOf('ALTER FUNCTION public.inventory_cost_apply_manual_correction', start);
  const writer = migration.slice(start, end);
  assert.match(writer, /IF m\.quantity_delta>0 THEN\s*uqty:=m\.quantity_delta/);
  assert.match(writer, /inventory_cost_open_manual_correction_layer/);
  assert.match(writer, /inventory_cost_build_layer_outflow_plan/);
  assert.match(writer, /round\(valued\*cost\.current_wac,8\)/);
  assert.match(writer, /WHEN valued=cost\.valued_quantity THEN -coalesce\(cost\.inventory_value,0\)/);
  assert.doesNotMatch(writer, /source_unit_cost\s*\*|fifo|lifo/i);
});

test('source-level uniqueness and relational correction evidence prevent duplicate movement/costing', () => {
  assert.match(migration, /stock_movement_manual_correction_item_once/);
  assert.match(migration, /inventory_cost_event_manual_correction_item_once/);
  assert.match(migration, /manual_stock_correction_item_id,manual_stock_correction_id,outlet_id,product_id/);
  assert.match(migration, /manual_stock_correction_cost_event_guard/);
  assert.match(migration, /inventory_cost_manual_correction_allocation_consistent/);
  assert.match(runtime, /different request duplicated a posted correction/);
  assert.match(runtime, /multi-product invalid correction partially posted/);
});

test('standard stock reversal handles correction movements without a parallel reversal writer', () => {
  assert.doesNotMatch(migration, /CREATE FUNCTION public\.[^(]*manual_stock_correction_revers/i);
  assert.match(workspace, /only be corrected through a controlled reversal|pembalikan terkontrol/i);
  assert.match(runtime, /issue_stock_operation_intent\('REVERSE_MOVEMENT'/);
  assert.match(runtime, /reversal did not restore the original cost effect/);
  assert.match(runtime, /valued correction reversal did not restore recorded value/);
});

test('OWNER/ADMIN-only UI reuses bounded stock search and does not expose costing internals', () => {
  assert.match(route, /requireProfile/);
  assert.match(route, /\['OWNER','ADMIN'\]/);
  assert.match(stockPage, /Koreksi stok/);
  assert.match(action, /\["OWNER", "ADMIN"\]/);
  assert.match(action, /stock_workspace_read_page/);
  assert.match(action, /resolve_stock_barcode/);
  assert.match(workspace, /Tambah/);
  assert.match(workspace, /Kurangi/);
  assert.match(workspace, /Tinjau &amp; posting/);
  assert.match(workspace, /tidak dapat diedit setelah diposting/);
  assert.match(workspace, /reasonCategory === "OTHER" \? 10 : 3/);
  assert.match(workspace, /Saldo akan diperiksa saat posting/);
  assert.match(workspace, /posted_by_name[\s\S]*posted_at/);
  assert.match(reader, /profiles"\)\.select\("id,full_name"\)/);
  assert.match(workspace, /sessionStorage/);
  assert.doesNotMatch(action + reader + workspace, /inventory_cost_projections|inventory_cost_events|source_layer|current_wac|inventory_value/i);
});

test('rollback runtime covers REFERENCE_ONLY, BOOTSTRAP_READY, WAC_ACTIVE, role denial, replay, and source-level retry rejection', () => {
  for (const marker of [
    'REFERENCE_ONLY in/replay failed', 'REFERENCE_ONLY out failed', 'BOOTSTRAP_READY mutated stock/request',
    'WAC_ACTIVE manual IN did not remain unvalued', 'WAC_ACTIVE same-request replay duplicated stock or cost',
    'WAC reversal did not restore the original cost effect',
    'ADMIN post denied', 'GUDANG allowed', 'KASIR allowed', 'different request duplicated a posted correction',
    'three-decimal stock correction failed', 'multi-product invalid correction partially posted',
  ]) assert.ok(runtime.includes(marker), marker);
  assert.match(runtime, /\nROLLBACK;\s*$/);
  assert.match(runtime, /current_database\(\) NOT LIKE 'quena_c3c_staging_%'/);
});
