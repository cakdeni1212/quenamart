#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT
guard_local_target
assert_local_staging_marker
version="$(psql_local -Atqc "SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal DESC LIMIT 1")"
if [[ "$version" != '20260929260000' ]]; then
  printf 'REFUSED: acceptance migration is not the latest staging ledger row; nothing rolled back\n' >&2
  exit 184
fi
printf 'Rolling back only uncommitted Checkpoint A objects from guarded local staging\n'
psql_local <<'SQL'
BEGIN;
DROP FUNCTION public.inventory_cost_initial_hpp_acceptance_preview(uuid,text,text,integer,integer);
DROP FUNCTION public.prepare_initial_hpp_acceptance(uuid,uuid);
DROP FUNCTION public.resolve_initial_hpp_acceptance_exception(uuid,uuid,public.inventory_cost_hpp_acceptance_disposition,numeric,text,uuid);
DROP FUNCTION public.approve_initial_hpp_acceptance(uuid,uuid);
DROP FUNCTION public.inventory_cost_hpp_acceptance_evaluate(uuid);
DROP TABLE public.inventory_cost_hpp_acceptance_events;
DROP TABLE public.inventory_cost_hpp_acceptance_items;
DROP TABLE public.inventory_cost_hpp_acceptance_batches;
DROP TABLE public.inventory_cost_hpp_acceptance_requests;
DROP FUNCTION public.guard_inventory_cost_hpp_acceptance_item();
DROP FUNCTION public.guard_inventory_cost_hpp_acceptance_batch();
DROP FUNCTION public.guard_inventory_cost_hpp_acceptance_event();
DROP TYPE public.inventory_cost_hpp_acceptance_event_type;
DROP TYPE public.inventory_cost_hpp_acceptance_operation;
DROP TYPE public.inventory_cost_hpp_acceptance_disposition;
DROP TYPE public.inventory_cost_hpp_acceptance_status;
DELETE FROM quena_staging.applied_migrations WHERE version='20260929260000';
COMMIT;
SQL
printf 'PASS: Checkpoint A objects removed from local staging only\n'
