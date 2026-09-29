import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import {
  executeProductFieldReview,
  issueProductFieldReviewIntent,
  normalizeEvidenceNotes,
} from '../src/lib/product-audit/review-action-core.ts';
import {
  forgetReviewIntentId,
  listStoredReviewIntentIds,
  restoreStoredReviewIntent,
  storeReviewIntentId,
} from '../src/lib/product-audit/review-intent-storage.ts';

const action = readFileSync(new URL('../src/app/actions/product-field-audit.ts', import.meta.url), 'utf8');
const controls = readFileSync(new URL('../src/components/product-audit/field-review-controls.tsx', import.meta.url), 'utf8');
const page = readFileSync(new URL('../app/(workspace)/audit-produk/[productId]/page.tsx', import.meta.url), 'utf8');
const readModel = readFileSync(new URL('../src/lib/product-audit/read.ts', import.meta.url), 'utf8');
const core = readFileSync(new URL('../src/lib/product-audit/review-action-core.ts', import.meta.url), 'utf8');
const foundation = readFileSync(new URL('../supabase/migrations/20260929130000_field_audit_foundation_v1.sql', import.meta.url), 'utf8');
const intentMigration = readFileSync(new URL('../supabase/migrations/20260929160000_product_field_review_intents_v1.sql', import.meta.url), 'utf8');
const notesMigration = readFileSync(new URL('../supabase/migrations/20260929150000_product_field_review_notes_idempotency_v1.sql', import.meta.url), 'utf8');

const ids = {
  request: '5a1dc335-6b8e-44db-9ea0-a8e7bff12018',
  request2: 'f52a0ad4-2ae6-4ae7-8ef5-49e5fc7d7c09',
  product: '6c3627e0-a899-4299-98c5-0ba5c7e034e7',
  source: 'ba1543ea-e7c0-4815-8f05-73ead929e6c0',
  source2: '165d1b33-f57e-4854-971e-26da8e3b5a91',
  outlet: 'f98d8dd3-2fa6-4417-9bf6-84bd1f10f50f',
};

function formData({ product = ids.product, field = 'rack_label', status = 'SEDANG_DICEK', notes = ' Rak A ', outlet = ids.outlet, source = ids.source } = {}) {
  const form = new FormData();
  form.set('productId', product);
  form.set('fieldKey', field);
  form.set('status', status);
  form.set('evidenceNotes', notes);
  form.set('outletId', outlet ?? '');
  form.set('sourceRowId', source);
  return form;
}

function canonical({ product = ids.product, field = 'rack_label', status = 'SEDANG_DICEK', notes = 'Rak A', outlet = ids.outlet, source = ids.source } = {}) {
  return {
    p_product_id: product,
    p_outlet_id: field === 'barcode' ? null : outlet,
    p_field_key: field,
    p_status: status,
    p_source_import_row_id: source,
    p_evidence_notes: normalizeEvidenceNotes(notes),
  };
}

function mockStorage() {
  const entries = new Map();
  return {
    get length() { return entries.size; },
    key(index) { return [...entries.keys()][index] ?? null; },
    setItem(key, value) { entries.set(key, value); },
    removeItem(key) { entries.delete(key); },
    entries,
  };
}

function dependencies(overrides = {}) {
  return {
    getProfile: async () => ({ role: 'OWNER' }),
    readIntent: async (requestId) => ({ requestId, payload: canonical(), completed: false }),
    callRpc: async () => ({ error: null }),
    revalidate: () => {},
    logFailure: () => {},
    ...overrides,
  };
}

function issueDependencies(overrides = {}) {
  return {
    getProfile: async () => ({ role: 'OWNER' }),
    readCurrent: async () => ({ kind: 'ok', outletId: ids.outlet, fields: {
      rack_label: { outletId: ids.outlet, sourceRowId: ids.source },
      barcode: { outletId: null, sourceRowId: ids.source },
      hpp: { outletId: ids.outlet, sourceRowId: ids.source },
      selling_price: { outletId: ids.outlet, sourceRowId: ids.source },
      quantity: { outletId: ids.outlet, sourceRowId: ids.source },
      minimum_quantity: { outletId: ids.outlet, sourceRowId: ids.source },
    } }),
    issueIntent: async () => ({ requestId: ids.request, error: null }),
    logFailure: () => {},
    ...overrides,
  };
}

function fn(sql, name) {
  const marker = `create or replace function public.${name}(`;
  const start = sql.indexOf(marker);
  assert.notEqual(start, -1, `${name} exists`);
  const end = sql.indexOf('$$;', start);
  assert.notEqual(end, -1, `${name} body terminates`);
  return sql.slice(start, end + 3);
}

