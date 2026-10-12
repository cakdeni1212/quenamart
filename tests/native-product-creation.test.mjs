import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const read = (path) => readFile(new URL(path, import.meta.url), 'utf8');
const [migration, hppMigration, productList, createPage, action, form, posContracts, docs] = await Promise.all([
  read('../supabase/migrations/20260929380000_native_product_creation_v1.sql'),
  read('../supabase/migrations/20260929390000_native_product_reference_hpp_v1.sql'),
  read('../app/(workspace)/produk/page.tsx'),
  read('../app/(workspace)/produk/tambah/page.tsx'),
  read('../src/app/actions/native-product.ts'),
  read('../src/components/products/native-product-form.tsx'),
  read('../supabase/migrations/20260929330000_pos_cart_foundation_v1.sql'),
  read('../docs/IPOS_IMPORT.md'),
]);

test('only OWNER and ADMIN receive the creation entry point and route', () => {
  assert.match(productList, /isManager && <Link className="native-product-add" href="\/produk\/tambah">\+ Tambah Produk/);
  assert.match(createPage, /profile\.role !== "OWNER" && profile\.role !== "ADMIN"/);
  assert.match(action, /profile\.role !== "OWNER" && profile\.role !== "ADMIN"/);
  assert.match(createPage, /randomUUID\(\)/);
});

