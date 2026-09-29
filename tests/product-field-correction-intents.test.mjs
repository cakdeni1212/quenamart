import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import {
  canIssueCorrectionIntent,
  parseApplyCorrectionIntentResult,
  parseCorrectionIntentInput,
  parseCorrectionIntentRequestId,
  parseCorrectionIntentSummary,
} from '../src/lib/product-audit/correction-intent-core.ts';

const migration = readFileSync(new URL('../supabase/migrations/20260929170000_product_field_correction_intents_v1.sql', import.meta.url), 'utf8');
const foundation = readFileSync(new URL('../supabase/migrations/20260929130000_field_audit_foundation_v1.sql', import.meta.url), 'utf8');
const actions = readFileSync(new URL('../src/app/actions/product-field-correction-intents.ts', import.meta.url), 'utf8');
const core = readFileSync(new URL('../src/lib/product-audit/correction-intent-core.ts', import.meta.url), 'utf8');

const ids = {
  product: '2fdb6fbb-e383-4bed-9eb7-7a55627eb995',
  source: 'c14f4afa-c114-4d5e-acae-c232a82016d5',
  outlet: '52ea55dd-5608-4066-9e17-91666de1d78d',
  request: 'f52a0ad4-2ae6-4ae7-8ef5-49e5fc7d7c09',
};

function formData({ field = 'barcode', outlet = null, operation = 'ADD_ALIAS', value = '00012345', reason = '  Cek fisik  ' } = {}) {
  const form = new FormData();
  form.set('productId', ids.product);
  form.set('outletId', outlet ?? '');
  form.set('fieldKey', field);
  form.set('sourceImportRowId', ids.source);
  form.set('correctedValue', String(value));
  form.set('reason', reason);
  form.set('barcodeOperation', operation ?? '');
  return form;
}

function functionBody(name) {
  const start = migration.indexOf(`create or replace function public.${name}(`);
  assert.notEqual(start, -1, `${name} is defined`);
  const end = migration.indexOf('$$;', start);
  assert.notEqual(end, -1, `${name} body closes`);
  return migration.slice(start, end + 3);
}

test('role/field matrix allows managers all supported fields and GUDANG only barcode/rack', () => {
  for (const field of ['barcode', 'rack_label', 'hpp', 'selling_price']) {
    assert.equal(canIssueCorrectionIntent('OWNER', field), true);
    assert.equal(canIssueCorrectionIntent('ADMIN', field), true);
  }
  assert.equal(canIssueCorrectionIntent('GUDANG', 'barcode'), true);
  assert.equal(canIssueCorrectionIntent('GUDANG', 'rack_label'), true);
  assert.equal(canIssueCorrectionIntent('GUDANG', 'hpp'), false);
  assert.equal(canIssueCorrectionIntent('GUDANG', 'selling_price'), false);
  for (const field of ['barcode', 'rack_label', 'hpp', 'selling_price']) {
    assert.equal(canIssueCorrectionIntent('KASIR', field), false);
  }
});

test('stock and minimum stock are rejected by application parsing and SQL field allowlist', () => {
  assert.equal(parseCorrectionIntentInput(formData({ field: 'quantity', outlet: ids.outlet, operation: null, value: '2' })), null);
  assert.equal(parseCorrectionIntentInput(formData({ field: 'minimum_quantity', outlet: ids.outlet, operation: null, value: '2' })), null);
  assert.match(functionBody('issue_product_field_correction_intent'), /p_field_key not in \('barcode','rack_label','hpp','selling_price'\)/);
  assert.match(functionBody('apply_product_field_correction_payload'), /p_field_key not in \('barcode','rack_label','hpp','selling_price'\)/);
});

test('barcode aliases and replacements have distinct canonical operation payloads and NULL outlet', () => {
  const alias = parseCorrectionIntentInput(formData({ operation: 'ADD_ALIAS', value: ' 0000123 ' }));
  const replacement = parseCorrectionIntentInput(formData({ operation: 'REPLACE_SOURCE', value: '0000123' }));
  assert.equal(alias.outletId, null);
  assert.equal(alias.correctedValue, ' 0000123 ');
  assert.equal(alias.reason, 'Cek fisik');
  assert.equal(alias.barcodeOperation, 'ADD_ALIAS');
  assert.equal(replacement.barcodeOperation, 'REPLACE_SOURCE');
  assert.notEqual(alias.barcodeOperation, replacement.barcodeOperation);
  const body = functionBody('issue_product_field_correction_intent');
  assert.match(body, /'outlet_id',case when p_field_key='barcode' then null else p_outlet_id end/);
  assert.match(body, /'operation_type',normalized_operation/);
  assert.match(body, /if normalized_operation is null or normalized_operation not in \('ADD_ALIAS','REPLACE_SOURCE'\)/);
});

