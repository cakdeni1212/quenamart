#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker

expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: expected exact local migration ledger through 20260929190000; no migration was applied\n' >&2
  exit 80
fi

fixture_seeded="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.fixture_runs WHERE fixture_key = 'stock_foundation_v1')")"
if [[ "$fixture_seeded" != 't' ]]; then
  printf 'REFUSED: synthetic stock fixture marker is missing; no migration was applied\n' >&2
  exit 81
fi
expected_predecessors="$(psql_local -Atqc "SELECT count(*) = 2 FROM quena_staging.applied_migrations WHERE (version, filename) IN (('20260929180000','20260929180000_stock_foundation_v1.sql'),('20260929190000','20260929190000_stock_workspace_read_v1.sql'))")"
if [[ "$expected_predecessors" != 't' ]]; then
  printf 'REFUSED: predecessor migration filenames do not match 180000/190000; no migration was applied\n' >&2
  exit 85
fi

if [[ "$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929200000')")" == 't' ]]; then
  printf 'REFUSED: migration 200000 is already ledgered; inspect staging and run only the matrix\n' >&2
  exit 82
fi
if [[ "$(psql_local -Atqc "SELECT to_regprocedure('public.stock_opname_progress_counts(uuid)') IS NULL AND to_regprocedure('public.issue_stock_operation_intent(text,jsonb)') IS NOT NULL AND to_regprocedure('public.apply_stock_operation_intent(uuid)') IS NOT NULL")" != 't' ]]; then
  printf 'REFUSED: expected old stock RPCs and absent progress RPC; no migration was applied\n' >&2
  exit 83
fi

printf 'Applying 20260929200000 only to verified local staging target\n'
psql_local -f "$STAGING_ROOT/supabase/migrations/20260929200000_stock_opname_revision_guard_v1.sql"
psql_local -c "INSERT INTO quena_staging.applied_migrations(ordinal, version, filename) VALUES (12, '20260929200000', '20260929200000_stock_opname_revision_guard_v1.sql')"

actual_after="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_after" != "$expected_versions"$'\n20260929200000' ]]; then
  printf 'FAIL: migration committed but staging ledger is unexpected; stop and inspect\n' >&2
  exit 84
fi
printf 'PASS: 20260929200000 applied and recorded on guarded local staging only\n'
printf 'Next: bash tests/staging/run-stock-opname-revision-guard-matrix.sh\n'
