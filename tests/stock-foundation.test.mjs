import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const migration = readFileSync(new URL('../supabase/migrations/20260929180000_stock_foundation_v1.sql', import.meta.url), 'utf8');
const correctionIntentFix = readFileSync(new URL('../supabase/migrations/20260929171000_product_field_correction_intent_ambiguity_fix_v1.sql', import.meta.url), 'utf8');
const inventorySchema = readFileSync(new URL('../supabase/migrations/20260928_product_ipos_schema_v1.sql', import.meta.url), 'utf8');
const iposWorker = readFileSync(new URL('../supabase/migrations/20260928115000_ipos_worker_v1.sql', import.meta.url), 'utf8');
const normalization = readFileSync(new URL('../supabase/migrations/20260928143000_ipos_normalization_commit_v1.sql', import.meta.url), 'utf8');
const normalizationModel = readFileSync(new URL('../src/lib/ipos/normalize.ts', import.meta.url), 'utf8');
const preflightEngine = readFileSync(new URL('../src/lib/ipos/preflight-engine.ts', import.meta.url), 'utf8');
const stagingFixture = readFileSync(new URL('./staging/seed-stock-fixtures.sql', import.meta.url), 'utf8');
const stagingRuntime = readFileSync(new URL('./staging/runtime-stock-foundation.sql', import.meta.url), 'utf8');
const stagingBootstrap = readFileSync(new URL('./staging/bootstrap-supabase-compat.sql', import.meta.url), 'utf8');
const stagingReset = readFileSync(new URL('./staging/reset-stock-staging.sql', import.meta.url), 'utf8');
const stagingResetRunner = readFileSync(new URL('./staging/reset-stock-staging.sh', import.meta.url), 'utf8');
const commitPayloadBuilder = readFileSync(new URL('../src/lib/ipos/commit-payload.ts', import.meta.url), 'utf8');

function body(name) {
  const start = migration.indexOf(`create or replace function public.${name}(`);
  assert.notEqual(start, -1, `${name} exists`);
  const end = migration.indexOf('$$;', start);
  assert.notEqual(end, -1, `${name} body closes`);
  return migration.slice(start, end + 3);
}

test('foundation creates the approved stock model in a forward-only migration', () => {
  for (const object of [
    'stock_authority_periods', 'stock_balance_projection', 'stock_balance_baseline_events',
    'stock_balance_projection_events', 'stock_movement_batches', 'stock_movements',
    'stock_movement_source_reconciliations', 'stock_opname_sessions', 'stock_opname_items',
    'stock_opname_count_events', 'stock_opname_session_events', 'stock_operation_requests',
  ]) assert.match(migration, new RegExp(`create table public\\.${object}\\b`, 'i'));
  assert.match(migration, /begin;[\s\S]*commit;\s*$/i);
  assert.doesNotMatch(migration, /drop\s+(table|column|function|trigger)|alter\s+table\s+public\.product_inventory\s+drop/i);
});

test('stock snapshot remains separate from operational movements and product_inventory is not a stock write target', () => {
  assert.match(migration, /baseline_quantity numeric/);
  assert.match(migration, /unreconciled_movement_delta numeric not null default 0/);
  assert.match(migration, /effective_quantity numeric generated always as\s*\(baseline_quantity \+ unreconciled_movement_delta\)/);
  assert.match(migration, /stock_apply_balance_delta/);
  assert.doesNotMatch(body('apply_stock_operation_intent'), /update\s+public\.product_inventory/i);
  assert.doesNotMatch(body('stock_apply_balance_delta'), /product_inventory/i);
  assert.match(migration, /source_system public\.stock_movement_source/);
  assert.match(migration, /'IPOS_IMPORT', 'QUENA_POS', 'PURCHASING', 'STOCK_OPNAME', 'MANUAL', 'TRANSFER'/);
});

test('projection backfill retains real source provenance and rejects incompatible legacy state', () => {
  assert.match(migration, /Stock foundation backfill blocked: active quantity overrides require manual review/);
  assert.match(migration, /Stock foundation backfill blocked: inventory row lacks a valid completed source baseline/);
  assert.match(migration, /join public\.ipos_normalization_commits nc[\s\S]*nc\.status = 'COMPLETED'/);
  assert.equal((migration.match(/case jsonb_typeof\(cr\.normalized_data->'quantity'\)[\s\S]*?else false\s+end/gi) ?? []).length, 2);
  assert.match(migration, /when 'string' then[\s\S]*?cr\.normalized_data->>'quantity' ~ '\^-\?\[0-9\]\+\(\[\.\]\[0-9\]\+\)\?\$'[\s\S]*?\(cr\.normalized_data->>'quantity'\)::numeric = i\.quantity/i);
  assert.match(migration, /when 'string' then case\s+when cr\.normalized_data->>'quantity' ~ '[^']+'\s+then \(cr\.normalized_data->>'quantity'\)::numeric = i\.quantity\s+else false\s+end/i,
    'string-to-numeric cast is reached only after canonical syntax validation');
  assert.match(migration, /e\.value->>'code' = 'INVALID_NUMERIC_VALUE' and e\.value->>'field' = 'STOK'/);
  assert.match(migration, /baseline_source_import_row_id, baseline_batch_id, baseline_commit_id/);
  assert.match(migration, /foreign key \(baseline_source_import_row_id, baseline_batch_id, outlet_id, product_id\)/);
  assert.match(migration, /on conflict \(product_id, outlet_id\) do nothing/);
  assert.match(migration, /insert into public\.stock_balance_baseline_events[\s\S]*'BOOTSTRAP'[\s\S]*on conflict/);
});

