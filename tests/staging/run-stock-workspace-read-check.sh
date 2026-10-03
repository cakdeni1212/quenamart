#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker

applied="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929190000' AND filename = '20260929190000_stock_workspace_read_v1.sql')")"
if [[ "$applied" != 't' ]]; then
  printf 'REFUSED: migration 190000 is not recorded as applied; this checker will not apply it\n' >&2
  exit 60
fi
signature_exists="$(psql_local -Atqc "SELECT to_regprocedure('public.stock_workspace_read_page(uuid,text,text,boolean,text,integer,integer)') IS NOT NULL")"
if [[ "$signature_exists" != 't' ]]; then
  printf 'REFUSED: migration ledger says 190000 is applied but its function signature is missing\n' >&2
  exit 61
fi

printf 'Checking the existing 190000 RPC; this script does not apply migrations\n'
psql_local -f "$SCRIPT_DIR/diagnose-stock-workspace-read.sql"
psql_local -f "$SCRIPT_DIR/runtime-stock-workspace-read.sql"
