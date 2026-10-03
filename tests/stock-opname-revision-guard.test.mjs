import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const foundation = readFileSync(new URL('../supabase/migrations/20260929180000_stock_foundation_v1.sql', import.meta.url), 'utf8');
const revision = readFileSync(new URL('../supabase/migrations/20260929200000_stock_opname_revision_guard_v1.sql', import.meta.url), 'utf8');
const progressTests = readFileSync(new URL('./staging/runtime-stock-opname-revision-guard.sql', import.meta.url), 'utf8');
const applyRunner = readFileSync(new URL('./staging/apply-stock-opname-revision-guard.sh', import.meta.url), 'utf8');
const runtimeRunner = readFileSync(new URL('./staging/run-stock-opname-revision-guard-matrix.sh', import.meta.url), 'utf8');
const appFiles = [
  readFileSync(new URL('../src/lib/stock/opname-count-action.ts', import.meta.url), 'utf8'),
  readFileSync(new URL('../src/components/stock/stock-opname-counting.tsx', import.meta.url), 'utf8'),
].join('\n');

function functionBody(source, name) {
  const start = source.indexOf(`create or replace function public.${name}(`);
  assert.notEqual(start, -1, `${name} definition exists`);
  const end = source.indexOf('$$;', start);
  assert.notEqual(end, -1, `${name} body closes`);
  return source.slice(start, end + 3);
}

function through(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  assert.notEqual(start, -1, `missing marker ${startMarker}`);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.notEqual(end, -1, `missing marker ${endMarker}`);
  return source.slice(start, end);
}

test('forward migration keeps public intent/apply RPC signatures and security contract', () => {
  assert.match(revision, /create or replace function public\.issue_stock_operation_intent\(\s*p_operation_key text,\s*p_payload jsonb\s*\)\s*returns uuid\s*language plpgsql\s*security definer\s*set search_path = pg_catalog/i);
  assert.match(revision, /create or replace function public\.apply_stock_operation_intent\(p_request_id uuid\)\s*returns jsonb\s*language plpgsql\s*security definer\s*set search_path = pg_catalog/i);
  for (const fn of ['issue_stock_operation_intent(text,jsonb)', 'apply_stock_operation_intent(uuid)']) {
    assert.match(revision, new RegExp(`alter function public\\.${fn.replace(/[(),]/g, '\\$&')} owner to postgres`, 'i'));
    assert.match(revision, new RegExp(`revoke all on function public\\.${fn.replace(/[(),]/g, '\\$&')} from public, anon, service_role`, 'i'));
    assert.match(revision, new RegExp(`grant execute on function public\\.${fn.replace(/[(),]/g, '\\$&')} to authenticated`, 'i'));
  }
});

