#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

# This is the first database operation: identity-only SELECTs, before DDL.
guard_local_target

versions=(
  '20260928|20260928_product_ipos_schema_v1.sql'
  '20260928115000|20260928115000_ipos_worker_v1.sql'
  '20260928143000|20260928143000_ipos_normalization_commit_v1.sql'
  '20260929100000|20260929100000_product_workspace_read_v1.sql'
  '20260929130000|20260929130000_field_audit_foundation_v1.sql'
  '20260929150000|20260929150000_product_field_review_notes_idempotency_v1.sql'
  '20260929160000|20260929160000_product_field_review_intents_v1.sql'
  '20260929170000|20260929170000_product_field_correction_intents_v1.sql'
  '20260929171000|20260929171000_product_field_correction_intent_ambiguity_fix_v1.sql'
)
for spec in "${versions[@]}"; do
  filename="${spec#*|}"
  if [[ ! -f "$STAGING_ROOT/supabase/migrations/$filename" ]]; then
    printf 'REFUSED: required local migration is missing: %s; no schema was changed\n' "$filename" >&2
    exit 28
  fi
done

ledger_exists="$(psql_local -Atqc "SELECT to_regclass('quena_staging.applied_migrations') IS NOT NULL")"
if [[ "$ledger_exists" != 't' ]]; then
  clean_target="$(psql_local -Atqc "
    SELECT to_regnamespace('auth') IS NULL
       AND to_regnamespace('storage') IS NULL
       AND to_regnamespace('quena_staging') IS NULL
       AND to_regtype('public.user_role') IS NULL
       AND to_regclass('public.profiles') IS NULL
       AND NOT EXISTS (
         SELECT 1 FROM pg_catalog.pg_class c
         JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public'
       )
       AND NOT EXISTS (
         SELECT 1 FROM pg_catalog.pg_proc p
         JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
       )
       AND NOT EXISTS (
         SELECT 1 FROM pg_catalog.pg_type t
         JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
         WHERE n.nspname = 'public' AND t.typtype IN ('d', 'e', 'r')
       )")"
  if [[ "$clean_target" != 't' ]]; then
    printf 'REFUSED: staging database is not empty and has no harness ledger; no schema was changed\n' >&2
    exit 24
  fi
  psql_local -f "$SCRIPT_DIR/bootstrap-supabase-compat.sql"
fi
assert_local_staging_marker
psql_local -f "$SCRIPT_DIR/seed-stock-actors.sql"

recorded="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
recorded_count=0
if [[ -n "$recorded" ]]; then
  while IFS= read -r version; do
    expected="${versions[$recorded_count]:-}"
    expected="${expected%%|*}"
    if [[ -z "$expected" || "$version" != "$expected" ]]; then
      printf 'REFUSED: local staging migration ledger is not an expected prefix (unexpected version %q)\n' "$version" >&2
      exit 25
    fi
    recorded_count=$((recorded_count + 1))
  done <<< "$recorded"
fi

for index in "${!versions[@]}"; do
  spec="${versions[$index]}"
  version="${spec%%|*}"
  filename="${spec#*|}"
  if (( index < recorded_count )); then
    continue
  fi
  printf 'Applying local baseline migration %s\n' "$filename"
  psql_local -f "$STAGING_ROOT/supabase/migrations/$filename"
  psql_local -c "INSERT INTO quena_staging.applied_migrations(ordinal, version, filename) VALUES ($((index + 1)), '$version', '$filename')"
done

fixture_seeded="$(psql_local -Atqc "SELECT EXISTS (SELECT 1 FROM quena_staging.fixture_runs WHERE fixture_key = 'stock_foundation_v1')")"
if [[ "$fixture_seeded" != 't' ]]; then
  printf 'Seeding synthetic stock fixtures through the Phase 2B commit RPC\n'
  psql_local -f "$SCRIPT_DIR/seed-stock-fixtures.sql"
fi

printf '\nBaseline preparation finished through correction-intent fix 20260929171000. Migration 20260929180000 was NOT applied.\n'
psql_local -f "$SCRIPT_DIR/verify-stock-staging.sql"