test('Server Actions use the cookie-session client, no admin client, and only review RPCs', () => {
  assert.match(action, /from "@\/lib\/supabase\/server"/);
  assert.match(action, /createClient\(\)/);
  assert.doesNotMatch(action, /supabase\/admin|service_role|SERVICE_ROLE/i);
  assert.match(action, /issue_product_field_review_intent/);
  assert.match(action, /read_product_field_review_intent/);
  assert.match(action, /record_product_field_review/);
  assert.doesNotMatch(action, /apply_product_field_correction/);
});

test('active profile and database-derived role are checked before replay', async () => {
  const order = [];
  const result = await executeProductFieldReview(ids.request, formData(), dependencies({
    getProfile: async () => { order.push('profile'); return { role: 'KASIR' }; },
    readIntent: async () => { order.push('intent'); return { requestId: ids.request, payload: canonical(), completed: true }; },
    callRpc: async () => { order.push('rpc'); return { error: null }; },
  }));
  assert.equal(result.code, 'DENIED');
  assert.deepEqual(order, ['profile']);
  assert.match(core, /roleCanReview\(profile\?\.role, canonical\.p_field_key\)/);
  assert.match(action, /getProfile/);
  assert.doesNotMatch(controls, /name="(?:actor|role|reviewerId|userId)"/);
});

test('durable intent IDs survive a simulated remount and are server-verifiable', async () => {
  const storage = mockStorage();
  const ledger = new Map();
  let issueCount = 0;
  const deps = issueDependencies({
    async issueIntent(payload) {
      const key = JSON.stringify(payload);
      if (!ledger.has(key)) ledger.set(key, ++issueCount === 1 ? ids.request : ids.request2);
      return { requestId: ledger.get(key), error: null };
    },
  });
  const first = await issueProductFieldReviewIntent(formData(), deps);
  assert.equal(first.requestId, ids.request);
  storeReviewIntentId(storage, ids.product, 'rack_label', first.requestId);

  // A new storage consumer simulates a browser reload/remounted component.
  const restored = await restoreStoredReviewIntent(storage, ids.product, 'rack_label', async (requestId) => ({
    requestId,
    payload: canonical(),
    completed: false,
  }));
  assert.equal(restored.requestId, ids.request);
  const reissued = await issueProductFieldReviewIntent(formData(), deps);
  assert.equal(reissued.requestId, restored.requestId);
  assert.equal(issueCount, 1);
  assert.match(intentMigration, /request_id uuid primary key default gen_random_uuid\(\)/i);
  assert.match(intentMigration, /canonical_payload jsonb not null/i);
  assert.match(intentMigration, /actor_id uuid not null/i);
  assert.match(controls, /localStorage/);
});

test('separate product/field tabs keep distinct opaque IDs without storing source or financial values', () => {
  const storage = mockStorage();
  storeReviewIntentId(storage, ids.product, 'rack_label', ids.request);
  storeReviewIntentId(storage, ids.product, 'barcode', ids.request2);
  storeReviewIntentId(storage, ids.request2, 'rack_label', ids.source2);
  assert.deepEqual(listStoredReviewIntentIds(storage, ids.product, 'rack_label'), [ids.request]);
  assert.deepEqual(listStoredReviewIntentIds(storage, ids.product, 'barcode'), [ids.request2]);
  assert.deepEqual(listStoredReviewIntentIds(storage, ids.request2, 'rack_label'), [ids.source2]);
  assert.doesNotMatch([...storage.entries.keys(), ...storage.entries.values()].join(' '), /HPP|sourceValue|evidenceNotes|BARCODE_VALUE/i);
});

test('a confirmed request already reflected by the current review state is retired after an RSC refresh', async () => {
  const storage = mockStorage();
  storeReviewIntentId(storage, ids.product, 'rack_label', ids.request);
  const recovered = await restoreStoredReviewIntent(storage, ids.product, 'rack_label', async (requestId) => ({
    requestId,
    completed: true,
    payload: canonical({ status: 'SEDANG_DICEK' }),
  }), (intent) => intent.completed
    && intent.payload.p_source_import_row_id === ids.source
    && intent.payload.p_status !== 'SUDAH_DIVERIFIKASI');
  assert.equal(recovered, null);
  assert.deepEqual(listStoredReviewIntentIds(storage, ids.product, 'rack_label'), []);
});

