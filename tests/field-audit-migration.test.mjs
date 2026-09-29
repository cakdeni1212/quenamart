import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/20260929130000_field_audit_foundation_v1.sql', import.meta.url),
  'utf8',
);
const commitMigration = readFileSync(
  new URL('../supabase/migrations/20260928143000_ipos_normalization_commit_v1.sql', import.meta.url),
  'utf8',
);
const functionBody = (name) => {
  const start = migration.indexOf(`create or replace function public.${name}`);
  assert.notEqual(start, -1, `missing function ${name}`);
  const end = migration.indexOf('$$;', start);
  assert.notEqual(end, -1, `unterminated function ${name}`);
  return migration.slice(start, end + 3);
};

test('new RPCs use fixed search paths, postgres ownership, and authenticated-only grants', () => {
  for (const name of [
    'read_product_field_source',
    'read_product_financial_field_source',
    'record_product_field_review',
    'apply_product_field_correction',
  ]) {
    const body = functionBody(name);
    assert.match(body, /set search_path = pg_catalog/i);
    assert.match(migration, new RegExp(`alter function public\\.${name}\\([^;]*\\) owner to postgres`, 'i'));
    assert.match(migration, new RegExp(`revoke all on function public\\.${name}\\([^;]*\\)\\s+from public, anon`, 'i'));
    assert.match(migration, new RegExp(`grant execute on function public\\.${name}\\([^;]*\\)\\s+to authenticated`, 'i'));
  }
  assert.match(functionBody('apply_product_field_correction'), /auth\.uid\(\)/);
  assert.doesNotMatch(functionBody('apply_product_field_correction'), /p_actor|p_reviewer|p_user_id/i);
});

test('financial source and correction paths deny missing roles and GUDANG/KASIR HPP access', () => {
  assert.match(functionBody('read_product_financial_field_source'), /role_value is null or role_value not in \('OWNER'.*'ADMIN'/s);
  assert.match(functionBody('apply_product_field_correction'), /role_value = 'GUDANG'.*p_field_key not in \('barcode','rack_label'\)/s);
  assert.match(functionBody('apply_product_field_correction'), /role_value = 'KASIR'/);
  assert.match(migration, /current_active_user_role\(\).*field_key in \('barcode','rack_label'\)/s);
  assert.match(migration, /field_key in \('barcode','rack_label','quantity','minimum_quantity'\)/);
});

test('correction RPC locks with the import convention and refuses stock/minimum edits', () => {
  const body = functionBody('apply_product_field_correction');
  assert.match(body, /pg_advisory_xact_lock\(734921, 2\)/);
  assert.match(body, /p_field_key not in \('barcode','rack_label','hpp','selling_price'\)/);
  assert.match(body, /product_field_overrides/);
  assert.match(body, /product_field_audit_reviews/);
  assert.match(body, /HUMAN_ACCEPTED_SOURCE/);
});

test('barcode input is normalized safely and conflicts are returned without reassignment', () => {
  const body = functionBody('apply_product_field_correction');
  assert.match(body, /value_text := regexp_replace/);
  assert.match(body, /value_text = '' or value_text ~ '\[\[:cntrl:\]\]'/);
  assert.match(body, /BARCODE_CONFLICT/);
  assert.match(body, /product_id<>p_product_id/);
  assert.match(functionBody('protect_manual_barcode_override_from_import'), /return null/);
  assert.match(migration, /product_field_overrides_one_source_barcode_unique/);
});

test('ADD_ALIAS retains all existing associations and creates no source replacement override', () => {
  const body = functionBody('apply_product_field_correction');
  const alias = body.slice(body.indexOf("if p_field_key = 'barcode' and p_barcode_operation = 'ADD_ALIAS'"), body.indexOf("elsif has_override"));
  assert.match(body, /p_barcode_operation not in \('ADD_ALIAS','REPLACE_SOURCE'\)/);
  assert.match(alias, /where b\.product_id=p_product_id and b\.barcode=value_text and b\.is_active/);
  assert.match(alias, /source_import_row_id,created_by,updated_by\)[\s\S]*values\(p_product_id,value_text,true,null,actor_id,actor_id\)/);
  assert.doesNotMatch(alias, /update public\.product_barcodes|product_field_overrides/);
  assert.match(body, /b\.product_id<>p_product_id/);
  assert.match(body, /already_present := found/);
});

