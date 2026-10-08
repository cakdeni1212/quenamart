#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker

readonly EXPECTED_MIGRATION_SHA='f3e6382354bf0c1f5d9f7f1530180ed039375ac42a7e7afac4bc9d493cc3e576'
readonly EXPECTED_VERSIONS=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000\n20260929230000\n20260929240000\n20260929250000\n20260929260000'
readonly MIGRATION_FILE="$STAGING_ROOT/supabase/migrations/20260929190000_stock_workspace_read_v1.sql"

actual_sha="$(shasum -a 256 "$MIGRATION_FILE" | awk '{print $1}')"
if [[ "$actual_sha" != "$EXPECTED_MIGRATION_SHA" ]]; then
  printf 'REFUSED: local migration SHA-256 %s does not match reviewed artifact %s\n' \
    "$actual_sha" "$EXPECTED_MIGRATION_SHA" >&2
  exit 70
fi

actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$EXPECTED_VERSIONS" ]]; then
  printf 'REFUSED: staging migration ledger does not match the expected chain through 190000; no test data was created\n' >&2
  exit 71
fi
signature_exists="$(psql_local -Atqc "SELECT to_regprocedure('public.stock_workspace_read_page(uuid,text,text,boolean,text,integer,integer)') IS NOT NULL")"
if [[ "$signature_exists" != 't' ]]; then
  printf 'REFUSED: reviewed stock workspace function is absent; no test data was created\n' >&2
  exit 72
fi

printf 'Reviewed artifact SHA-256: %s\n' "$actual_sha"
printf 'Running transactional synthetic 5,103-usable-projection scale check; no migration is applied\n'
psql_local -f "$SCRIPT_DIR/runtime-stock-workspace-scale.sql"