test('unknown result retains opaque ID; confirmed success consumes it and later intent gets a new ID', async () => {
  const storage = mockStorage();
  storeReviewIntentId(storage, ids.product, 'rack_label', ids.request);
  let nextId = ids.request2;
  const result = await executeProductFieldReview(ids.request, formData(), dependencies({
    callRpc: async () => { throw new Error('response lost'); },
  }));
  assert.equal(result.code, 'UNAVAILABLE');
  assert.deepEqual(listStoredReviewIntentIds(storage, ids.product, 'rack_label'), [ids.request]);

  const confirmed = await executeProductFieldReview(ids.request, formData(), dependencies());
  assert.equal(confirmed.code, 'OK');
  forgetReviewIntentId(storage, ids.product, 'rack_label', ids.request);
  assert.deepEqual(listStoredReviewIntentIds(storage, ids.product, 'rack_label'), []);

  const next = await issueProductFieldReviewIntent(formData({ status: 'SUDAH_DIVERIFIKASI' }), issueDependencies({
    issueIntent: async () => ({ requestId: nextId, error: null }),
  }));
  assert.equal(next.requestId, ids.request2);
  assert.notEqual(next.requestId, ids.request);
});

test('distinct product, field, source, status, and normalized note intents do not share semantic payloads', async () => {
  const payloads = [
    canonical(), canonical({ product: ids.request2 }), canonical({ field: 'barcode', outlet: null }),
    canonical({ source: ids.source2 }), canonical({ status: 'SUDAH_DIVERIFIKASI' }), canonical({ notes: 'catatan lain' }),
  ];
  assert.equal(new Set(payloads.map((item) => JSON.stringify(item))).size, payloads.length);
  assert.equal(normalizeEvidenceNotes('  Catatan  '), 'Catatan');
  assert.equal(normalizeEvidenceNotes('   '), null);
  assert.match(intentMigration, /on public\.product_field_review_intents\(actor_id, canonical_payload\)/);
  let serial = 0;
  const issued = new Set();
  const resultIds = [];
  for (const payload of payloads) {
    const form = formData({ product: payload.p_product_id, field: payload.p_field_key, status: payload.p_status,
      notes: payload.p_evidence_notes, outlet: payload.p_outlet_id, source: payload.p_source_import_row_id });
    const result = await issueProductFieldReviewIntent(form, issueDependencies({
      issueIntent: async (input) => {
        const key = JSON.stringify(input);
        if (!issued.has(key)) issued.add(key);
        return { requestId: `00000000-0000-4000-8000-${String(++serial).padStart(12, '0')}`, error: null };
      },
    }));
    resultIds.push(result.requestId);
  }
  assert.equal(new Set(resultIds).size, payloads.length);
});

test('different notes with a reused issued ID are sent to the RPC and receive request-reuse conflict', async () => {
  let sent;
  const result = await executeProductFieldReview(ids.request, formData({ notes: 'catatan berubah' }), dependencies({
    readIntent: async (requestId) => ({ requestId, payload: canonical({ notes: 'catatan asli' }), completed: false }),
    async callRpc(payload) { sent = payload; return { error: { code: '22023', message: 'Request ID was already used for another review' } }; },
  }));
  assert.equal(sent.p_evidence_notes, 'catatan berubah');
  assert.equal(result.code, 'CONFLICT');
});

test('exact retry after source advancement reaches RPC replay without an application stale precheck', async () => {
  let calls = 0;
  const result = await executeProductFieldReview(ids.request, formData(), dependencies({
    readIntent: async (requestId) => ({ requestId, payload: canonical(), completed: true }),
    async callRpc(payload) { calls += 1; assert.equal(payload.p_source_import_row_id, ids.source); return { error: null }; },
  }));
  assert.equal(result.code, 'OK');
  assert.equal(calls, 1);
  assert.doesNotMatch(core, /readCurrent\(productId\)/);
  assert.match(intentMigration, /if found then[\s\S]*return prior_request\.id/);
});

test('new intents still require trusted fresh source context before ID issuance', async () => {
  let calls = 0;
  const result = await issueProductFieldReviewIntent(formData(), issueDependencies({
    readCurrent: async () => ({ kind: 'ok', outletId: ids.outlet, fields: { rack_label: { outletId: ids.outlet, sourceRowId: ids.source2 } } }),
    async issueIntent() { calls += 1; return { requestId: ids.request, error: null }; },
  }));
  assert.equal(result.code, 'STALE');
  assert.equal(calls, 0);
  assert.match(intentMigration, /if current_source is distinct from p_source_import_row_id[\s\S]*Source changed/);
});

