#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker

expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: expected exact local ledger through 20260929200000; no migration was applied\n' >&2
  exit 80
fi

fixture_seeded="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.fixture_runs WHERE fixture_key = 'stock_foundation_v1')")"
if [[ "$fixture_seeded" != 't' ]]; then
  printf 'REFUSED: synthetic stock fixture marker is missing; no migration was applied\n' >&2
  exit 81
fi
predecessors="$(psql_local -Atqc "SELECT count(*) = 3 FROM quena_staging.applied_migrations WHERE (version, filename) IN (('20260929180000','20260929180000_stock_foundation_v1.sql'),('20260929190000','20260929190000_stock_workspace_read_v1.sql'),('20260929200000','20260929200000_stock_opname_revision_guard_v1.sql'))")"
if [[ "$predecessors" != 't' ]]; then
  printf 'REFUSED: stock migration filenames through 200000 do not match; no migration was applied\n' >&2
  exit 82
fi
if [[ "$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929210000')")" == 't' ]]; then
  printf 'REFUSED: migration 210000 is already ledgered; run only the results matrix\n' >&2
  exit 83
fi
prerequisites="$(psql_local -Atqc "SELECT to_regprocedure('public.stock_opname_progress_counts(uuid)') IS NOT NULL AND to_regprocedure('public.issue_stock_operation_intent(text,jsonb)') IS NOT NULL AND to_regprocedure('public.apply_stock_operation_intent(uuid)') IS NOT NULL AND to_regprocedure('public.stock_opname_posted_results_page(uuid,text,text,integer,integer)') IS NULL AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='stock_opname_sessions' AND column_name='posted_metadata_captured_at')")"
if [[ "$prerequisites" != 't' ]]; then
  printf 'REFUSED: unexpected pre/post-210000 schema; no migration was applied\n' >&2
  exit 84
fi

actual_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929210000_stock_opname_results_v1.sql" | awk '{print $1}')"
expected_sha='6145310dc482692fbca6db7846f907135ff46d19fd11e50bc6bc6a6686ee9c73'
if [[ "$actual_sha" != "$expected_sha" ]]; then
  printf 'REFUSED: migration SHA mismatch; expected %s got %s\n' "$expected_sha" "$actual_sha" >&2
  exit 85
fi

printf 'Applying 20260929210000 only to verified local staging target\n'
psql_local -f "$STAGING_ROOT/supabase/migrations/20260929210000_stock_opname_results_v1.sql"
psql_local -c "INSERT INTO quena_staging.applied_migrations(ordinal, version, filename) VALUES (13, '20260929210000', '20260929210000_stock_opname_results_v1.sql')"
actual_after="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_after" != "$expected_versions"$'\n20260929210000' ]]; then
  printf 'FAIL: migration committed but local ledger is unexpected; stop and inspect\n' >&2
  exit 86
fi
printf 'PASS: 20260929210000 applied and recorded on guarded local staging only\n'
printf 'Next: bash tests/staging/run-stock-opname-results-matrix.sh\n'
