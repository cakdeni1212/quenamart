#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker
expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000\n20260929230000\n20260929240000\n20260929250000\n20260929260000\n20260929270000\n20260929280000\n20260929290000\n20260929300000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: exact guarded C3B migration frontier required; no test mutations started\n' >&2
  exit 240
fi
receipt_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929290000_costing_purchase_receipt_acquisition_v1.sql" | awk '{print $1}')"
if [[ "$receipt_sha" != '3bea5f2fe6bd83f49020c7bea5519bf847627299fff9e0505aa7a52f69455617' ]]; then
  printf 'REFUSED: C3A migration checksum differs from reviewed immutable version\n' >&2
  exit 241
fi
objects="$(psql_local -Atqc "SELECT to_regclass('public.inventory_cost_source_layers') IS NOT NULL
  AND to_regclass('public.inventory_cost_source_layer_balances') IS NOT NULL
  AND to_regclass('public.inventory_cost_layer_allocations') IS NOT NULL
  AND to_regprocedure('public.apply_stock_operation_intent(uuid)') IS NOT NULL
  AND EXISTS(SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname='inventory_cost_event_layer_allocation_consistent')")"
if [[ "$objects" != t ]]; then
  printf 'REFUSED: C3B schema/functions are incomplete\n' >&2
  exit 242
fi

before="$(psql_local -Atq -f "$SCRIPT_DIR/costing-stock-opname-source-layer-state.sql")"
set +e
psql_local -f "$SCRIPT_DIR/runtime-costing-stock-opname-source-layers.sql"
test_status=$?
set -e
after="$(psql_local -Atq -f "$SCRIPT_DIR/costing-stock-opname-source-layer-state.sql")"
if [[ "$before" != "$after" ]]; then
  printf 'FAIL: rollback-only C3B runtime test changed durable staging fingerprints\nBefore: %s\nAfter: %s\n' "$before" "$after" >&2
  exit 243
fi
if [[ "$test_status" -ne 0 ]]; then
  printf 'C3B runtime matrix failed with status %s; durable stock/cost fingerprints matched\n' "$test_status" >&2
  exit "$test_status"
fi
printf 'PASS: C3B rollback-only runtime matrix left local stock/cost state unchanged\n'