test('REPLACE_SOURCE preserves old association history and protects the corrected source value', () => {
  const body = functionBody('apply_product_field_correction');
  assert.match(body, /p_barcode_operation = 'REPLACE_SOURCE'[\s\S]*field_key='barcode'[\s\S]*source_import_row_id is not null/);
  assert.match(body, /-- Retire active imported\/source associations, not manual aliases/);
  assert.match(body, /set is_active=false,updated_by=actor_id[\s\S]*where product_id=p_product_id and is_active and source_import_row_id is not null/);
  assert.match(body, /insert into public\.product_field_overrides[\s\S]*'barcode',normalized_value,value_reason,p_source_import_row_id/);
  assert.doesNotMatch(functionBody('reconcile_barcode_override_on_import'), /set is_active = false/);
  assert.match(functionBody('finalize_barcode_override_sync_after_raw_link'), /update public\.product_field_overrides[\s\S]*set is_active = false/);
  assert.match(functionBody('protect_manual_barcode_override_from_import'), /return null/);
});

test('barcode operation is mandatory and irrelevant operations are rejected', () => {
  const body = functionBody('apply_product_field_correction');
  assert.match(body, /if p_field_key = 'barcode' then[\s\S]*p_barcode_operation is null or p_barcode_operation not in \('ADD_ALIAS','REPLACE_SOURCE'\)[\s\S]*Barcode operation must be ADD_ALIAS or REPLACE_SOURCE/);
  assert.match(body, /elsif p_barcode_operation is not null then[\s\S]*Barcode operation is only valid for BARCODE/);
});

test('REPLACE_SOURCE retires every active imported association while retaining NULL-provenance aliases and inactive history', () => {
  const body = functionBody('apply_product_field_correction');
  const replaceBlock = body.slice(body.indexOf("if p_field_key='barcode' then\n      -- Retire active imported/source associations"), body.indexOf("if not same_as_source then", body.indexOf("if p_field_key='barcode' then\n      -- Retire active imported/source associations")));
  assert.match(replaceBlock, /where product_id=p_product_id and is_active and source_import_row_id is not null/);
  assert.doesNotMatch(replaceBlock, /source_import_row_id=p_source_import_row_id/);
  assert.match(replaceBlock, /select b\.id into barcode_row[\s\S]*where b\.product_id=p_product_id and b\.barcode=value_text and b\.is_active/);
  assert.match(body, /set is_active=false,updated_by=actor_id[\s\S]*source_import_row_id is not null/);
  assert.match(functionBody('preserve_manual_barcode_alias_provenance'), /old\.source_import_row_id is null[\s\S]*new\.source_import_row_id := null/);
});

test('source-replacement imports still synchronize matching values and suppress differing values', () => {
  const reconciliation = functionBody('reconcile_barcode_override_on_import');
  const finalizer = functionBody('finalize_barcode_override_sync_after_raw_link');
  const guard = functionBody('protect_manual_barcode_override_from_import');
  assert.match(reconciliation, /v_matches := v_valid and to_jsonb\(v_incoming\) = v_override\.corrected_value/);
  assert.doesNotMatch(reconciliation, /update public\.product_barcodes|update public\.product_field_overrides/);
  assert.match(reconciliation, /SOURCE_CONFLICT/);
  assert.match(finalizer, /new\.product_id is null or new\.status <> 'VALID'/);
  assert.match(finalizer, /c\.product_id = new\.product_id and c\.action in \('CREATE', 'UPDATE'\)/);
  assert.match(finalizer, /'SOURCE_SYNCED'[\s\S]*update public\.product_barcodes[\s\S]*set source_import_row_id = new\.id/);
  assert.match(finalizer, /update public\.product_field_overrides[\s\S]*set is_active = false/);
  assert.match(guard, /if not exists \([\s\S]*event_type = 'SOURCE_SYNCED'[\s\S]*\) then\s+return null/);
  assert.match(functionBody('apply_product_field_correction'), /'operation_type', p_barcode_operation[\s\S]*'corrected_value', normalized_value[\s\S]*'reason', value_reason/);
});

test('barcode reconciliation distinguishes matching source, conflicts, and leaves aliases outside replacement protection', () => {
  const reconcile = functionBody('reconcile_barcode_override_on_import');
  const guard = functionBody('protect_manual_barcode_override_from_import');
  assert.match(reconcile, /v_matches := v_valid and to_jsonb\(v_incoming\) = v_override\.corrected_value/);
  assert.match(reconcile, /if not v_matches then[\s\S]*'SOURCE_CONFLICT'/);
  assert.doesNotMatch(reconcile, /SOURCE_SYNCED/);
  assert.doesNotMatch(reconcile, /set source_import_row_id = new\.last_import_row_id/);
  assert.match(functionBody('finalize_barcode_override_sync_after_raw_link'), /set source_import_row_id = new\.id/);
  assert.match(guard, /o\.is_active and o\.source_import_row_id is not null/);
  assert.match(guard, /event_type = 'SOURCE_SYNCED'/);
  assert.match(functionBody('apply_product_field_correction'), /p_barcode_operation = 'ADD_ALIAS'[\s\S]*?source_import_row_id,created_by,updated_by\)[\s\S]*?source_import_row_id is not null/s);
  assert.match(migration, /create unique index product_field_overrides_one_source_barcode_unique[\s\S]*field_key = 'barcode' and is_active and source_import_row_id is not null/);
  assert.match(migration, /create trigger product_barcodes_preserve_manual_alias_provenance[\s\S]*before update on public\.product_barcodes/i);
  assert.match(functionBody('preserve_manual_barcode_alias_provenance'), /old\.source_import_row_id is null and not exists[\s\S]*new\.source_import_row_id := null/);
  assert.match(commitMigration, /on conflict \(product_id, barcode\) where is_active do update/i);
});

