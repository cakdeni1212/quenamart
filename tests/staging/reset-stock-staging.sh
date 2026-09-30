#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

# Read-only identity proof precedes both the human confirmation and reset SQL.
guard_local_target
assert_local_staging_marker
printf 'This removes only the marked local quena_stock_staging schemas and data. Cluster roles are retained.\n'
printf 'Type RESET quena_stock_staging to continue: '
IFS= read -r confirmation
if [[ "$confirmation" != 'RESET quena_stock_staging' ]]; then
  printf 'Reset cancelled; no database changes were made.\n'
  exit 0
fi

psql_local -f "$SCRIPT_DIR/reset-stock-staging.sql"
printf 'Local staging schemas reset. No database was dropped; run prepare-stock-staging.sh to rebuild.\n'
