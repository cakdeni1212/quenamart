#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGING_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib.sh"

GENERATED_SQL=''
cleanup_scale_rpc_check() {
  if [[ -n "${GENERATED_SQL:-}" ]]; then
    rm -f -- "$GENERATED_SQL"
  fi
  cleanup_local_pgpass
}
trap cleanup_scale_rpc_check EXIT

guard_local_target
assert_local_staging_marker

readonly EXPECTED_MIGRATION_SHA='f3e6382354bf0c1f5d9f7f1530180ed039375ac42a7e7afac4bc9d493cc3e576'
readonly EXPECTED_VERSIONS=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000'
readonly MIGRATION_FILE="$STAGING_ROOT/supabase/migrations/20260929190000_stock_workspace_read_v1.sql"
readonly FIXTURE_SOURCE="$SCRIPT_DIR/runtime-stock-workspace-scale.sql"
readonly DIAGNOSTIC_TAIL="$SCRIPT_DIR/stock-workspace-scale-rpc-check.sql"

actual_sha="$(shasum -a 256 "$MIGRATION_FILE" | awk '{print $1}')"
if [[ "$actual_sha" != "$EXPECTED_MIGRATION_SHA" ]]; then
  printf 'REFUSED: migration SHA-256 %s does not match reviewed artifact %s\n' \
    "$actual_sha" "$EXPECTED_MIGRATION_SHA" >&2
  exit 70
fi

actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$EXPECTED_VERSIONS" ]]; then
  printf 'REFUSED: local staging ledger does not match the expected chain through 190000; no fixture data was created\n' >&2
  exit 71
fi

signature_exists="$(psql_local -Atqc "SELECT to_regprocedure('public.stock_workspace_read_page(uuid,text,text,boolean,text,integer,integer)') IS NOT NULL")"
if [[ "$signature_exists" != 't' ]]; then
  printf 'REFUSED: stock_workspace_read_page is absent; no fixture data was created\n' >&2
  exit 72
fi

marker='-- Execute the actual RPC as authenticated OWNER under RLS/SECURITY INVOKER.'
if [[ "$(grep -Fc -- "$marker" "$FIXTURE_SOURCE")" != '1' ]]; then
  printf 'REFUSED: could not identify the unique end of the reusable synthetic fixture setup\n' >&2
  exit 73
fi

GENERATED_SQL="$(mktemp "${TMPDIR:-/tmp}/quena-stock-scale-rpc-check.XXXXXX")"
awk -v marker="$marker" 'index($0, marker) { exit } { print }' "$FIXTURE_SOURCE" > "$GENERATED_SQL"
cat "$DIAGNOSTIC_TAIL" >> "$GENERATED_SQL"

printf 'Reviewed migration SHA-256: %s\n' "$actual_sha"
printf 'Acceptance: exact fixture/result correctness; no statement-timeout changes; all seven RPC calls complete; each <= 1,000 ms; default/page/status/rack calls preferably < 500 ms. A targeted EXPLAIN ANALYZE BUFFERS is emitted only for a completed case above 1,000 ms.\n'
printf 'Running the actual RPC scale checks after ANALYZE inside one rollback-only transaction; no migration is applied\n'
psql_local -f "$GENERATED_SQL"
