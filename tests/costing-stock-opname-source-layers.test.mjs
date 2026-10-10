import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/20260929300000_costing_stock_opname_source_layers_v1.sql', import.meta.url),
  'utf8',
).toLowerCase();

function apportionMills(quantityMills, buckets) {
  const total = buckets.reduce((sum, row) => sum + row.available, 0n);
  assert.ok(quantityMills > 0n && quantityMills <= total);
  const rows = buckets.map((row) => {
    const numerator = quantityMills * row.available;
    return { ...row, share: numerator / total, remainder: numerator % total };
  });
  let remaining = quantityMills - rows.reduce((sum, row) => sum + row.share, 0n);
  const ranked = [...rows].sort((a, b) => {
    if (a.remainder !== b.remainder) return a.remainder > b.remainder ? -1 : 1;
    return a.key.localeCompare(b.key);
  });
  for (const row of ranked) {
    if (remaining === 0n) break;
    row.share += 1n;
    remaining -= 1n;
  }
  assert.equal(remaining, 0n);
  return new Map(rows.map((row) => [row.key, row.share]));
}

test('C3B adds protected quantity provenance without carrying source values into layers', () => {
  assert.match(migration, /create table public\.inventory_cost_source_layers/);
  assert.match(migration, /create table public\.inventory_cost_source_layer_balances/);
  assert.match(migration, /create table public\.inventory_cost_layer_allocations/);
  assert.match(migration, /source_event_type/);
  assert.match(migration, /original_valued_quantity/);
  assert.match(migration, /original_provisional_quantity/);
  assert.match(migration, /original_unvalued_quantity/);
  assert.match(migration, /remaining_valued_quantity/);
  assert.match(migration, /remaining_provisional_quantity/);
  assert.match(migration, /remaining_unvalued_quantity/);
  assert.match(migration, /cost event and source-layer allocations do not reconcile/i);
  const allocationDefinition = migration.slice(
    migration.indexOf('create table public.inventory_cost_layer_allocations'),
    migration.indexOf('create unique index inventory_cost_layer_allocation_event_layer_kind_once'),
  );
  assert.doesNotMatch(allocationDefinition, /inventory_value|carrying_value|unit_cost/);
  assert.match(migration, /physical_quantity_delta=valued_quantity_delta\+unvalued_quantity_delta/);
});

test('C3B protects source layers with manager-only read and no direct DML', () => {
  for (const table of [
    'inventory_cost_source_layers',
    'inventory_cost_source_layer_balances',
    'inventory_cost_layer_allocations',
  ]) {
    assert.match(migration, new RegExp(`alter table public\\.${table} enable row level security`));
    assert.match(migration, new RegExp(`${table}_manager_read`));
  }
  assert.match(migration, /from public,anon,authenticated,service_role/);
  assert.match(migration, /current_active_user_role\(\) in \('owner'::public\.user_role,'admin'::public\.user_role\)/);
});

test('outflow allocates unvalued first and valued provenance proportionally in integer thousandths', () => {
  assert.match(migration, /inventory_cost_build_layer_outflow_plan/);
  assert.match(migration, /p_quantity\*1000/);
  assert.match(migration, /floor\(v_quantity_mills\*e\.available_mills\/v_available_mills\)/);
  assert.match(migration, /remainder_numerator desc,layer_id,bucket/);
  assert.match(migration, /v_remove_unvalued:=least\(abs\(v_m\.quantity_delta\),v_cost\.unvalued_quantity\)/);
  assert.match(migration, /v_plan_valued:=public\.inventory_cost_build_layer_outflow_plan/);
  assert.match(migration, /'unvalued_first_then_proportional'/);
  assert.doesNotMatch(migration, /fifo|lifo/);
});

