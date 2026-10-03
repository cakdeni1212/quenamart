#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker

expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
already_applied="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929190000' AND filename = '20260929190000_stock_workspace_read_v1.sql')")"

if [[ "$already_applied" == 't' ]]; then
  if [[ "$actual_versions" != "$expected_versions"$'\n20260929190000' ]]; then
    printf 'REFUSED: staging ledger has unexpected state after 190000; inspect manually\n' >&2
    exit 50
  fi
  printf 'Migration 190000 is already recorded; rerunning read-only runtime/EXPLAIN checks\n'
else
  if [[ "$actual_versions" != "$expected_versions" ]]; then
    printf 'REFUSED: expected clean staging ledger through 180000; no migration was applied\n' >&2
    exit 51
  fi
  if [[ "$(psql_local -Atqc "SELECT to_regprocedure('public.stock_workspace_read_page(uuid,text,text,boolean,text,integer,integer)') IS NULL")" != 't' ]]; then
    printf 'REFUSED: function signature already exists without ledger entry; no migration was applied\n' >&2
    exit 52
  fi
  printf 'Applying 20260929190000 only to verified local staging target\n'
  psql_local -f "$STAGING_ROOT/supabase/migrations/20260929190000_stock_workspace_read_v1.sql"
  psql_local -c "INSERT INTO quena_staging.applied_migrations(ordinal, version, filename) VALUES (11, '20260929190000', '20260929190000_stock_workspace_read_v1.sql')"
fi

fixture_seeded="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.fixture_runs WHERE fixture_key = 'stock_foundation_v1')")"
if [[ "$fixture_seeded" != 't' ]]; then
  printf 'REFUSED: synthetic stock fixture marker is missing\n' >&2
  exit 53
fi

psql_local -f "$SCRIPT_DIR/runtime-stock-workspace-read.sql"
