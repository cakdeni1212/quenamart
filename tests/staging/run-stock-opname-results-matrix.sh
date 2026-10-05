#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

# This runner executes both the complete Checkpoint 6 post regression matrix
# and the Checkpoint 7 result/snapshot matrix. Both SQL files end in ROLLBACK.
guard_local_target
assert_local_staging_marker

expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: expected exact local ledger through 20260929210000; no test mutation was run\n' >&2
  exit 90
fi
fixture_seeded="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.fixture_runs WHERE fixture_key = 'stock_foundation_v1')")"
if [[ "$fixture_seeded" != 't' ]]; then
  printf 'REFUSED: synthetic stock fixture marker is missing; no test mutation was run\n' >&2
  exit 91
fi
expected_files="$(psql_local -Atqc "SELECT count(*) = 4 FROM quena_staging.applied_migrations WHERE (version, filename) IN (('20260929180000','20260929180000_stock_foundation_v1.sql'),('20260929190000','20260929190000_stock_workspace_read_v1.sql'),('20260929200000','20260929200000_stock_opname_revision_guard_v1.sql'),('20260929210000','20260929210000_stock_opname_results_v1.sql'))")"
if [[ "$expected_files" != 't' ]]; then
  printf 'REFUSED: local stock migration filenames do not match expected chain\n' >&2
  exit 92
fi
required_objects="$(psql_local -Atqc "SELECT to_regprocedure('public.stock_opname_posted_results_page(uuid,text,text,integer,integer)') IS NOT NULL AND (SELECT count(*) = 8 FROM information_schema.columns WHERE table_schema='public' AND ((table_name='stock_opname_sessions' AND column_name IN ('posted_outlet_name_snapshot','posted_metadata_captured_at')) OR (table_name='stock_opname_items' AND column_name IN ('posted_product_name_snapshot','posted_sku_snapshot','posted_rack_label_snapshot','posted_unit_label_snapshot','posted_display_barcode_snapshot','posted_metadata_captured_at'))))")"
if [[ "$required_objects" != 't' ]]; then
  printf 'REFUSED: expected results RPC or snapshot columns are missing\n' >&2
  exit 93
fi
actual_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929210000_stock_opname_results_v1.sql" | awk '{print $1}')"
expected_sha='6145310dc482692fbca6db7846f907135ff46d19fd11e50bc6bc6a6686ee9c73'
if [[ "$actual_sha" != "$expected_sha" ]]; then
  printf 'REFUSED: migration SHA mismatch; expected %s got %s\n' "$expected_sha" "$actual_sha" >&2
  exit 94
fi

bash "$SCRIPT_DIR/refresh-stock-opname-results-rpc.sh"

state_before="$(psql_local -Atq -f "$SCRIPT_DIR/stock-opname-create-state.sql")$(psql_local -Atq -f "$SCRIPT_DIR/stock-opname-results-state.sql")"
set +e
psql_local -f "$SCRIPT_DIR/runtime-stock-opname-post.sql"
post_status=$?
if [[ "$post_status" -eq 0 ]]; then
  psql_local -f "$SCRIPT_DIR/runtime-stock-opname-results.sql"
  results_status=$?
else
  results_status=0
fi
set -e
state_after="$(psql_local -Atq -f "$SCRIPT_DIR/stock-opname-create-state.sql")$(psql_local -Atq -f "$SCRIPT_DIR/stock-opname-results-state.sql")"
if [[ "$state_after" != "$state_before" ]]; then
  printf 'FAIL: durable fingerprint changed across rollback-only Checkpoint 6/7 matrices\n' >&2
  printf 'Before: %s\nAfter:  %s\n' "$state_before" "$state_after" >&2
  exit 95
fi
if [[ "$post_status" -ne 0 ]]; then
  printf 'Checkpoint 6 POST_SESSION regression matrix failed with status %s; fingerprint matched after rollback\n' "$post_status" >&2
  exit "$post_status"
fi
if [[ "$results_status" -ne 0 ]]; then
  printf 'Checkpoint 7 results matrix failed with status %s; fingerprint matched after rollback\n' "$results_status" >&2
  exit "$results_status"
fi
printf 'PASS: Checkpoint 6 regression and Checkpoint 7 results matrices rolled back; durable fingerprints match\n'