test('invalid STOK with an advanced source pointer cannot seed the bootstrap baseline', () => {
  const bootstrapGuard = migration.slice(migration.indexOf('do $$'), migration.indexOf('insert into public.stock_authority_periods'));
  assert.match(bootstrapGuard, /i\.source_import_row_id/);
  assert.match(bootstrapGuard, /when 'string' then[\s\S]*?\(cr\.normalized_data->>'quantity'\)::numeric = i\.quantity/i);
  assert.match(bootstrapGuard, /INVALID_NUMERIC_VALUE'[\s\S]*'STOK'/);
  assert.match(bootstrapGuard, /raise exception 'Stock foundation backfill blocked/);
});

test('ordinary imports only record observations and never infer source chronology or advance baseline', () => {
  const refresh = body('refresh_stock_balance_from_ipos_inventory');
  assert.match(refresh, /cr\.normalized_data/);
  assert.match(refresh, /nc\.status in \('PROCESSING', 'COMPLETED'\)/);
  assert.doesNotMatch(refresh, /b\.created_at|batch_created_at|v_batch_id\s*[<>=]/i);
  assert.doesNotMatch(refresh, /set[^;]*baseline_quantity\s*=|set[^;]*baseline_source_import_row_id\s*=|set[^;]*unreconciled_movement_delta\s*=/i);
  assert.match(refresh, /SOURCE_CHRONOLOGY_UNVERIFIED/);
  assert.match(refresh, /QUENA_AUTHORITY_OBSERVATION/);
  assert.match(refresh, /v_period_mode = 'QUENA_MOVEMENT_LEDGER'/);
  assert.match(refresh, /ACTIVE_OVERRIDE_BLOCKED/);
  assert.match(refresh, /INVALID_STOCK_VALUE/);
  assert.match(refresh, /\) or \(\s*\(jsonb_typeof\(v_normalized_data->'quantity'\) is distinct from 'number'\s+and jsonb_typeof\(v_normalized_data->'quantity'\) is distinct from 'string'\)\s+or \(jsonb_typeof\(v_normalized_data->'quantity'\) = 'string'\s+and coalesce\(v_normalized_data->>'quantity' !~ '\^-\?\[0-9\]\+\(\[\.\]\[0-9\]\+\)\?\$', true\)\)\s*\) then/i,
    'import observation classifier has a complete, parenthesized invalid-type/string predicate');
  assert.doesNotMatch(refresh, /\bor\s+case\s+jsonb_typeof\(v_normalized_data->'quantity'\)/i,
    'the PL/pgSQL IF predicate does not embed the parser-fragile CASE expression');
  assert.match(refresh, /last_observation_source_import_row_id = new\.source_import_row_id/);
  assert.match(migration, /last_observation_status in \('BOOTSTRAPPED', 'INVALID_STOCK_VALUE'/);
  assert.match(refresh, /insert into public\.stock_authority_periods/);
  assert.match(migration, /ipos_normalization_rows_stock_source_lookup_idx/);
  assert.match(migration, /after insert on public\.product_inventory[\s\S]*after update of source_import_row_id on public\.product_inventory/);
  assert.match(normalization, /pg_advisory_xact_lock\(734921, 2\)/);
});

test('quantity JSON accepts JSON numbers and canonical numeric strings without unsafe casts', () => {
  const bootstrap = migration.slice(migration.indexOf('do $$'), migration.indexOf('insert into public.stock_authority_periods'));
  const backfill = migration.slice(migration.indexOf('insert into public.stock_balance_projection ('), migration.indexOf('insert into public.stock_balance_baseline_events'));
  for (const [label, sql] of [['bootstrap validation', bootstrap], ['projection backfill', backfill]]) {
    assert.match(sql, /when 'number' then \(cr\.normalized_data->>'quantity'\)::numeric = i\.quantity/i, `${label} accepts JSON number values`);
    assert.match(sql, /when 'string' then case\s+when cr\.normalized_data->>'quantity' ~ '\^-\?\[0-9\]\+\(\[\.\]\[0-9\]\+\)\?\$'\s+then \(cr\.normalized_data->>'quantity'\)::numeric = i\.quantity\s+else false\s+end/i,
      `${label} casts strings only after canonical numeric syntax validation`);
    assert.match(sql, /else false\s+end/i, `${label} rejects other JSON value types`);
  }
  const refresh = body('refresh_stock_balance_from_ipos_inventory');
  assert.match(refresh, /jsonb_typeof\(v_normalized_data->'quantity'\) = 'string'[\s\S]*?coalesce\(v_normalized_data->>'quantity' !~ '\^-\?\[0-9\]\+\(\[\.\]\[0-9\]\+\)\?\$', true\)/i,
    'classifier rejects malformed strings without casting them');
  assert.match(refresh, /INVALID_NUMERIC_VALUE'[\s\S]*?'STOK'/i, 'STOK validation failures remain invalid');
});

test('quantity precision supports three decimals, signed movements, and valid reversal references', () => {
  assert.match(migration, /baseline_quantity = trunc\(baseline_quantity, 3\)/);
  assert.match(migration, /physical_quantity = trunc\(physical_quantity, 3\)/);
  assert.match(migration, /quantity_delta <> 0[\s\S]*quantity_delta = trunc\(quantity_delta, 3\)/);
  assert.match(migration, /movement_type = 'REVERSAL' and reverses_movement_id is not null/);
  assert.match(migration, /create unique index stock_movement_one_reversal_per_original/);
  assert.match(migration, /balance_after = balance_before \+ quantity_delta/);
  assert.match(migration, /V1 product rule: the accepted baseline and Quena effective quantity cannot[\s\S]*be negative/);
  assert.match(body('stock_apply_balance_delta'), /Stock movement would make effective stock negative/);
});

test('barcode resolver qualifies RETURNS TABLE columns and counts distinct products, not matching rows', () => {
  const resolver = body('resolve_stock_barcode');
  assert.match(resolver, /group by p\.id, p\.sku, p\.name, os\.rack_label, bp\.effective_quantity/);
  assert.match(resolver, /\(array_agg\(b\.id order by b\.id\)\)\[1\] as barcode_id/);
  assert.match(resolver, /array_agg\(m\.product_id order by m\.product_id\)/);
  assert.match(resolver, /case when s\.match_count = 1 then s\.product_id end/);
  assert.match(resolver, /case when s\.match_count = 0 then 'BARCODE_NOT_FOUND'/);
  assert.match(resolver, /when s\.match_count = 1 then 'BARCODE_MATCH'[\s\S]*else 'BARCODE_AMBIGUOUS'/);
  assert.match(resolver, /b\.barcode = btrim\(p_barcode\) collate "C"/);
  assert.match(resolver, /p_barcode ~ '\[\[:cntrl:\]\]'/);
  assert.doesNotMatch(resolver, /\.hpp|product_costs/i);
});

test('posted movement and audit histories reject UPDATE and DELETE', () => {
  for (const table of [
    'stock_movement_batches', 'stock_movements', 'stock_movement_source_reconciliations',
    'stock_balance_baseline_events', 'stock_balance_projection_events',
    'stock_opname_count_events', 'stock_opname_session_events',
  ]) assert.match(migration, new RegExp(`create trigger [\\w]+ before update or delete on public\\.${table}`, 'i'));
  assert.match(migration, /Final stock history is append-only; use a reversal movement/);
  assert.match(migration, /Posted or cancelled stock-opname sessions are immutable/);
  assert.match(migration, /Items in posted or cancelled stock-opname sessions are immutable/);
});

test('stock operation requests are private, actor-bound, payload-bound, and serialized for identical targets', () => {
  const issue = body('issue_stock_operation_intent');
  assert.match(issue, /v_actor uuid := auth\.uid\(\)/);
  assert.match(issue, /current_active_user_role\(\)/);
  assert.match(issue, /v_hash := md5\(v_payload::text\)/);
  assert.match(issue, /pg_advisory_xact_lock/);
  assert.match(migration, /stock_operation_one_pending_intent_per_target/);
  assert.match(migration, /revoke all on public\.[\s\S]*stock_operation_requests[\s\S]*from public, anon, authenticated, service_role/);
  assert.doesNotMatch(migration, /grant\s+select[^;]*stock_operation_requests/i);
  assert.match(body('read_stock_operation_intent'), /request_id = p_request_id and r\.actor_id = v_actor/);
  assert.match(body('read_stock_operation_intent'), /jsonb_build_object\('available', true, 'requestId', v_request\.request_id,[\s\S]*'operation',[\s\S]*'state'/);
  assert.doesNotMatch(body('read_stock_operation_intent'), /request_payload|payload_hash|corrected_value|hpp/i);
});

test('role rules deny KASIR and reserve approval, reconciliation, and reversal for OWNER/ADMIN', () => {
  const issue = body('issue_stock_operation_intent');
  const apply = body('apply_stock_operation_intent');
  assert.match(issue, /v_role = 'KASIR'::public\.user_role/);
  assert.match(apply, /v_role = 'KASIR'::public\.user_role/);
  assert.match(issue, /p_operation_key = 'POST_SESSION' and v_role = 'GUDANG'/);
  assert.match(apply, /if v_role not in \('OWNER'::public\.user_role, 'ADMIN'::public\.user_role\)[\s\S]*Stock approval permission denied/);
  assert.match(issue, /RECONCILE_MOVEMENT[\s\S]*Source reconciliation requires OWNER or ADMIN/);
  assert.match(issue, /REVERSE_MOVEMENT[\s\S]*Movement reversal requires OWNER or ADMIN/);
  assert.match(migration, /create policy stock_movement_reconciliations_select_managers/);
  assert.doesNotMatch(migration, /product_costs|product_cost_history|\.hpp\b/i);
});

test('opname enforces scope, active overlap, repeat-count history, explicit zero, full coverage, and stale recount', () => {
  assert.match(migration, /create unique index stock_opname_no_active_overlap[\s\S]*where active_scope/);
  assert.match(migration, /unique \(session_id, product_id\)/);
  assert.match(migration, /physical_quantity numeric/);
  assert.match(migration, /jsonb_typeof\(p_payload->'physical_quantity'\) is distinct from 'number'/);
  assert.match(body('apply_stock_operation_intent'), /case when v_item\.revision_no = 0 then 'COUNTED'[\s\S]*else 'RECOUNTED'/);
  assert.match(body('apply_stock_operation_intent'), /v_qty - v_item\.baseline_quantity/);
  assert.match(body('apply_stock_operation_intent'), /Full opname requires an available stock baseline for every in-scope product/);
  assert.match(body('apply_stock_operation_intent'), /Every item needs a count or reviewed exception/);
  assert.match(body('apply_stock_operation_intent'), /STALE_BASELINE/);
  assert.match(body('apply_stock_operation_intent'), /Baseline refreshed; physical recount required/);
  assert.match(body('apply_stock_operation_intent'), /for update/);
  assert.match(body('apply_stock_operation_intent'), /FULL means all products in the stock projection at the moment the[\s\S]*session is created/);
  const apply = body('apply_stock_operation_intent');
  assert.match(apply, /revision_no = revision_no \+ 1, updated_at = now\(\)[\s\S]*returning revision_no into v_revision_no/);
  assert.match(apply, /'STALE_BASELINE', v_revision_no/);
  assert.doesNotMatch(apply, /select revision_no \+ 1 from public\.stock_opname_items/);
});

test('stale count attempts reserve unique revisions and exact retries do not consume another', () => {
  const apply = body('apply_stock_operation_intent');
  const countBranch = apply.slice(apply.indexOf("elsif v_req.operation_key = 'RECORD_COUNT'"), apply.indexOf("elsif v_req.operation_key = 'REBASE_ITEM'"));
  assert.match(apply, /v_req\.state in \('COMPLETED'::public\.stock_request_state, 'STALE'::public\.stock_request_state,[\s\S]*?return v_req\.result/);
  assert.match(countBranch, /select \* into v_item from public\.stock_opname_items i[\s\S]*?for update/);
  assert.match(countBranch, /revision_no = revision_no \+ 1[\s\S]*?returning revision_no into v_revision_no/);
  assert.match(countBranch, /'STALE_BASELINE', v_revision_no/);
  assert.match(countBranch, /update public\.stock_operation_requests set state = 'STALE'[\s\S]*?return v_result/);
  assert.doesNotMatch(countBranch, /raise exception[^;]*STALE_BASELINE/i,
    'stale result returns normally so its revision/event/request state commit atomically');
  assert.match(body('apply_stock_operation_intent'), /revision_no = revision_no \+ 1, updated_at = now\(\)\s*where id = v_row\.id returning revision_no into v_revision_no/,
    'stale posting also reserves the next item revision before writing its event');
  assert.match(stagingRuntime, /Exact stale-count retry consumed another revision or event/);
  assert.match(stagingRuntime, /Distinct stale count requests reused or reordered an item revision/);
  assert.match(stagingRuntime, /Next valid recount did not advance beyond both stale revisions/);
});

test('a reversal pair is reconciled atomically by net delta and cannot be split', () => {
  const apply = body('apply_stock_operation_intent');
  const reconcile = apply.slice(apply.indexOf("elsif v_req.operation_key = 'RECONCILE_MOVEMENT'"), apply.indexOf("elsif v_req.operation_key = 'REVERSE_MOVEMENT'"));
  assert.match(migration, /reconciliation_group_id uuid not null references public\.stock_movements\(id\)/);
  assert.match(migration, /unique \(reconciliation_group_id, movement_id\)/);
  assert.match(reconcile, /v_group_id := coalesce\(v_movement\.reverses_movement_id, v_movement\.id\)/);
  assert.match(reconcile, /where m\.id = v_group_id for update/);
  assert.match(reconcile, /where m\.reverses_movement_id = v_group_id for update/);
  assert.match(reconcile, /v_group_delta := v_group_original\.quantity_delta[\s\S]*v_group_reversal\.quantity_delta/);
  assert.match(reconcile, /where m\.id = v_group_id or m\.reverses_movement_id = v_group_id/);
  assert.match(reconcile, /if v_inserted_count <> v_group_count then/);
  assert.match(reconcile, /unreconciled_movement_delta = p\.unreconciled_movement_delta - v_group_delta/);
  assert.match(reconcile, /quantity_delta, balance_before, balance_after[\s\S]*'MOVEMENT_RECONCILED', v_request, -v_group_delta/);
  assert.match(reconcile, /where r\.reconciliation_group_id = v_group_id/);
  assert.match(apply, /A reconciled movement cannot be reversed/);
  assert.match(apply, /A reversal cannot itself be reversed/);
  // Baseline 20 + (-3 + 3) overlay = 20; removing the group net (zero) leaves 20.
  assert.match(reconcile, /v_group_delta := v_group_original\.quantity_delta[\s\S]*\+ case when v_has_reversal then v_group_reversal\.quantity_delta else 0 end/);
});

test('documented projection examples preserve overlay and reconcile a zero-net reversal group', () => {
  const effective = (baseline, deltas) => baseline + deltas.reduce((sum, delta) => sum + delta, 0);
  assert.equal(effective(20, [-3]), 17); // A and C: later observation alone does not remove overlay.
  assert.equal(effective(20, [-3, 3]), 20); // B: pair net zero, so group reconciliation keeps 20.
  assert.match(migration, /set unreconciled_movement_delta = p\.unreconciled_movement_delta - v_group_delta/);
  assert.match(migration, /last_observation_status = v_event_type/);
  assert.match(migration, /ordinary imports only record observations|Neither upload time nor batch identity establishes workbook chronology/i);
});

test('GUDANG may review explicit count exceptions but cannot post; approved actors can approve their own session', () => {
  const issue = body('issue_stock_operation_intent');
  const apply = body('apply_stock_operation_intent');
  assert.match(issue, /elsif p_operation_key = 'REVIEW_EXCEPTION' then[\s\S]*reason is required/);
  assert.doesNotMatch(issue, /Exception review requires OWNER or ADMIN/);
  assert.doesNotMatch(apply, /REVIEW_EXCEPTION[\s\S]{0,180}v_role = 'GUDANG'/);
  assert.match(apply, /approved_by = v_actor/);
  assert.match(migration, /created_by uuid not null references auth\.users/);
  assert.match(apply, /last_counted_by = v_actor/);
});

test('movement posting is exact-once and cannot create a negative effective balance', () => {
  const apply = body('apply_stock_operation_intent');
  const balance = body('stock_apply_balance_delta');
  assert.match(migration, /operation_request_id uuid not null unique/);
  assert.match(migration, /stock_movement_source_event_once/);
  assert.match(migration, /stock_balance_projection_request_event_once[\s\S]*request_id, event_type, product_id/);
  assert.match(migration, /stock_movement_batch_source_context_unique/);
  assert.match(migration, /stock_movement_opname_item_fk/);
  assert.match(migration, /reverses_movement_id uuid references public\.stock_movements\(id\)/);
  assert.match(migration, /stock_movement_validate_reversal/);
  assert.match(body('validate_stock_movement_reversal'), /m\.product_id = new\.product_id and m\.outlet_id = new\.outlet_id/);
  assert.match(body('validate_stock_movement_reversal'), /quantity_delta <> -v_original_delta/);
  assert.match(balance, /for update/);
  assert.match(balance, /Stock movement would make effective stock negative/);
  assert.match(apply, /state in \('COMPLETED'.*?return v_req\.result/s);
  assert.match(apply, /insert into public\.stock_movements/);
  assert.match(apply, /update public\.stock_operation_requests set state = 'COMPLETED'/);
});

test('source reflection is explicit and future iPos sales are not wired as stock movements', () => {
  const apply = body('apply_stock_operation_intent');
  assert.match(apply, /v_req\.operation_key = 'RECONCILE_MOVEMENT'/);
  assert.match(apply, /v_period\.mode <> 'IPOS_SNAPSHOT_PLUS_QUENA_MOVEMENTS'/);
  assert.match(apply, /baseline_source_import_row_id is distinct from/);
  assert.match(apply, /confirmed_by, reason, request_id/);
  assert.match(apply, /cr\.batch_id = r\.batch_id[\s\S]*cr\.action in \('CREATE', 'UPDATE'\)/);
  assert.match(apply, /nc\.batch_id = r\.batch_id[\s\S]*nc\.outlet_id = r\.outlet_id[\s\S]*nc\.status = 'COMPLETED'/);
  assert.match(apply, /unreconciled_movement_delta = p\.unreconciled_movement_delta - v_group_delta/);
  assert.doesNotMatch(migration, /ipos_sales|daily_sales|SALES_IMPORT/i);
});

test('barcode resolution returns zero/one/many states without selecting an ambiguous product', () => {
  const resolver = body('resolve_stock_barcode');
  assert.match(resolver, /where b\.is_active and b\.barcode = btrim\(p_barcode\) collate "C"/);
  assert.match(resolver, /when s\.match_count = 0 then 'BARCODE_NOT_FOUND'/);
  assert.match(resolver, /when s\.match_count = 1 then 'BARCODE_MATCH'[\s\S]*else 'BARCODE_AMBIGUOUS'/);
  assert.match(resolver, /case when s\.match_count = 1 then s\.product_id end/);
  assert.match(resolver, /security invoker/);
  assert.match(resolver, /GUDANG/);
});

test('RLS is enabled everywhere, browser roles get read-only views, and definer functions are hardened', () => {
  const tables = [
    'stock_authority_periods', 'stock_balance_projection', 'stock_balance_baseline_events',
    'stock_balance_projection_events', 'stock_operation_requests', 'stock_opname_sessions',
    'stock_opname_items', 'stock_opname_count_events', 'stock_opname_session_events',
    'stock_movement_batches', 'stock_movements', 'stock_movement_source_reconciliations',
  ];
  for (const table of tables) assert.match(migration, new RegExp(`alter table public\\.${table} enable row level security`, 'i'));
  for (const name of [
    'refresh_stock_balance_from_ipos_inventory', 'stock_apply_balance_delta',
    'stock_opname_content_hash', 'issue_stock_operation_intent',
    'read_stock_operation_intent', 'apply_stock_operation_intent',
  ]) {
    const fn = body(name);
    assert.match(fn, /set search_path = pg_catalog/i, name);
    assert.match(migration, new RegExp(`alter function public\\.${name}\\([^;]*owner to postgres`, 'i'), name);
  }
  assert.match(migration, /grant execute on function public\.issue_stock_operation_intent\(text,jsonb\) to authenticated/);
  assert.match(migration, /grant execute on function public\.apply_stock_operation_intent\(uuid\) to authenticated/);
  assert.match(migration, /grant execute on function public\.resolve_stock_barcode\(uuid,text\) to authenticated/);
});

test('existing iPos inventory history remains snapshot history, not a movement ledger', () => {
  assert.match(inventorySchema, /create table public\.product_inventory_history/);
  assert.match(inventorySchema, /inventory_history_immutable/);
  assert.match(inventorySchema, /product_inventory_capture_history/);
  assert.doesNotMatch(inventorySchema, /stock_opname|stock_movements/);
});

test('staging fixtures use the trusted iPos request, claim, and completion lifecycle', () => {
  const uploader = inventorySchema.slice(
    inventorySchema.indexOf('create or replace function public.stamp_import_uploader()'),
    inventorySchema.indexOf('$$;', inventorySchema.indexOf('create or replace function public.stamp_import_uploader()')) + 3,
  );
  const claim = iposWorker.slice(
    iposWorker.indexOf('create or replace function public.claim_ipos_import_request('),
    iposWorker.indexOf('$$;', iposWorker.indexOf('create or replace function public.claim_ipos_import_request(')) + 3,
  );
  assert.match(uploader, /new\.status <> 'UPLOADED'/);
  assert.match(uploader, /new\.started_at is not null or new\.completed_at is not null/);
  assert.match(claim, /insert into public\.ipos_import_batches/);
  assert.match(claim, /set status = 'PROCESSING'/);
  assert.match(stagingFixture, /public\.request_ipos_import\(/);
  assert.match(stagingFixture, /set local role authenticated/i);
  assert.match(stagingFixture, /public\.claim_ipos_import_request\(/);
  assert.match(stagingFixture, /set local role service_role/i);
  assert.match(stagingFixture, /public\.complete_ipos_import_request\(v_request, v_batch, 8\)/);
  assert.doesNotMatch(stagingFixture, /insert into public\.ipos_import_batches/i);
  assert.doesNotMatch(stagingFixture, /update public\.ipos_import_batches\s+set status\s*=\s*'COMPLETED'/i);
});

test('runtime role tests set authenticated actor claims before RLS-protected fixture lookups', () => {
  const authenticatedBlock = stagingRuntime.slice(
    stagingRuntime.indexOf('DO $authenticated_role_tests$'),
    stagingRuntime.indexOf('$authenticated_role_tests$;', stagingRuntime.indexOf('DO $authenticated_role_tests$') + 4),
  );
  const ownerBlock = stagingRuntime.slice(
    stagingRuntime.indexOf('DO $owner_and_integrity_tests$'),
    stagingRuntime.indexOf('$owner_and_integrity_tests$;', stagingRuntime.indexOf('DO $owner_and_integrity_tests$') + 4),
  );
  const authClaim = authenticatedBlock.indexOf("set_config('request.jwt.claim.sub', v_owner::text, true)");
  assert.notEqual(authClaim, -1);
  for (const lookup of [
    'SELECT id INTO STRICT v_outlet FROM public.outlets',
    'SELECT id INTO STRICT v_product FROM public.products',
  ]) assert.ok(authClaim < authenticatedBlock.indexOf(lookup), `${lookup} follows the OWNER claim`);
  assert.ok(ownerBlock.indexOf("set_config('request.jwt.claim.sub', v_owner::text, true)")
    < ownerBlock.indexOf('SELECT id INTO STRICT v_outlet'), 'owner/integrity lookups follow the OWNER claim');
  assert.match(inventorySchema, /create policy outlets_select_active[\s\S]*?using \(public\.current_active_user_role\(\) is not null\)/i);
  assert.match(inventorySchema, /create policy products_select_active[\s\S]*?using \(public\.current_active_user_role\(\) is not null\)/i);
});

test('synthetic normalization payload matches the real RPC array/object and scalar JSON types', () => {
  const valuesBlock = stagingFixture.slice(
    stagingFixture.indexOf('SELECT * FROM (VALUES'),
    stagingFixture.indexOf(') AS seed(source_row_id', stagingFixture.indexOf('SELECT * FROM (VALUES')),
  );
  assert.doesNotMatch(valuesBlock, /'\{\}'::jsonb/, 'audit_findings seed values must never be JSON objects');
  assert.match(valuesBlock, /'\[\]'::jsonb/);
  assert.match(valuesBlock, /'\["DUPLICATE_BARCODE"\]'::jsonb/);
  assert.match(stagingFixture, /'audit_findings', r\.findings/);
  assert.match(stagingFixture, /'issues', '\[\]'::jsonb/);
  assert.match(stagingFixture, /'blocked_override_fields', '\[\]'::jsonb/);
  assert.match(stagingFixture, /'expectedState', jsonb_build_object\([\s\S]*'products', '\[\]'::jsonb,[\s\S]*'barcodes', '\[\]'::jsonb,[\s\S]*'overrides', '\[\]'::jsonb/);
  assert.match(stagingFixture, /'normalized_data', jsonb_build_object\(/);
  assert.match(stagingFixture, /'quantity', r\.quantity::text/);
  assert.match(normalizationModel, /canonical: string/);
  assert.match(preflightEngine, /quantity: row\.normalized\.quantity\.state === "valid" \? row\.normalized\.quantity\.value\.canonical : null/);
  assert.match(stagingFixture, /'minimumQuantity', '0'/);
  assert.match(stagingFixture, /'sellingPrice', '1000'/);
  assert.match(stagingFixture, /'hpp', '500'/);
  assert.match(normalization, /jsonb_typeof\(p_payload->'rows'\) <> 'array'/);
  assert.match(normalization, /jsonb_array_elements_text\(coalesce\(x\.audit_findings, '\[\]'::jsonb\)\)/);
  assert.match(normalization, /coalesce\(x\.issues, '\[\]'::jsonb\)/);
  assert.match(normalization, /jsonb_array_elements_text\(coalesce\(x\.blocked_override_fields, '\[\]'::jsonb\)\)/);
  assert.match(commitPayloadBuilder, /audit_findings: row\.auditFindings/);
  assert.match(commitPayloadBuilder, /issues: row\.issues/);
  assert.match(commitPayloadBuilder, /blocked_override_fields: row\.blockedOverrideFields/);
});

test('same-product barcode aliases use the authenticated correction workflow, not table DML', () => {
  assert.doesNotMatch(stagingFixture, /insert\s+into\s+public\.product_barcodes/i);
  assert.match(stagingFixture, /public\.issue_product_field_review_intent\(/i);
  assert.match(stagingFixture, /public\.record_product_field_review\(/i);
  assert.match(stagingFixture, /public\.issue_product_field_correction_intent\(/i);
  assert.match(stagingFixture, /public\.apply_product_field_correction_intent\(/i);
  assert.equal((stagingFixture.match(/'ADD_ALIAS'/g) ?? []).length, 2);
  assert.match(stagingFixture, /STG-BASE20-ALIAS-A/);
  assert.match(stagingFixture, /STG-BASE20-ALIAS-B/);
  assert.match(stagingFixture, /set local role authenticated[\s\S]*issue_product_field_review_intent/i);
  assert.match(stagingFixture, /automatic[a-z ]*verif/i);
  assert.match(stagingFixture, /\\quit 1/);
});

test('correction-intent forward fix removes PL/pgSQL conflict-target variable ambiguity', () => {
  const fixedIssueRpc = correctionIntentFix.slice(
    correctionIntentFix.indexOf('create or replace function public.issue_product_field_correction_intent('),
    correctionIntentFix.indexOf('$$;', correctionIntentFix.indexOf('create or replace function public.issue_product_field_correction_intent(')) + 3,
  );
  assert.match(fixedIssueRpc, /v_actor_id uuid := auth\.uid\(\)/);
  assert.match(fixedIssueRpc, /v_request_payload jsonb/);
  assert.match(fixedIssueRpc, /values\(v_actor_id,v_request_payload\)/);
  assert.match(fixedIssueRpc, /on conflict \(actor_id,request_payload\) where completed_at is null do nothing/i);
  assert.doesNotMatch(fixedIssueRpc, /\bactor_id uuid := auth\.uid\(\)|\brequest_payload jsonb;/);
  assert.match(correctionIntentFix, /language plpgsql security definer[\s\S]*set search_path = pg_catalog/i);
  assert.match(correctionIntentFix, /owner to postgres/i);
  assert.match(correctionIntentFix, /from public, anon, authenticated, service_role/i);
  assert.match(correctionIntentFix, /to authenticated/i);
  assert.match(stagingFixture, /public\.record_product_field_review\([\s\S]*?SEDANG_DICEK[\s\S]*?\)[\s\S]*?public\.issue_product_field_correction_intent\([\s\S]*?ADD_ALIAS[\s\S]*?public\.apply_product_field_correction_intent/i);
  assert.match(stagingFixture, /STG-BASE20-ALIAS-A/);
});

test('shared correction payload qualifies both correction-intent completion updates', () => {
  const sharedApply = correctionIntentFix.slice(
    correctionIntentFix.indexOf('create or replace function public.apply_product_field_correction_payload('),
    correctionIntentFix.indexOf('$$;', correctionIntentFix.indexOf('create or replace function public.apply_product_field_correction_payload(')) + 3,
  );
  assert.equal((sharedApply.match(/update public\.product_field_correction_intents as pci/gi) ?? []).length, 2);
  assert.equal((sharedApply.match(/where pci\.request_id\s*=\s*p_request_id[\s\S]*?pci\.actor_id\s*=\s*apply_correction_payload_block\.actor_id[\s\S]*?pci\.completed_at\s+is\s+null/gi) ?? []).length, 2);
  assert.doesNotMatch(sharedApply, /where\s+request_id\s*=\s*p_request_id\s+and\s+actor_id\s*=/i);
  assert.match(stagingFixture, /alias_a_present_without_losing_imported_barcode/i);
  assert.match(stagingFixture, /both_aliases_and_imported_barcode_present/i);
});

test('staging correction lifecycle uses separate ordered RPC transactions', () => {
  assert.equal((stagingFixture.match(/public\.issue_product_field_review_intent\(/g) ?? []).length, 2);
  assert.equal((stagingFixture.match(/public\.record_product_field_review\(/g) ?? []).length, 2);
  assert.equal((stagingFixture.match(/public\.issue_product_field_correction_intent\(/g) ?? []).length, 2);
  assert.equal((stagingFixture.match(/public\.apply_product_field_correction_intent\(/g) ?? []).length, 2);
  assert.equal((stagingFixture.match(/SELECT pg_catalog\.pg_sleep\(0\.01\)/g) ?? []).length, 8);
  assert.match(stagingFixture, /short gap ensures the[\s\S]*transaction_timestamp\(\) value/i);
  assert.match(stagingFixture, /COMMIT;\s*SELECT pg_catalog\.pg_sleep\(0\.01\);\s*BEGIN;\s*SELECT set_config\('request\.jwt\.claim\.sub'/i);
});

test('staging fixture writes use existing import paths or local-only setup and do not weaken grants', () => {
  assert.match(stagingFixture, /insert into storage\.objects/i, 'storage row only represents synthetic upload metadata');
  assert.match(stagingFixture, /set local role service_role[\s\S]*insert into public\.ipos_import_rows/i);
  assert.match(stagingFixture, /public\.request_ipos_import\(/i);
  assert.match(stagingFixture, /public\.claim_ipos_import_request\(/i);
  assert.match(stagingFixture, /public\.complete_ipos_import_request\(/i);
  assert.match(stagingFixture, /public\.commit_ipos_normalization\(/i);
  assert.match(stagingFixture, /insert into quena_staging\.fixture_runs/i);
  assert.doesNotMatch(stagingFixture, /\b(grant|revoke)\b|alter\s+table\s+public\.(product_barcodes|product_inventory)/i);
  assert.doesNotMatch(stagingBootstrap, /\b(grant|revoke)\b[^;]*product_barcodes|product_barcodes[^;]*\b(grant|revoke)\b/i);
  assert.doesNotMatch(stagingBootstrap, /disable row level security/i);
  assert.doesNotMatch(stagingFixture, /insert\s+into\s+public\.(products|product_inventory|product_outlet_settings|product_costs|product_selling_prices)/i);
});

test('staging reset is local-marker gated and never drops the database or cluster roles', () => {
  assert.match(stagingReset, /current_database\(\) <> 'quena_stock_staging'/);
  assert.match(stagingReset, /inet_server_port\(\) <> 5432/);
  assert.match(stagingReset, /host\(inet_server_addr\(\)\).+127\.0\.0\.1.+::1/s);
  assert.match(stagingReset, /quena_staging\.environment/);
  assert.match(stagingReset, /DROP SCHEMA public CASCADE/i);
  assert.match(stagingReset, /DROP SCHEMA storage CASCADE/i);
  assert.doesNotMatch(stagingReset, /DROP DATABASE|DROP ROLE|ALTER ROLE/i);
  assert.match(stagingResetRunner, /Type RESET quena_stock_staging/);
  assert.match(stagingResetRunner, /guard_local_target/);
});
