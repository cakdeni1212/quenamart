#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker
expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000\n20260929230000\n20260929240000\n20260929250000\n20260929260000\n20260929270000\n20260929280000\n20260929290000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: staging migration ledger must end at 20260929290000; no migration applied\n' >&2
  exit 230
fi

prepare_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929280000_costing_hpp_acceptance_prepare_performance_v1.sql" | awk '{print $1}')"
receipt_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929290000_costing_purchase_receipt_acquisition_v1.sql" | awk '{print $1}')"
if [[ "$prepare_sha" != '9cdda5db8e68644c6fa4b2fc8e468c8e42d42264c1443a6b9f49d7c61fc6f84d' \
   || "$receipt_sha" != '3bea5f2fe6bd83f49020c7bea5519bf847627299fff9e0505aa7a52f69455617' ]]; then
  printf 'REFUSED: reviewed immutable 280000/290000 checksum mismatch; no migration applied\n' >&2
  exit 231
fi
if find "$STAGING_ROOT/supabase/migrations" -maxdepth 1 -type f -name '202609293*.sql' ! -name '20260929300000_costing_stock_opname_source_layers_v1.sql' | grep -q .; then
  printf 'REFUSED: an unexpected migration after 300000 exists; no migration applied\n' >&2
  exit 232
fi

prerequisites="$(psql_local -Atqc "SELECT to_regclass('public.inventory_cost_source_layers') IS NULL
  AND to_regclass('public.inventory_cost_source_layer_balances') IS NULL
  AND to_regclass('public.inventory_cost_layer_allocations') IS NULL
  AND to_regprocedure('public.inventory_cost_apply_purchase_receipt(uuid,uuid,uuid,uuid)') IS NOT NULL
  AND to_regprocedure('public.inventory_cost_bootstrap_outlet(uuid,uuid)') IS NOT NULL
  AND to_regprocedure('public.apply_stock_operation_intent(uuid)') IS NOT NULL")"
if [[ "$prerequisites" != t ]]; then
  printf 'REFUSED: prerequisite or collision check failed; no migration applied\n' >&2
  exit 233
fi

printf 'Applying only 20260929300000 to guarded local staging\n'
psql_local -f "$STAGING_ROOT/supabase/migrations/20260929300000_costing_stock_opname_source_layers_v1.sql"
psql_local -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename)
  VALUES(22,'20260929300000','20260929300000_costing_stock_opname_source_layers_v1.sql')"
installed="$(psql_local -Atqc "SELECT to_regclass('public.inventory_cost_source_layers') IS NOT NULL
  AND to_regclass('public.inventory_cost_source_layer_balances') IS NOT NULL
  AND to_regclass('public.inventory_cost_layer_allocations') IS NOT NULL
  AND to_regprocedure('public.inventory_cost_apply_stock_movement_operation(uuid,text,uuid)') IS NOT NULL
  AND to_regprocedure('public.apply_stock_operation_intent(uuid)') IS NOT NULL")"
if [[ "$installed" != t ]]; then
  printf 'FAIL: C3B migration committed but required objects are missing; stop and inspect\n' >&2
  exit 234
fi
printf 'PASS: 20260929300000 applied and recorded on guarded local staging only\n'
