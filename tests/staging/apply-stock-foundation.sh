#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

# First database operation is read-only and verifies exact database + loopback.
guard_local_target
assert_local_staging_marker

expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: expected the complete baseline through 20260929171000; no migration was applied\n' >&2
  exit 30
fi
fixture_seeded="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.fixture_runs WHERE fixture_key = 'stock_foundation_v1')")"
if [[ "$fixture_seeded" != 't' ]]; then
  printf 'REFUSED: synthetic baseline fixture is missing; no migration was applied\n' >&2
  exit 31
fi
if [[ "$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929180000')")" == 't' ]]; then
  printf 'REFUSED: migration 180000 is already recorded; inspect staging instead of rerunning it\n' >&2
  exit 32
fi

printf 'Applying 20260929180000 only to verified local staging target\n'
psql_local -f "$STAGING_ROOT/supabase/migrations/20260929180000_stock_foundation_v1.sql"
psql_local -c "INSERT INTO quena_staging.applied_migrations(ordinal, version, filename) VALUES (10, '20260929180000', '20260929180000_stock_foundation_v1.sql')"
psql_local -f "$SCRIPT_DIR/verify-stock-staging.sql"
