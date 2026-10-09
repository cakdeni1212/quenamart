#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT
guard_local_target
assert_local_staging_marker
versions="$(psql_local -Atqc 'SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal')"
if [[ "$versions" != *$'20260929290000' ]]; then
  printf 'REFUSED: C3A must be the latest ledgered staging migration\n' >&2
  exit 218
fi
empty="$(psql_local -Atqc "SELECT
  (SELECT count(*)=0 FROM public.purchase_receipt_acquisition_estimate_revisions)
  AND (SELECT count(*)=0 FROM public.inventory_cost_events)
  AND (SELECT count(*)=0 FROM public.inventory_cost_event_batches)
  AND (SELECT count(*)=0 FROM public.inventory_cost_projections)
  AND (SELECT count(*)=0 FROM public.inventory_costing_outlet_authority)")"
if [[ "$empty" != t ]]; then
  printf 'REFUSED: C3A runtime data exists; review staging state, no rollback performed\n' >&2
  exit 219
fi

psql_local <<'SQL'
BEGIN;
DROP FUNCTION public.inventory_cost_apply_purchase_receipt(uuid,uuid,uuid,uuid);
DROP FUNCTION public.purchase_receipt_acquisition_estimate_save(uuid,uuid,integer,integer,text,numeric,text,text);
DROP FUNCTION public.append_purchase_receipt_estimate_revision(uuid,uuid,uuid,uuid,public.purchase_receipt_acquisition_evidence_kind,numeric,text,text);
DROP FUNCTION public.inventory_cost_projection_page(uuid,text,integer,integer);
DROP FUNCTION public.inventory_cost_bootstrap_outlet(uuid,uuid);
DROP FUNCTION public.apply_purchase_receipt_post_intent(uuid);
DROP FUNCTION public.issue_purchase_receipt_post_intent(uuid);
DROP FUNCTION public.purchase_receipt_save_draft(uuid,integer,timestamptz,text,jsonb);
DROP TRIGGER purchase_receipt_estimate_immutable ON public.purchase_receipt_acquisition_estimate_revisions;
DROP FUNCTION public.guard_purchase_receipt_acquisition_estimate_immutable();
DROP TABLE public.purchase_receipt_acquisition_estimate_revisions;
DROP INDEX public.inventory_cost_purchase_receipt_item_once;
ALTER TABLE public.inventory_cost_events
  DROP CONSTRAINT inventory_cost_event_receipt_item_identity_fk,
  DROP CONSTRAINT inventory_cost_event_stock_movement_identity_fk,
  DROP CONSTRAINT inventory_cost_event_projection_state_valid,
  ALTER COLUMN valuation_status_before TYPE public.inventory_cost_valuation_status
    USING valuation_status_before::text::public.inventory_cost_valuation_status,
  ALTER COLUMN valuation_status_after TYPE public.inventory_cost_valuation_status
    USING valuation_status_after::text::public.inventory_cost_valuation_status,
  DROP COLUMN physical_quantity_delta,
  DROP COLUMN physical_quantity_before,
  DROP COLUMN physical_quantity_after,
  DROP COLUMN IF EXISTS valued_quantity_delta,
  DROP COLUMN provisional_quantity_delta,
  DROP COLUMN provisional_quantity_before,
  DROP COLUMN provisional_quantity_after,
  DROP COLUMN unvalued_quantity_delta,
  DROP COLUMN unvalued_quantity_before,
  DROP COLUMN unvalued_quantity_after,
  DROP COLUMN valuation_basis,
  DROP COLUMN frozen_unit_cost,
  DROP COLUMN IF EXISTS basis_cost_event_id,
  DROP COLUMN receipt_id,
  DROP COLUMN receipt_item_id,
  DROP COLUMN stock_movement_id,
  DROP COLUMN stock_request_id,
  DROP COLUMN acquisition_evidence_revision;
ALTER TABLE public.inventory_cost_projections
  DROP CONSTRAINT inventory_cost_projection_state_consistent,
  DROP CONSTRAINT inventory_cost_projection_stock_quantity_fk,
  ALTER COLUMN valuation_status TYPE public.inventory_cost_valuation_status
    USING valuation_status::text::public.inventory_cost_valuation_status,
  ALTER COLUMN physical_quantity DROP NOT NULL,
  DROP COLUMN physical_quantity,
  DROP COLUMN provisional_quantity,
  DROP COLUMN unvalued_quantity,
  ADD CONSTRAINT inventory_cost_projection_valuation_consistent CHECK (
    (valuation_status='UNVALUED' AND inventory_value IS NULL AND current_wac IS NULL)
    OR (valuation_status IN ('VALUED','PROVISIONAL') AND valued_quantity IS NOT NULL
      AND ((valued_quantity=0 AND inventory_value=0 AND current_wac IS NULL)
        OR (valued_quantity>0 AND inventory_value IS NOT NULL AND current_wac IS NOT NULL)))
  );
ALTER TABLE public.purchase_receipt_items DROP CONSTRAINT purchase_receipt_item_receipt_product_identity;
ALTER TABLE public.inventory_cost_operation_requests
  DROP CONSTRAINT inventory_cost_operation_requests_operation_key_check,
  ADD CONSTRAINT inventory_cost_operation_requests_operation_key_check CHECK (operation_key='BOOTSTRAP_OUTLET');
DROP TYPE public.inventory_cost_acquisition_basis;
DROP TYPE public.purchase_receipt_acquisition_evidence_kind;
DROP TYPE public.inventory_cost_projection_status;
DELETE FROM quena_staging.applied_migrations WHERE version='20260929290000';
COMMIT;
SQL
printf 'PASS: empty local C3A schema rolled back; no business or production data was touched\n'
