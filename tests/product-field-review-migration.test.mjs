import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const migration = readFileSync(new URL('../supabase/migrations/20260929150000_product_field_review_notes_idempotency_v1.sql', import.meta.url), 'utf8');
const appliedMigration = readFileSync(new URL('../supabase/migrations/20260929130000_field_audit_foundation_v1.sql', import.meta.url), 'utf8');
const intentMigration = readFileSync(new URL('../supabase/migrations/20260929160000_product_field_review_intents_v1.sql', import.meta.url), 'utf8');

function reviewFunction(sql) {
  const start = sql.indexOf('create or replace function public.record_product_field_review(');
  assert.notEqual(start, -1, 'review RPC definition exists');
  const end = sql.indexOf('$$;', start);
  assert.notEqual(end, -1, 'review RPC body terminates');
  return sql.slice(start, end + 3);
}

test('forward migration binds review request replay to canonical evidence notes', () => {
  const body = reviewFunction(migration);
  assert.match(body, /prior_request\.evidence_notes is distinct from nullif\(btrim\(p_evidence_notes\), ''\)/);
  assert.match(body, /nullif\(btrim\(p_evidence_notes\), ''\), p_request_id/);
  assert.match(body, /Request ID was already used for another review/);
  assert.match(body, /return prior_request\.id/);
  assert.match(body, /pg_advisory_xact_lock\(734921, 2\)/);
});

test('same canonical note replays while changed note changes the stored-note comparison', () => {
  const body = reviewFunction(migration);
  const normalized = "nullif(btrim(p_evidence_notes), '')";
  assert.equal(body.split(normalized).length - 1, 2);
  assert.ok(body.includes(`prior_request.evidence_notes is distinct from ${normalized}`));
});

test('updated RPC preserves deployed security mode, owner, search path, and execution grants', () => {
  const body = reviewFunction(migration);
  assert.match(body, /language plpgsql security definer/i);
  assert.match(body, /set search_path = pg_catalog/i);
  assert.match(migration, /alter function public\.record_product_field_review\([^;]+\) owner to postgres/i);
  assert.match(migration, /revoke all on function public\.record_product_field_review\([^;]+\)\s+from public, anon, authenticated, service_role/i);
  assert.match(migration, /grant execute on function public\.record_product_field_review\([^;]+\)\s+to authenticated/i);
});

test('migration is additive and the deployed Phase 3B.1A migration remains unchanged', () => {
  assert.match(migration, /^begin;/);
  assert.match(migration, /create or replace function public\.record_product_field_review/);
  assert.match(migration, /commit;\s*$/);
  const oldBody = reviewFunction(appliedMigration);
  assert.doesNotMatch(oldBody, /prior_request\.evidence_notes is distinct from/);
  assert.match(oldBody, /prior_request\.status is distinct from p_status/);
});

test('durable review intent registry is private, actor-bound, and payload-bound', () => {
  assert.match(intentMigration, /create table public\.product_field_review_intents/i);
  assert.match(intentMigration, /actor_id uuid not null references auth\.users/i);
  assert.match(intentMigration, /canonical_payload jsonb not null/i);
  assert.match(intentMigration, /enable row level security/i);
  assert.match(intentMigration, /revoke all on public\.product_field_review_intents from public, anon, authenticated, service_role/i);
  assert.match(intentMigration, /on public\.product_field_review_intents\(actor_id, canonical_payload\)\s+where completed_at is null/i);
  assert.match(intentMigration, /request_id uuid primary key default gen_random_uuid\(\)/i);
});

test('intent issuer validates active role/source and database generates/reuses outstanding IDs', () => {
  const start = intentMigration.indexOf('create or replace function public.issue_product_field_review_intent(');
  const end = intentMigration.indexOf('$$;', start) + 3;
  const issueBody = intentMigration.slice(start, end);
  assert.match(issueBody, /auth\.uid\(\)/);
  assert.match(issueBody, /current_active_user_role\(\)/);
  assert.match(issueBody, /p_status is null or p_field_key is null/);
  assert.match(issueBody, /Source changed/);
  assert.match(issueBody, /insert into public\.product_field_review_intents\(actor_id, canonical_payload\)/i);
  assert.match(issueBody, /on conflict \(actor_id, canonical_payload\) where completed_at is null do nothing/i);
});

test('review RPC replays a completed exact request before intent/source freshness and consumes atomically', () => {
  const start = intentMigration.indexOf('create or replace function public.record_product_field_review(');
  const end = intentMigration.indexOf('$$;', start) + 3;
  const body = intentMigration.slice(start, end);
  assert.ok(body.indexOf('select * into prior_request') < body.indexOf('select * into intent_row'));
  assert.ok(body.indexOf('return prior_request.id') < body.indexOf('select p.last_import_row_id'));
  assert.ok(body.indexOf('select p.last_import_row_id') < body.indexOf('insert into public.product_field_audit_reviews'));
  assert.ok(body.indexOf('insert into public.product_field_audit_reviews') < body.indexOf('update public.product_field_review_intents'));
  assert.match(body, /set completed_at = pg_catalog\.now\(\), review_id = current_source_id/);
  assert.match(body, /canonical_payload is distinct from canonical/);
  assert.match(body, /prior_request\.evidence_notes is distinct from normalized_notes/);
});

test('intent lookup returns only the authenticated actor’s authorized intent metadata', () => {
  const start = intentMigration.indexOf('create or replace function public.read_product_field_review_intent(');
  const end = intentMigration.indexOf('$$;', start) + 3;
  const body = intentMigration.slice(start, end);
  assert.match(body, /auth\.uid\(\)/);
  assert.match(body, /i\.request_id = p_request_id and i\.actor_id = v_actor_id/);
  assert.match(body, /role_value = 'GUDANG'[\s\S]*canonical_payload ->> 'field_key' not in \('barcode','rack_label','quantity','minimum_quantity'\)/);
  assert.match(body, /return jsonb_build_object\([\s\S]*'payload', intent_row\.canonical_payload/);
});