test('issued intent payload is checked by RPC before new-request freshness and after exact replay branch', () => {
  const body = fn(intentMigration, 'record_product_field_review');
  assert.ok(body.indexOf('select * into prior_request') < body.indexOf('select * into intent_row'));
  assert.ok(body.indexOf('select * into intent_row') < body.indexOf('select p.last_import_row_id'));
  assert.match(body, /canonical_payload is distinct from canonical/);
  assert.match(body, /prior_request\.evidence_notes is distinct from normalized_notes/);
});

test('GUDANG HPP isolation and KASIR denial remain in loader, intent RPCs, and action core', () => {
  assert.match(readModel, /manager\s*\?\s*supabase\.rpc\("read_product_financial_field_source"/);
  assert.match(readModel, /\.\.\.\(manager \? \{ financial:/);
  assert.match(core, /role !== "KASIR"/);
  assert.match(core, /\["barcode", "rack_label", "quantity", "minimum_quantity"\]/);
  const issue = fn(intentMigration, 'issue_product_field_review_intent');
  const read = fn(intentMigration, 'read_product_field_review_intent');
  assert.match(issue, /role_value = 'GUDANG'[\s\S]*p_field_key not in \('barcode','rack_label','quantity','minimum_quantity'\)/);
  assert.match(read, /role_value = 'GUDANG'[\s\S]*canonical_payload ->> 'field_key' not in \('barcode','rack_label','quantity','minimum_quantity'\)/);
});

test('database intent ledger is private and security-definer functions have fixed search path and narrow grants', () => {
  assert.match(intentMigration, /enable row level security/);
  assert.match(intentMigration, /revoke all on public\.product_field_review_intents from public, anon, authenticated, service_role/i);
  for (const name of ['issue_product_field_review_intent', 'read_product_field_review_intent', 'record_product_field_review']) {
    const body = fn(intentMigration, name);
    assert.match(body, /security definer[\s\S]*set search_path = pg_catalog/i);
    assert.match(intentMigration, new RegExp(`alter function public\\.${name}\\([^;]+\\) owner to postgres`, 'i'));
    assert.match(intentMigration, new RegExp(`grant execute on function public\\.${name}\\([^;]+\\) to authenticated`, 'i'));
  }
  assert.match(intentMigration, /from public, anon, authenticated, service_role/i);
});

test('role checks still run before completed-request replay and no correction RPC is invoked', () => {
  const body = fn(intentMigration, 'record_product_field_review');
  assert.ok(body.indexOf('current_active_user_role') < body.indexOf('select * into prior_request'));
  assert.match(body, /prior_request\.reviewer_id <> v_actor_id/);
  assert.doesNotMatch(action + core, /apply_product_field_correction/);
  assert.doesNotMatch(action, /supabase\/admin|service_role/i);
});

test('stock and minimum stock remain review-only', () => {
  assert.match(page, /Perubahan stok belum tersedia/);
  assert.doesNotMatch(action + core, /apply_product_field_correction/);
});

test('notes idempotency remains canonical in the local notes migration', () => {
  const body = fn(notesMigration, 'record_product_field_review');
  assert.match(body, /prior_request\.evidence_notes is distinct from nullif\(btrim\(p_evidence_notes\), ''\)/);
  assert.match(body, /nullif\(btrim\(p_evidence_notes\), ''\), p_request_id/);
  assert.match(foundation, /prior_request\.status is distinct from p_status/);
});

test('trusted action maps stale/conflict errors safely and catches thrown profile/intent/RPC failures', async () => {
  const phases = [];
  const base = dependencies({ logFailure: (phase) => phases.push(phase) });
  const profile = await executeProductFieldReview(ids.request, formData(), { ...base, getProfile: async () => { throw new Error('private profile'); } });
  const intent = await executeProductFieldReview(ids.request, formData(), { ...base, readIntent: async () => { throw new Error('private intent'); } });
  const rpc = await executeProductFieldReview(ids.request, formData(), { ...base, callRpc: async () => { throw new Error('private database'); } });
  for (const result of [profile, intent, rpc]) {
    assert.equal(result.code, 'UNAVAILABLE');
    assert.doesNotMatch(result.message, /private|database/);
  }
  assert.deepEqual(phases, ['profile', 'intent_read', 'rpc']);
});

test('active finding and human review remain separate; ordering matches the deployed RPC', () => {
  assert.match(page, /Cek petugas tidak menghapus temuan iPos/);
  assert.match(readModel, /\.order\("reviewed_at", \{ ascending: false \}\)\s*\.order\("created_at", \{ ascending: false \}\)\s*\.order\("id", \{ ascending: false \}\)/);
  assert.match(foundation, /order by r\.reviewed_at desc, r\.created_at desc, r\.id desc limit 1/);
});
