import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(new URL('../supabase/migrations/20260929350000_pos_atomic_checkout_v1.sql', import.meta.url), 'utf8');
const ui = await readFile(new URL('../src/components/pos/pos-workspace.tsx', import.meta.url), 'utf8');

test('P1D-B installs a single authenticated checkout RPC behind the WAC gate', () => {
  assert.match(migration, /CREATE FUNCTION public\.pos_checkout_complete\(/);
  assert.match(migration, /SECURITY DEFINER SET search_path=pg_catalog/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.pos_checkout_complete[\s\S]* TO authenticated/);
  assert.match(migration, /REVOKE ALL ON FUNCTION public\.pos_checkout_complete[\s\S]* FROM PUBLIC,anon,service_role/);
  assert.match(migration, /auth_state IS DISTINCT FROM 'WAC_ACTIVE'[\s\S]*POS_COSTING_NOT_ACTIVE/);
  assert.doesNotMatch(migration, /UPDATE public\.inventory_costing_outlet_authority/);
});

test('checkout revalidates cart, stock before price, and server-calculates tender', () => {
  const stock = migration.indexOf('FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=li.product_id FOR UPDATE');
  const price = migration.indexOf('FROM public.product_selling_prices s WHERE s.outlet_id=o AND s.product_id=li.product_id FOR UPDATE');
  assert.ok(stock >= 0 && price > stock, 'stock lock must precede selling-price lock');
  assert.match(migration, /c\.revision<>p_expected_cart_revision[\s\S]*POS_CART_STALE/);
  assert.match(migration, /proj\.effective_quantity<li\.quantity[\s\S]*POS_INSUFFICIENT_STOCK/);
  assert.match(migration, /price\.amount IS DISTINCT FROM li\.observed_unit_price[\s\S]*POS_PRICE_CHANGED/);
  assert.match(migration, /received:=round\(p_cash_received_amount,2\)[\s\S]*change_amt:=received-total/);
  assert.match(migration, /VALUES\(sale,o,p_payment_method,total,received,change_amt,ref,a\)/);
});

test('checkout reuses stock and C3B costing kernels and preserves unvalued COGS as NULL', () => {
  assert.match(migration, /public\.stock_apply_balance_delta\(li\.product_id,o,-li\.quantity\)/);
  assert.match(migration, /public\.inventory_cost_build_layer_outflow_plan\(p_outlet,v_line\.product_id,v_uv,'UNVALUED'\)/);
  assert.match(migration, /public\.inventory_cost_build_layer_outflow_plan\(p_outlet,v_line\.product_id,v_val,'VALUED'\)/);
  assert.match(migration, /public\.inventory_cost_apply_layer_plan\(/);
  assert.match(migration, /CASE WHEN v_final_qty>0 THEN CASE[\s\S]*END END/);
  assert.match(migration, /WHEN v_uv>0 THEN 'UNRESOLVED'/);
  assert.match(migration, /VALUES\(v_line\.id,p_sale,p_outlet,v_line\.product_id,p_request,v_m\.id,v_event,v_line\.quantity,v_val,v_prov,v_uv,/);
  assert.doesNotMatch(migration, /COALESCE\([^\n]*resolved_cogs_amount[^\n]*,\s*0/);
});

test('native sale stock evidence is normalized and generic reversal is blocked', () => {
  assert.match(migration, /stock_movement_batch_pos_sale_once/);
  assert.match(migration, /stock_movement_pos_sale_item_once/);
  assert.match(migration, /FOREIGN KEY\(pos_sale_item_id,pos_sale_id,outlet_id,product_id\)/);
  assert.match(migration, /guard_no_pos_sale_reversal/);
  assert.match(migration, /POS_COMPLETED_SALE_REVERSAL_FORBIDDEN/);
  assert.match(migration, /UPDATE public\.pos_carts SET status='COMPLETED'/);
});

test('P1D-B does not enable Bayar or add cashier-facing cost data', () => {
  assert.match(ui, /disabled/);
  assert.doesNotMatch(ui, /pos_checkout_complete|SALE_COGS|inventory_cost_apply_pos_sale/);
  assert.doesNotMatch(migration.slice(migration.indexOf('CREATE FUNCTION public.pos_checkout_complete')), /resolved_cogs_amount|provisional_cogs_amount|current_wac|inventory_value/);
});
