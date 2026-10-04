import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { canAccessSection } from '../src/lib/auth/roles.ts';

const action = readFileSync(new URL('../src/lib/stock/opname-create-action.ts', import.meta.url), 'utf8');
const page = readFileSync(new URL('../app/(workspace)/stok/opname/baru/page.tsx', import.meta.url), 'utf8');
const form = readFileSync(new URL('../src/components/stock/stock-opname-create-form.tsx', import.meta.url), 'utf8');
const reader = readFileSync(new URL('../src/lib/stock/opname-create-read.ts', import.meta.url), 'utf8');
const detail = readFileSync(new URL('../app/(workspace)/stok/opname/[id]/page.tsx', import.meta.url), 'utf8');
const countReader = readFileSync(new URL('../src/lib/stock/opname-count-read.ts', import.meta.url), 'utf8');
const migration = readFileSync(new URL('../supabase/migrations/20260929180000_stock_foundation_v1.sql', import.meta.url), 'utf8');
const runtimeSql = readFileSync(new URL('./staging/runtime-stock-opname-create.sql', import.meta.url), 'utf8');
const runtimeRunner = readFileSync(new URL('./staging/run-stock-opname-create-matrix.sh', import.meta.url), 'utf8');
const stateSql = readFileSync(new URL('./staging/stock-opname-create-state.sql', import.meta.url), 'utf8');

test('OWNER, ADMIN, and GUDANG may create opname; KASIR is denied server-side', () => {
  for (const role of ['OWNER', 'ADMIN', 'GUDANG']) assert.equal(canAccessSection(role, 'stok'), true);
  assert.equal(canAccessSection('KASIR', 'stok'), false);
  assert.match(action, /getProfile\(\)[\s\S]*canAccessSection\(profile\.role, "stok"\)/);
  assert.match(page, /requireProfile\(\)[\s\S]*canAccessSection\(profile\.role, "stok"\)/);
});

test('FULL payload delegates exact projection scope to CREATE_SESSION with an empty product list', () => {
  assert.match(form, /Semua produk dengan saldo dalam proyeksi outlet saat sesi dibuat/);
  assert.match(action, /scope === "FULL" \? \[\] : productIds/);
  assert.match(action, /p_operation_key: "CREATE_SESSION"/);
  assert.match(migration, /if v_payload->>'scope_type' = 'FULL'[\s\S]*from public\.stock_balance_projection p[\s\S]*where p\.outlet_id = v_outlet_id/);
  assert.match(reader, /stock_workspace_read_page/);
  assert.match(reader, /missingProjectionCount: workspace\.integrity\.missing_projection_count/);
});