test('largest-remainder quantity shares are exact, stable, and bounded to thousandths', () => {
  const first = apportionMills(3n, [
    { key: 'layer-a/final', available: 2n },
    { key: 'layer-b/provisional', available: 2n },
    { key: 'layer-c/final', available: 2n },
  ]);
  const replay = apportionMills(3n, [
    { key: 'layer-c/final', available: 2n },
    { key: 'layer-a/final', available: 2n },
    { key: 'layer-b/provisional', available: 2n },
  ]);
  assert.deepEqual([...first].sort(), [...replay].sort());
  assert.deepEqual([...first.values()].reduce((sum, value) => sum + value, 0n), 3n);
  assert.equal(first.get('layer-a/final'), 1n);
  assert.equal(first.get('layer-b/provisional'), 1n);
  assert.equal(first.get('layer-c/final'), 1n);
});

test('opname adds positive variance as unvalued and prices valued shrinkage at aggregate WAC', () => {
  assert.match(migration, /v_unvalued:=v_m\.quantity_delta/);
  assert.match(migration, /v_remove_valued\*v_cost\.current_wac/);
  assert.match(migration, /if v_remove_valued=v_cost\.valued_quantity then\s*v_value_delta:=-coalesce\(v_cost\.inventory_value,0\)/);
  assert.match(migration, /valuation_basis.*current_wac/s);
  assert.match(migration, /inventory_value_delta/);
  assert.match(migration, /'opname_adjustment'/);
});

test('stock post wrapper serializes with the shared cutover lock and is atomic with costing', () => {
  const wrapper = migration.slice(migration.indexOf('create function public.apply_stock_operation_intent(p_request_id uuid)'));
  const advisory = wrapper.indexOf("'cost_bootstrap_outlet:'");
  const requestLock = wrapper.indexOf('for update');
  const bootstrapGate = wrapper.indexOf("v_authority='bootstrap_ready'");
  const stockCall = wrapper.indexOf('apply_stock_operation_intent_pre_c3b(p_request_id);', bootstrapGate);
  const costingCall = wrapper.indexOf('inventory_cost_apply_stock_movement_operation(p_request_id,v_operation,v_outlet)');
  assert.ok(advisory >= 0 && requestLock > advisory && bootstrapGate > requestLock);
  assert.ok(stockCall > bootstrapGate && costingCall > stockCall);
  assert.match(wrapper, /if v_authority='bootstrap_ready' then\s*raise exception/s);
  assert.match(wrapper, /v_authority='wac_active'.*inventory_cost_apply_stock_movement_operation/s);
  assert.match(wrapper, /grant execute on function public\.apply_stock_operation_intent\(uuid\) to authenticated/);
});

test('source identity prevents duplicate opname costing and duplicate reversal', () => {
  assert.match(migration, /inventory_cost_event_source_stock_movement_once/);
  assert.match(migration, /where source_stock_movement_id is not null/);
  assert.match(migration, /inventory_cost_event_reversal_once/);
  assert.match(migration, /where reverses_cost_event_id is not null/);
  assert.match(migration, /opname cost event source does not match its stock movement/i);
  assert.match(migration, /reversal cost event does not exactly invert its original event/i);
});

test('reversal inverts original layer allocations and blocks dependent source activity', () => {
  assert.match(migration, /later\.cost_version>v_orig\.cost_version_after/);
  assert.match(migration, /use a compensating stock correction/);
  assert.match(migration, /-v_alloc\.physical_quantity_delta/);
  assert.match(migration, /-v_alloc\.valued_quantity_delta/);
  assert.match(migration, /reverses_allocation_id/);
  assert.match(migration, /v_orig\.inventory_value_delta/);
  assert.match(migration, /inventory_cost_layer_balance_ledger_consistent/);
});

test('bootstrap and C3A receipt wrappers open source layers without activating WAC', () => {
  assert.match(migration, /inventory_cost_apply_purchase_receipt_pre_c3b/);
  assert.match(migration, /inventory_cost_open_source_layer\(v_event\.id\)/);
  assert.match(migration, /inventory_cost_bootstrap_outlet_pre_c3b/);
  assert.match(migration, /coalesce\(v_result->>'code',''\)='bootstrap_ready'/);
  assert.doesNotMatch(migration, /update public\.inventory_costing_outlet_authority set status='wac_active'/);
  assert.doesNotMatch(migration, /perform public\.inventory_cost_bootstrap_outlet\(/);
});
