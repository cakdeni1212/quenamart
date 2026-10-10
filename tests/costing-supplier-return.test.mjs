import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const migration = read('supabase/migrations/20260929320000_costing_supplier_return_v1.sql');
const actions = read('src/app/actions/supplier-return.ts');
const reader = read('src/lib/stock/supplier-return-read.ts');
const route = read('app/(workspace)/pembelian/retur-supplier/page.tsx');
const sidebar = read('src/components/app/sidebar.tsx');
const workspace = read('src/components/purchasing/supplier-return-workspace.tsx');

test('C3D is forward capability only and preserves the existing stock/cost authorities', () => {
  assert.match(migration, /^-- C3D:[\s\S]*?BEGIN;/);
  assert.match(migration, /CREATE TABLE public\.supplier_returns/);
  assert.match(migration, /CREATE TABLE public\.supplier_return_items/);
  assert.match(migration, /CREATE TABLE public\.supplier_return_events/);
  assert.match(migration, /movement_type='SUPPLIER_RETURN'/);
  assert.doesNotMatch(migration, /inventory_cost_bootstrap_outlet\([^;]+\);|UPDATE public\.inventory_costing_outlet_authority[\s\S]*WAC_ACTIVE/i);
  assert.doesNotMatch(migration, /UPDATE public\.(?:product_inventory|stock_balance_projection)\s+SET/i);
  assert.doesNotMatch(migration, /UPDATE public\.(?:purchase_invoices|supplier_payables|supplier_payments)/i);
});

test('returns require supplier, bounded reason, positive precise quantities, and support optional linked legacy evidence', () => {
  assert.match(migration, /supplier_id uuid NOT NULL REFERENCES public\.suppliers/);
  assert.match(migration, /quantity numeric NOT NULL CHECK\(quantity>0 AND quantity=trunc\(quantity,3\)/);
  assert.match(migration, /supplier_return_item_source_shape/);
  assert.match(migration, /accepted_quantity\+i\.bonus_quantity/);
  assert.match(migration, /Supplier return exceeds returnable quantity from linked receipt/);
  assert.doesNotMatch(migration, /rejected_quantity\s*\+|short_quantity\s*\+/i);
  assert.match(migration, /Only draft supplier return lines can change/);
  assert.match(migration, /Posted or cancelled supplier return is immutable/);
});

test('post validates linked attribution and current stock atomically under the shared lock hierarchy', () => {
  const start = migration.indexOf('CREATE FUNCTION public.post_supplier_return');
  const end = migration.indexOf('ALTER FUNCTION public.post_supplier_return', start);
  const post = migration.slice(start, end);
  assert.ok(post.indexOf('pg_advisory_xact_lock') < post.indexOf('FOR UPDATE'));
  assert.ok(post.indexOf("authority='BOOTSTRAP_READY'") < post.indexOf('INSERT INTO public.stock_operation_requests'));
  assert.ok(post.indexOf('purchase_receipt_items WHERE id=x.source_receipt_item_id FOR UPDATE') < post.indexOf('stock_apply_balance_delta'));
  assert.ok(post.indexOf('ORDER BY product_id LOOP') < post.indexOf('stock_apply_balance_delta'));
  assert.match(post, /effective_quantity </);
  assert.match(post, /inventory_cost_apply_supplier_return/);
  assert.match(post, /SUPPLIER_RETURN/);
  assert.match(post, /state='COMPLETED'/);
});

test('WAC return cost uses unvalued-first source allocations and aggregate WAC, never receipt source price', () => {
  const start = migration.indexOf('CREATE FUNCTION public.inventory_cost_apply_supplier_return');
  const end = migration.indexOf('ALTER FUNCTION public.inventory_cost_apply_supplier_return', start);
  const writer = migration.slice(start, end);
  assert.match(writer, /least\(x\.quantity,c\.unvalued_quantity\)/);
  assert.match(writer, /inventory_cost_build_layer_outflow_plan/);
  assert.match(writer, /round\(v_valued\*c\.current_wac,8\)/);
  assert.match(writer, /WHEN v_valued=c\.valued_quantity THEN -coalesce\(c\.inventory_value,0\)/);
  assert.match(writer, /'SUPPLIER_RETURN','SUPPLIER_RETURN',d\.id,p_request_id/);
  assert.match(writer, /sourceReceiptIsAttributionOnly/);
  assert.doesNotMatch(writer, /source_unit_cost\s*\*|frozen_unit_cost\s*\*|fifo|lifo/i);
  assert.match(migration, /inventory_cost_event_supplier_return_item_once/);
  assert.match(migration, /stock_movement_supplier_return_item_once/);
});

test('role boundaries, SECURITY DEFINER actor checks, and operational-only responses are enforced', () => {
  for (const name of ['create_supplier_return','update_supplier_return','cancel_supplier_return','post_supplier_return']) {
    const start = migration.indexOf(`CREATE FUNCTION public.${name}`);
    const end = migration.indexOf(`ALTER FUNCTION public.${name}`, start);
    const body = migration.slice(start, end);
    assert.match(body, /SECURITY DEFINER SET search_path=pg_catalog/);
    if (name === 'post_supplier_return') assert.match(body, /supplier_return_assert_manager/);
    else assert.match(body, /supplier_return_assert_editor/);
  }
  assert.match(migration, /v_actor uuid:=auth\.uid\(\)/);
  assert.match(migration, /supplier_returns_operational_read/);
  assert.match(migration, /supplier_return_resolve_barcode/);
  assert.match(migration, /FROM PUBLIC,anon,authenticated,service_role/);
  assert.doesNotMatch(actions + reader + workspace, /inventory_cost_projections|inventory_cost_events|source_layer|current_wac|inventory_value|frozen_unit_cost/i);
  assert.match(actions, /\["OWNER", "ADMIN", "GUDANG"\]/);
  assert.match(actions, /\["OWNER", "ADMIN"\]/);
});

test('application adds the Purchasing child entry and operational draft/posting flow', () => {
  assert.match(sidebar, /Retur Supplier[\s\S]*pembelian/);
  assert.match(route, /OWNER.*ADMIN.*GUDANG/);
  assert.match(workspace, /supplierReturnReceiptCandidates/);
  assert.match(workspace, /Tidak ditautkan \/ legacy/);
  assert.match(workspace, /Tinjau &amp; posting/);
  assert.match(workspace, /tidak dapat diedit setelah diposting/);
  assert.match(workspace, /sessionStorage/);
  assert.match(reader, /supplier_return_items/);
  assert.match(reader, /posted_by_name/);
  assert.match(workspace, /posted_by_name[\s\S]*posted_at/);
});
