import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const migration = await readFile(new URL("../supabase/migrations/20260929330000_pos_cart_foundation_v1.sql", import.meta.url), "utf8");
const action = await readFile(new URL("../src/app/actions/pos-cart.ts", import.meta.url), "utf8");
const readModel = await readFile(new URL("../src/lib/pos/cart-read.ts", import.meta.url), "utf8");
const architecture = await readFile(new URL("../docs/POS_ARCHITECTURE.md", import.meta.url), "utf8");

test("P1B migration is additive persisted-cart foundation with no completed-sale state", () => {
  for (const table of ["pos_carts", "pos_cart_items", "pos_cart_events", "pos_cart_mutation_requests"]) {
    assert.match(migration, new RegExp(`CREATE TABLE public\\.${table}\\b`));
  }
  assert.match(migration, /CREATE TYPE public\.pos_cart_status AS ENUM \('ACTIVE','PARKED','CANCELLED'\)/);
  assert.doesNotMatch(migration, /'COMPLETED'|'PAYMENT_IN_PROGRESS'/);
});

test("P1B installs no checkout, payment, revenue, stock movement, or costing writer", () => {
  assert.doesNotMatch(migration, /CREATE TABLE public\.(sales|sale_items|sale_payments)\b/i);
  assert.doesNotMatch(migration, /INSERT\s+INTO\s+public\.(stock_movements|stock_movement_batches|inventory_cost_events|inventory_cost_event_batches|inventory_cost_source_layers|inventory_cost_layer_allocations)\b/i);
  assert.doesNotMatch(migration, /UPDATE\s+public\.(stock_balance_projection|inventory_cost_projections)\b/i);
  assert.doesNotMatch(migration, /CREATE FUNCTION public\.(complete_sale|checkout|post_sale)\b/i);
});

test("POS RPCs bind actor/outlet, use fixed search paths, and check roles", () => {
  for (const fn of ["pos_cart_context", "pos_cart_create", "pos_cart_add_item", "pos_cart_set_item_quantity", "pos_cart_acknowledge_price", "pos_cart_transition", "pos_resolve_barcode", "pos_search_products", "pos_cart_workspace_read"]) {
    const start = migration.indexOf(`CREATE FUNCTION public.${fn}(`);
    assert.notEqual(start, -1, `${fn} exists`);
    const end = migration.indexOf("ALTER FUNCTION public.", start);
    const body = migration.slice(start, end);
    assert.match(body, /SECURITY DEFINER/);
    assert.match(body, /SET search_path=pg_catalog,public/);
  }
  assert.match(migration, /a:=auth\.uid\(\)/);
  assert.match(migration, /current_active_user_role\(\)/);
  assert.match(migration, /'OWNER'::public\.user_role,'ADMIN'::public\.user_role,'KASIR'::public\.user_role/);
});

test("cart tables deny direct client DML and events are append-only", () => {
  assert.match(migration, /ENABLE ROW LEVEL SECURITY/);
  assert.match(migration, /FORCE ROW LEVEL SECURITY/);
  assert.match(migration, /REVOKE ALL ON public\.pos_carts,public\.pos_cart_items,public\.pos_cart_events,public\.pos_cart_mutation_requests FROM PUBLIC,anon,authenticated,service_role/);
  assert.match(migration, /guard_pos_cart_event_immutable/);
});

test("cart mutations use request identity plus optimistic revision", () => {
  assert.match(migration, /CREATE TABLE public\.pos_cart_mutation_requests[\s\S]*request_id uuid PRIMARY KEY/);
  assert.match(migration, /payload_hash text NOT NULL/);
  assert.match(migration, /POS_CART_REQUEST_REUSED/);
  assert.match(migration, /POS_CART_STALE_REVISION/);
  assert.match(migration, /ON CONFLICT\(request_id\) DO NOTHING/);
  assert.match(action, /requestId/);
  assert.match(action, /expectedRevision/);
});

test("scan retries replay while distinct scans increment one product line", () => {
  assert.match(migration, /UNIQUE\(cart_id,product_id\)/);
  assert.match(migration, /new_qty:=item\.quantity\+p_quantity_delta/);
  assert.match(migration, /pos_cart_request_begin\(p_request_id,c\.actor_id,c\.outlet_id,'ADD_ITEM'/);
});

test("price evidence is server-selected and stale cart prices are visible", () => {
  assert.match(migration, /observed_price_history_id uuid REFERENCES public\.product_selling_price_history/);
  assert.match(migration, /pos_product_contract\(c\.outlet_id,p_product\)/);
  assert.match(migration, /POS_PRICE_CHANGED_ACK_REQUIRED/);
  assert.match(migration, /'price_status',CASE WHEN s\.amount IS NULL OR s\.amount<=0 THEN 'UNAVAILABLE' WHEN s\.amount<>i\.observed_unit_price THEN 'CHANGED' ELSE 'CURRENT' END/);
  assert.match(migration, /POS_PRICE_CHANGED_RETRY/);
  assert.match(action, /p_confirmed_price: input\.currentPrice/);
});

test("KASIR barcode/search results are bounded and omit cost fields", () => {
  assert.match(migration, /CREATE FUNCTION public\.pos_resolve_barcode\(p_barcode text\)/);
  assert.match(migration, /BARCODE_NOT_FOUND/);
  assert.match(migration, /BARCODE_AMBIGUOUS/);
  assert.match(migration, /CREATE FUNCTION public\.pos_search_products\(p_query text,p_limit integer DEFAULT 25\)/);
  assert.match(migration, /least\(greatest\(coalesce\(p_limit,25\),1\),25\)/);
  assert.doesNotMatch(migration, /product_costs|inventory_cost_projections|inventory_cost_source_layers|hpp|wac/i);
  assert.match(action, /resolvePosBarcode/);
  assert.match(action, /searchPosProducts/);
});

test("cart lifecycle persists park, resume, cancellation, and multiple carts", () => {
  assert.match(migration, /'PARKED','CANCELLED'/);
  assert.match(migration, /'PARK','RESUME','CANCEL'/);
  assert.match(migration, /pos_cart_park/);
  assert.match(migration, /pos_cart_resume/);
  assert.match(migration, /pos_cart_cancel/);
  assert.doesNotMatch(migration, /UNIQUE\s*\([^)]*created_by[^)]*\).*ACTIVE/s);
});

test("read model is bounded and server-only", () => {
  assert.match(readModel, /import "server-only"/);
  assert.match(readModel, /p_limit: 20/);
  assert.match(migration, /lim:=least\(greatest\(coalesce\(p_limit,20\),1\),30\)/);
  assert.match(migration, /'effective_stock',b\.effective_quantity/);
  assert.match(migration, /'observed_total'/);
  assert.doesNotMatch(readModel, /product_costs|inventory_cost|hpp|wac/i);
});

test("architecture records final P1B boundary and cutover rules", () => {
  assert.match(architecture, /REFERENCE_ONLY/);
  assert.match(architecture, /UNVALUED/);
  assert.match(architecture, /P1B/);
  assert.match(architecture, /checkout/);
});
