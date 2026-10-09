\set ON_ERROR_STOP on
\timing on
DO $guard$
BEGIN
  IF current_database()<>'quena_stock_staging'
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR inet_server_port()<>5432 OR current_setting('server_version_num')::integer/10000<>15
    OR current_setting('server_encoding')<>'UTF8'
    OR NOT EXISTS(SELECT 1 FROM quena_staging.environment WHERE name='quena_stock_staging') THEN
    RAISE EXCEPTION 'Refusing costing runtime matrix outside guarded local PostgreSQL staging';
  END IF;
END $guard$;

BEGIN;
SET LOCAL statement_timeout='90s';
SET LOCAL lock_timeout='10s';
SELECT id outlet_id FROM public.outlets WHERE code='QUENA-MART-1' AND is_active \gset
SELECT id product_valued FROM public.products WHERE sku='STG-FULL-A' \gset
SELECT id product_unvalued FROM public.products WHERE sku='STG-FULL-B' \gset
SELECT id product_zero FROM public.products WHERE sku='STG-STALE' \gset
SELECT source_import_row_id source_valued_row FROM public.product_costs WHERE product_id=:'product_valued'::uuid AND outlet_id=:'outlet_id'::uuid \gset
SELECT source_import_row_id source_zero_row FROM public.product_costs WHERE product_id=:'product_zero'::uuid AND outlet_id=:'outlet_id'::uuid \gset
SELECT id authority_period FROM public.stock_authority_periods WHERE outlet_id=:'outlet_id'::uuid AND ended_at IS NULL \gset
SELECT set_config('quena.cost_fixture.outlet',:'outlet_id',true);
SELECT set_config('quena.cost_fixture.product_valued',:'product_valued',true);
SELECT set_config('quena.cost_fixture.product_unvalued',:'product_unvalued',true);
SELECT set_config('quena.cost_fixture.product_zero',:'product_zero',true);
SELECT set_config('quena.cost_fixture.source_valued',:'source_valued_row',true);
SELECT set_config('quena.cost_fixture.source_zero',:'source_zero_row',true);

DO $fixtures$
DECLARE
  v_outlet uuid := current_setting('quena.cost_fixture.outlet')::uuid;
  v_product_valued uuid := current_setting('quena.cost_fixture.product_valued')::uuid;
  v_product_unvalued uuid := current_setting('quena.cost_fixture.product_unvalued')::uuid;
  v_product_zero uuid := current_setting('quena.cost_fixture.product_zero')::uuid;
  v_source_valued uuid := current_setting('quena.cost_fixture.source_valued')::uuid;
  v_source_zero uuid := current_setting('quena.cost_fixture.source_zero')::uuid;
BEGIN
  IF v_source_valued IS NULL OR v_source_zero IS NULL THEN RAISE EXCEPTION 'Fixture HPP provenance is missing'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.stock_balance_projection WHERE outlet_id=v_outlet
    AND product_id IN (v_product_valued,v_product_unvalued,v_product_zero) AND effective_quantity>0) THEN
    RAISE EXCEPTION 'Expected positive stock fixture rows are unavailable';
  END IF;
  INSERT INTO public.product_field_audit_reviews(product_id,outlet_id,field_key,status,
    source_import_row_id,reviewer_id,evidence_notes,request_id)
  VALUES (v_product_valued,v_outlet,'hpp','SUDAH_DIVERIFIKASI',v_source_valued,
    'a0000000-0000-4000-8000-000000000001','Synthetic costing bootstrap fixture verification',gen_random_uuid()),
    (v_product_zero,v_outlet,'hpp','SUDAH_DIVERIFIKASI',v_source_zero,
    'a0000000-0000-4000-8000-000000000001','Synthetic zero-stock bootstrap fixture verification',gen_random_uuid());
  UPDATE public.product_costs SET hpp=NULL,updated_by='a0000000-0000-4000-8000-000000000001'
    WHERE product_id=v_product_unvalued AND outlet_id=v_outlet;
  UPDATE public.stock_balance_projection SET unreconciled_movement_delta=-baseline_quantity,updated_at=now()
    WHERE product_id=v_product_zero AND outlet_id=v_outlet;
  IF (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id=v_product_zero AND outlet_id=v_outlet)<>0 THEN
    RAISE EXCEPTION 'Zero-stock costing fixture setup failed';
  END IF;
