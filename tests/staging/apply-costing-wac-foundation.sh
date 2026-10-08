#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker
expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000\n20260929230000\n20260929240000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: expected exact guarded staging ledger through 20260929240000; nothing applied\n' >&2
  exit 170
fi
actual_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929250000_costing_wac_foundation_v1.sql" | awk '{print $1}')"
if [[ "$actual_sha" != 'ad0531ef545acf92d6d6dc57098e35d4b4f013036b858c8c59c01024cbb26f06' ]]; then
  printf 'REFUSED: costing migration SHA mismatch; nothing applied\n' >&2
  exit 171
fi
prerequisites="$(psql_local -Atqc "SELECT to_regclass('public.stock_balance_projection') IS NOT NULL
  AND to_regclass('public.stock_authority_periods') IS NOT NULL
  AND to_regclass('public.product_costs') IS NOT NULL
  AND to_regclass('public.product_field_audit_reviews') IS NOT NULL
  AND to_regclass('public.inventory_cost_projections') IS NULL
  AND to_regprocedure('public.inventory_cost_bootstrap_outlet(uuid,uuid)') IS NULL")"
if [[ "$prerequisites" != t ]]; then
  printf 'REFUSED: prerequisite schema mismatch or costing object collision; nothing applied\n' >&2
  exit 172
fi

printf 'Applying migration 20260929250000 only to guarded local staging\n'
psql_local -f "$STAGING_ROOT/supabase/migrations/20260929250000_costing_wac_foundation_v1.sql"
psql_local -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename)
  VALUES (17,'20260929250000','20260929250000_costing_wac_foundation_v1.sql')"
installed="$(psql_local -Atqc "SELECT to_regclass('public.inventory_cost_projections') IS NOT NULL
  AND to_regclass('public.inventory_cost_events') IS NOT NULL
  AND to_regclass('public.inventory_cost_event_batches') IS NOT NULL
  AND to_regprocedure('public.inventory_cost_bootstrap_outlet(uuid,uuid)') IS NOT NULL
  AND to_regprocedure('public.inventory_cost_projection_page(uuid,text,integer,integer)') IS NOT NULL")"
if [[ "$installed" != t ]]; then
  printf 'FAIL: migration committed locally but a required costing object is missing; inspect staging\n' >&2
  exit 173
fi
printf 'PASS: 20260929250000 applied and recorded on guarded local staging only\n'
printf 'Next: bash tests/staging/run-costing-wac-foundation-matrix.sh\n'
