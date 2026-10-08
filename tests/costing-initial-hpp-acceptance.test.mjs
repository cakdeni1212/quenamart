import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const migration = readFileSync(new URL('../supabase/migrations/20260929260000_costing_initial_hpp_acceptance_v1.sql', import.meta.url), 'utf8');
const staging = readFileSync(new URL('./staging/runtime-costing-hpp-acceptance.sql', import.meta.url), 'utf8');

test('Checkpoint A is additive and never executes bootstrap or changes WAC/stock/HPP authority', () => {
  assert.match(migration, /BEGIN;[\s\S]*CREATE TYPE public\.inventory_cost_hpp_acceptance_status/);
  assert.match(migration, /COMMIT;\s*$/);
  assert.doesNotMatch(migration, /PERFORM\s+public\.inventory_cost_bootstrap_outlet|SELECT\s+public\.inventory_cost_bootstrap_outlet/);
  assert.doesNotMatch(migration, /INSERT\s+INTO\s+public\.(inventory_cost_projections|inventory_cost_events|inventory_cost_event_batches|inventory_costing_outlet_authority)/i);
  assert.doesNotMatch(migration, /UPDATE\s+public\.(product_costs|product_cost_history|product_inventory|stock_balance_projection|stock_movements)/i);
});

test('acceptance batches preserve one-time lifecycle, provenance, source summary and immutable events', () => {
  for (const field of ['rule_version', 'source_snapshot_hash', 'source_import_batch_count', 'normalization_commit_count',
    'candidate_count', 'exception_count', 'blocking_reason_counts', 'warning_counts', 'estimated_opening_value',
    'prepared_by', 'prepared_at', 'approved_by', 'approved_at', 'prepare_request_id', 'approve_request_id']) {
    assert.match(migration, new RegExp(`\\b${field}\\b`));
  }
  assert.match(migration, /'PREPARED', 'APPROVED', 'INVALIDATED', 'CONSUMED'/);
  assert.match(migration, /inventory_cost_hpp_acceptance_one_active_outlet/);
  assert.match(migration, /HPP acceptance audit events are append-only/);
  assert.match(migration, /Approved or invalidated HPP acceptance evidence is immutable/);
});

test('candidate blockers and warning-only signals follow the approved structural rule', () => {
  for (const reason of ['HPP_MISSING', 'HPP_ZERO', 'HPP_INVALID_BOUNDS_OR_SCALE', 'SOURCE_PROVENANCE_MISSING',
    'SOURCE_PROVENANCE_INVALID', 'NORMALIZED_SOURCE_HPP_MISSING', 'NORMALIZED_SOURCE_HPP_INVALID_BOUNDS_OR_SCALE',
    'CURRENT_SOURCE_HPP_MISMATCH', 'SOURCE_OVERRIDE_CONFLICT', 'COST_HISTORY_MISSING',
    'LATEST_COST_HISTORY_MISMATCH', 'ACTIVE_HPP_OVERRIDE', 'UNRESOLVED_OR_CONFLICTING_HPP_REVIEW',
    'OPEN_HPP_SOURCE_CONFLICT', 'OPEN_COST_AUDIT_FINDING', 'SELLING_PRICE_MISSING_OR_INVALID',
    'HPP_NOT_BELOW_SELLING_PRICE']) assert.ok(migration.includes(reason), `missing blocker ${reason}`);
  for (const warning of ['ONE_RUPIAH_HPP', 'GROSS_MARGIN_AT_OR_BELOW_5_PERCENT',
    'GROSS_MARGIN_ABOVE_80_PERCENT', 'HIGH_ABSOLUTE_HPP_OUTLIER']) assert.ok(migration.includes(warning));
  assert.match(migration, /THEN 'AUTO_CANDIDATE' ELSE 'EXCEPTION'/);
  assert.match(migration, /percentile_disc\(0\.99\)/);
  assert.match(migration, /current_hpp>3\*w\.p99_hpp/);
});

