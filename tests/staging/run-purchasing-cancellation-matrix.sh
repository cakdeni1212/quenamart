#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT
guard_local_target
assert_local_staging_marker
expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000\n20260929230000\n20260929240000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then printf 'REFUSED: expected exact local migration ledger through 20260929240000\n' >&2; exit 150; fi
installed="$(psql_local -Atqc "SELECT to_regprocedure('public.purchase_receipt_cancel_draft(uuid)') IS NOT NULL AND to_regprocedure('public.purchase_invoice_document_cleanup_mark(uuid,boolean)') IS NOT NULL AND to_regprocedure('public.purchase_invoice_link_receipt(uuid,uuid,boolean)') IS NOT NULL")"
if [[ "$installed" != t ]]; then printf 'REFUSED: required cancellation contract is not installed\n' >&2; exit 151; fi
before="$(psql_local -Atq -f "$SCRIPT_DIR/purchasing-cancellation-state.sql")"
set +e
psql_local -f "$SCRIPT_DIR/runtime-purchasing-cancellation.sql"
test_status=$?
set -e
after="$(psql_local -Atq -f "$SCRIPT_DIR/purchasing-cancellation-state.sql")"
if [[ "$before" != "$after" ]]; then printf 'FAIL: cancellation runtime fingerprint changed after rollback\nBefore: %s\nAfter: %s\n' "$before" "$after" >&2; exit 152; fi
if [[ "$test_status" -ne 0 ]]; then printf 'Cancellation matrix failed with status %s; rollback fingerprint matched\n' "$test_status" >&2; exit "$test_status"; fi
printf 'PASS: purchasing draft cancellation matrix rolled back; stock, HPP, and purchasing fingerprint matched\n'
printf 'Note: local PostgreSQL staging validates cleanup metadata retry state; private Storage HTTP deletion is covered by server-action contract tests only.\n'
