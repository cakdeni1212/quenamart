#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

guard_local_target
assert_local_staging_marker
expected_versions=$'20260928\n20260928115000\n20260928143000\n20260929100000\n20260929130000\n20260929150000\n20260929160000\n20260929170000\n20260929171000\n20260929180000\n20260929190000\n20260929200000\n20260929210000\n20260929220000\n20260929230000'
actual_versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$actual_versions" != "$expected_versions" ]]; then
  printf 'REFUSED: expected exact local migration ledger through 20260929230000; nothing applied\n' >&2
  exit 140
fi
collision="$(psql_local -Atqc "SELECT to_regprocedure('public.purchase_receipt_cancel_draft(uuid)') IS NOT NULL OR EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name IN ('purchase_receipts','purchase_invoices','purchase_invoice_documents') AND column_name IN ('cancelled_by','cancelled_at','cleanup_status'))")"
if [[ "$collision" != f ]]; then printf 'REFUSED: cancellation objects already exist; nothing applied\n' >&2; exit 141; fi
migration="$STAGING_ROOT/supabase/migrations/20260929240000_purchasing_receipt_draft_cancellation_v1.sql"
sha="$(shasum -a 256 "$migration" | awk '{print $1}')"
printf 'Applying only migration 20260929240000 to guarded local staging (SHA-256 %s)\n' "$sha"
psql_local -f "$migration"
psql_local -c "INSERT INTO quena_staging.applied_migrations(ordinal,version,filename) VALUES (16,'20260929240000','20260929240000_purchasing_receipt_draft_cancellation_v1.sql')"
installed="$(psql_local -Atqc "SELECT to_regprocedure('public.purchase_receipt_cancel_draft(uuid)') IS NOT NULL AND to_regprocedure('public.purchase_invoice_document_cleanup_mark(uuid,boolean)') IS NOT NULL AND EXISTS(SELECT 1 FROM pg_constraint WHERE conname='purchase_receipt_lifecycle_consistent') AND EXISTS(SELECT 1 FROM pg_constraint WHERE conname='purchase_invoice_lifecycle_shape')")"
if [[ "$installed" != t ]]; then printf 'FAIL: migration applied but cancellation contract is incomplete\n' >&2; exit 142; fi
printf 'PASS: migration 20260929240000 installed on guarded local staging only\n'
