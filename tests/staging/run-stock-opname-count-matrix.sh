#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

# This runner never applies migrations. Mutations use the existing authenticated
# operation-intent boundary inside a transaction that is unconditionally rolled back.
guard_local_target
assert_local_staging_marker

foundation_applied="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929180000' AND filename = '20260929180000_stock_foundation_v1.sql')")"
workspace_applied="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929190000' AND filename = '20260929190000_stock_workspace_read_v1.sql')")"
required_rpcs="$(psql_local -Atqc "SELECT to_regprocedure('public.issue_stock_operation_intent(text,jsonb)') IS NOT NULL AND to_regprocedure('public.apply_stock_operation_intent(uuid)') IS NOT NULL AND to_regprocedure('public.resolve_stock_barcode(uuid,text)') IS NOT NULL")"
fixture_seeded="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.fixture_runs WHERE fixture_key = 'stock_foundation_v1')")"
if [[ "$foundation_applied" != 't' || "$workspace_applied" != 't' || "$required_rpcs" != 't' || "$fixture_seeded" != 't' ]]; then
  printf 'REFUSED: local Stock Foundation/Workspace migration, RPCs, or synthetic fixture marker missing; no runtime test was run\n' >&2
  exit 60
fi

printf 'Running RECORD_COUNT role, revision, retry, and baseline-stale assertions in a rollback-only transaction\n'
state_before="$(psql_local -Atq -f "$SCRIPT_DIR/stock-opname-create-state.sql")"

set +e
psql_local -f "$SCRIPT_DIR/runtime-stock-opname-count.sql"
runtime_status=$?
set -e

state_after="$(psql_local -Atq -f "$SCRIPT_DIR/stock-opname-create-state.sql")"
if [[ "$state_after" != "$state_before" ]]; then
  printf 'FAIL: durable staging state changed across the RECORD_COUNT matrix despite rollback\n' >&2
  printf 'Before matrix: %s\n' "$state_before" >&2
  printf 'After matrix:  %s\n' "$state_after" >&2
  exit 70
fi
if [[ "$runtime_status" -ne 0 ]]; then
  printf 'Runtime SQL failed with status %s; post-rollback durable-state fingerprint is unchanged\n' "$runtime_status" >&2
  exit "$runtime_status"
fi

printf 'PASS: post-ROLLBACK durable-state fingerprint matches; fixture data is unchanged\n'
