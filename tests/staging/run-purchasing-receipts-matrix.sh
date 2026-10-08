#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker
expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000\n20260929230000\n20260929240000\n20260929250000\n20260929260000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then printf 'REFUSED: expected exact local migration ledger through 20260929220000\n' >&2; exit 110; fi
installed="$(psql_local -Atqc "SELECT to_regprocedure('public.issue_purchase_receipt_post_intent(uuid)') IS NOT NULL AND to_regprocedure('public.apply_purchase_receipt_post_intent(uuid)') IS NOT NULL AND to_regprocedure('public.purchase_supplier_upsert(uuid,text,text,text,text,boolean)') IS NOT NULL AND to_regprocedure('public.purchase_receipt_save_draft(uuid,integer,timestamptz,text,jsonb)') IS NOT NULL AND to_regprocedure('public.purchase_invoice_finalize(uuid,uuid,integer,numeric,text,date,text)') IS NOT NULL")"
if [[ "$installed" != 't' ]]; then printf 'REFUSED: required purchasing RPC contract is missing\n' >&2; exit 111; fi
actual_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929220000_purchasing_receipts_v1.sql" | awk '{print $1}')"
expected_sha='446ef119001f8bb6fca3e405392db507851a4b49b054268cca27247d793e37e4'
if [[ "$actual_sha" != "$expected_sha" ]]; then printf 'REFUSED: local migration SHA mismatch\n' >&2; exit 112; fi
bash "$SCRIPT_DIR/refresh-purchasing-post-rpc.sh"
before="$(psql_local -Atq -f "$SCRIPT_DIR/purchasing-receipts-state.sql")"
set +e
psql_local -f "$SCRIPT_DIR/runtime-purchasing-receipts.sql"
test_status=$?
set -e
after="$(psql_local -Atq -f "$SCRIPT_DIR/purchasing-receipts-state.sql")"
if [[ "$before" != "$after" ]]; then printf 'FAIL: rollback fingerprint changed\nBefore: %s\nAfter: %s\n' "$before" "$after" >&2; exit 113; fi
if [[ "$test_status" -ne 0 ]]; then printf 'Purchasing runtime matrix failed with status %s; durable fingerprint matches after rollback\n' "$test_status" >&2; exit "$test_status"; fi
printf 'PASS: purchasing Phase 1 runtime matrix rolled back; durable fingerprint matches\n'
