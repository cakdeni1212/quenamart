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
  printf 'REFUSED: guarded staging ledger must end exactly at 20260929290000; no test mutations started\n' >&2
  exit 214
fi
candidate_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929290000_costing_purchase_receipt_acquisition_v1.sql" | awk '{print $1}')"
if [[ "$candidate_sha" != '3bea5f2fe6bd83f49020c7bea5519bf847627299fff9e0505aa7a52f69455617' ]]; then
  printf 'REFUSED: C3A migration checksum changed; no test mutations started\n' >&2
  exit 215
fi
installed="$(psql_local -Atqc "SELECT to_regprocedure('public.purchase_receipt_acquisition_estimate_save(uuid,uuid,integer,integer,text,numeric,text,text)') IS NOT NULL
  AND to_regprocedure('public.inventory_cost_bootstrap_outlet(uuid,uuid)') IS NOT NULL
  AND to_regprocedure('public.apply_purchase_receipt_post_intent(uuid)') IS NOT NULL
  AND to_regclass('public.inventory_cost_purchase_receipt_item_once') IS NOT NULL")"
if [[ "$installed" != t ]]; then
  printf 'REFUSED: C3A function/index contract is not installed\n' >&2
  exit 216
fi

before="$(psql_local -Atq -f "$SCRIPT_DIR/costing-purchase-receipt-state.sql")"
set +e
psql_local -f "$SCRIPT_DIR/runtime-costing-purchase-receipt.sql"
test_status=$?
set -e
after="$(psql_local -Atq -f "$SCRIPT_DIR/costing-purchase-receipt-state.sql")"
if [[ "$before" != "$after" ]]; then
  printf 'FAIL: C3A rollback matrix changed durable stock/purchasing/costing evidence\nBefore: %s\nAfter: %s\n' "$before" "$after" >&2
  exit 217
fi
if [[ "$test_status" -ne 0 ]]; then
  printf 'C3A rollback matrix failed with status %s; durable state fingerprint matched\n' "$test_status" >&2
  exit "$test_status"
fi
printf 'PASS: C3A runtime matrix rolled back; stock, purchasing, product costs, and costing fingerprints match\n'
