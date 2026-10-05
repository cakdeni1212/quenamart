import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { canAccessSection } from '../src/lib/auth/roles.ts';

const migration = readFileSync(new URL('../supabase/migrations/20260929210000_stock_opname_results_v1.sql', import.meta.url), 'utf8');
const foundation = readFileSync(new URL('../supabase/migrations/20260929180000_stock_foundation_v1.sql', import.meta.url), 'utf8');
const post = readFileSync(new URL('../supabase/migrations/20260929200000_stock_opname_revision_guard_v1.sql', import.meta.url), 'utf8');
const postRuntime = readFileSync(new URL('../tests/staging/runtime-stock-opname-post.sql', import.meta.url), 'utf8');
const resultsRuntime = readFileSync(new URL('../tests/staging/runtime-stock-opname-results.sql', import.meta.url), 'utf8');
const applyRunner = readFileSync(new URL('../tests/staging/apply-stock-opname-results.sh', import.meta.url), 'utf8');
const runner = readFileSync(new URL('../tests/staging/run-stock-opname-results-matrix.sh', import.meta.url), 'utf8');
const refreshRunner = readFileSync(new URL('../tests/staging/refresh-stock-opname-results-rpc.sh', import.meta.url), 'utf8');
const stagingLib = readFileSync(new URL('../tests/staging/lib.sh', import.meta.url), 'utf8');

test('posting snapshots are captured by a BEFORE REVIEW-to-POSTED trigger without replacing POST_SESSION', () => {
  assert.match(migration, /CREATE TRIGGER stock_opname_session_snapshot_capture\s+BEFORE UPDATE OF status ON public\.stock_opname_sessions/);
  assert.match(migration, /OLD\.status <> 'REVIEW'[\s\S]*NEW\.status <> 'POSTED'/);
  assert.match(migration, /pg_trigger_depth\(\) < 2/);
  assert.match(migration, /quena\.stock_opname_snapshot_session/);
  assert.match(migration, /v_captured_items <> v_expected_items/);
  assert.doesNotMatch(migration, /CREATE OR REPLACE FUNCTION public\.apply_stock_operation_intent/);
  assert.match(foundation, /create trigger stock_opname_item_guard before update or delete on public\.stock_opname_items/i);
  assert.match(migration, /stock_opname_session_snapshot_guard/);
});

test('snapshot fields cover outlet and all item display metadata with a consistency marker', () => {
  for (const field of [
    'posted_outlet_name_snapshot', 'posted_metadata_captured_at',
    'posted_product_name_snapshot', 'posted_sku_snapshot', 'posted_rack_label_snapshot',
    'posted_unit_label_snapshot', 'posted_display_barcode_snapshot',
  ]) assert.match(migration, new RegExp(field));
  assert.match(migration, /ORDER BY b\.created_at ASC, b\.id ASC\s+LIMIT 1/);
  assert.match(migration, /current_barcodes AS MATERIALIZED[\s\S]*?DISTINCT ON \(b\.product_id\)[\s\S]*?LEFT JOIN current_barcodes cb/);
  assert.doesNotMatch(migration, /scanned_barcode_id/);
  assert.match(post, /v_delta := v_row\.physical_quantity - v_row\.baseline_quantity/);
  assert.match(foundation, /quantity_variance numeric generated always as\s+\(physical_quantity - baseline_quantity\) stored/);
});

test('posted results use immutable quantities and never use current projection as historical after', () => {
  assert.match(migration, /'historical_after_quantity', CASE WHEN r\.is_counted THEN r\.physical_quantity ELSE NULL END/);
  assert.match(migration, /'NOT_CHANGED_BY_OPNAME'/);
  assert.match(migration, /'LEGACY_UNAVAILABLE'/);
  assert.match(migration, /'CURRENT_FALLBACK'/);
  assert.doesNotMatch(migration, /stock_balance_projection/);
  assert.doesNotMatch(migration, /product_costs|\bhpp\b|selling_price|profit/i);
});

test('result RPC is bounded, invoker-secured, database-filtered, and role gated', () => {
  assert.match(migration, /stock_opname_posted_results_page\(\s*p_session_id uuid,[\s\S]*p_search text[\s\S]*p_result_filter text[\s\S]*p_page integer[\s\S]*p_page_size integer/);
  assert.match(migration, /SECURITY INVOKER\s+SET search_path = pg_catalog/);
  for (const filter of ['ALL', 'DIFFERENCE', 'MATCH', 'INCREASE', 'DECREASE', 'EXCEPTION']) assert.match(migration, new RegExp(`WHEN '${filter}'`));
  assert.match(migration, /LIMIT \(SELECT page_size FROM normalized_page\)/);
  assert.match(migration, /FROM normalized_page np\s+LEFT JOIN \([\s\S]*\) r ON true/);
  assert.match(migration, /FILTER \(WHERE r\.id IS NOT NULL\)/);
  assert.match(migration, /'FORBIDDEN'/);
  assert.match(migration, /FROM PUBLIC, anon, service_role/);
  assert.match(migration, /TO authenticated/);
  assert.equal(canAccessSection('OWNER', 'stok'), true);
  assert.equal(canAccessSection('ADMIN', 'stok'), true);
  assert.equal(canAccessSection('GUDANG', 'stok'), true);
  assert.equal(canAccessSection('KASIR', 'stok'), false);
});

test('local staging artifacts cover snapshots, legacy provenance, rollback, and Checkpoint 6 regressions', () => {
  for (const marker of ['positive', 'negative', 'zero', 'exception', 'CURRENT_FALLBACK', 'product-name search', 'SKU search', 'SKU re-key remains rejected']) {
    assert.match(resultsRuntime, new RegExp(marker, 'i'));
  }
  for (const filter of ['DIFFERENCE', 'MATCH', 'INCREASE', 'DECREASE', 'EXCEPTION']) assert.match(resultsRuntime, new RegExp(`'${filter}'`));
  assert.match(resultsRuntime, /RESET ROLE/);
  assert.match(resultsRuntime, /SKU metadata change unexpectedly bypassed the established immutable-SKU guard/);
  assert.match(resultsRuntime, /ROLLBACK;/);
  assert.match(postRuntime, /v_changed_session AND s\.posted_metadata_captured_at IS NOT NULL/);
  assert.match(postRuntime, /v_stale_session AND s\.posted_metadata_captured_at IS NOT NULL/);
  assert.match(postRuntime, /v_replay_metadata_after IS DISTINCT FROM v_replay_metadata_before/);
  assert.match(applyRunner, /guard_local_target[\s\S]*assert_local_staging_marker/);
  assert.match(stagingLib, /STAGING_HOST='localhost'/);
  assert.match(stagingLib, /STAGING_PORT='5432'/);
  assert.match(stagingLib, /STAGING_DATABASE='quena_stock_staging'/);
  assert.match(runner, /runtime-stock-opname-post\.sql/);
  assert.match(runner, /runtime-stock-opname-results\.sql/);
  assert.match(runner, /stock-opname-results-state\.sql/);
  assert.match(runner, /refresh-stock-opname-results-rpc\.sh/);
  assert.match(refreshRunner, /expected_versions=/);
  assert.match(refreshRunner, /awk[\s\S]*stock_opname_posted_results_page/);
  assert.doesNotMatch(refreshRunner, /INSERT INTO quena_staging\.applied_migrations|supabase db push|migration repair/i);
  assert.doesNotMatch(runner + applyRunner, /supabase db push|supabase link|migration repair|\.env\.local|giwuzemjmimuvhtvjfhq/);
});