END $fixtures$;

SELECT md5(string_agg(product_id::text||':'||effective_quantity::text||':'||balance_version::text,
  E'\n' ORDER BY product_id)) before_value INTO TEMP TABLE costing_stock_before
FROM public.stock_balance_projection WHERE outlet_id=:'outlet_id'::uuid;
SELECT md5(string_agg(product_id::text||':'||coalesce(quantity::text,'NULL'),E'\n' ORDER BY product_id)) before_value
  INTO TEMP TABLE costing_inventory_before FROM public.product_inventory WHERE outlet_id=:'outlet_id'::uuid;
SELECT md5(string_agg(product_id::text||':'||coalesce(hpp::text,'NULL')||':'||coalesce(source_import_row_id::text,''),
  E'\n' ORDER BY product_id)) before_value INTO TEMP TABLE costing_hpp_before
FROM public.product_costs WHERE outlet_id=:'outlet_id'::uuid;

SELECT gen_random_uuid()::text bootstrap_request \gset
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT set_config('quena.costing_bootstrap_result',
  public.inventory_cost_bootstrap_outlet(:'outlet_id'::uuid,:'bootstrap_request'::uuid)::text,true);
SELECT set_config('quena.costing_bootstrap_replay',
  public.inventory_cost_bootstrap_outlet(:'outlet_id'::uuid,:'bootstrap_request'::uuid)::text,true);
RESET ROLE;

DO $bootstrap_assertions$
DECLARE
  v_result jsonb := current_setting('quena.costing_bootstrap_result')::jsonb;
  v_replay jsonb := current_setting('quena.costing_bootstrap_replay')::jsonb;
  v_outlet uuid := current_setting('quena.cost_fixture.outlet')::uuid;
  v_product_valued uuid := current_setting('quena.cost_fixture.product_valued')::uuid;
  v_product_unvalued uuid := current_setting('quena.cost_fixture.product_unvalued')::uuid;
  v_product_zero uuid := current_setting('quena.cost_fixture.product_zero')::uuid;
  v_expected numeric;
  v_projection public.inventory_cost_projections%rowtype;