test('barcode sync finalizes after Phase 2B links the raw row and before its barcode phase', () => {
  const finalizer = functionBody('finalize_barcode_override_sync_after_raw_link');
  const triggerAt = migration.indexOf('create trigger ipos_barcode_override_sync_after_raw_link');
  const rawLinkAt = commitMigration.indexOf('update public.ipos_import_rows r');
  const barcodePhaseAt = commitMigration.indexOf('update public.product_barcodes b');
  assert.match(commitMigration, /update public\.ipos_import_rows r[\s\S]*set product_id = c\.product_id/);
  assert.ok(rawLinkAt >= 0 && barcodePhaseAt > rawLinkAt);
  assert.ok(triggerAt > migration.indexOf('create or replace function public.finalize_barcode_override_sync_after_raw_link'));
  assert.match(migration, /after update of product_id on public\.ipos_import_rows[\s\S]*when \(old\.product_id is null and new\.product_id is not null\)/i);
  assert.match(finalizer, /join public\.ipos_normalization_commits n[\s\S]*n\.status = 'PROCESSING'/);
  assert.match(finalizer, /perform public\.field_audit_record_reconciliation\([\s\S]*'SOURCE_SYNCED'/);
  assert.match(finalizer, /set source_import_row_id = new\.id[\s\S]*where id = v_override\.barcode_id and product_id = new\.product_id and is_active/);
  assert.match(finalizer, /update public\.product_field_overrides[\s\S]*set is_active = false[\s\S]*where id = v_override\.id and is_active/);
  assert.match(migration, /product_field_reconciliation_import_event_unique/);
});

test('barcode sync keeps the immediate provenance FK, aliases, and conflict protection', () => {
  const baseSchema = readFileSync(new URL('../supabase/migrations/20260928_product_ipos_schema_v1.sql', import.meta.url), 'utf8');
  const reconciliation = functionBody('reconcile_barcode_override_on_import');
  const finalizer = functionBody('finalize_barcode_override_sync_after_raw_link');
  assert.match(baseSchema, /constraint product_barcodes_source_product_fk[\s\S]*references public\.ipos_import_rows\(id, product_id\) on delete restrict;/i);
  assert.doesNotMatch(migration, /drop constraint product_barcodes_source_product_fk|alter constraint product_barcodes_source_product_fk/i);
  assert.doesNotMatch(reconciliation, /set source_import_row_id/);
  assert.match(finalizer, /where id = v_override\.barcode_id and product_id = new\.product_id and is_active/);
  assert.match(functionBody('protect_manual_barcode_override_from_import'), /if not exists[\s\S]*SOURCE_SYNCED[\s\S]*return null/);
  assert.match(functionBody('preserve_manual_barcode_alias_provenance'), /old\.source_import_row_id is null[\s\S]*new\.source_import_row_id := null/);
  assert.match(commitMigration, /update public\.ipos_import_rows r[\s\S]*set product_id = c\.product_id/);
  assert.match(commitMigration, /on conflict \(product_id, barcode\) where is_active do update[\s\S]*where existing_barcode\.source_import_row_id is not null/);
});

test('scalar reconciliation runs before existing override guards and preserves current values on conflict', () => {
  const body = functionBody('reconcile_field_override_on_import');
  assert.match(body, /else[\s\S]*new\.rack_label := old\.rack_label/);
  assert.match(body, /new\.hpp := old\.hpp/);
  assert.match(body, /new\.amount := old\.amount/);
  for (const suffix of ['product_settings', 'product_costs', 'product_prices']) {
    assert.match(migration, new RegExp(`create trigger a_${suffix}_source_override_reconcile[\\s\\S]*before update`, 'i'));
  }
});

test('correction request IDs are bound to normalized semantic payloads and serialized', () => {
  const body = functionBody('apply_product_field_correction');
  assert.match(migration, /create table public\.product_field_correction_requests[\s\S]*request_id uuid primary key[\s\S]*request_payload jsonb not null[\s\S]*result jsonb not null/);
  for (const key of ['actor_id', 'product_id', 'outlet_id', 'field_key', 'source_import_row_id', 'operation_type', 'corrected_value', 'reason']) {
    assert.match(body, new RegExp(`'${key}'`));
  }
  assert.match(body, /pg_advisory_xact_lock\(734921, 2\)[\s\S]*from public\.product_field_correction_requests[\s\S]*for update/);
  assert.match(body, /request_payload is distinct from request_payload then[\s\S]*IDEMPOTENCY_KEY_REUSED/);
  assert.match(body, /return prior_correction_request\.result/);
  assert.match(body, /insert into public\.product_field_correction_requests\([\s\S]*request_payload,result,review_id/);
  assert.match(migration, /request_id uuid primary key/);
});

test('retry returns before normalized/history/review/reconciliation writes', () => {
  const body = functionBody('apply_product_field_correction');
  const replayAt = body.indexOf('return prior_correction_request.result');
  const writesAt = body.indexOf('update public.product_');
  assert.ok(replayAt >= 0 && (writesAt === -1 || replayAt < writesAt));
  assert.match(body, /if prior_correction_request\.actor_id <> actor_id[\s\S]*request_payload is distinct from request_payload/);
  assert.match(body, /insert into public\.product_field_audit_reviews/);
  assert.match(body, /field_audit_record_reconciliation/);
  assert.match(migration, /create trigger a_product_costs_source_override_reconcile/);
  assert.match(migration, /create trigger a_product_prices_source_override_reconcile/);
});

test('idempotency rejects corrected-value, reason, and operation changes under a reused key', () => {
  const body = functionBody('apply_product_field_correction');
  assert.match(body, /'corrected_value', normalized_value/);
  assert.match(body, /'reason', value_reason/);
  assert.match(body, /'operation_type', p_barcode_operation/);
  assert.match(body, /request_payload is distinct from request_payload then[\s\S]*IDEMPOTENCY_KEY_REUSED/);
  assert.match(body, /prior_correction_request\.actor_id <> actor_id/);
});

test('alias and replacement operations retain separate import protection behavior', () => {
  const correction = functionBody('apply_product_field_correction');
  const alias = correction.slice(correction.indexOf("if p_field_key = 'barcode' and p_barcode_operation = 'ADD_ALIAS'"), correction.indexOf("elsif has_override"));
  assert.doesNotMatch(alias, /set is_active=false/);
  assert.doesNotMatch(alias, /insert into public\.product_field_overrides/);
  assert.match(functionBody('protect_manual_barcode_override_from_import'), /o\.field_key = 'barcode'[\s\S]*o\.is_active and o\.source_import_row_id is not null/);
  assert.match(functionBody('preserve_manual_barcode_alias_provenance'), /old\.source_import_row_id is null/);
});

test('import reconciliation covers conflict and synchronization, and suppresses conflicting barcode inserts', () => {
  const scalar = functionBody('reconcile_field_override_on_import');
  assert.match(scalar, /SOURCE_SYNCED/);
  assert.match(scalar, /SOURCE_CONFLICT/);
  assert.match(scalar, /deactivated_by/);
  const barcode = functionBody('reconcile_barcode_override_on_import');
  assert.match(barcode, /SOURCE_CONFLICT/);
  const finalizer = functionBody('finalize_barcode_override_sync_after_raw_link');
  assert.match(finalizer, /SOURCE_SYNCED/);
  assert.match(finalizer, /deactivated_by/);
  assert.match(functionBody('protect_manual_barcode_override_from_import'), /SOURCE_SYNCED/);
  assert.match(migration, /on public\.product_barcodes\s+for each row execute function public\.protect_manual_barcode_override_from_import/i);
});

test('review transitions are append-only, human-attributed, and do not write automated PERLU status', () => {
  const body = functionBody('record_product_field_review');
  assert.match(body, /actor_id uuid := auth\.uid\(\)/);
  assert.match(body, /p_status not in \('SEDANG_DICEK'.*'SUDAH_DIVERIFIKASI'/s);
  assert.doesNotMatch(body, /PERLU_KOREKSI_IPOS/);
  assert.match(body, /pg_advisory_xact_lock\(734921, 2\)/);
});

test('raw snapshots and findings are untouched by new writer bodies', () => {
  const correction = functionBody('apply_product_field_correction');
  assert.doesNotMatch(correction, /update public\.ipos_import_rows/i);
  assert.doesNotMatch(correction, /delete from public\.product_audit_findings/i);
  assert.match(functionBody('read_product_field_source'), /raw_data -> 'KODEBARCODE'.*raw_data -> 'RAK'/s);
  assert.doesNotMatch(functionBody('read_product_field_source'), /raw_data\s*,/i);
  assert.match(functionBody('read_product_financial_field_source'), /role_value is null or role_value not in/);
});
