import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import {
  classifyStockStatus,
  filterStockRows,
  paginateStockRows,
  parseStockWorkspaceQuery,
  summarizeStockRows,
} from '../src/lib/stock/workspace.ts';
import { canAccessSection } from '../src/lib/auth/roles.ts';

const workspace = readFileSync(new URL('../src/lib/stock/workspace.ts', import.meta.url), 'utf8');
const read = readFileSync(new URL('../src/lib/stock/read.ts', import.meta.url), 'utf8');
const page = readFileSync(new URL('../app/(workspace)/stok/page.tsx', import.meta.url), 'utf8');
const component = readFileSync(new URL('../src/components/stock/stock-workspace.tsx', import.meta.url), 'utf8');
const roles = readFileSync(new URL('../src/lib/auth/roles.ts', import.meta.url), 'utf8');
const sidebar = readFileSync(new URL('../src/components/app/sidebar.tsx', import.meta.url), 'utf8');
const migration = readFileSync(new URL('../supabase/migrations/20260929190000_stock_workspace_read_v1.sql', import.meta.url), 'utf8');
const runtimeSql = readFileSync(new URL('../tests/staging/runtime-stock-workspace-read.sql', import.meta.url), 'utf8');
const diagnosticSql = readFileSync(new URL('../tests/staging/diagnose-stock-workspace-read.sql', import.meta.url), 'utf8');
const diagnosticRunner = readFileSync(new URL('../tests/staging/run-stock-workspace-read-check.sh', import.meta.url), 'utf8');
const scaleSql = readFileSync(new URL('../tests/staging/runtime-stock-workspace-scale.sql', import.meta.url), 'utf8');
const scaleRunner = readFileSync(new URL('../tests/staging/run-stock-workspace-scale-check.sh', import.meta.url), 'utf8');
const analyzeDiagnosticSql = readFileSync(new URL('../tests/staging/stock-workspace-analyze-diagnostic.sql', import.meta.url), 'utf8');
const analyzeDiagnosticRunner = readFileSync(new URL('../tests/staging/run-stock-workspace-analyze-diagnostic.sh', import.meta.url), 'utf8');
const scaleRpcCheckSql = readFileSync(new URL('../tests/staging/stock-workspace-scale-rpc-check.sql', import.meta.url), 'utf8');
const scaleRpcCheckRunner = readFileSync(new URL('../tests/staging/run-stock-workspace-scale-rpc-check.sh', import.meta.url), 'utf8');
const stagingLib = readFileSync(new URL('../tests/staging/lib.sh', import.meta.url), 'utf8');

test('stock status follows the presentation rules using effective quantity and minimum', () => {
  assert.equal(classifyStockStatus(0, 5), 'HABIS');
  assert.equal(classifyStockStatus(4, 5), 'MENIPIS');
  assert.equal(classifyStockStatus(5, 5), 'MENIPIS');
  assert.equal(classifyStockStatus(6, 5), 'AMAN');
  assert.equal(classifyStockStatus(0.125, null), 'AMAN');
  assert.equal(classifyStockStatus(null, 4), 'DATA_BELUM_TERSEDIA');
});

test('query parsing is URL-backed, bounded, and rejects unsupported stock status filters', () => {
  const query = parseStockWorkspaceQuery({ q: '  mie  ', status: 'UNKNOWN', rak: 'kosong', page: '-4', scan: '000123' });
  assert.deepEqual(query, { q: 'mie', category: '', status: 'SEMUA', emptyRack: true, page: 1, scan: '000123' });
  assert.equal(parseStockWorkspaceQuery({ q: 'x'.repeat(140) }).q.length, 120);
  assert.equal(parseStockWorkspaceQuery({ status: 'MENIPIS', page: '3' }).page, 3);
  assert.equal(parseStockWorkspaceQuery({ category: '  Minuman  ' }).category, 'Minuman');
});

test('rack-empty and stock status filters compose; summaries count the same stock records', () => {
  const rows = [
    { productId: 'a', rack: 'R1', status: 'HABIS' },
    { productId: 'b', rack: null, status: 'MENIPIS' },
    { productId: 'c', rack: ' ', status: 'AMAN' },
  ];
  assert.deepEqual(filterStockRows(rows, 'MENIPIS', true).map((row) => row.productId), ['b']);
  assert.deepEqual(summarizeStockRows(rows), { total: 3, habis: 1, menipis: 1, aman: 1 });
});