BEGIN
  IF v_result->>'code'<>'BOOTSTRAP_READY' OR v_result->>'authorityStatus'<>'BOOTSTRAP_READY'
    OR v_result->>'productCount' IS NULL THEN RAISE EXCEPTION 'BOOTSTRAP_RESULT_INVALID: %',v_result; END IF;
  IF v_result IS DISTINCT FROM v_replay THEN RAISE EXCEPTION 'BOOTSTRAP_REPLAY_CHANGED_RESULT'; END IF;
  SELECT effective_quantity*500 INTO v_expected FROM public.stock_balance_projection
    WHERE outlet_id=v_outlet AND product_id=v_product_valued;
  SELECT * INTO v_projection FROM public.inventory_cost_projections
    WHERE outlet_id=v_outlet AND product_id=v_product_valued;
  IF v_projection.valuation_status<>'VALUED' OR v_projection.current_wac<>500
    OR v_projection.inventory_value<>round(v_expected,8)
    OR v_projection.valued_quantity<>(SELECT effective_quantity FROM public.stock_balance_projection
      WHERE outlet_id=v_outlet AND product_id=v_product_valued) THEN
    RAISE EXCEPTION 'VALID_HPP_BOOTSTRAP_MISMATCH';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.inventory_cost_events e
      WHERE e.outlet_id=v_outlet AND e.product_id=v_product_valued AND e.event_type='OPENING'
        AND e.physical_quantity_before=0 AND e.physical_quantity_delta=(SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=v_outlet AND product_id=v_product_valued)
        AND e.physical_quantity_after=e.physical_quantity_delta
        AND e.valued_quantity_before=0 AND e.valued_quantity_delta=e.valued_quantity_after
        AND e.valued_quantity_after=e.physical_quantity_after
        AND e.provisional_quantity_before=0 AND e.provisional_quantity_delta=0 AND e.provisional_quantity_after=0
        AND e.unvalued_quantity_before=0 AND e.unvalued_quantity_delta=0 AND e.unvalued_quantity_after=0
        AND e.inventory_value_before=0 AND e.inventory_value_delta=e.inventory_value_after
        AND e.inventory_value_after=v_projection.inventory_value AND e.wac_after=v_projection.current_wac) THEN
    RAISE EXCEPTION 'VALUED_OPENING_EVENT_DOES_NOT_RECONCILE';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.inventory_cost_projections cp
    WHERE cp.outlet_id=v_outlet AND cp.product_id=v_product_unvalued
      AND cp.valuation_status='UNVALUED'
      AND cp.physical_quantity=(SELECT effective_quantity FROM public.stock_balance_projection
        WHERE outlet_id=v_outlet AND product_id=v_product_unvalued)
      AND cp.valued_quantity=0 AND cp.unvalued_quantity=cp.physical_quantity
      AND cp.inventory_value IS NULL AND cp.current_wac IS NULL) THEN
    RAISE EXCEPTION 'MISSING_HPP_WAS_NOT_LEFT_UNVALUED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.inventory_cost_events e
      WHERE e.outlet_id=v_outlet AND e.product_id=v_product_unvalued AND e.event_type='OPENING'
        AND e.physical_quantity_before=0 AND e.physical_quantity_delta=e.physical_quantity_after
        AND e.valued_quantity_before=0 AND e.valued_quantity_delta=0 AND e.valued_quantity_after=0
        AND e.unvalued_quantity_before=0 AND e.unvalued_quantity_delta=e.physical_quantity_after
        AND e.unvalued_quantity_after=e.physical_quantity_after AND e.provisional_quantity_delta=0
        AND e.valuation_basis='UNVALUED' AND e.frozen_unit_cost IS NULL
        AND e.inventory_value_after IS NULL AND e.wac_after IS NULL) THEN
    RAISE EXCEPTION 'UNVALUED_OPENING_EVENT_DOES_NOT_RECONCILE';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.inventory_cost_projections cp
    WHERE cp.outlet_id=v_outlet AND cp.product_id=v_product_zero
      AND cp.valuation_status='VALUED' AND cp.valued_quantity=0
      AND cp.inventory_value=0 AND cp.current_wac IS NULL) THEN
    RAISE EXCEPTION 'ZERO_STOCK_BOOTSTRAP_SEMANTICS_INVALID';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.inventory_cost_events e
      WHERE e.outlet_id=v_outlet AND e.product_id=v_product_zero AND e.event_type='OPENING'
        AND e.physical_quantity_before=0 AND e.physical_quantity_delta=0 AND e.physical_quantity_after=0
        AND e.valued_quantity_before=0 AND e.valued_quantity_delta=0 AND e.valued_quantity_after=0
        AND e.provisional_quantity_before=0 AND e.provisional_quantity_delta=0 AND e.provisional_quantity_after=0
        AND e.unvalued_quantity_before=0 AND e.unvalued_quantity_delta=0 AND e.unvalued_quantity_after=0
        AND e.inventory_value_before=0 AND e.inventory_value_delta=0 AND e.inventory_value_after=0
        AND e.wac_after IS NULL AND e.valuation_status_after='VALUED') THEN
    RAISE EXCEPTION 'ZERO_STOCK_OPENING_EVENT_DOES_NOT_RECONCILE';
  END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_cost_projections cp
    JOIN public.inventory_cost_events e ON e.id=cp.last_cost_event_id
    WHERE cp.outlet_id=v_outlet AND (cp.cost_version<>e.cost_version_after
      OR cp.stock_balance_version<>e.stock_balance_version OR e.actor_id<>'a0000000-0000-4000-8000-000000000001')) THEN
    RAISE EXCEPTION 'COST_VERSION_EVENT_LINKAGE_INVALID';
  END IF;
  IF (SELECT before_value FROM costing_stock_before)<>
    (SELECT md5(string_agg(product_id::text||':'||effective_quantity::text||':'||balance_version::text,
      E'\n' ORDER BY product_id)) FROM public.stock_balance_projection WHERE outlet_id=v_outlet) THEN
    RAISE EXCEPTION 'BOOTSTRAP_CHANGED_STOCK_PROJECTION';
  END IF;
  IF (SELECT before_value FROM costing_inventory_before)<>
    (SELECT md5(string_agg(product_id::text||':'||coalesce(quantity::text,'NULL'),E'\n' ORDER BY product_id))
      FROM public.product_inventory WHERE outlet_id=v_outlet) THEN RAISE EXCEPTION 'BOOTSTRAP_CHANGED_PRODUCT_INVENTORY'; END IF;
  IF (SELECT before_value FROM costing_hpp_before)<>
    (SELECT md5(string_agg(product_id::text||':'||coalesce(hpp::text,'NULL')||':'||coalesce(source_import_row_id::text,''),
      E'\n' ORDER BY product_id)) FROM public.product_costs WHERE outlet_id=v_outlet) THEN RAISE EXCEPTION 'BOOTSTRAP_CHANGED_HPP_SOURCE'; END IF;
