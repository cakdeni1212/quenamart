#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker
expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000\n20260929230000\n20260929240000\n20260929250000\n20260929260000\n20260929270000\n20260929280000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: guarded staging ledger must end exactly at 20260929280000; no migration applied\n' >&2
  exit 210
fi
prepare_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929280000_costing_hpp_acceptance_prepare_performance_v1.sql" | awk '{print $1}')"
if [[ "$prepare_sha" != '9cdda5db8e68644c6fa4b2fc8e468c8e42d42264c1443a6b9f49d7c61fc6f84d' ]]; then
  printf 'REFUSED: immutable 280000 checksum mismatch; no migration applied\n' >&2
  exit 211
fi
candidate_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929290000_costing_purchase_receipt_acquisition_v1.sql" | awk '{print $1}')"
if [[ "$candidate_sha" != '3bea5f2fe6bd83f49020c7bea5519bf847627299fff9e0505aa7a52f69455617' ]]; then
  printf 'REFUSED: C3A candidate checksum guard has not been reviewed; no migration applied\n' >&2
  exit 212
fi
prerequisites="$(psql_local -Atqc "SELECT to_regclass('public.purchase_receipts') IS NOT NULL
  AND to_regclass('public.purchase_receipt_items') IS NOT NULL
  AND to_regclass('public.inventory_cost_projections') IS NOT NULL
  AND to_regclass('public.inventory_cost_event_batches') IS NOT NULL
  AND to_regclass('public.purchase_receipt_acquisition_estimate_revisions') IS NULL
  AND to_regtype('public.inventory_cost_projection_status') IS NULL")"
if [[ "$prerequisites" != t ]]; then
  printf 'REFUSED: prerequisite schema mismatch or C3A collision; no migration applied\n' >&2
  exit 213
fi

printf 'Applying only 20260929290000 to guarded local staging\n'
psql_local -f "$STAGING_ROOT/supabase/migrations/20260929290000_costing_purchase_receipt_acquisition_v1.sql"
psql_local -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename)
  VALUES(21,'20260929290000','20260929290000_costing_purchase_receipt_acquisition_v1.sql')"
printf 'PASS: 20260929290000 applied and ledger recorded on guarded local staging only\n'