test('numeric values and reasons are canonicalized compatibly with the correction RPC', () => {
  const hpp = parseCorrectionIntentInput(formData({ field: 'hpp', outlet: ids.outlet, operation: null, value: '010000.50', reason: '  Cost verified  ' }));
  const price = parseCorrectionIntentInput(formData({ field: 'selling_price', outlet: ids.outlet, operation: null, value: '10000.50', reason: 'price check' }));
  assert.equal(hpp.correctedValue, 10000.5);
  assert.equal(hpp.reason, 'Cost verified');
  assert.equal(price.correctedValue, 10000.5);
  assert.match(functionBody('issue_product_field_correction_intent'), /value_num<>trunc\(value_num,2\)/);
  assert.match(functionBody('issue_product_field_correction_intent'), /normalized_value := to_jsonb\(value_num\)/);
  assert.match(functionBody('apply_product_field_correction_payload'), /normalized_value := to_jsonb\(value_num\)/);
  assert.match(functionBody('issue_product_field_correction_intent'), /regexp_replace\(coalesce\(p_reason,''\), '\^\[\[:space:\]\]\+\|\[\[:space:\]\]\+\$', '', 'g'\)/);
});

test('intent table is private and enforces one pending actor/payload tuple', () => {
  assert.match(migration, /create table public\.product_field_correction_intents/i);
  assert.match(migration, /request_id uuid primary key default gen_random_uuid\(\)/i);
  assert.match(migration, /enable row level security/i);
  assert.match(migration, /revoke all on public\.product_field_correction_intents from public, anon, authenticated, service_role/i);
  assert.match(migration, /on public\.product_field_correction_intents\(actor_id, request_payload\)\s+where completed_at is null/i);
  assert.match(migration, /pg_advisory_xact_lock\(734921,2\)/);
  assert.match(migration, /where completed_at is null/i, 'completed intents are excluded from reuse uniqueness');
});

test('issuer requires the exact in-progress review and trusted current source before creating/reusing an intent', () => {
  const body = functionBody('issue_product_field_correction_intent');
  assert.match(body, /auth\.uid\(\)/);
  assert.match(body, /current_active_user_role\(\)/);
  assert.match(body, /latest_review\.status<>'SEDANG_DICEK'/);
  assert.match(body, /latest_review\.source_import_row_id is distinct from p_source_import_row_id/);
  assert.match(body, /current_source is distinct from p_source_import_row_id/);
  assert.match(body, /on conflict \(actor_id,request_payload\) where completed_at is null do nothing/i);
  assert.match(body, /select i\.request_id into request_value[\s\S]*i\.actor_id=issue_correction_intent_block\.actor_id/);
  for (const key of ['actor_id', 'product_id', 'outlet_id', 'field_key', 'source_import_row_id', 'operation_type', 'corrected_value', 'reason']) {
    assert.match(body, new RegExp(`'${key}'`));
  }
});

test('recovery is actor-bound and returns only safe metadata, never value, reason, or payload', () => {
  const body = functionBody('read_product_field_correction_intent');
  assert.match(body, /auth\.uid\(\)/);
  assert.match(body, /i\.request_id=p_request_id and i\.actor_id=read_correction_intent_block\.actor_id/);
  assert.match(body, /role_value='GUDANG'[\s\S]*request_payload ->> 'field_key' not in \('barcode','rack_label'\)/);
  assert.match(body, /'completed',intent_row\.completed_at is not null/);
  assert.doesNotMatch(body, /'corrected_value'|'reason'|'request_payload'/);
  const summary = parseCorrectionIntentSummary(ids.request, {
    request_id: ids.request, product_id: ids.product, outlet_id: null, field_key: 'barcode',
    source_import_row_id: ids.source, barcode_operation: 'ADD_ALIAS', completed: false,
  });
  assert.deepEqual(summary, {
    requestId: ids.request, productId: ids.product, outletId: null, fieldKey: 'barcode',
    sourceImportRowId: ids.source, barcodeOperation: 'ADD_ALIAS', completed: false,
  });
  assert.equal(parseCorrectionIntentSummary(ids.request, {
    request_id: ids.request, product_id: ids.product, outlet_id: ids.outlet, field_key: 'hpp',
    source_import_row_id: ids.source, barcode_operation: null, completed: false, corrected_value: 9,
  }).fieldKey, 'hpp');
});