END $bootstrap_assertions$;

-- A new UUID must never reset an already bootstrapped outlet.
SELECT gen_random_uuid()::text new_bootstrap_request \gset
SET LOCAL ROLE authenticated;
SELECT set_config('quena.costing_second_bootstrap',
  public.inventory_cost_bootstrap_outlet(:'outlet_id'::uuid,:'new_bootstrap_request'::uuid)::text,true);
RESET ROLE;
DO $second_bootstrap_assertion$
BEGIN
  IF current_setting('quena.costing_second_bootstrap')::jsonb->>'code'<>'ALREADY_BOOTSTRAPPED' THEN
    RAISE EXCEPTION 'NEW_BOOTSTRAP_REQUEST_RESET_EXISTING_CUTOVER';
  END IF;
END $second_bootstrap_assertion$;

-- OWNER and ADMIN can use the bounded manager read contract.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
SET LOCAL ROLE authenticated;
SELECT set_config('quena.costing_admin_read',public.inventory_cost_projection_page(:'outlet_id'::uuid,NULL,1,100)::text,true);
RESET ROLE;
DO $admin_read$
BEGIN
  IF current_setting('quena.costing_admin_read')::jsonb->>'ok'<>'true'
    OR current_setting('quena.costing_admin_read')::jsonb->>'pageSize'<>'100' THEN
    RAISE EXCEPTION 'ADMIN_COST_READ_FAILED_OR_PAGE_NOT_BOUNDED';
  END IF;
END $admin_read$;

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
SELECT set_config('quena.gudang_cost_read',public.inventory_cost_projection_page(:'outlet_id'::uuid,NULL,1,50)::text,true);
SELECT set_config('quena.gudang_projection_rows',(SELECT count(*)::text FROM public.inventory_cost_projections),true);
SELECT set_config('quena.gudang_event_rows',(SELECT count(*)::text FROM public.inventory_cost_events),true);
SELECT set_config('quena.gudang_batch_rows',(SELECT count(*)::text FROM public.inventory_cost_event_batches),true);
SELECT set_config('quena.gudang_authority_rows',(SELECT count(*)::text FROM public.inventory_costing_outlet_authority),true);
DO $gudang_write$
DECLARE blocked boolean := false;
BEGIN
  BEGIN EXECUTE 'UPDATE public.inventory_cost_projections SET inventory_value=0';
  EXCEPTION WHEN insufficient_privilege THEN blocked := true; END;
  IF NOT blocked THEN RAISE EXCEPTION 'GUDANG_DIRECT_COST_WRITE_WAS_NOT_DENIED'; END IF;
END $gudang_write$;
RESET ROLE;
DO $gudang_read$
BEGIN
  IF current_setting('quena.gudang_cost_read')::jsonb->>'code'<>'FORBIDDEN'
    OR current_setting('quena.gudang_projection_rows')<>'0'
    OR current_setting('quena.gudang_event_rows')<>'0'
    OR current_setting('quena.gudang_batch_rows')<>'0'
    OR current_setting('quena.gudang_authority_rows')<>'0' THEN RAISE EXCEPTION 'GUDANG_COST_DATA_EXPOSED'; END IF;
