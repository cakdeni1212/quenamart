#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

# This runner never applies migrations. All matrix mutations are inside the
# runtime SQL transaction, which ends with ROLLBACK.
guard_local_target
assert_local_staging_marker

expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000\n20260929230000\n20260929240000\n20260929250000\n20260929260000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: expected exact local migration ledger through 20260929200000; no test mutation was run\n' >&2
  exit 90
fi
fixture_seeded="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.fixture_runs WHERE fixture_key = 'stock_foundation_v1')")"
if [[ "$fixture_seeded" != 't' ]]; then
  printf 'REFUSED: synthetic stock fixture marker is missing; no test mutation was run\n' >&2
  exit 91
fi
expected_migrations="$(psql_local -Atqc "SELECT count(*) = 3 FROM quena_staging.applied_migrations WHERE (version, filename) IN (('20260929180000','20260929180000_stock_foundation_v1.sql'),('20260929190000','20260929190000_stock_workspace_read_v1.sql'),('20260929200000','20260929200000_stock_opname_revision_guard_v1.sql'))")"
if [[ "$expected_migrations" != 't' ]]; then
  printf 'REFUSED: migration filenames do not match expected local stock chain; no test mutation was run\n' >&2
  exit 94
fi
functions_present="$(psql_local -Atqc "SELECT to_regprocedure('public.stock_opname_progress_counts(uuid)') IS NOT NULL AND to_regprocedure('public.issue_stock_operation_intent(text,jsonb)') IS NOT NULL AND to_regprocedure('public.apply_stock_operation_intent(uuid)') IS NOT NULL")"
if [[ "$functions_present" != 't' ]]; then
  printf 'REFUSED: expected 200000 functions are missing; no test mutation was run\n' >&2
  exit 92
fi

printf 'Running rollback-only REBASE_ITEM / REVIEW_EXCEPTION / progress matrix\n'
state_before="$(psql_local -Atq -f "$SCRIPT_DIR/stock-opname-create-state.sql")"
set +e
psql_local -f "$SCRIPT_DIR/runtime-stock-opname-revision-guard.sql"
runtime_status=$?
set -e
state_after="$(psql_local -Atq -f "$SCRIPT_DIR/stock-opname-create-state.sql")"
if [[ "$state_after" != "$state_before" ]]; then
  printf 'FAIL: durable local staging state changed across rollback-only revision-guard matrix\n' >&2
  printf 'Before: %s\nAfter:  %s\n' "$state_before" "$state_after" >&2
  exit 93
fi
if [[ "$runtime_status" -ne 0 ]]; then
  printf 'Runtime matrix failed with status %s; durable fingerprint is unchanged after rollback\n' "$runtime_status" >&2
  exit "$runtime_status"
fi
printf 'PASS: post-ROLLBACK durable-state fingerprint matches; local fixtures unchanged\n'
