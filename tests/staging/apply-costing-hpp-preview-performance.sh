#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker
expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000\n20260929230000\n20260929240000\n20260929250000\n20260929260000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: guarded staging ledger must end at 20260929260000; no migration applied\n' >&2
  exit 190
fi
acceptance_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929260000_costing_initial_hpp_acceptance_v1.sql" | awk '{print $1}')"
if [[ "$acceptance_sha" != '425a8182a370a8d4f84cfe471f991f37fcb16ff4b6cb88940861ac71c5428c6a' ]]; then
  printf 'REFUSED: immutable Checkpoint A migration SHA mismatch; no migration applied\n' >&2
  exit 191
fi
installed="$(psql_local -Atqc "SELECT to_regprocedure('public.inventory_cost_initial_hpp_acceptance_preview(uuid,text,text,integer,integer)') IS NOT NULL")"
if [[ "$installed" != t ]]; then
  printf 'REFUSED: Checkpoint A preview function is missing; no migration applied\n' >&2
  exit 192
fi

printf 'Applying only 20260929270000 to guarded local staging\n'
psql_local -f "$STAGING_ROOT/supabase/migrations/20260929270000_costing_hpp_acceptance_preview_performance_v1.sql"
psql_local -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename)
  VALUES(19,'20260929270000','20260929270000_costing_hpp_acceptance_preview_performance_v1.sql')"
printf 'PASS: 20260929270000 applied and ledger recorded on guarded local staging only\n'
