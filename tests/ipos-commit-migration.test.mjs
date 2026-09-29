import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = await readFile(new URL("../supabase/migrations/20260928143000_ipos_normalization_commit_v1.sql", import.meta.url), "utf8");

test("commit migration has unique per-batch/version idempotency and a transaction-local claim", () => {
  assert.match(migration, /unique \(batch_id, normalization_version\)/i);
  assert.match(migration, /from public\.ipos_import_batches\s+where id = p_batch_id\s+for update/i);
  assert.match(migration, /pg_advisory_xact_lock\(734921, 2\)/i);
  assert.match(migration, /if prior_commit\.status = 'COMPLETED' then\s+return prior_commit\.result/i);
  assert.match(migration, /commit_id_value, p_batch_id, batch_row\.outlet_id[\s\S]*'PROCESSING'/i);
  assert.match(migration, /set status = 'COMPLETED', completed_at = now\(\)/i);
});

test("all raw-row links require a completed snapshot and an active commit marker", () => {
  assert.match(migration, /c\.status = 'PROCESSING'\s+and b\.status = 'COMPLETED'/i);
  assert.match(migration, /new\.raw_data is distinct from old\.raw_data/i);
  assert.match(migration, /new\.status = 'VALID' and new\.product_id is null/i);
  assert.match(migration, /new\.status = 'INVALID' and new\.product_id is not null/i);
  assert.match(migration, /revoke insert, update on public\.ipos_import_rows from service_role/i);
});

test("stale preflight reference state aborts before normalized writes", () => {
  const compare = migration.indexOf("if actual_state_value is distinct from expected_state_value");
  const firstProductWrite = migration.indexOf("insert into public.products as current_product");
  assert.ok(compare > 0 && compare < firstProductWrite);
  assert.match(migration, /Normalized products, barcodes, or overrides changed since preflight/i);
});

test("history, findings, overrides, and product retention remain transactional", () => {
  assert.match(migration, /insert into public\.product_audit_findings[\s\S]*on conflict \(import_row_id, finding_code\) do nothing/i);
  assert.match(migration, /set status = 'RESOLVED', resolution_batch_id = p_batch_id/i);
  assert.match(migration, /override_conflicts text\[\] not null/i);
  assert.doesNotMatch(migration, /delete\s+from\s+public\.products/i);
  assert.doesNotMatch(migration, /delete\s+from\s+public\.product_.*_history/i);
  assert.match(migration, /begin;[\s\S]*commit;\s*$/i);
});

test("RPC is SECURITY DEFINER with fixed search path and service-role-only execution", () => {
  const functionStart = migration.indexOf("create or replace function public.commit_ipos_normalization");
  const functionEnd = migration.indexOf("$$;", functionStart);
  const definition = migration.slice(functionStart, functionEnd);
  assert.match(definition, /security definer/i);
  assert.match(definition, /set search_path = pg_catalog/i);
  assert.match(migration, /revoke all on function public\.commit_ipos_normalization\(uuid, text, jsonb\)\s+from public, anon, authenticated, service_role/i);
  assert.match(migration, /grant execute on function public\.commit_ipos_normalization\(uuid, text, jsonb\) to service_role/i);
  assert.match(migration, /revoke insert, update on public\.products,[\s\S]*from service_role/i);
  assert.match(migration, /create policy ipos_normalization_commit_rows_select_managers[\s\S]*OWNER[\s\S]*ADMIN/i);
});
