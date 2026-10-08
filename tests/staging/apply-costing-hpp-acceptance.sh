#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker
expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000\n20260929230000\n20260929240000\n20260929250000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: guarded staging ledger must end at 20260929250000; no migration applied\n' >&2
  exit 180
fi
foundation_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929250000_costing_wac_foundation_v1.sql" | awk '{print $1}')"
if [[ "$foundation_sha" != 'ad0531ef545acf92d6d6dc57098e35d4b4f013036b858c8c59c01024cbb26f06' ]]; then
  printf 'REFUSED: committed Checkpoint 1 migration SHA mismatch; no migration applied\n' >&2
  exit 181
fi
collision="$(psql_local -Atqc "SELECT to_regclass('public.inventory_cost_hpp_acceptance_batches') IS NOT NULL
  OR to_regprocedure('public.inventory_cost_initial_hpp_acceptance_preview(uuid,text,text,integer,integer)') IS NOT NULL")"
if [[ "$collision" != f ]]; then
  printf 'REFUSED: acceptance schema collision found; no migration applied\n' >&2
  exit 182
fi

printf 'Applying 20260929260000 only to guarded local staging\n'
psql_local -f "$STAGING_ROOT/supabase/migrations/20260929260000_costing_initial_hpp_acceptance_v1.sql"
psql_local -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename)
  VALUES(18,'20260929260000','20260929260000_costing_initial_hpp_acceptance_v1.sql')"
installed="$(psql_local -Atqc "SELECT to_regclass('public.inventory_cost_hpp_acceptance_batches') IS NOT NULL
  AND to_regclass('public.inventory_cost_hpp_acceptance_items') IS NOT NULL
  AND to_regclass('public.inventory_cost_hpp_acceptance_events') IS NOT NULL
  AND to_regprocedure('public.inventory_cost_initial_hpp_acceptance_preview(uuid,text,text,integer,integer)') IS NOT NULL
  AND to_regprocedure('public.prepare_initial_hpp_acceptance(uuid,uuid)') IS NOT NULL
  AND to_regprocedure('public.resolve_initial_hpp_acceptance_exception(uuid,uuid,public.inventory_cost_hpp_acceptance_disposition,numeric,text,uuid)') IS NOT NULL
  AND to_regprocedure('public.approve_initial_hpp_acceptance(uuid,uuid)') IS NOT NULL")"
if [[ "$installed" != t ]]; then
  printf 'FAIL: acceptance migration committed locally but expected objects are missing\n' >&2
  exit 183
fi
printf 'PASS: 20260929260000 applied and ledger recorded on guarded local staging only\n'
