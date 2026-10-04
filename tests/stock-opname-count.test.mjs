import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { canAccessSection } from '../src/lib/auth/roles.ts';
import { countInputError, escapePostgrestContains, parseStockOpnameCountQuery } from '../src/lib/stock/opname-count-model.ts';

const page = readFileSync(new URL('../app/(workspace)/stok/opname/[id]/page.tsx', import.meta.url), 'utf8');
const read = readFileSync(new URL('../src/lib/stock/opname-count-read.ts', import.meta.url), 'utf8');
const model = readFileSync(new URL('../src/lib/stock/opname-count-model.ts', import.meta.url), 'utf8');
const action = readFileSync(new URL('../src/lib/stock/opname-count-action.ts', import.meta.url), 'utf8');
const workspace = readFileSync(new URL('../src/components/stock/stock-opname-counting.tsx', import.meta.url), 'utf8');
const migration = readFileSync(new URL('../supabase/migrations/20260929180000_stock_foundation_v1.sql', import.meta.url), 'utf8');
const runtimeSql = readFileSync(new URL('./staging/runtime-stock-opname-count.sql', import.meta.url), 'utf8');
const runtimeRunner = readFileSync(new URL('./staging/run-stock-opname-count-matrix.sh', import.meta.url), 'utf8');

test('OWNER, ADMIN, and GUDANG can access the count route; KASIR is denied server-side', () => {
  for (const role of ['OWNER', 'ADMIN', 'GUDANG']) assert.equal(canAccessSection(role, 'stok'), true);
  assert.equal(canAccessSection('KASIR', 'stok'), false);
  assert.match(page, /requireProfile\(\)[\s\S]*canAccessSection\(profile\.role, "stok"\)/);
  assert.match(action, /authorizedProfile\(\)[\s\S]*canAccessSection\(profile\.role, "stok"\)/);
});

