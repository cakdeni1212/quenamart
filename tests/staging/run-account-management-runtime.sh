#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker
installed="$(psql_local -Atqc "SELECT to_regprocedure('public.account_management_list(text,text,text,integer,integer)') IS NOT NULL AND to_regprocedure('public.account_management_invite_begin(uuid,text,text,text)') IS NOT NULL AND to_regprocedure('public.account_management_update(uuid,text,text,boolean)') IS NOT NULL")"
if [[ "$installed" != 't' ]]; then
  printf 'REFUSED: account management migration is not installed in guarded local staging\n' >&2
  exit 40
fi

psql_local -f "$SCRIPT_DIR/runtime-account-management.sql"