test('UUID-only apply consumes the actor-owned stored payload through the shared correction core', () => {
  const body = functionBody('apply_product_field_correction_intent');
  assert.match(body, /\(p_request_id uuid\)/);
  assert.match(body, /auth\.uid\(\)/);
  assert.match(body, /current_active_user_role\(\)/);
  assert.match(body, /i\.request_id=p_request_id\s+and i\.actor_id=apply_correction_intent_block\.actor_id/);
  assert.match(body, /intent_payload ->> 'product_id'/);
  assert.match(body, /intent_payload -> 'corrected_value'/);
  assert.match(body, /intent_payload ->> 'reason'/);
  assert.match(body, /apply_product_field_correction_payload\(/);
  assert.doesNotMatch(body, /p_corrected_value|p_reason|p_product_id|p_field_key|p_actor_id/);
  assert.match(body, /return public\.apply_product_field_correction_payload\(/);
  assert.doesNotMatch(body, /jsonb_build_object\([^;]*(corrected_value|reason|request_payload)/i);
  assert.doesNotMatch(body, /completed_at is null/, 'completed intents must reach the ledger replay path');
});

test('UUID-only apply replays completed results before source freshness and keeps stale pending intents incomplete', () => {
  const wrapper = functionBody('apply_product_field_correction_intent');
  const coreBody = functionBody('apply_product_field_correction_payload');
  assert.ok(wrapper.indexOf('apply_product_field_correction_payload(') > wrapper.indexOf('select i.request_payload'));
  assert.ok(coreBody.indexOf('return prior_correction_request.result') < coreBody.indexOf('Barcode source changed; reload before correcting'));
  assert.ok(coreBody.indexOf('return prior_correction_request.result') < coreBody.indexOf('Begin review for the current source row before saving a correction'));
  const lastCompletion = coreBody.lastIndexOf('set completed_at=pg_catalog.now(), correction_request_id=p_request_id');
  assert.ok(coreBody.indexOf('latest_review.status') < lastCompletion);
  assert.ok(coreBody.indexOf('Barcode source changed; reload before correcting') < lastCompletion);
});

test('foreign UUID and GUDANG financial probing return indistinguishable unavailable metadata', () => {
  const recovery = functionBody('read_product_field_correction_intent');
  const apply = functionBody('apply_product_field_correction_intent');
  assert.match(recovery, /where i\.request_id=p_request_id and i\.actor_id=read_correction_intent_block\.actor_id/);
  assert.match(recovery, /role_value='GUDANG'[\s\S]*request_payload ->> 'field_key' not in \('barcode','rack_label'\) then\s+return null/);
  assert.match(apply, /if not found then\s+raise exception using errcode='22023', message='Correction intent is unavailable'/);
  assert.match(apply, /role_value='GUDANG'[\s\S]*intent_payload ->> 'field_key' not in \('barcode','rack_label'\) then\s+raise exception using errcode='22023', message='Correction intent is unavailable'/);
  assert.equal(parseCorrectionIntentSummary(ids.request, null), null);
});

test('apply server action accepts and sends only an opaque UUID and never exposes payload data', () => {
  assert.equal(parseCorrectionIntentRequestId(ids.request), ids.request);
  assert.equal(parseCorrectionIntentRequestId('not-a-uuid'), null);
  const action = actions.slice(actions.indexOf('export async function applyProductFieldCorrectionIntentAction'));
  assert.match(action, /applyProductFieldCorrectionIntentAction\(\s*requestIdValue: string/);
  assert.match(action, /rpc\("apply_product_field_correction_intent",\s*\{\s*p_request_id: requestId,\s*\}\)/);
  assert.doesNotMatch(action, /correctedValue|corrected_value|reason|outletId|sourceImportRowId/);
  assert.doesNotMatch(action, /rpc\(["']apply_product_field_correction["']/);
  assert.doesNotMatch(action, /supabase\/admin|service_role|localStorage|sessionStorage|cookies\(/i);
});

test('apply result DTO strips unexpected private fields and preserves barcode conflict replay result', () => {
  assert.deepEqual(parseApplyCorrectionIntentResult({
    ok: true, sourceSynchronized: true, corrected_value: 'private', reason: 'private',
  }), { ok: true, outcome: 'APPLIED', sourceSynchronized: true });
  assert.deepEqual(parseApplyCorrectionIntentResult({
    ok: false, code: 'BARCODE_CONFLICT', corrected_value: 'private', reason: 'private',
  }), { ok: true, outcome: 'BARCODE_CONFLICT', sourceSynchronized: null });
  assert.equal(parseApplyCorrectionIntentResult({ ok: false, code: 'OTHER' }), null);
});

test('correction RPC preserves completed replay before intent/source checks and rejects changed payload', () => {
  const body = functionBody('apply_product_field_correction_payload');
  assert.ok(body.indexOf('if found then\n    if prior_correction_request.actor_id') < body.indexOf('select * into intent_row'));
  assert.ok(body.indexOf('return prior_correction_request.result') < body.indexOf('perform 1 from public.products'));
  assert.match(body, /prior_correction_request\.request_payload is distinct from request_payload/);
  assert.match(body, /intent_row\.request_payload is distinct from request_payload/);
  assert.match(body, /IDEMPOTENCY_KEY_REUSED/);
  assert.match(body, /latest_review\.status<>'SEDANG_DICEK'/);
  assert.match(body, /prior_correction_request\.actor_id <> actor_id/);
  assert.match(body, /'operation_type', p_barcode_operation/);
  assert.match(body, /'corrected_value', normalized_value/);
  assert.match(body, /'reason', value_reason/);
});

test('completed intents are not reused and foreign actor UUIDs cannot recover metadata', () => {
  const issue = functionBody('issue_product_field_correction_intent');
  const recovery = functionBody('read_product_field_correction_intent');
  assert.match(migration, /where completed_at is null/i);
  assert.match(issue, /i\.completed_at is null/);
  assert.match(recovery, /i\.request_id=p_request_id and i\.actor_id=read_correction_intent_block\.actor_id/);
  assert.match(functionBody('apply_product_field_correction_payload'), /prior_correction_request\.actor_id <> actor_id/);
});

test('exact completed correction replay precedes current source and review freshness validation', () => {
  const body = functionBody('apply_product_field_correction_payload');
  const replay = body.indexOf('return prior_correction_request.result');
  const source = body.indexOf('Barcode source changed; reload before correcting');
  const review = body.indexOf('Begin review for the current source row before saving a correction');
  assert.ok(replay > -1 && replay < source && replay < review);
});

test('concurrent issue and correction submissions serialize on the shared transaction lock', () => {
  const issue = functionBody('issue_product_field_correction_intent');
  const apply = functionBody('apply_product_field_correction_payload');
  assert.match(issue, /pg_advisory_xact_lock\(734921,2\)/);
  assert.match(apply, /pg_advisory_xact_lock\(734921, 2\)/);
  assert.match(apply, /from public\.product_field_correction_requests r where r\.request_id=p_request_id for update/);
  assert.match(apply, /from public\.product_field_correction_intents i[\s\S]*for update/);
});

test('pending source-stale intent remains incomplete because freshness failure precedes completion', () => {
  const body = functionBody('apply_product_field_correction_payload');
  const freshness = body.indexOf("Barcode source changed; reload before correcting");
  const completion = body.lastIndexOf('set completed_at=pg_catalog.now(), correction_request_id=p_request_id');
  assert.ok(freshness > -1 && freshness < completion);
  assert.ok(body.indexOf('latest_review.status') < completion);
  assert.match(body, /if current_source is distinct from p_source_import_row_id|source changed/i);
});

test('BARCODE_CONFLICT is persisted and completes the same intent atomically', () => {
  const body = functionBody('apply_product_field_correction_payload');
  const conflict = body.indexOf("'code','BARCODE_CONFLICT'");
  const saveResult = body.indexOf('insert into public.product_field_correction_requests(request_id,actor_id,request_payload,result)', conflict);
  const complete = body.indexOf('set completed_at=pg_catalog.now(), correction_request_id=p_request_id', saveResult);
  const returned = body.indexOf('return result_value', complete);
  assert.ok(conflict > -1 && saveResult > conflict && complete > saveResult && returned > complete);
  assert.match(body, /if not found then raise exception 'Correction intent completion failed'/);
});

test('successful correction request and intent completion share the transaction', () => {
  const body = functionBody('apply_product_field_correction_payload');
  assert.match(migration, /^begin;/);
  assert.match(migration, /commit;\s*$/);
  assert.ok(body.indexOf('insert into public.product_field_correction_requests(\n    request_id,actor_id,request_payload,result,review_id')
    < body.lastIndexOf('set completed_at=pg_catalog.now(), correction_request_id=p_request_id'));
  assert.match(body, /if not found then raise exception 'Correction intent completion failed'/);
  assert.match(body, /product_field_audit_reviews\(product_id,outlet_id,field_key,status/);
});

test('migration keeps the deployed correction operation body and adds only intent enforcement/completion hooks', () => {
  const originalStart = foundation.indexOf('create or replace function public.apply_product_field_correction(');
  const originalEnd = foundation.indexOf('alter function public.apply_product_field_correction(', originalStart);
  const original = foundation.slice(originalStart, originalEnd).trim();
  const revised = functionBody('apply_product_field_correction_payload');
  for (const invariant of [
    "Barcode operation must be ADD_ALIAS or REPLACE_SOURCE",
    "Barcode correction is not outlet-scoped",
    "Begin review for the current source row before saving a correction",
    "BARCODE_CONFLICT",
    "Retire active imported/source associations, not manual aliases",
    "HUMAN_ACCEPTED_SOURCE",
    "SOURCE_CONFLICT",
    "SUDAH_DIVERIFIKASI",
    "sourceSynchronized",
    "alreadyPresent",
  ]) {
    assert.ok(original.includes(invariant), `deployed RPC includes ${invariant}`);
    assert.ok(revised.includes(invariant), `effective RPC preserves ${invariant}`);
  }
  assert.match(actions, /from "@\/lib\/supabase\/server"/);
  assert.match(actions, /issue_product_field_correction_intent/);
  assert.match(actions, /read_product_field_correction_intent/);
  assert.doesNotMatch(actions, /rpc\([\"']apply_product_field_correction[\"']/i);
  assert.match(actions, /rpc\([\"']apply_product_field_correction_intent[\"']/i);
  assert.doesNotMatch(actions, /supabase\/admin|service_role/i);
  assert.doesNotMatch(actions + core, /localStorage|sessionStorage|cookies\(/);
});

test('effective correction function differs from deployed body only at intent enforcement/completion points', () => {
  const oldStart = foundation.indexOf('create or replace function public.apply_product_field_correction(');
  const oldEnd = foundation.indexOf('alter function public.apply_product_field_correction(', oldStart);
  const oldBody = foundation.slice(oldStart, oldEnd).trim();
  let newBody = functionBody('apply_product_field_correction_payload').trim();
  newBody = newBody
    .replace('public.apply_product_field_correction_payload(', 'public.apply_product_field_correction(')
    .replace('<<apply_correction_payload_block>>\n', '')
    .replace('  intent_row public.product_field_correction_intents%rowtype;\n', '')
    .replace(/\n  select \* into intent_row\n  from public\.product_field_correction_intents i\n  where i\.request_id=p_request_id and i\.actor_id=apply_correction_payload_block\.actor_id\n  for update;\n  if not found or intent_row\.request_payload is distinct from request_payload then\n    raise exception using errcode='22023', message='IDEMPOTENCY_KEY_REUSED';\n  end if;\n  if intent_row\.completed_at is not null then\n    raise exception using errcode='22023', message='Correction intent is already completed without a matching correction request';\n  end if;/, '')
    .replace(/\n      update public\.product_field_correction_intents\n      set completed_at=pg_catalog\.now\(\), correction_request_id=p_request_id\n      where request_id=p_request_id and actor_id=apply_correction_payload_block\.actor_id and completed_at is null;\n      if not found then raise exception 'Correction intent completion failed'; end if;/, '')
    .replace(/\n  update public\.product_field_correction_intents\n  set completed_at=pg_catalog\.now\(\), correction_request_id=p_request_id\n  where request_id=p_request_id and actor_id=apply_correction_payload_block\.actor_id and completed_at is null;\n  if not found then raise exception 'Correction intent completion failed'; end if;/, '')
    .replace('apply_correction_payload_block.actor_id', 'apply_correction_block.actor_id');
  assert.equal(newBody.replace(/\s+/g, ' ').trim(), oldBody.replace(/\s+/g, ' ').trim());
});

test('all new definer functions preserve least-privilege ownership/search path/grants', () => {
  for (const name of ['issue_product_field_correction_intent', 'read_product_field_correction_intent', 'apply_product_field_correction_payload', 'apply_product_field_correction', 'apply_product_field_correction_intent']) {
    const body = functionBody(name);
    assert.match(body, /security definer[\s\S]*set search_path = pg_catalog/i);
    assert.match(migration, new RegExp(`alter function public\\.${name}\\([^;]+\\) owner to postgres`, 'i'));
    assert.match(migration, new RegExp(`revoke all on function public\\.${name}\\([^;]+\\)\\s+from public,\\s*anon,\\s*authenticated,\\s*service_role`, 'i'));
    if (name !== 'apply_product_field_correction_payload') {
      assert.match(migration, new RegExp(`grant execute on function public\\.${name}\\([^;]+\\)\\s+to authenticated`, 'i'));
    } else {
      assert.doesNotMatch(migration, /grant execute on function public\\.apply_product_field_correction_payload[^;]*to authenticated/i);
    }
  }
});
