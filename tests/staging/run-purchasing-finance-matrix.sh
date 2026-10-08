#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT
guard_local_target
assert_local_staging_marker
expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000\n20260929230000\n20260929240000\n20260929250000\n20260929260000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then printf 'REFUSED: expected exact staging ledger through 20260929230000\n' >&2; exit 130; fi
installed="$(psql_local -Atqc "SELECT to_regprocedure('public.purchase_invoice_create_draft(uuid,uuid,uuid)') IS NOT NULL AND to_regprocedure('public.purchase_invoice_save_draft(uuid,integer,text,date,date,text,numeric,jsonb)') IS NOT NULL AND to_regprocedure('public.purchase_invoice_finalize(uuid,uuid,integer,numeric,text,date,text)') IS NOT NULL AND to_regprocedure('public.purchase_record_supplier_payment(uuid,uuid,uuid,date,numeric,text,text,jsonb)') IS NOT NULL AND to_regprocedure('public.purchase_invoice_financial_detail(uuid)') IS NOT NULL")"
if [[ "$installed" != t ]]; then printf 'REFUSED: required Phase 2 RPC contract is missing\n' >&2; exit 131; fi
actual_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929230000_purchasing_invoice_payables_v1.sql" | awk '{print $1}')"
expected_sha='87589ec96c5ebf749c83307130449f30bf1196c94eabab3fb19149b100ec9741'
if [[ "$actual_sha" != "$expected_sha" ]]; then printf 'REFUSED: Phase 2 migration SHA mismatch\n' >&2; exit 132; fi
bash "$SCRIPT_DIR/refresh-purchasing-post-rpc.sh"
before="$(psql_local -Atq -f "$SCRIPT_DIR/purchasing-finance-state.sql")"
set +e
psql_local -f "$SCRIPT_DIR/runtime-purchasing-finance.sql"
test_status=$?
set -e
after="$(psql_local -Atq -f "$SCRIPT_DIR/purchasing-finance-state.sql")"
if [[ "$before" != "$after" ]]; then printf 'FAIL: finance/receipt/stock fingerprint changed after rollback\nBefore: %s\nAfter: %s\n' "$before" "$after" >&2; exit 133; fi
if [[ "$test_status" -ne 0 ]]; then printf 'Finance runtime matrix failed with status %s; rollback fingerprint matched\n' "$test_status" >&2; exit "$test_status"; fi
printf 'PASS: purchasing Phase 2 financial matrix rolled back; durable fingerprint matches\n'
printf 'Next: run bash tests/staging/run-purchasing-receipts-matrix.sh for Phase 1 regression\n'
