#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT
guard_local_target
assert_local_staging_marker
actual_sha="$(shasum -a 256 "$STAGING_ROOT/supabase/migrations/20260929220000_purchasing_receipts_v1.sql" | awk '{print $1}')"
expected_sha='446ef119001f8bb6fca3e405392db507851a4b49b054268cca27247d793e37e4'
if [[ "$actual_sha" != "$expected_sha" ]]; then printf 'REFUSED: purchasing migration SHA mismatch\n' >&2; exit 120; fi
if [[ "$(psql_local -Atqc "SELECT EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929220000')")" != 't' ]]; then
  printf 'REFUSED: local purchasing migration is not applied\n' >&2; exit 121
fi
temp_sql="$(mktemp "${TMPDIR:-/tmp}/quena-purchasing-rpcs.XXXXXX.sql")"
trap 'rm -f -- "$temp_sql"; cleanup_local_pgpass' EXIT
awk '/^CREATE FUNCTION public\./ { copying=1 }
  copying { print }
  copying && /^\$\$;/ { print ""; copying=0 }' "$STAGING_ROOT/supabase/migrations/20260929220000_purchasing_receipts_v1.sql" \
  | sed 's/^CREATE FUNCTION/CREATE OR REPLACE FUNCTION/' > "$temp_sql"
if ! rg -q '^CREATE OR REPLACE FUNCTION public\.apply_purchase_receipt_post_intent\(p_request_id uuid\)' "$temp_sql" \
  || ! rg -q '^CREATE OR REPLACE FUNCTION public\.purchase_receipt_create_draft\(' "$temp_sql"; then
  printf 'REFUSED: could not isolate the required functions from the reviewed migration\n' >&2; exit 122
fi
psql_local -f "$temp_sql"
psql_local -v ON_ERROR_STOP=1 <<'SQL'
DROP POLICY suppliers_read_authorized ON public.suppliers;
CREATE POLICY suppliers_read_authorized ON public.suppliers FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role)
    AND (public.current_active_user_role() <> 'GUDANG'::public.user_role OR is_active
      OR EXISTS (SELECT 1 FROM public.purchase_receipts r WHERE r.supplier_id = suppliers.id)));
SQL
printf 'PASS: refreshed only purchasing migration function bodies on guarded local staging\n'
