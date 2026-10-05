#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT
guard_local_target
assert_local_staging_marker
expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: expected exact local staging ledger through 20260929220000; nothing applied\n' >&2
  exit 120
fi
required="$(psql_local -Atqc "SELECT to_regprocedure('public.issue_purchase_receipt_post_intent(uuid)') IS NOT NULL AND to_regprocedure('public.apply_purchase_receipt_post_intent(uuid)') IS NOT NULL AND to_regclass('public.purchase_invoices') IS NULL AND to_regclass('public.supplier_payments') IS NULL")"
if [[ "$required" != t ]]; then printf 'REFUSED: purchasing finance prerequisites/collision check failed\n' >&2; exit 121; fi
actual_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929230000_purchasing_invoice_payables_v1.sql" | awk '{print $1}')"
expected_sha='87589ec96c5ebf749c83307130449f30bf1196c94eabab3fb19149b100ec9741'
if [[ "$actual_sha" != "$expected_sha" ]]; then printf 'REFUSED: migration checksum differs; nothing applied\n' >&2; exit 122; fi
printf 'Applying purchasing invoice/payables migration 20260929230000 to guarded local staging only\n'
psql_local -f "$STAGING_ROOT/supabase/migrations/20260929230000_purchasing_invoice_payables_v1.sql"
psql_local -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename) VALUES (15,'20260929230000','20260929230000_purchasing_invoice_payables_v1.sql')"
installed="$(psql_local -Atqc "SELECT to_regprocedure('public.purchase_invoice_create_draft(uuid,uuid,uuid)') IS NOT NULL AND to_regprocedure('public.purchase_invoice_save_draft(uuid,integer,text,date,date,text,numeric,jsonb)') IS NOT NULL AND to_regprocedure('public.purchase_invoice_finalize(uuid,uuid,integer,numeric,text,date,text)') IS NOT NULL AND to_regprocedure('public.purchase_record_supplier_payment(uuid,uuid,uuid,date,numeric,text,text,jsonb)') IS NOT NULL AND to_regprocedure('public.purchase_invoice_financial_detail(uuid)') IS NOT NULL AND to_regprocedure('public.purchase_payables_page(text,text,integer,integer)') IS NOT NULL")"
if [[ "$installed" != t ]]; then printf 'FAIL: migration committed but required RPCs are missing; inspect local staging\n' >&2; exit 123; fi
printf 'PASS: migration 20260929230000 applied to guarded local staging only\n'
printf 'Next: bash tests/staging/run-purchasing-finance-matrix.sh\n'
