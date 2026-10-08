#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
RPC_SQL="$(mktemp "${TMPDIR:-/tmp}/quena-stock-results-rpc.XXXXXX.sql")"
trap 'rm -f -- "$RPC_SQL"; cleanup_local_pgpass' EXIT

guard_local_target
assert_local_staging_marker

expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000\n20260929230000\n20260929240000\n20260929250000\n20260929260000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: expected exact local ledger through 20260929210000; RPC refresh was not run\n' >&2
  exit 100
fi
actual_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929210000_stock_opname_results_v1.sql" | awk '{print $1}')"
expected_sha='6145310dc482692fbca6db7846f907135ff46d19fd11e50bc6bc6a6686ee9c73'
if [[ "$actual_sha" != "$expected_sha" ]]; then
  printf 'REFUSED: migration SHA mismatch; expected %s got %s\n' "$expected_sha" "$actual_sha" >&2
  exit 101
fi
prerequisites="$(psql_local -Atq <<'SQL'
SELECT to_regprocedure('public.stock_opname_posted_results_page(uuid,text,text,integer,integer)') IS NOT NULL
  AND (SELECT count(*) = 8
       FROM information_schema.columns
       WHERE table_schema = 'public'
         AND ((table_name = 'stock_opname_sessions'
               AND column_name IN ('posted_outlet_name_snapshot', 'posted_metadata_captured_at'))
           OR (table_name = 'stock_opname_items'
               AND column_name IN ('posted_product_name_snapshot', 'posted_sku_snapshot',
                   'posted_rack_label_snapshot', 'posted_unit_label_snapshot',
                   'posted_display_barcode_snapshot', 'posted_metadata_captured_at'))))
  AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles r WHERE r.rolname = session_user AND r.rolsuper);
SQL
)"
if [[ "$prerequisites" != 't' ]]; then
  printf 'REFUSED: expected 210000 snapshot schema/function or trusted local session user is missing\n' >&2
  exit 102
fi

awk '
  /^CREATE OR REPLACE FUNCTION public\.stock_opname_posted_results_page\(/ { copying = 1; found++ }
  copying { print }
  copying && /^  TO authenticated;$/ { finished = 1; exit }
  END { if (found != 1 || !finished) exit 1 }
' "$STAGING_ROOT/supabase/migrations/20260929210000_stock_opname_results_v1.sql" > "$RPC_SQL"
if [[ ! -s "$RPC_SQL" ]] \
  || ! rg -Uq '^ALTER FUNCTION public\.stock_opname_posted_results_page\(uuid, text, text, integer, integer\)\n  OWNER TO postgres;$' "$RPC_SQL" \
  || ! rg -q '^  TO authenticated;$' "$RPC_SQL"; then
  printf 'REFUSED: could not extract the complete fixed results RPC definition\n' >&2
  exit 103
fi

printf 'Refreshing only stock_opname_posted_results_page from pinned migration source on local staging\n'
psql_local -f "$RPC_SQL"
printf 'PASS: local results RPC definition refreshed; no migration or fixture data changed\n'
