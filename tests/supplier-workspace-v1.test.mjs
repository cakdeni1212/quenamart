import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const migration = read('supabase/migrations/20260929440000_supplier_workspace_v1.sql');
const page = read('app/(workspace)/pembelian/supplier/page.tsx');
const detailPage = read('app/(workspace)/pembelian/supplier/[supplierId]/page.tsx');
const actions = read('src/lib/purchasing/actions.ts');
const reader = read('src/lib/purchasing/supplier-workspace-read.ts');
const listUi = read('src/components/purchasing/supplier-workspace.tsx');
const detailUi = read('src/components/purchasing/supplier-detail-workspace.tsx');

test('supplier workspace extends the existing supplier master and does not create a parallel identity', () => {
  assert.match(migration, /ALTER TABLE public\.suppliers\s+ADD COLUMN address text,\s+ADD COLUMN notes text/);
  assert.doesNotMatch(migration, /CREATE TABLE public\.(?:supplier_master|supplier_directory|supplier_workspace)/i);
  assert.match(migration, /supplier_code/);
  assert.match(migration, /is_active=coalesce\(p_is_active,is_active\)/);
  assert.doesNotMatch(migration, /DELETE FROM public\.suppliers|DROP TABLE public\.suppliers/i);
});

test('supplier workspace RPCs are fixed-search-path and enforce active actor roles server-side', () => {
  for (const name of ['supplier_workspace_upsert','supplier_workspace_page','supplier_workspace_detail']) {
    const start = migration.indexOf(`CREATE FUNCTION public.${name}`);
    const end = migration.indexOf(`ALTER FUNCTION public.${name}`, start);
    const body = migration.slice(start, end);
    assert.ok(start >= 0 && end > start, `${name} exists`);
    assert.match(body, /SECURITY DEFINER SET search_path\s*=\s*pg_catalog/);
    assert.match(body, /auth\.uid\(\)/);
    assert.match(body, /r IS NULL/);
  }
  assert.match(migration, /r NOT IN \('OWNER'::public\.user_role,'ADMIN'::public\.user_role,'GUDANG'::public\.user_role\)/);
  assert.match(migration, /Supplier financial access denied/);
  assert.match(migration, /FROM PUBLIC,anon,service_role/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.supplier_workspace_detail[\s\S]+TO authenticated/);
});

test('financial summaries use finalized invoice payables and allocated payments without receipt multiplication', () => {
  assert.match(migration, /sp\.original_amount-coalesce\(pa\.paid,0\)/);
  assert.match(migration, /supplier_payment_allocations a ON a\.payable_id=sp\.id/);
  assert.match(migration, /i\.status='FINALIZED'/);
  assert.match(migration, /r\.status='POSTED'/);
  assert.match(migration, /purchase_invoice_receipts pir/);
  assert.doesNotMatch(migration, /JOIN public\.purchase_receipt_items[\s\S]{0,200}supplier_payables/);
  assert.doesNotMatch(migration, /inventory_cost|source_layer|current_wac|hpp|cogs/i);
});

test('supplier reads are bounded and GUDANG receives identity-only rows', () => {
  assert.match(migration, /LEAST\(greatest\(coalesce\(p_page_size,20\),1\),30\)/i);
  assert.match(migration, /'financialAccess',false/);
  const gudang = migration.slice(migration.indexOf("IF r='GUDANG'"), migration.indexOf('WITH payable AS', migration.indexOf("IF r='GUDANG'")));
  assert.match(gudang, /s\.display_name/);
  assert.doesNotMatch(gudang, /outstanding|supplier_payables|supplier_payment_allocations|purchase_invoices/i);
  assert.match(reader, /\["OWNER", "ADMIN"\]\.includes\(profile\.role\)/);
  assert.match(reader, /supplier_workspace_page/);
  assert.match(reader, /supplier_workspace_detail/);
});

test('workspace routes preserve existing role boundaries and link existing purchase workflows', () => {
  assert.match(page, /\["OWNER", "ADMIN", "GUDANG"\]/);
  assert.match(page, /canManage=\{profile\.role === "OWNER" \|\| profile\.role === "ADMIN"\}/);
  assert.match(detailPage, /\["OWNER", "ADMIN"\]/);
  assert.match(detailUi, /\/pembelian\/nota\/\$\{p\.id\}/);
  assert.match(detailUi, /\/pembelian\/barang-masuk\/baru\?supplier=\$\{s\.id\}/);
  assert.match(detailUi, /wa\.me/);
  assert.match(listUi, /primaryAction\.primary/);
  assert.match(listUi, /primaryAction\.secondary/);
  assert.match(actions, /supplier_workspace_upsert/);
});
