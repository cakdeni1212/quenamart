#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker
expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000\n20260929230000\n20260929240000\n20260929250000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: expected exact staging ledger through 20260929250000; no test mutation was run\n' >&2
  exit 174
fi
actual_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929250000_costing_wac_foundation_v1.sql" | awk '{print $1}')"
if [[ "$actual_sha" != 'ad0531ef545acf92d6d6dc57098e35d4b4f013036b858c8c59c01024cbb26f06' ]]; then
  printf 'REFUSED: costing migration SHA changed; no test mutation was run\n' >&2
  exit 175
fi
installed="$(psql_local -Atqc "SELECT to_regprocedure('public.inventory_cost_bootstrap_outlet(uuid,uuid)') IS NOT NULL
  AND to_regprocedure('public.inventory_cost_projection_page(uuid,text,integer,integer)') IS NOT NULL
  AND (SELECT prosecdef FROM pg_catalog.pg_proc WHERE oid='public.inventory_cost_projection_page(uuid,text,integer,integer)'::regprocedure)=false")"
if [[ "$installed" != t ]]; then
  printf 'REFUSED: costing RPC/security contract is not installed as expected\n' >&2
  exit 176
fi

before="$(psql_local -Atq -f "$SCRIPT_DIR/costing-wac-foundation-state.sql")"
set +e
psql_local -f "$SCRIPT_DIR/runtime-costing-wac-foundation.sql"
test_status=$?
set -e
after="$(psql_local -Atq -f "$SCRIPT_DIR/costing-wac-foundation-state.sql")"
if [[ "$before" != "$after" ]]; then
  printf 'FAIL: costing bootstrap runtime changed durable stock/iPos/HPP state across rollback\nBefore: %s\nAfter: %s\n' "$before" "$after" >&2
  exit 177
fi
if [[ "$test_status" -ne 0 ]]; then
  printf 'Costing bootstrap matrix failed with status %s; durable rollback fingerprint matched\n' "$test_status" >&2
  exit "$test_status"
fi
printf 'PASS: costing bootstrap/security matrix rolled back; stock, iPos, and HPP fingerprint matched\n'