test('preview is manager-only, bounded, paginated and groups live exceptions/warnings in PostgreSQL', () => {
  assert.match(migration, /inventory_cost_initial_hpp_acceptance_preview\([\s\S]*p_page_size integer DEFAULT 50/);
  assert.match(migration, /v_size integer:=least\(greatest\(coalesce\(p_page_size,50\),1\),100\)/);
  assert.match(migration, /'positiveStockProducts',[\s\S]*'autoCandidates',[\s\S]*'exceptions',[\s\S]*'warningProducts'/);
  assert.match(migration, /'exceptionCountsByReason',[\s\S]*'warningCountsByCode'/);
  assert.match(migration, /ILIKE '%'\|\|v_search\|\|'%'/);
  assert.match(migration, /v_role NOT IN \('OWNER'::public\.user_role,'ADMIN'::public\.user_role\)/);
  assert.match(migration, /RETURN jsonb_build_object\('ok',false,'code','FORBIDDEN'\)/);
});

test('prepare snapshots provenance under the shared iPos lock and exact replay is actor/payload bound', () => {
  assert.match(migration, /PERFORM pg_catalog\.pg_advisory_xact_lock\(734921,2\)/);
  assert.match(migration, /prepare_initial_hpp_acceptance\(p_outlet_id uuid,p_request_id uuid\)/);
  assert.match(migration, /COST_HPP_ACCEPTANCE_REQUEST:/);
  assert.match(migration, /v_req\.actor_id<>v_actor OR v_req\.operation<>'PREPARE' OR v_req\.payload<>v_payload/);
  assert.match(migration, /source_snapshot_hash/);
  assert.match(migration, /WHERE e\.effective_quantity>0 ORDER BY e\.product_id/);
  assert.match(migration, /Initial HPP acceptance is unavailable after costing bootstrap or activation/);
});

test('all four reasoned exception dispositions are restricted and opening overrides are cutover-only', () => {
  for (const disposition of ['ACCEPT_CURRENT_HPP', 'OPENING_HPP_OVERRIDE', 'LEAVE_UNVALUED', 'AUTHORITATIVE_ZERO']) {
    assert.ok(migration.includes(`'${disposition}'`));
  }
  assert.match(migration, /AUTHORITATIVE_ZERO requires an existing explicit HPP value of zero/);
  assert.match(migration, /Current HPP is unavailable or zero; use AUTHORITATIVE_ZERO only for explicit zero/);
  assert.match(migration, /Opening HPP override must be positive, within range, and have at most 2 decimals/);
  assert.match(migration, /resolution_reason text/);
  assert.doesNotMatch(migration, /UPDATE\s+public\.(product_costs|product_cost_history|ipos_import_rows)/i);
});

test('stale fingerprint excludes stock quantity/version and includes every cost-trust fact', () => {
  const fingerprint = migration.slice(migration.indexOf('md5(jsonb_build_array('), migration.indexOf('AS source_fingerprint'));
  assert.doesNotMatch(fingerprint, /effective_quantity|balance_version/);
  for (const fact of ['current_hpp', 'current_hpp_updated_at', 'source_import_row_id', 'source_import_batch_id',
    'normalization_commit_id', 'source_row_status', 'normalized_source_hpp', 'source_valid', 'source_conflict_codes',
    'latest_cost_history_id', 'latest_history_hpp', 'latest_history_source_row_id', 'latest_review_id',
    'latest_review_status', 'active_override_id', 'active_override_value', 'open_cost_findings',
    'selling_price', 'selling_price_updated_at', 'latest_selling_price_history_id']) {
    assert.ok(fingerprint.includes(fact), `fingerprint missing ${fact}`);
  }
  assert.match(migration, /live\.source_fingerprint IS DISTINCT FROM i\.current_source_fingerprint/);
  assert.match(staging, /stock-quantity-only change is not in the cost-trust[\s\S]*fingerprint/);
});

test('OWNER alone approves; protected tables are manager-read-only and direct client writes are revoked', () => {
  assert.match(migration, /v_role IS DISTINCT FROM 'OWNER'::public\.user_role/);
  assert.match(migration, /Only OWNER may approve initial HPP acceptance/);
  assert.match(migration, /REVOKE ALL ON public\.inventory_cost_hpp_acceptance_requests,[\s\S]*FROM PUBLIC,anon,authenticated,service_role/);
  assert.match(migration, /inventory_cost_hpp_acceptance_batches_read_managers/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.inventory_cost_initial_hpp_acceptance_preview/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.prepare_initial_hpp_acceptance/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.resolve_initial_hpp_acceptance_exception/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.approve_initial_hpp_acceptance/);
  assert.match(staging, /GUDANG\/KASIR acceptance financial data was exposed/);
  assert.match(staging, /ADMIN final approval was not denied/);
});

test('approval revalidates before freezing and never calls bootstrap or writes costing/stock state', () => {
  assert.match(migration, /Every exception must have an explicit reasoned disposition before approval/);
  assert.match(migration, /UPDATE public\.inventory_cost_hpp_acceptance_batches SET status='APPROVED'/);
  assert.match(migration, /UPDATE public\.inventory_cost_hpp_acceptance_items i SET quantity_at_approval/);
  assert.match(staging, /HPP approval bootstrapped or activated WAC/);
  assert.match(staging, /Approval unexpectedly changed stock projection/);
});
