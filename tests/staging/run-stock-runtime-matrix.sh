#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

# No schema/data mutation occurs until this exact local target is verified.
guard_local_target
assert_local_staging_marker
foundation_applied="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929180000' AND filename = '20260929180000_stock_foundation_v1.sql')")"
if [[ "$foundation_applied" != 't' ]]; then
  printf 'REFUSED: stock foundation is not recorded as applied in this local staging database\n' >&2
  exit 40
fi

printf 'Running transactional synthetic runtime assertions; final ROLLBACK leaves fixtures unchanged\n'
psql_local -f "$SCRIPT_DIR/runtime-stock-foundation.sql"
