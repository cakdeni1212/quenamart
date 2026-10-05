#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker
expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: expected exact local migration ledger through 20260929210000; nothing applied\n' >&2
  exit 100
fi
required="$(psql_local -Atqc "SELECT to_regprocedure('public.stock_apply_balance_delta(uuid,uuid,numeric)') IS NOT NULL AND to_regprocedure('public.current_active_user_role()') IS NOT NULL AND to_regclass('public.stock_operation_requests') IS NOT NULL AND to_regclass('public.purchase_receipts') IS NULL AND to_regclass('public.suppliers') IS NULL")"
if [[ "$required" != 't' ]]; then
  printf 'REFUSED: prerequisite stock contract mismatch or purchasing objects already exist\n' >&2
  exit 101
fi
actual_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929220000_purchasing_receipts_v1.sql" | awk '{print $1}')"
expected_sha='446ef119001f8bb6fca3e405392db507851a4b49b054268cca27247d793e37e4'
if [[ "$actual_sha" != "$expected_sha" ]]; then
  printf 'REFUSED: purchasing migration SHA mismatch; expected %s got %s\n' "$expected_sha" "$actual_sha" >&2
  exit 102
fi
printf 'Applying migration 20260929220000 only to verified local staging target\n'
psql_local -f "$STAGING_ROOT/supabase/migrations/20260929220000_purchasing_receipts_v1.sql"
psql_local -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename) VALUES (14,'20260929220000','20260929220000_purchasing_receipts_v1.sql')"
installed="$(psql_local -Atqc "SELECT to_regprocedure('public.issue_purchase_receipt_post_intent(uuid)') IS NOT NULL AND to_regprocedure('public.apply_purchase_receipt_post_intent(uuid)') IS NOT NULL AND to_regprocedure('public.purchase_receipt_resolve_barcode(text)') IS NOT NULL AND to_regclass('public.purchase_receipts') IS NOT NULL")"
if [[ "$installed" != 't' ]]; then printf 'FAIL: migration committed but required objects are missing; inspect staging\n' >&2; exit 103; fi
printf 'PASS: migration 20260929220000 applied to guarded local staging only\n'
printf 'Next: bash tests/staging/run-purchasing-receipts-matrix.sh\n'