test('creation is one authenticated, replay-safe, outlet-scoped RPC', () => {
  assert.match(migration, /CREATE FUNCTION public\.native_product_create\(/);
  assert.match(migration, /SECURITY DEFINER SET search_path=pg_catalog,public/);
  assert.match(migration, /v_actor uuid:=auth\.uid\(\)/);
  assert.match(migration, /current_active_user_role\(\)/);
  assert.match(migration, /NATIVE_PRODUCT_REQUEST:/);
  assert.match(migration, /NATIVE_PRODUCT_REQUEST_CONFLICT/);
  assert.match(migration, /RETURN v_existing\.result/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.native_product_create[\s\S]*TO authenticated/);
  assert.match(migration, /FROM PUBLIC,anon,service_role/);
  assert.match(action, /supabase\.rpc\("native_product_create"/);
});

test('SKU generation is server-side and concurrent identities remain unique', () => {
  assert.match(migration, /CREATE SEQUENCE public\.native_product_sku_seq/);
  assert.match(migration, /nextval\('public\.native_product_sku_seq'\)/);
  assert.match(migration, /products_sku_key/);
  assert.match(migration, /NATIVE_PRODUCT_SKU_EXISTS/);
  assert.match(migration, /NATIVE_PRODUCT_BARCODE:/);
  assert.match(migration, /LOCK TABLE public\.product_barcodes IN SHARE ROW EXCLUSIVE MODE/);
  assert.match(migration, /NATIVE_PRODUCT_BARCODE_EXISTS/);
});

test('current outlet selling price writes through the existing history trigger', () => {
  assert.match(migration, /INSERT INTO public\.product_selling_prices\(product_id,outlet_id,amount,created_by,updated_by\)/);
  assert.doesNotMatch(migration, /INSERT INTO public\.product_selling_price_history/);
  assert.match(migration, /NATIVE_PRODUCT_PRICE_INVALID/);
  assert.match(action, /p_selling_price: sellingPrice/);
  assert.match(hppMigration, /p_reference_hpp numeric/);
  assert.match(hppMigration, /INSERT INTO public\.product_costs\(product_id,outlet_id,hpp,source_import_row_id,created_by,updated_by\)/);
  assert.match(hppMigration, /VALUES\(v_product,v_outlet,p_reference_hpp,NULL,v_actor,v_actor\)/);
  assert.match(hppMigration, /'reference_hpp',p_reference_hpp/);
  assert.match(hppMigration, /DROP FUNCTION public\.native_product_create\(uuid,text,text,text,text,text,text,text,numeric\)/);
  assert.match(action, /p_reference_hpp: hpp/);
  assert.match(form, /HPP \/ Harga Pokok/);
  assert.match(form, /Harga jual lebih rendah dari HPP/);
  assert.match(form, /import \{ compareRupiah \} from "@\/lib\/money"/);
  assert.match(form, /compareRupiah\(sellingPrice, hpp\) === -1/);
  assert.match(action, /NATIVE_PRODUCT_SKU_EXISTS: "Kode SKU sudah digunakan\."/);
  assert.match(action, /NATIVE_PRODUCT_BARCODE_EXISTS: "Barcode sudah digunakan oleh produk lain\."/);
});

test('native creation records only its audited zero baseline, without acquisition/cost/bootstrap', () => {
  assert.match(migration, /CREATE TABLE public\.stock_native_zero_baselines/);
  assert.match(migration, /accepted_baseline_quantity numeric NOT NULL DEFAULT 0 CHECK \(accepted_baseline_quantity=0\)/);
  assert.match(migration, /INSERT INTO public\.stock_balance_projection\([\s\S]*baseline_quantity,native_zero_baseline_request_id/);
  assert.match(migration, /NATIVE_ZERO_BASELINE_ACCEPTED/);
  assert.match(migration, /VALUES\(v_product,v_outlet,0,NULL,v_actor,v_actor\)/);
  assert.doesNotMatch(migration, /INSERT\s+INTO\s+public\.(stock_movements|stock_movement_batches|inventory_cost_projections|inventory_cost_event_batches|inventory_cost_events|inventory_cost_source_layers|product_costs|product_cost_history|inventory_cost_hpp_acceptance_batches)/i);
  assert.doesNotMatch(hppMigration, /INSERT\s+INTO\s+public\.(stock_movements|stock_movement_batches|inventory_cost_projections|inventory_cost_event_batches|inventory_cost_events|inventory_cost_source_layers|inventory_cost_hpp_acceptance_batches)/i);
  assert.match(form, /name="hpp"/);
  assert.match(form, /name="sellingPrice"/);
  assert.match(hppMigration, /VALUES\(v_product,v_outlet,p_reference_hpp,NULL,v_actor,v_actor\)/);
  assert.match(hppMigration, /DROP FUNCTION/);
  assert.doesNotMatch(migration, /inventory_cost_bootstrap_outlet\s*\(/i);
  assert.doesNotMatch(form, /name="(?:initialStock|stockQuantity)"/i);
  assert.match(form, /Stok awal produk baru adalah 0/);
  assert.match(migration, /Stock baseline refresh requires an iPos source row/);
  assert.match(migration, /STOCK_CUTOVER_NATIVE_BASELINE_INVALID/);
  assert.match(migration, /p\.native_zero_baseline_request_id IS NULL/);
});

test('native product uses the existing POS inventory, price, and barcode read contract', () => {
  assert.match(migration, /INSERT INTO public\.product_inventory/);
  assert.match(migration, /INSERT INTO public\.product_barcodes/);
  assert.match(posContracts, /JOIN public\.product_inventory i ON i\.product_id=p\.id AND i\.outlet_id=c\.outlet_id/);
  assert.match(posContracts, /JOIN public\.product_selling_prices s ON s\.product_id=p\.id AND s\.outlet_id=c\.outlet_id AND s\.amount>0/);
  assert.match(posContracts, /FROM public\.product_barcodes pb WHERE pb\.product_id=p\.id AND pb\.is_active/);
  assert.match(docs, /iPos-imported products retain/);
  assert.match(docs, /audited zero-stock baseline/);
});

test('success returns to the normal product detail and the UI explains stock policy', () => {
  assert.match(action, /redirect\(`\/produk\/\$\{result\.product_id\}\?created=1`\)/);
  assert.match(form, /Simpan Produk/);
  assert.match(form, /Stok awal produk baru adalah 0\. Tambahkan stok melalui Barang Masuk/);
});