END $gudang_read$;

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
SET LOCAL ROLE authenticated;
SELECT set_config('quena.kasir_cost_read',public.inventory_cost_projection_page(:'outlet_id'::uuid,NULL,1,50)::text,true);
SELECT set_config('quena.kasir_projection_rows',(SELECT count(*)::text FROM public.inventory_cost_projections),true);
SELECT set_config('quena.kasir_event_rows',(SELECT count(*)::text FROM public.inventory_cost_events),true);
SELECT set_config('quena.kasir_batch_rows',(SELECT count(*)::text FROM public.inventory_cost_event_batches),true);
SELECT set_config('quena.kasir_authority_rows',(SELECT count(*)::text FROM public.inventory_costing_outlet_authority),true);
RESET ROLE;
DO $kasir_read$
BEGIN
  IF current_setting('quena.kasir_cost_read')::jsonb->>'code'<>'FORBIDDEN'
    OR current_setting('quena.kasir_projection_rows')<>'0'
    OR current_setting('quena.kasir_event_rows')<>'0'
    OR current_setting('quena.kasir_batch_rows')<>'0'
    OR current_setting('quena.kasir_authority_rows')<>'0' THEN RAISE EXCEPTION 'KASIR_COST_DATA_EXPOSED'; END IF;
END $kasir_read$;

-- Authenticated clients have no direct cost projection/event DML. Ledger triggers also reject privileged edits.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
DO $client_write_guards$
DECLARE blocked boolean := false;
BEGIN
  BEGIN EXECUTE 'UPDATE public.inventory_cost_projections SET current_wac=0';
  EXCEPTION WHEN insufficient_privilege THEN blocked := true; END;
  IF NOT blocked THEN RAISE EXCEPTION 'OWNER_DIRECT_COST_WRITE_WAS_NOT_DENIED'; END IF;
END $client_write_guards$;
RESET ROLE;
DO $ledger_guards$
DECLARE v_event uuid; blocked_update boolean := false; blocked_delete boolean := false;
BEGIN
  SELECT id INTO v_event FROM public.inventory_cost_events ORDER BY id LIMIT 1;
  BEGIN UPDATE public.inventory_cost_events SET metadata=metadata WHERE id=v_event;
  EXCEPTION WHEN SQLSTATE '55000' THEN blocked_update := true; END;
  BEGIN DELETE FROM public.inventory_cost_events WHERE id=v_event;
  EXCEPTION WHEN SQLSTATE '55000' THEN blocked_delete := true; END;
  IF NOT blocked_update OR NOT blocked_delete THEN RAISE EXCEPTION 'COST_EVENT_IMMUTABILITY_GUARD_FAILED'; END IF;
END $ledger_guards$;

DO $numeric_guards$
DECLARE v_projection public.inventory_cost_projections%rowtype; v_rejected boolean := false;
BEGIN
  SELECT * INTO v_projection FROM public.inventory_cost_projections
    WHERE valuation_status='VALUED' AND valued_quantity>0 ORDER BY product_id LIMIT 1;
  IF (SELECT format_type(a.atttypid,a.atttypmod) FROM pg_catalog.pg_attribute a
    WHERE a.attrelid='public.inventory_cost_projections'::regclass AND a.attname='current_wac')<>'numeric(20,8)'
    OR (SELECT format_type(a.atttypid,a.atttypmod) FROM pg_catalog.pg_attribute a
    WHERE a.attrelid='public.inventory_cost_projections'::regclass AND a.attname='inventory_value')<>'numeric(32,8)' THEN
    RAISE EXCEPTION 'COST_PRECISION_SCHEMA_MISMATCH';
  END IF;
  IF 0.12345678::numeric(20,8)<>0.12345678 THEN RAISE EXCEPTION 'FRACTIONAL_RUPIAH_PRECISION_LOST'; END IF;
  BEGIN
    UPDATE public.inventory_cost_projections SET inventory_value=-0.01 WHERE outlet_id=v_projection.outlet_id AND product_id=v_projection.product_id;
    RAISE EXCEPTION 'EXPECTED_NEGATIVE_VALUATION_REJECTION' USING ERRCODE='P0001';
  EXCEPTION WHEN check_violation THEN v_rejected := true; END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'NEGATIVE_INVENTORY_VALUE_WAS_ACCEPTED'; END IF;
END $numeric_guards$;

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT public.inventory_cost_bootstrap_outlet(:'outlet_id'::uuid,:'bootstrap_request'::uuid) IS NOT NULL AS owner_bootstrap_replay;
RESET ROLE;
ROLLBACK;
