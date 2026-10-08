#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT
guard_local_target
assert_local_staging_marker
expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000\n20260929230000\n20260929240000\n20260929250000\n20260929260000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: guarded staging migration ledger is not exactly through 20260929260000\n' >&2
  exit 185
fi
foundation_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929250000_costing_wac_foundation_v1.sql" | awk '{print $1}')"
if [[ "$foundation_sha" != 'ad0531ef545acf92d6d6dc57098e35d4b4f013036b858c8c59c01024cbb26f06' ]]; then
  printf 'REFUSED: immutable Checkpoint 1 migration SHA mismatch\n' >&2
  exit 186
fi
objects="$(psql_local -Atqc "SELECT to_regprocedure('public.inventory_cost_initial_hpp_acceptance_preview(uuid,text,text,integer,integer)') IS NOT NULL
  AND to_regprocedure('public.prepare_initial_hpp_acceptance(uuid,uuid)') IS NOT NULL
  AND to_regprocedure('public.resolve_initial_hpp_acceptance_exception(uuid,uuid,public.inventory_cost_hpp_acceptance_disposition,numeric,text,uuid)') IS NOT NULL
  AND to_regprocedure('public.approve_initial_hpp_acceptance(uuid,uuid)') IS NOT NULL")"
if [[ "$objects" != t ]]; then
  printf 'REFUSED: expected acceptance RPC contracts are not installed\n' >&2
  exit 187
fi

before="$(psql_local -Atq -f "$SCRIPT_DIR/costing-wac-foundation-state.sql")"
set +e
psql_local -f "$SCRIPT_DIR/runtime-costing-hpp-acceptance.sql"
test_status=$?
set -e
after="$(psql_local -Atq -f "$SCRIPT_DIR/costing-wac-foundation-state.sql")"
acceptance_rows="$(psql_local -Atqc "SELECT
  (SELECT count(*) FROM public.inventory_cost_hpp_acceptance_batches)||':'||
  (SELECT count(*) FROM public.inventory_cost_hpp_acceptance_items)||':'||
  (SELECT count(*) FROM public.inventory_cost_hpp_acceptance_events)||':'||
  (SELECT count(*) FROM public.inventory_cost_hpp_acceptance_requests)")"
if [[ "$before" != "$after" || "$acceptance_rows" != '0:0:0:0' ]]; then
  printf 'FAIL: rollback fingerprint changed or acceptance test rows persisted\nBefore: %s\nAfter: %s\nAcceptance rows: %s\n' "$before" "$after" "$acceptance_rows" >&2
  exit 188
fi
if [[ "$test_status" -ne 0 ]]; then
  printf 'HPP acceptance staging matrix failed with status %s; rollback fingerprints matched\n' "$test_status" >&2
  exit "$test_status"
fi
printf 'PASS: HPP acceptance prepare/resolve/approval and role matrix rolled back; HPP, stock, iPos and WAC fingerprints matched\n'