test('PARTIAL requires explicit unique products with nonnull effective quantity and baseline provenance', () => {
  assert.match(action, /formData\.getAll\("product_id"\)/);
  assert.match(action, /\[\.\.\.new Set\(selected/);
  assert.match(action, /scope === "PARTIAL" && productIds\.length === 0/);
  assert.match(form, /stock_balance_projection/);
  assert.match(form, /not\("effective_quantity", "is", null\)/);
  assert.match(form, /not\("baseline_source_import_row_id", "is", null\)/);
  assert.match(form, /selected\.has\(row\.product_id\)/);
  assert.match(form, /Pindai barcode \(tekan Enter\)/);
  assert.match(action, /product_ids: scope === "FULL" \? \[\] : productIds/);
});

test('PARTIAL barcode resolution preserves exact 0/1/many behavior and blocks unusable baselines', () => {
  assert.match(form, /rpc\("resolve_stock_barcode"/);
  assert.match(form, /BARCODE_NOT_FOUND/);
  assert.match(form, /BARCODE_AMBIGUOUS/);
  assert.match(form, /BARCODE_MATCH/);
  assert.match(form, /system_quantity/);
  assert.match(form, /baseline yang dapat digunakan/);
});

test('FULL setup shows projection-scope and missing/unusable data warnings without snapshot fallback', () => {
  assert.match(reader, /\.from\("stock_balance_projection"\)/);
  assert.match(reader, /count: "exact", head: true/);
  assert.match(reader, /effective_quantity\.is\.null,baseline_source_import_row_id\.is\.null/);
  assert.match(form, /missingProjectionCount > 0/);
  assert.match(form, /unusableProjectionCount > 0/);
  assert.doesNotMatch(reader + form, /product_inventory[\s\S]{0,200}quantity/);
});

test('creation applies exactly the issued request UUID and uses only CREATE_SESSION RPC mutations', () => {
  assert.match(action, /rpc\("issue_stock_operation_intent"/);
  assert.match(action, /rpc\("apply_stock_operation_intent", \{\s*p_request_id: requestId/);
  assert.match(action, /redirect\(`\/stok\/opname\/\$\{applied\.sessionId\}`\)/);
  assert.doesNotMatch(action, /\.from\("stock_opname_(sessions|items|session_events)"\)\s*\.(insert|update|upsert|delete)|RECORD_COUNT|REBASE_ITEM|REVIEW_EXCEPTION|SUBMIT_REVIEW|RETURN_TO_COUNTING|CANCEL_SESSION|POST_SESSION|REVERSE_MOVEMENT|RECONCILE_MOVEMENT|service_role/i);
  assert.match(action, /stock_opname_no_active_overlap/);
  assert.match(action, /Permintaan opname sudah berubah/);
});

test('confirmation is explicit and buttons prevent duplicate in-flight submission', () => {
  assert.match(form, /name="confirm" value="yes" required/);
  assert.match(form, /disabled=\{pending \|\| !canCreate\}/);
  assert.match(action, /formData\.get\("confirm"\) !== "yes"/);
});

test('detail route is read-only and reports created session scope, status, time, and item count', () => {
  assert.match(detail, /readStockOpnameCounting\(profile, id, query\)/);
  assert.match(countReader, /\.from\("stock_opname_sessions"\)[\s\S]*\.maybeSingle\(\)/);
  assert.match(countReader, /\.from\("stock_opname_items"\)[\s\S]*select\([\s\S]*\{ count: "exact" \}\)[\s\S]*\.range\(/);
  assert.match(countReader, /rpc\("stock_opname_progress_counts", \{ p_session_id: session\.id \}\)/);
  assert.match(countReader, /scope_type/);
  assert.match(countReader, /created_at/);
  assert.doesNotMatch(detail, /RECORD_COUNT|REBASE_ITEM|REVIEW_EXCEPTION|SUBMIT_REVIEW|CANCEL_SESSION|POST_SESSION|HPP|product_costs/i);
});

test('create flow exposes no HPP or financial data and never changes product_inventory/projection directly', () => {
  assert.doesNotMatch(action + form + reader, /\bhpp\b|cost|profit|product_costs|service_role/i);
  assert.doesNotMatch(action, /\.from\("stock_balance_projection"\)|\.from\("stock_opname_(sessions|items|session_events)"\)/);
  assert.doesNotMatch(action, /\.from\("product_inventory"\)|\.from\("product_inventory_history"\)/);
  assert.doesNotMatch(form, /client\.from\([^)]*\)\s*\.(insert|update|upsert|delete)\(/);
});

test('staging CREATE_SESSION runtime matrix is local-only, role-authenticated, and rollback-only', () => {
  assert.match(runtimeRunner, /guard_local_target/);
  assert.match(runtimeRunner, /assert_local_staging_marker/);
  assert.match(runtimeRunner, /version = '20260929180000'/);
  assert.match(runtimeRunner, /version = '20260929190000'/);
  assert.doesNotMatch(runtimeRunner, /supabase\s+(db\s+push|migration\s+repair)|\.env\.local|SUPABASE_SERVICE_ROLE_KEY/i);
  assert.match(runtimeSql, /SET LOCAL ROLE authenticated/);
  assert.match(runtimeSql, /ROLLBACK;\s*\\echo 'PASS:/);
  assert.match(runtimeRunner, /state_before=.*stock-opname-create-state\.sql/);
  assert.match(runtimeRunner, /state_after=.*stock-opname-create-state\.sql/);
  assert.match(runtimeRunner, /if \[\[ "\$state_after" != "\$state_before" \]\]/);
  assert.match(runtimeRunner, /post-rollback durable-state fingerprint is unchanged/);
  assert.match(stateSql, /BEGIN READ ONLY/);
  assert.match(stateSql, /owned_sequences/);
  assert.match(stateSql, /product_inventory_history/);
  assert.match(stateSql, /product_costs/);
  assert.match(stateSql, /stock_opname_session_events/);
  assert.doesNotMatch(runtimeSql, /changed durable fixture state before final rollback/);
  assert.match(runtimeSql, /issue_stock_operation_intent\('CREATE_SESSION'/);
  assert.match(runtimeSql, /apply_stock_operation_intent\(/);
  assert.doesNotMatch(runtimeSql, /INSERT\s+INTO|UPDATE\s+public\.(stock_|product_inventory)|DELETE\s+FROM|CREATE\s+(TEMP|TEMPORARY)\s+TABLE/i);
});

test('staging CREATE_SESSION matrix covers role, scope, baseline, overlap, retry, and no-mutation contracts', () => {
  for (const actor of ['OWNER', 'ADMIN', 'GUDANG', 'KASIR']) assert.match(runtimeSql, new RegExp(`'${actor}'::public\\.user_role`));
  assert.match(runtimeSql, /scope_type', 'FULL'/);
  assert.match(runtimeSql, /scope_type', 'PARTIAL'/);
  assert.match(runtimeSql, /baseline_quantity IS DISTINCT FROM p\.effective_quantity/);
  assert.match(runtimeSql, /baseline_balance_version IS DISTINCT FROM p\.balance_version/);
  assert.match(runtimeSql, /stock_opname_no_active_overlap/);
  assert.match(runtimeSql, /Exact apply retry did not replay/);
  assert.match(runtimeSql, /post-completion reissue did not create a new request identity/);
  assert.match(runtimeSql, /Durable cleanup is[\s\S]*only after the outer ROLLBACK/);
  assert.match(runtimeRunner, /durable-state fingerprint matches/);
  assert.match(migration, /if v_req\.operation_key = 'CREATE_SESSION' then[\s\S]*?insert into public\.stock_opname_sessions[\s\S]*?insert into public\.stock_opname_items[\s\S]*?insert into public\.stock_opname_session_events/);
  assert.doesNotMatch(migration.match(/if v_req\.operation_key = 'CREATE_SESSION' then([\s\S]*?)elsif v_req\.operation_key = 'RECORD_COUNT' then/)?.[1] ?? '', /product_costs|product_inventory\s+set|stock_balance_projection\s+set|stock_movements\s*\(/i);
});