test('count controls appear only while the database session status is COUNTING', () => {
  assert.match(workspace, /const canCount = data\.session\?\.status === "COUNTING"/);
  assert.match(workspace, /\{canCount &&/);
  assert.match(action, /issue_stock_operation_intent/);
  assert.match(migration, /v_session\.status <> 'COUNTING'::public\.stock_opname_status/);
});

test('quantity accepts zero and up to three dot/comma decimals, while rejecting blank, negative, malformed, and excess precision', () => {
  assert.equal(countInputError('0'), null);
  assert.equal(countInputError('12.345'), null);
  assert.equal(countInputError('12,345'), null);
  assert.match(countInputError('') ?? '', /kosong bukan nol/i);
  assert.match(countInputError('-1') ?? '', /angka nonnegatif/i);
  assert.match(countInputError('1.2345') ?? '', /maksimal tiga/i);
  assert.match(countInputError('1,2.3') ?? '', /maksimal tiga/i);
});

test('count operation binds caller revision, canonical quantity, and optional scanned barcode to existing RPCs', () => {
  assert.match(action, /p_operation_key: "RECORD_COUNT"/);
  assert.match(action, /expected_revision: input\.expectedRevision/);
  assert.match(action, /physical_quantity: Number\(input\.physicalQuantity\.replace\(",", "\."\)\)/);
  assert.match(action, /barcode_id: input\.barcodeId/);
  assert.match(action, /rpc\("apply_stock_operation_intent", \{ p_request_id: requestId \}\)/);
});

test('uncertain apply retry keeps and reuses the same request UUID instead of issuing another count', () => {
  assert.match(workspace, /savePendingValue\(pendingKey\(data\.session\.id, item\.productId\), JSON\.stringify\(pending\)\)/);
  assert.match(workspace, /finishApply\(item\.productId, pending\)/);
  assert.match(workspace, /removePendingValue\(pendingKey\(data\.session\.id, productId\)\)/);
  assert.match(migration, /if v_req\.state in \('COMPLETED'::public\.stock_request_state, 'STALE'::public\.stock_request_state/);
});

test('stale client revision and projection baseline have distinct messages and baseline-stale items require later action', () => {
  assert.match(model, /ITEM_REVISION_MISMATCH/);
  assert.match(model, /PROJECTION_BASELINE_CHANGED/);
  assert.match(action, /kind: "stale-item"/);
  assert.match(action, /kind: "stale-baseline"/);
  assert.match(workspace, /disabled=\{!editable\}/);
  assert.match(workspace, /requiresRecount \? "Perlu hitung ulang"/);
  assert.match(model, /Saldo stok berubah sejak opname dimulai/);
});

test('scanner resolves exact 0/1/many and only focuses an existing session item; scanning never changes quantity', () => {
  assert.match(workspace, /rpc\("resolve_stock_barcode"/);
  assert.match(workspace, /BARCODE_NOT_FOUND/);
  assert.match(workspace, /BARCODE_AMBIGUOUS/);
  assert.match(workspace, /BARCODE_MATCH/);
  assert.match(workspace, /Produk ini tidak termasuk dalam sesi opname/);
  assert.match(workspace, /Pemindaian hanya memilih item; jumlah tidak berubah/);
  assert.match(workspace, /Simpan hitungan/);
  assert.doesNotMatch(workspace, /physicalQuantity\s*\+\s*1|setQuantity\([^)]*\+\s*1/);
});

test('bounded count reads use server pagination/search, one progress RPC, and batched page metadata', () => {
  assert.match(model, /STOCK_OPNAME_COUNT_PAGE_SIZE = 40/);
  assert.match(read, /\.range\(\(query\.page - 1\) \* STOCK_OPNAME_COUNT_PAGE_SIZE/);
  assert.match(read, /referencedTable: "products"/);
  assert.match(read, /rpc\("stock_opname_progress_counts", \{ p_session_id: session\.id \}\)/);
  assert.match(read, /exception_reviewed_by, exception_reviewed_at/);
  assert.doesNotMatch(read, /const count = \(\)|count\(\)\.not\("physical_quantity"|count\(\)\.eq\("requires_recount"/);
  assert.match(read, /\.in\("product_id", productIds\)/);
  assert.doesNotMatch(read, /for\s*\([^)]*productIds|Promise\.all\([^)]*map\(/);
  assert.match(read, /\.order\("name"[\s\S]*\.order\("sku"[\s\S]*\.order\("product_id"/);
});

test('count display uses the captured opname baseline and generated variance, never current snapshot quantity or HPP', () => {
  assert.match(read, /baseline_quantity, physical_quantity, quantity_variance/);
  assert.match(workspace, /Saldo saat sesi dibuat/);
  assert.match(workspace, /item\.baselineQuantity/);
  assert.match(workspace, /item\.variance/);
  assert.doesNotMatch(read + action + workspace, /product_inventory\.quantity|product_inventory\).*quantity|\bhpp\b|product_costs|profit|service_role/i);
  assert.doesNotMatch(action + workspace, /\.from\("stock_opname_items"\)\s*\.(insert|update|upsert|delete)|\.from\("stock_balance_projection"\)\s*\.(insert|update|upsert|delete)/i);
});

test('count action remains scoped to RECORD_COUNT while posting uses its own action module', () => {
  assert.match(action, /p_operation_key: "RECORD_COUNT"/);
  assert.doesNotMatch(action, /SUBMIT_REVIEW|RETURN_TO_COUNTING|CANCEL_SESSION|POST_SESSION|REVERSE_MOVEMENT|RECONCILE_MOVEMENT/);
  assert.match(workspace, /POST_SESSION/);
  assert.doesNotMatch(workspace, /REVERSE_MOVEMENT|RECONCILE_MOVEMENT/);
});

test('URL parsing is bounded and invalid filters fall back to ALL; PostgREST search is quoted', () => {
  assert.deepEqual(parseStockOpnameCountQuery({ page: '9', filter: 'COUNTED', q: '  sku-2  ' }), { page: 9, filter: 'COUNTED', q: 'sku-2' });
  assert.equal(parseStockOpnameCountQuery({ page: '-4', filter: 'INVALID' }).page, 1);
  assert.equal(parseStockOpnameCountQuery({ filter: 'INVALID' }).filter, 'ALL');
  assert.equal(escapePostgrestContains('a,b'), '"%a,b%"');
  assert.equal(escapePostgrestContains('a_b%'), '"%a\\_b\\%%"');
});

test('rollback-only local runtime matrix covers the RECORD_COUNT role, revision, retry, and baseline contracts', () => {
  for (const actor of ['OWNER', 'ADMIN', 'GUDANG', 'KASIR']) assert.match(runtimeSql, new RegExp(`v_${actor.toLowerCase()} uuid`));
  assert.match(runtimeSql, /physical_quantity', 0, 'expected_revision', 0/);
  assert.match(runtimeSql, /physical_quantity', 1\.234, 'expected_revision', 0/);
  assert.match(runtimeSql, /physical_quantity', 2\.345, 'expected_revision', 1/);
  assert.match(runtimeSql, /ITEM_REVISION_MISMATCH/);
  assert.match(runtimeSql, /PROJECTION_BASELINE_CHANGED/);
  assert.match(runtimeSql, /apply_stock_operation_intent\(v_request\)/);
  assert.match(runtimeSql, /ROLLBACK;\s*\\echo 'PASS:/);
  assert.match(runtimeRunner, /guard_local_target/);
  assert.match(runtimeRunner, /assert_local_staging_marker/);
  assert.match(runtimeRunner, /state_before=.*stock-opname-create-state\.sql/);
  assert.match(runtimeRunner, /state_after=.*stock-opname-create-state\.sql/);
  assert.match(runtimeRunner, /if \[\[ "\$state_after" != "\$state_before" \]\]/);
  assert.doesNotMatch(runtimeSql, /INSERT\s+INTO|UPDATE\s+public\.(stock_|product_inventory)|DELETE\s+FROM|CREATE\s+(TEMP|TEMPORARY)\s+TABLE/i);
  assert.doesNotMatch(runtimeRunner, /supabase\s+(db\s+push|migration\s+repair)|\.env\.local|SUPABASE_SERVICE_ROLE_KEY/i);
});