test('expected revisions are required, range-checked, and included in canonical identity', () => {
  const issue = functionBody(revision, 'issue_stock_operation_intent');
  const itemOps = issue.slice(issue.indexOf("elsif p_operation_key in ('REBASE_ITEM', 'REVIEW_EXCEPTION')"), issue.indexOf("elsif p_operation_key = 'RECONCILE_MOVEMENT'"));
  assert.match(itemOps, /jsonb_typeof\(p_payload->'expected_revision'\) is distinct from 'number'/);
  assert.match(itemOps, /< 0[\s\S]*> 2147483647[\s\S]*<> trunc\(v_expected_revision_numeric\)/);
  assert.match(itemOps, /'expected_revision', v_expected_revision/);
  assert.match(issue, /v_hash := md5\(v_payload::text\)/);
  assert.match(itemOps, /REVIEW_EXCEPTION'[\s\S]*'reason', v_note/);
  assert.match(itemOps, /'REBASE_ITEM', 'REVIEW_EXCEPTION'[\s\S]*'expected_revision', v_expected_revision/);
});

test('locked revision mismatch terminalizes only the request before projection/item mutation', () => {
  const apply = functionBody(revision, 'apply_stock_operation_intent');
  for (const op of ['REBASE_ITEM', 'REVIEW_EXCEPTION']) {
    const start = apply.indexOf(`elsif v_req.operation_key = '${op}' then`);
    const end = apply.indexOf(op === 'REBASE_ITEM' ? "elsif v_req.operation_key = 'REVIEW_EXCEPTION' then" : "elsif v_req.operation_key = 'SUBMIT_REVIEW' then", start + 1);
    const branch = apply.slice(start, end);
    const lock = branch.indexOf('for update;');
    const mismatch = branch.indexOf("'reason', 'ITEM_REVISION_MISMATCH'");
    const projection = branch.indexOf('from public.stock_balance_projection');
    const mutation = branch.indexOf('update public.stock_opname_items');
    assert.ok(lock >= 0 && mismatch > lock && projection > mismatch && mutation > projection, `${op} lock/check/mutation order`);
    const mismatchBlock = branch.slice(mismatch - 140, projection);
    assert.match(mismatchBlock, /'expectedRevision', v_expected_revision/);
    assert.match(mismatchBlock, /'currentRevision', v_item\.revision_no/);
    assert.match(mismatchBlock, /'refreshRequired', true/);
    assert.doesNotMatch(mismatchBlock, /recountRequired/);
    assert.match(mismatchBlock, /update public\.stock_operation_requests set state = 'STALE'/);
    assert.doesNotMatch(mismatchBlock, /stock_opname_items|stock_opname_count_events/);
  }
  assert.match(apply, /'reason', 'EXPECTED_REVISION_REQUIRED'/);
});

test('all unrelated shared operation branches are mechanically identical to migration 180000', () => {
  const oldIssue = functionBody(foundation, 'issue_stock_operation_intent');
  const newIssue = functionBody(revision, 'issue_stock_operation_intent');
  assert.equal(through(oldIssue, "if p_operation_key = 'CREATE_SESSION' then", "elsif p_operation_key in ('RECORD_COUNT', 'REBASE_ITEM', 'REVIEW_EXCEPTION') then"),
    through(newIssue, "if p_operation_key = 'CREATE_SESSION' then", "elsif p_operation_key in ('RECORD_COUNT', 'REBASE_ITEM', 'REVIEW_EXCEPTION') then"));
  assert.equal(through(oldIssue, "elsif p_operation_key = 'RECONCILE_MOVEMENT' then", "else\n    raise exception using errcode = '22023', message = 'Unsupported stock operation';"),
    through(newIssue, "elsif p_operation_key = 'RECONCILE_MOVEMENT' then", "else\n    raise exception using errcode = '22023', message = 'Unsupported stock operation';"));
  const oldRecordCount = through(oldIssue, "if p_operation_key = 'RECORD_COUNT' then", "elsif p_operation_key = 'REVIEW_EXCEPTION' then");
  const newRecordCount = through(newIssue, "if p_operation_key = 'RECORD_COUNT' then", "elsif p_operation_key in ('REBASE_ITEM', 'REVIEW_EXCEPTION') then");
  assert.equal(oldRecordCount, newRecordCount, 'RECORD_COUNT intent semantics stay unchanged');

  const oldApply = functionBody(foundation, 'apply_stock_operation_intent');
  const newApply = functionBody(revision, 'apply_stock_operation_intent');
  assert.equal(through(oldApply, "if v_req.operation_key = 'CREATE_SESSION' then", "elsif v_req.operation_key = 'RECORD_COUNT' then"),
    through(newApply, "if v_req.operation_key = 'CREATE_SESSION' then", "elsif v_req.operation_key = 'RECORD_COUNT' then"));
  assert.equal(through(oldApply, "elsif v_req.operation_key = 'RECORD_COUNT' then", "elsif v_req.operation_key = 'REBASE_ITEM' then"),
    through(newApply, "elsif v_req.operation_key = 'RECORD_COUNT' then", "elsif v_req.operation_key = 'REBASE_ITEM' then"));
  assert.equal(through(oldApply, "elsif v_req.operation_key = 'SUBMIT_REVIEW' then", "elsif v_req.operation_key = 'RECONCILE_MOVEMENT' then"),
    through(newApply, "elsif v_req.operation_key = 'SUBMIT_REVIEW' then", "elsif v_req.operation_key = 'RECONCILE_MOVEMENT' then"));
  assert.equal(through(oldApply, "elsif v_req.operation_key = 'RECONCILE_MOVEMENT' then", "else\n    raise exception using errcode = '22023', message = 'Unsupported stock operation';"),
    through(newApply, "elsif v_req.operation_key = 'RECONCILE_MOVEMENT' then", "else\n    raise exception using errcode = '22023', message = 'Unsupported stock operation';"));
});

test('progress RPC is one-snapshot invoker read with locked accounting semantics and least privilege', () => {
  assert.match(revision, /create or replace function public\.stock_opname_progress_counts\(p_session_id uuid\)\s*returns jsonb\s*language sql\s*stable\s*security invoker\s*set search_path = pg_catalog/i);
  for (const key of ['total', 'counted', 'exception', 'accounted', 'remaining', 'recount_required']) assert.ok(revision.includes(`'${key}'`));
  assert.match(revision, /physical_quantity is not null and not i\.requires_recount/);
  assert.match(revision, /physical_quantity is null[\s\S]*exception_reason is not null[\s\S]*exception_reviewed_by is not null[\s\S]*exception_reviewed_at is not null[\s\S]*not i\.requires_recount/);
  assert.match(revision, /count\(\*\) filter \(where i\.requires_recount\)/);
  assert.match(revision, /alter function public\.stock_opname_progress_counts\(uuid\) owner to postgres/);
  assert.match(revision, /revoke all on function public\.stock_opname_progress_counts\(uuid\) from public, anon, service_role/);
  assert.match(revision, /grant execute on function public\.stock_opname_progress_counts\(uuid\) to authenticated/);
  assert.doesNotMatch(revision.slice(revision.indexOf('create or replace function public.stock_opname_progress_counts')), /product_costs|hpp|profit|product_inventory/);
});

test('rollback staging artifacts cover roles, revision races, legacy requests, exact progress and cleanup', () => {
  for (const role of ['OWNER', 'ADMIN', 'GUDANG', 'KASIR']) assert.match(progressTests, new RegExp(`v_${role.toLowerCase()} uuid`));
  for (const marker of ['ITEM_REVISION_MISMATCH', 'EXPECTED_REVISION_REQUIRED', 'BASELINE_REFRESHED', 'EXCEPTION_REVIEWED', 'stock_opname_progress_counts', 'ROLLBACK']) assert.ok(progressTests.includes(marker));
  assert.match(progressTests, /legacy pending REBASE_ITEM/i);
  assert.match(progressTests, /legacy pending REVIEW_EXCEPTION/i);
  assert.match(progressTests, /'total'\s*,\s*8[\s\S]*'counted'\s*,\s*2[\s\S]*'exception'\s*,\s*2[\s\S]*'accounted'\s*,\s*4[\s\S]*'remaining'\s*,\s*4[\s\S]*'recount_required'\s*,\s*2/);
  assert.match(progressTests, /KASIR was allowed to issue REBASE_ITEM/);
  assert.match(progressTests, /KASIR was allowed to issue REVIEW_EXCEPTION/);
  assert.match(applyRunner, /guard_local_target/);
  assert.match(applyRunner, /assert_local_staging_marker/);
  assert.match(applyRunner, /20260929190000/);
  assert.match(applyRunner, /20260929200000/);
  assert.match(runtimeRunner, /state_before=.*stock-opname-create-state\.sql/);
  assert.match(runtimeRunner, /state_after=.*stock-opname-create-state\.sql/);
  assert.match(runtimeRunner, /if \[\[ "\$state_after" != "\$state_before" \]\]/);
  assert.doesNotMatch(`${applyRunner}\n${runtimeRunner}`, /supabase\s+(db\s+push|migration\s+repair)|\.env\.local|SUPABASE_SERVICE_ROLE_KEY|giwuzemjmimuvhtvjfhq/i);
  assert.doesNotMatch(appFiles, /\.from\("stock_opname_(sessions|items|count_events)"\)\s*\.(insert|update|upsert|delete)/i);
});
