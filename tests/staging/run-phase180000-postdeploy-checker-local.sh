#!/usr/bin/env bash
set -euo pipefail

readonly DB_HOST="localhost"
readonly DB_PORT="5432"
readonly DB_NAME="quena_stock_staging"
readonly CHECKER="tests/production/phase180000-postdeploy-verification.sql"

if [[ ! -f "$CHECKER" ]]; then
  printf 'Missing production checker: %s\n' "$CHECKER" >&2
  exit 1
fi

# All psql sessions launched by this wrapper default to read-only transactions.
export PGOPTIONS='-c default_transaction_read_only=on'

target_identity="$(psql -X -w -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 -At -F '|' -c "
    WITH expected_relations(relname) AS (
      VALUES ('stock_authority_periods'), ('stock_balance_projection'),
             ('stock_balance_baseline_events'), ('stock_operation_requests'),
             ('stock_opname_sessions'), ('stock_opname_items'),
             ('stock_opname_count_events'), ('stock_opname_session_events'),
             ('stock_movement_batches'), ('stock_movements'),
             ('stock_movement_source_reconciliations'), ('stock_balance_projection_events')
    ), expected_types(typname) AS (
      VALUES ('stock_authority_mode'), ('stock_movement_type'), ('stock_movement_source'),
             ('stock_opname_scope'), ('stock_opname_status'), ('stock_count_event_type'),
             ('stock_opname_event_type'), ('stock_request_state')
    ), expected_functions(signature) AS (
      VALUES ('public.validate_stock_movement_reversal()'),
             ('public.refresh_stock_balance_from_ipos_inventory()'),
             ('public.reject_stock_ledger_mutation()'),
             ('public.guard_posted_stock_opname()'),
             ('public.guard_posted_stock_opname_item()'),
             ('public.stock_apply_balance_delta(uuid,uuid,numeric)'),
             ('public.stock_opname_content_hash(uuid)'),
             ('public.issue_stock_operation_intent(text,jsonb)'),
             ('public.read_stock_operation_intent(uuid)'),
             ('public.resolve_stock_barcode(uuid,text)'),
             ('public.apply_stock_operation_intent(uuid)')
    )
    SELECT current_database(),
           current_setting('server_version_num')::integer / 10000,
           (SELECT count(*) FROM expected_relations e
            WHERE to_regclass('public.' || e.relname) IS NOT NULL),
           (SELECT count(*) FROM expected_types e
            JOIN pg_catalog.pg_type t
              ON t.typnamespace = 'public'::regnamespace
             AND t.typname = e.typname AND t.typtype = 'e'),
           (SELECT count(*) FROM expected_functions e
            WHERE to_regprocedure(e.signature) IS NOT NULL)
  ")"

printf 'Local target structural identity: %s\n' "$target_identity"
if [[ "$target_identity" != 'quena_stock_staging|15|12|8|11' ]]; then
  printf 'Refusing: expected localhost:5432/quena_stock_staging, PostgreSQL 15, and all Phase 180000 relations/types/functions.\n' >&2
  exit 2
fi

local_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/qmart-phase180000-local-check.XXXXXX")"
local_checker="$(mktemp "$local_tmp_dir/qmart-phase180000-local-check.XXXXXX")"
cleanup() {
  if [[ "${KEEP_LOCAL_CHECK_SQL:-0}" == "1" ]]; then
    printf 'Generated local checker retained at: %s\n' "$local_checker"
  else
    rm -f "$local_checker"
    rmdir "$local_tmp_dir"
  fi
}
trap cleanup EXIT

python3 - "$CHECKER" "$local_checker" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text()
output_path = Path(sys.argv[2])

# Remove only the production Supabase ledger CTEs. PostgreSQL staging has no
# Supabase migration ledger relation; gate 1 is replaced separately below.
prefix = re.compile(
    r"expected_migrations\(version\) AS \(.*?^expected_types\(typname, labels\) AS \(",
    re.DOTALL | re.MULTILINE,
)
source, prefix_count = prefix.subn("expected_types(typname, labels) AS (", source)
if prefix_count != 1:
    raise SystemExit("Expected exactly one production migration-ledger CTE block")

# Gate 1 remains present as REVIEW/nonblocking to make its production-only
# status explicit. Gates 2-34 are retained byte-for-byte from the source file.
gate_one = re.compile(
    r"  SELECT 1 AS check_order,'migration_ledger_exact'.*?\n  UNION ALL\n  SELECT 2,",
    re.DOTALL,
)
replacement = (
    "  SELECT 1 AS check_order,'migration_ledger_local_not_applicable'::text AS check_name,\n"
    "    'REVIEW'::text AS status,\n"
    "    'Supabase migration ledger is not present in native local PostgreSQL staging'::text AS actual,\n"
    "    'not applicable locally'::text AS expected,\n"
    "    'Only production ledger gate 1 is bypassed for local parse/runtime validation.'::text AS detail,\n"
    "    false AS blocking\n"
    "  UNION ALL\n  SELECT 2,"
)
source, gate_count = gate_one.subn(replacement, source)
if gate_count != 1:
    raise SystemExit("Expected exactly one gate 1 to replace")

# Defensive check: ensure every component gate after gate 1 is unchanged.
original = Path(sys.argv[1]).read_text()
gate2 = "  SELECT 2,'stock_enums_and_labels'"
original_tail = original[original.index(gate2):]
variant_tail = source[source.index(gate2):]
if original_tail != variant_tail:
    raise SystemExit("Local transformation changed gate 2 or a later gate")

gate_numbers = [int(x) for x in re.findall(r"^\s*SELECT\s+(\d+),\s*'[^']+'", source, re.MULTILINE)]
if gate_numbers != list(range(2, 35)) + [999]:
    raise SystemExit(f"Unexpected local checker gate numbering: {gate_numbers}")
if "SELECT 1 AS check_order,'migration_ledger_local_not_applicable'" not in source:
    raise SystemExit("Local ledger REVIEW gate was not generated")
if "supabase_migrations.schema_migrations" in source:
    raise SystemExit("Local checker still references the Supabase migration ledger")

output_path.write_text(source)
PY

printf 'Running local-only checker variant; gate 1 is REVIEW, gates 2-34 are unchanged.\n'
psql -X -w -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 -P pager=off -f "$local_checker"