test('pagination defaults to 50 rows and clamps out-of-range pages', () => {
  const rows = Array.from({ length: 117 }, (_, index) => index);
  assert.deepEqual(paginateStockRows(rows, 1), {
    rows: rows.slice(0, 50), page: 1, pages: 3, total: 117, start: 1, end: 50,
  });
  assert.equal(paginateStockRows(rows, 99).page, 3);
  assert.equal(paginateStockRows([], 1).start, 0);
  assert.match(workspace, /STOCK_PAGE_SIZE = 50/);
});

test('server route enforces allowed roles and uses the stock projection as effective stock source', () => {
  assert.match(page, /canAccessSection\(profile\.role, "stok"\)/);
  assert.match(roles, /stok: \["OWNER", "ADMIN", "GUDANG"\]/);
  assert.match(sidebar, /label: "Stok", href: "\/stok", section: "stok"/);
  assert.match(read, /rpc\("stock_workspace_read_page"/);
  assert.match(read, /effective_quantity/);
  assert.match(migration, /bp\.effective_quantity/);
  assert.match(read, /classifyStockStatus\(effectiveQuantity, minimumQuantity\)/);
  assert.doesNotMatch(read, /from\("product_inventory"\)|product_costs|\bhpp\b|selling_price/);
});

test('stock page explains controlled stock changes without presenting direct editing', () => {
  assert.match(page, /Saldo efektif dari proyeksi stok Quena Mart/);
  assert.match(page, /Perubahan stok dilakukan melalui alur terkontrol seperti Stock Opname/);
  assert.match(page, /href="\/stok\/opname">Daftar opname</);
  assert.doesNotMatch(page, /Baca saja|BACA SAJA|stock-readonly-badge/);
  assert.doesNotMatch(page, /stock_operation_intent|UPDATE|INSERT|onChange=\{.*effectiveQuantity/);
});

test('barcode submission uses exact resolver and preserves 0/1/many outcomes without product creation', () => {
  assert.match(read, /rpc\("resolve_stock_barcode"/);
  assert.match(read, /BARCODE_NOT_FOUND/);
  assert.match(read, /BARCODE_AMBIGUOUS/);
  assert.match(read, /BARCODE_MATCH/);
  assert.match(component, /encodeURIComponent\(barcode\)/);
  assert.match(component, /router\.push\(`\/stok\?scan=/);
  assert.match(component, /className="stock-product-link"/);
  assert.doesNotMatch(component, /\/kasir|addToCart|createProduct|stock_operation_intent/);
});

test('OWNER, ADMIN, and GUDANG may enter Stock; KASIR is denied by the shared role policy', () => {
  assert.equal(canAccessSection('OWNER', 'stok'), true);
  assert.equal(canAccessSection('ADMIN', 'stok'), true);
  assert.equal(canAccessSection('GUDANG', 'stok'), true);
  assert.equal(canAccessSection('KASIR', 'stok'), false);
});

test('search is debounced and scanner Enter bypasses it; browser receives only the current page', () => {
  assert.match(component, /}, 225\)/);
  assert.match(component, /stock-category-filter/);
  assert.match(component, /categoryTimer/);
  assert.match(component, /function scan\(/);
  assert.match(component, /timer\.current\) clearTimeout/);
  assert.match(read, /p_page_size: STOCK_PAGE_SIZE/);
  assert.match(read, /p_category: query\.category \|\| null/);
  assert.match(read, /p_page: query\.page/);
  assert.match(read, /query,\s*rows,/);
  assert.match(component, /data\.rows\.map/);
  assert.doesNotMatch(component, /data\.allRows|data\.allProducts/);
});

test('workspace exposes product navigation and no HPP/cost fields to its client component', () => {
  assert.match(component, /href=\{`\/produk\/\$\{row\.productId\}`\}/);
  assert.doesNotMatch(component, /\bhpp\b|product_costs|selling_price/);
  assert.match(read, /function toSafeRow/);
  assert.match(read, /productId: product\.product_id/);
  assert.match(read, /effectiveQuantity,/);
  assert.match(read, /minimumQuantity,/);
});

test('server diagnostics identify failed stock reads without logging request credentials or product data', () => {
  assert.match(read, /logStockReadFailure\("stock_workspace_read_page", error, \{ page: query\.page \}\)/);
  assert.match(read, /logStockReadFailure\("stock_authority_periods", error\)/);
  const logger = read.slice(read.indexOf('function logStockReadFailure'), read.indexOf('\nfunction toSafeRow'));
  assert.match(logger, /code: safeDiagnosticText\(error\.code\)/);
  assert.match(logger, /message: safeDiagnosticText\(error\.message\)/);
  assert.match(logger, /details: safeDiagnosticText\(error\.details\)/);
  assert.match(logger, /hint: safeDiagnosticText\(error\.hint\)/);
  assert.doesNotMatch(logger, /access_token|authorization|cookie|process\.env|user\.id|product_id|productIds/i);
});

test('default Stock workspace uses one bounded database RPC instead of walking product pages or projection chunks', () => {
  assert.match(read, /rpc\("stock_workspace_read_page"/);
  assert.match(read, /p_page_size: STOCK_PAGE_SIZE/);
  assert.doesNotMatch(read, /fetchAllProductWorkspaceRows|product_workspace_list|fetchProjectionQuantities|\.in\("product_id"/);
  assert.match(read, /const rows = \(result\.rows \?\? \[\]\)\.map\(mapPageRow\)/);
  assert.match(migration, /v_page_size integer := least\(greatest\(coalesce\(p_page_size, 50\), 1\), 50\)/);
});

test('Stock read RPC searches and filters in SQL, returns summaries independent of status, and keeps projection authoritative', () => {
  const definition = migration.slice(migration.indexOf('create or replace function public.stock_workspace_read_page'), migration.indexOf('alter function public.stock_workspace_read_page'));
  assert.match(definition, /m\.effective_quantity/);
  assert.match(definition, /p\.name ilike|m\.name ilike/);
  assert.match(definition, /m\.sku ilike/);
  assert.match(definition, /search_barcode\.barcode ilike/);
  assert.match(definition, /search_barcode\.is_active/);
  assert.match(definition, /nullif\(btrim\(m\.rack\), ''\) is null/);
  assert.match(definition, /m\.category = v_category/);
  assert.match(definition, /summary as \([\s\S]*?from classified as c\s*\)/);
  assert.match(definition, /filtered as materialized \([\s\S]*?v_stock_status = 'ALL' or c\.stock_status = v_stock_status/);
  assert.match(definition, /order by f\.name collate "C", f\.sku collate "C", f\.product_id/);
  assert.match(definition, /filtered_total/);
  assert.match(definition, /when m\.effective_quantity = 0 then 'HABIS'/);
  assert.match(definition, /m\.minimum_stock > 0|coalesce\(m\.minimum_stock, 0\) > 0/);
  assert.match(definition, /m\.effective_quantity <= m\.minimum_stock then 'MENIPIS'/);
  assert.match(definition, /not m\.projection_usable/);
  assert.doesNotMatch(definition, /i\.quantity|hpp|product_costs|selling_price|raw_data|dynamic sql/i);
});

test('Stock read RPC is authenticated-only, role-gated, invoker-secured, and read-only', () => {
  const definition = migration.slice(migration.indexOf('create or replace function public.stock_workspace_read_page'), migration.indexOf('alter function public.stock_workspace_read_page'));
  assert.match(definition, /security invoker/i);
  assert.match(definition, /set search_path = pg_catalog, public/i);
  assert.match(definition, /'OWNER'::public\.user_role/);
  assert.match(definition, /'ADMIN'::public\.user_role/);
  assert.match(definition, /'GUDANG'::public\.user_role/);
  assert.match(definition, /Stock access denied/);
  assert.match(migration, /revoke all on function public\.stock_workspace_read_page\([^;]+ from public, anon, service_role/);
  assert.match(migration, /grant execute on function public\.stock_workspace_read_page\([^;]+ to authenticated/);
  assert.doesNotMatch(definition, /\b(insert|update|delete|merge|truncate)\s+into?\b/i);
});

test('Stock page summaries and row count are supplied by the bounded RPC, with visible integrity warning', () => {
  assert.match(read, /summary: \{/);
  assert.match(read, /filtered_total/);
  assert.match(read, /missing_projection_count/);
  assert.match(component, /missingProjectionCount > 0/);
  assert.match(component, /data\.rows\.map/);
  assert.doesNotMatch(component, /data\.allRows|data\.allProducts/);
});

test('staging runtime sets the OWNER JWT before RLS-protected fixture lookups and diagnoses missing prerequisites', () => {
  const ownerClaim = runtimeSql.indexOf("set_config('request.jwt.claim.sub', v_owner::text, true)");
  const outletLookup = runtimeSql.indexOf('FROM public.outlets AS o');
  assert.ok(ownerClaim >= 0 && ownerClaim < outletLookup);
  assert.match(runtimeSql, /auth\.uid\(\) IS DISTINCT FROM v_owner/);
  assert.match(runtimeSql, /current_active_user_role\(\) IS DISTINCT FROM 'OWNER'/);
  assert.match(runtimeSql, /fixture outlet QUENA-MART-1 is missing, inactive, or hidden by RLS/);
  assert.match(runtimeSql, /no visible active authority period/);
  assert.match(runtimeSql, /membership\/projection mismatch/);
});

test('already-applied staging checker is fail-closed and never reapplies migration 190000', () => {
  assert.match(diagnosticSql, /BEGIN READ ONLY/);
  assert.match(diagnosticSql, /auth\.uid\(\)/);
  assert.match(diagnosticSql, /current_active_user_role\(\)/);
  assert.match(diagnosticSql, /stock_authority_periods/);
  assert.match(diagnosticSql, /stock_balance_projection/);
  assert.match(diagnosticRunner, /guard_local_target/);
  assert.match(diagnosticRunner, /assert_local_staging_marker/);
  assert.match(diagnosticRunner, /migration 190000 is not recorded as applied/);
  assert.match(diagnosticRunner, /psql_local -f "\$SCRIPT_DIR\/diagnose-stock-workspace-read\.sql"/);
  assert.match(diagnosticRunner, /psql_local -f "\$SCRIPT_DIR\/runtime-stock-workspace-read\.sql"/);
  assert.doesNotMatch(diagnosticRunner, /psql_local -f "\$STAGING_ROOT\/supabase\/migrations|INSERT INTO|supabase db push/);
});

test('scale harness pins the reviewed migration, uses synthetic transaction-scoped data, and rolls back', () => {
  assert.match(stagingLib, /STAGING_DATABASE='quena_stock_staging'/);
  assert.match(stagingLib, /STAGING_HOST='localhost'/);
  assert.match(stagingLib, /STAGING_PORT='5432'/);
  assert.match(scaleRunner, /guard_local_target/);
  assert.match(scaleRunner, /assert_local_staging_marker/);
  assert.match(scaleRunner, /f3e6382354bf0c1f5d9f7f1530180ed039375ac42a7e7afac4bc9d493cc3e576/);
  assert.match(scaleRunner, /20260929190000.*stock_workspace_read_page/s);
  assert.doesNotMatch(scaleRunner, /psql_local -f "\$STAGING_ROOT\/supabase\/migrations|supabase db push|SUPABASE_SERVICE_ROLE_KEY/);
  assert.match(scaleSql, /BEGIN;/);
  assert.match(scaleSql, /ROLLBACK;/);
  assert.match(scaleSql, /generate_series\(1, 5096\)/);
  assert.match(scaleSql, /5,103 usable projections/);
  assert.match(scaleSql, /SET LOCAL ROLE authenticated/);
  assert.match(scaleSql, /stock_workspace_read_page/);
  for (const caseLabel of ['PERFORMANCE A:', 'PERFORMANCE B1:', 'PERFORMANCE B2:', 'PERFORMANCE C:', 'PERFORMANCE D:', 'PERFORMANCE E:', 'PERFORMANCE F1:', 'PERFORMANCE G:']) {
    assert.ok(scaleSql.includes(caseLabel), `missing ${caseLabel}`);
  }
  assert.match(scaleSql, /EXPLAIN \(ANALYZE, BUFFERS, COSTS, SUMMARY\)/);
  assert.doesNotMatch(scaleSql, /drop database|supabase db push|https?:\/\/|SUPABASE_SERVICE_ROLE_KEY/i);
});

test('ANALYZE diagnostic reuses only the synthetic setup and compares the same relational plan before and after statistics refresh', () => {
  assert.match(analyzeDiagnosticRunner, /guard_local_target/);
  assert.match(analyzeDiagnosticRunner, /assert_local_staging_marker/);
  assert.match(analyzeDiagnosticRunner, /f3e6382354bf0c1f5d9f7f1530180ed039375ac42a7e7afac4bc9d493cc3e576/);
  assert.match(analyzeDiagnosticRunner, /20260929190000.*stock_workspace_read_page/s);
  assert.match(analyzeDiagnosticRunner, /runtime-stock-workspace-scale\.sql/);
  assert.match(analyzeDiagnosticRunner, /stock-workspace-analyze-diagnostic\.sql/);
  assert.match(analyzeDiagnosticRunner, /mktemp .*quena-stock-analyze-diagnostic\.XXXXXX/);
  assert.doesNotMatch(analyzeDiagnosticRunner, /psql_local -f "\$STAGING_ROOT\/supabase\/migrations|supabase db push|service_role key/i);
  assert.match(scaleSql, /BEGIN;/);
  assert.match(analyzeDiagnosticRunner, /awk .*FIXTURE_SOURCE/);
  assert.match(analyzeDiagnosticSql, /EXPLAIN \(ANALYZE, BUFFERS, VERBOSE, COSTS, SUMMARY\)[\s\S]*?EXECUTE stock_workspace_analyze_plan/);
  const planExecutions = analyzeDiagnosticSql.split('\n').filter((line) => line.startsWith('EXECUTE stock_workspace_analyze_plan('));
  assert.deepEqual(planExecutions, [
    "EXECUTE stock_workspace_analyze_plan(:'scale_outlet_id'::uuid, NULL, 'ALL', false, NULL, 1, 50);",
    "EXECUTE stock_workspace_analyze_plan(:'scale_outlet_id'::uuid, NULL, 'ALL', false, NULL, 1, 50);",
  ]);
  for (const table of ['product_inventory', 'product_outlet_settings', 'stock_balance_projection', 'product_barcodes', 'products']) {
    assert.equal((analyzeDiagnosticSql.match(new RegExp(`ANALYZE public\\.${table};`, 'g')) ?? []).length, 1, `${table} should be analyzed once`);
  }
  assert.match(analyzeDiagnosticSql, /SET LOCAL ROLE authenticated/);
  assert.match(analyzeDiagnosticSql, /current_active_user_role\(\) IS DISTINCT FROM 'OWNER'/);
  assert.match(analyzeDiagnosticSql, /PRIMARY KEY|UNIQUE/);
  assert.match(analyzeDiagnosticSql, /ROLLBACK;/);
  assert.doesNotMatch(analyzeDiagnosticSql, /drop database|supabase db push|https?:\/\/|SUPABASE_SERVICE_ROLE_KEY/i);
});

test('post-ANALYZE scale RPC harness is guarded, measures seven correct cases, and rolls the fixture back', () => {
  assert.match(scaleRpcCheckRunner, /guard_local_target/);
  assert.match(scaleRpcCheckRunner, /assert_local_staging_marker/);
  assert.match(scaleRpcCheckRunner, /f3e6382354bf0c1f5d9f7f1530180ed039375ac42a7e7afac4bc9d493cc3e576/);
  assert.match(scaleRpcCheckRunner, /20260929190000.*stock_workspace_read_page/s);
  assert.match(scaleRpcCheckRunner, /runtime-stock-workspace-scale\.sql/);
  assert.doesNotMatch(scaleRpcCheckRunner, /psql_local -f "\$STAGING_ROOT\/supabase\/migrations|supabase db push|statement_timeout|https?:\/\//i);
  assert.match(scaleRpcCheckSql, /ANALYZE public\.product_inventory;/);
  assert.match(scaleRpcCheckSql, /ANALYZE public\.product_outlet_settings;/);
  assert.match(scaleRpcCheckSql, /ANALYZE public\.stock_balance_projection;/);
  assert.match(scaleRpcCheckSql, /ANALYZE public\.product_barcodes;/);
  assert.match(scaleRpcCheckSql, /ANALYZE public\.products;/);
  assert.match(scaleRpcCheckSql, /SET LOCAL ROLE authenticated/);
  assert.match(scaleRpcCheckSql, /current_active_user_role\(\) IS DISTINCT FROM 'OWNER'/);
  for (const caseName of ['A-default-page-1', 'B-page-50', 'C-HABIS', 'D-MENIPIS', 'E-rack-empty', 'F-selective-SKU', 'G-selective-barcode']) {
    assert.ok(scaleRpcCheckSql.includes(`'${caseName}'`), `missing RPC case ${caseName}`);
  }
  assert.match(scaleRpcCheckSql, /v_elapsed_ms > 1000/);
  assert.match(scaleRpcCheckSql, /EXPLAIN \(ANALYZE, BUFFERS, VERBOSE, COSTS, SUMMARY, FORMAT JSON\)/);
  assert.match(scaleRpcCheckSql, /ROLLBACK;/);
  assert.doesNotMatch(scaleRpcCheckSql, /drop database|supabase db push|https?:\/\/|SUPABASE_SERVICE_ROLE_KEY/i);
});
