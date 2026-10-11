import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/20260929340000_pos_sales_evidence_v1.sql', import.meta.url),
  'utf8',
).toLowerCase();
const cartMigration = readFileSync(
  new URL('../supabase/migrations/20260929330000_pos_cart_foundation_v1.sql', import.meta.url),
  'utf8',
).toLowerCase();

test('P1D-A adds schema evidence and COMPLETED enum values only', () => {
  for (const table of [
    'pos_checkout_requests', 'sales', 'sale_items', 'sale_payments',
    'sale_item_cost_evidence', 'sale_item_cost_allocations', 'sale_item_cost_resolutions',
  ]) assert.match(migration, new RegExp(`create table public\\.${table}`));
  assert.match(migration, /alter type public\.pos_cart_status add value 'completed'/);
  assert.match(migration, /alter type public\.pos_cart_event_type add value 'completed'/);
  assert.match(migration, /create sequence public\.pos_sale_number_seq/);
  assert.match(migration, /qpos-\[0-9\]\{8\}-\[0-9\]\{8,\}/);
});

test('sale identities and snapshots are outlet scoped and constrained', () => {
  assert.match(migration, /sales_native_cart_once unique\(pos_cart_id\)/);
  assert.match(migration, /checkout_request_id uuid not null unique/);
  assert.match(migration, /sales_number_outlet_unique unique\(outlet_id,sale_number\)/);
  assert.match(migration, /discount_total numeric\(32,2\) not null default 0 check \(discount_total=0\)/);
  assert.match(migration, /grand_total=subtotal-discount_total/);
  assert.match(migration, /quantity=trunc\(quantity,3\)/);
  assert.match(migration, /line_subtotal numeric\(32,2\) generated always/);
  assert.match(migration, /foreign key\(selling_price_history_id,product_id,outlet_id\)/);
  assert.match(migration, /unique\(sale_id,product_id\)/);
});

test('payments support multiple tenders and enforce cash/noncash shape', () => {
  assert.match(migration, /'cash','qris','card','e_wallet'/);
  assert.match(migration, /applied_amount numeric\(32,2\) not null check \(applied_amount>0\)/);
  assert.match(migration, /received_amount>=applied_amount and change_amount=received_amount-applied_amount/);
  assert.match(migration, /method<>'cash' and received_amount is null and change_amount is null/);
  assert.doesNotMatch(migration, /unique\s*\(sale_id\)\s*;/);
});

test('checkout replay schema is dedicated and has no callable writer', () => {
  assert.match(migration, /payment_payload_hash text not null/);
  assert.match(migration, /expected_cart_revision bigint not null/);
  assert.match(migration, /sale_id uuid unique/);
  assert.doesNotMatch(migration, /security definer/);
  assert.doesNotMatch(migration, /create\s+(or replace\s+)?function public\.(pos_)?(complete|checkout|create_sale)/);
  assert.doesNotMatch(migration, /grant execute/);
});

test('unknown COGS stays nullable and source allocation linkage is normalized', () => {
  assert.match(migration, /resolved_cogs_amount numeric\(32,8\)/);
  assert.match(migration, /provisional_cogs_amount numeric\(32,8\)/);
  assert.match(migration, /'resolved','provisional','partially_unresolved','unresolved'/);
  assert.match(migration, /valued_quantity\+unvalued_quantity=quantity/);
  assert.match(migration, /source_layer_allocation_id uuid not null/);
  assert.match(migration, /inventory_cost_layer_allocations\(/);
  assert.match(migration, /sale_item_cost_allocation_once unique\(sale_item_id,source_layer_allocation_id\)/);
  assert.match(migration, /sale_item_cost_resolution_once unique\(source_layer_allocation_id,resolution_cost_event_id\)/);
  assert.match(migration, /sale_item_cost_evidence_immutable/);
  assert.match(migration, /sale_item_cost_allocations_immutable/);
  assert.match(migration, /sale_item_cost_resolutions_immutable/);
});

test('P1D-A exposes no sale/payment/stock/COGS mutation path', () => {
  assert.doesNotMatch(migration, /insert into public\.(sales|sale_items|sale_payments|stock_movements|stock_movement_batches|inventory_cost_events|inventory_cost_event_batches)/);
  assert.doesNotMatch(migration, /update public\.(pos_carts|stock_balance_projection|inventory_cost_projections)/);
  assert.doesNotMatch(migration, /bootstrap|wac_active/i);
  assert.match(migration, /revoke all on public\.pos_checkout_requests,public\.sales,public\.sale_items,public\.sale_payments/);
  assert.match(migration, /grant select on public\.sale_item_cost_evidence,public\.sale_item_cost_allocations,public\.sale_item_cost_resolutions to authenticated/);
  assert.match(migration, /current_active_user_role\(\) in \('owner'::public\.user_role,'admin'::public\.user_role\)/);
  assert.match(migration, /alter table public\.sales force row level security/);
  assert.match(migration, /revoke all on sequence public\.pos_sale_number_seq/);
});

test('existing P1B mutations continue to require ACTIVE cart state', () => {
  const mutationSection = cartMigration.slice(
    cartMigration.indexOf('create function public.pos_cart_add_item'),
    cartMigration.indexOf('create function public.pos_resolve_barcode'),
  );
  assert.equal((mutationSection.match(/cart\.status<>'active'/g) ?? []).length, 3);
  assert.match(mutationSection, /p_operation='park' and cart\.status='active'/);
  assert.match(mutationSection, /p_operation='resume' and cart\.status='parked'/);
  assert.match(mutationSection, /p_operation='cancel' and cart\.status in \('active','parked'\)/);
});
