#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

# This runner never applies a migration. Its only write calls are the existing
# CREATE_SESSION RPCs inside a SQL transaction that unconditionally rolls back.
guard_local_target
assert_local_staging_marker

foundation_applied="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929180000' AND filename = '20260929180000_stock_foundation_v1.sql')")"
workspace_applied="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929190000' AND filename = '20260929190000_stock_workspace_read_v1.sql')")"
create_rpc="$(psql_local -Atqc "SELECT to_regprocedure('public.issue_stock_operation_intent(text,jsonb)') IS NOT NULL AND to_regprocedure('public.apply_stock_operation_intent(uuid)') IS NOT NULL")"
if [[ "$foundation_applied" != 't' || "$workspace_applied" != 't' || "$create_rpc" != 't' ]]; then
  printf 'REFUSED: expected 180000/190000 ledger entries and stock intent RPCs; no test mutation was run\n' >&2
  exit 60
fi

fixture_seeded="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.fixture_runs WHERE fixture_key = 'stock_foundation_v1')")"
if [[ "$fixture_seeded" != 't' ]]; then
  printf 'REFUSED: synthetic stock fixture marker is missing; no test mutation was run\n' >&2
  exit 61
fi

printf 'Running CREATE_SESSION role/scope/idempotency assertions in one rollback-only transaction\n'
state_before="$(psql_local -Atq -f "$SCRIPT_DIR/stock-opname-create-state.sql")"

set +e
psql_local -f "$SCRIPT_DIR/runtime-stock-opname-create.sql"
runtime_status=$?
set -e

state_after="$(psql_local -Atq -f "$SCRIPT_DIR/stock-opname-create-state.sql")"
if [[ "$state_after" != "$state_before" ]]; then
  printf 'FAIL: durable staging state changed across the CREATE_SESSION matrix despite rollback\n' >&2
  printf 'Before rollback-only matrix: %s\n' "$state_before" >&2
  printf 'After rollback-only matrix:  %s\n' "$state_after" >&2
  exit 70
fi

if [[ "$runtime_status" -ne 0 ]]; then
  printf 'Runtime SQL failed with status %s; post-rollback durable-state fingerprint is unchanged\n' "$runtime_status" >&2
  exit "$runtime_status"
fi

printf 'PASS: post-ROLLBACK durable-state fingerprint matches; fixture data is unchanged\n'
