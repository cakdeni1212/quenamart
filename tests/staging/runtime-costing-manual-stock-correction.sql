-- Rollback-only C3C integration checks against a disposable local clone.
\set ON_ERROR_STOP on
\timing on
DO $guard$
BEGIN
  IF current_database() NOT LIKE 'quena_c3c_staging_%' OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR inet_server_port()<>55432 OR current_setting('server_version_num')::integer/10000<>15
    OR NOT EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929300000')
    OR NOT EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929310000') THEN
    RAISE EXCEPTION 'Refusing C3C runtime outside disposable local staging clone';
  END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_event_batches)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections) THEN
    RAISE EXCEPTION 'C3C runtime requires rollback-clean costing fixture';
  END IF;
END; $guard$;

CREATE FUNCTION pg_temp.c3c_post_estimated_receipt(p_outlet uuid,p_product uuid,p_quantity numeric,p_unit_price numeric)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_supplier uuid; v_receipt uuid; v_item uuid; v_request uuid; v_result jsonb;
BEGIN
  v_supplier:=public.purchase_supplier_upsert(NULL,'C3C source layer fixture supplier',NULL,NULL,NULL,true);
  v_receipt:=public.purchase_receipt_create_draft(p_outlet,v_supplier,now(),'C3C WAC/provenance runtime fixture');
  PERFORM public.purchase_receipt_save_draft(v_receipt,1,now(),NULL,jsonb_build_array(jsonb_build_object(
    'product_id',p_product,'accepted_quantity',p_quantity,'bonus_quantity',0,'rejected_quantity',0)));
  SELECT id INTO STRICT v_item FROM public.purchase_receipt_items WHERE receipt_id=v_receipt AND product_id=p_product;
  PERFORM public.purchase_receipt_acquisition_estimate_save(v_receipt,v_item,2,0,'MANAGER_ESTIMATE',p_unit_price,NULL,'C3C isolated fixture');
  v_request:=public.issue_purchase_receipt_post_intent(v_receipt);
  v_result:=public.apply_purchase_receipt_post_intent(v_request);
  IF v_result->>'code'<>'POSTED' THEN RAISE EXCEPTION 'C3C receipt fixture failed: %',v_result; END IF;
  RETURN v_receipt;
END; $$;

BEGIN;
SET LOCAL statement_timeout='90s';
SET LOCAL lock_timeout='8s';
DO $matrix$
<<matrix>>
DECLARE
  owner_id uuid:='a0000000-0000-4000-8000-000000000001';
  admin_id uuid:='a0000000-0000-4000-8000-000000000002';
  gudang_id uuid:='a0000000-0000-4000-8000-000000000003';
  kasir_id uuid:='a0000000-0000-4000-8000-000000000004';
  outlet uuid; product uuid; second_product uuid; before_qty numeric; after_qty numeric;
  v_correction_id uuid; request_id uuid; result jsonb; replay jsonb; denied text;
  movement_id uuid; movement_id_two uuid; reversal_request uuid; value_before numeric; source_layer uuid;
  bootstrap_result jsonb; receipt_id uuid; wac_before numeric; original_cost_event public.inventory_cost_events%rowtype;
  correction_item_id uuid; reversal_cost_event public.inventory_cost_events%rowtype; value_after_later_receipt numeric;
BEGIN
  SELECT id INTO STRICT outlet FROM public.outlets WHERE code='QUENA-MART-1' AND is_active;
  SELECT id INTO STRICT product FROM public.products WHERE sku='STG-BASE20';
  SELECT id INTO STRICT second_product FROM public.products WHERE sku='STG-FULL-B';
  SELECT effective_quantity INTO STRICT before_qty FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product;
  PERFORM set_config('request.jwt.claim.sub',owner_id::text,true);
  PERFORM set_config('role','authenticated',true);

  -- REFERENCE_ONLY posts stock in/out, replays the same result, and creates no cost records.
  result:=public.create_manual_stock_correction(outlet,'FOUND','Fixture stock added outside receiving',
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity_delta',3,'note','reference in')));
  v_correction_id:=(result->>'id')::uuid; request_id:=gen_random_uuid();
  result:=public.post_manual_stock_correction(v_correction_id,request_id);
  replay:=public.post_manual_stock_correction(v_correction_id,request_id);
  IF result IS DISTINCT FROM replay OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product)<>before_qty+3
    OR (SELECT count(*) FROM public.stock_movements WHERE manual_stock_correction_id=v_correction_id)<>1
    OR EXISTS(SELECT 1 FROM public.inventory_cost_events) THEN RAISE EXCEPTION 'REFERENCE_ONLY in/replay failed'; END IF;
  denied:=NULL;
  BEGIN PERFORM public.post_manual_stock_correction(v_correction_id,gen_random_uuid());
  EXCEPTION WHEN unique_violation THEN denied:=SQLSTATE; END;
  IF denied IS DISTINCT FROM '23505' OR (SELECT count(*) FROM public.stock_movements WHERE manual_stock_correction_id=v_correction_id)<>1
    THEN RAISE EXCEPTION 'different request duplicated a posted correction'; END IF;
  SELECT effective_quantity INTO before_qty FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product;
  result:=public.create_manual_stock_correction(outlet,'DAMAGED','Fixture stock removal',
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity_delta',-2)));
  v_correction_id:=(result->>'id')::uuid; PERFORM public.post_manual_stock_correction(v_correction_id,gen_random_uuid());
  IF (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product)<>before_qty-2
    OR EXISTS(SELECT 1 FROM public.inventory_cost_events) THEN RAISE EXCEPTION 'REFERENCE_ONLY out failed'; END IF;

  -- Three-decimal quantity and all-or-nothing multi-product validation.
  result:=public.create_manual_stock_correction(outlet,'FOUND','Fractional stock correction fixture',
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity_delta',0.125)));
  v_correction_id:=(result->>'id')::uuid; request_id:=gen_random_uuid();
  PERFORM public.post_manual_stock_correction(v_correction_id,request_id);
  IF (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product)<>before_qty-2+0.125
    THEN RAISE EXCEPTION 'three-decimal stock correction failed'; END IF;
  SELECT effective_quantity INTO before_qty FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product;
  result:=public.create_manual_stock_correction(outlet,'OTHER','All lines must succeed atomically',jsonb_build_array(
    jsonb_build_object('product_id',product,'quantity_delta',1),jsonb_build_object('product_id',second_product,'quantity_delta',-99999999999)));
  v_correction_id:=(result->>'id')::uuid; request_id:=gen_random_uuid(); denied:=NULL;
  BEGIN PERFORM public.post_manual_stock_correction(v_correction_id,request_id);
  EXCEPTION WHEN check_violation OR invalid_parameter_value THEN denied:=SQLSTATE; END;
  PERFORM set_config('role','none',true);
  IF denied IS NULL OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product)<>before_qty
    OR EXISTS(SELECT 1 FROM public.stock_movement_batches b WHERE b.operation_request_id=matrix.request_id)
    OR EXISTS(SELECT 1 FROM public.stock_operation_requests sor WHERE sor.request_id=matrix.request_id)
    THEN RAISE EXCEPTION 'multi-product invalid correction partially posted'; END IF;
  PERFORM set_config('role','authenticated',true);

  -- Stable draft line ID, audit update, cancel, and role denial.
  result:=public.create_manual_stock_correction(outlet,'OTHER','Documented test correction reason',
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity_delta',1)));
  v_correction_id:=(result->>'id')::uuid;
  IF (SELECT count(*) FROM public.manual_stock_correction_items i WHERE i.correction_id=v_correction_id)<>1 THEN RAISE EXCEPTION 'draft line missing'; END IF;
  PERFORM public.update_manual_stock_correction(v_correction_id,1,'OTHER','Revised documented test correction',
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity_delta',2)));
  IF (SELECT count(*) FROM public.manual_stock_correction_events e WHERE e.correction_id=v_correction_id AND e.event_type='UPDATED')<>1
    OR (SELECT quantity_delta FROM public.manual_stock_correction_items i WHERE i.correction_id=v_correction_id)<>2
    THEN RAISE EXCEPTION 'draft update/audit failed'; END IF;
  PERFORM public.cancel_manual_stock_correction(v_correction_id,'Fixture is no longer required');
  PERFORM set_config('request.jwt.claim.sub',gudang_id::text,true); denied:=NULL;
  BEGIN PERFORM public.create_manual_stock_correction(outlet,'FOUND','GUDANG denied fixture',jsonb_build_array(jsonb_build_object('product_id',product,'quantity_delta',1)));
  EXCEPTION WHEN insufficient_privilege THEN denied:=SQLSTATE; END;
  IF denied IS DISTINCT FROM '42501' THEN RAISE EXCEPTION 'GUDANG allowed'; END IF;
  PERFORM set_config('request.jwt.claim.sub',kasir_id::text,true); denied:=NULL;
  BEGIN PERFORM public.create_manual_stock_correction(outlet,'FOUND','KASIR denied fixture',jsonb_build_array(jsonb_build_object('product_id',product,'quantity_delta',1)));
  EXCEPTION WHEN insufficient_privilege THEN denied:=SQLSTATE; END;
  IF denied IS DISTINCT FROM '42501' THEN RAISE EXCEPTION 'KASIR allowed'; END IF;

  -- Prepare WAC fixture with existing verified HPP evidence; correction remains retryable at BOOTSTRAP_READY.
  PERFORM set_config('request.jwt.claim.sub',owner_id::text,true);
  result:=public.create_manual_stock_correction(outlet,'FOUND','Bootstrap gate retry fixture',
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity_delta',3)));
  v_correction_id:=(result->>'id')::uuid; request_id:=gen_random_uuid();
  PERFORM set_config('role','none',true);
  INSERT INTO public.product_field_audit_reviews(product_id,outlet_id,field_key,status,source_import_row_id,reviewer_id,evidence_notes,request_id)
    SELECT product,outlet,'hpp','SUDAH_DIVERIFIKASI',source_import_row_id,owner_id,'C3C staging fixture',gen_random_uuid()
    FROM public.product_costs WHERE product_id=product AND outlet_id=outlet;
  bootstrap_result:=public.inventory_cost_bootstrap_outlet(outlet,'d1000000-0000-4000-8000-000000000310');
  IF bootstrap_result->>'code'<>'BOOTSTRAP_READY' THEN RAISE EXCEPTION 'bootstrap fixture failed: %',bootstrap_result; END IF;
  SELECT effective_quantity INTO before_qty FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product;
  denied:=NULL;
  BEGIN PERFORM public.post_manual_stock_correction(v_correction_id,request_id);
  EXCEPTION WHEN SQLSTATE '55000' THEN denied:=SQLSTATE; END;
  IF denied IS DISTINCT FROM '55000' OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product)<>before_qty
    OR EXISTS(SELECT 1 FROM public.stock_operation_requests sor WHERE sor.request_id=matrix.request_id)
    THEN RAISE EXCEPTION 'BOOTSTRAP_READY mutated stock/request'; END IF;
  UPDATE public.inventory_costing_outlet_authority SET status='WAC_ACTIVE',activated_by=owner_id,activated_at=now() WHERE outlet_id=outlet;
  PERFORM set_config('role','authenticated',true);
  value_before:=(SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=product);
  result:=public.post_manual_stock_correction(v_correction_id,request_id);
  replay:=public.post_manual_stock_correction(v_correction_id,request_id);
  IF result IS DISTINCT FROM replay OR (SELECT count(*) FROM public.inventory_cost_events WHERE manual_stock_correction_id=v_correction_id)<>1
    OR (SELECT count(*) FROM public.stock_movements WHERE manual_stock_correction_id=v_correction_id)<>1
    THEN RAISE EXCEPTION 'WAC_ACTIVE same-request replay duplicated stock or cost'; END IF;
  SELECT id INTO STRICT source_layer FROM public.inventory_cost_source_layers WHERE manual_stock_correction_id=v_correction_id;
  IF (SELECT remaining_unvalued_quantity FROM public.inventory_cost_source_layer_balances WHERE layer_id=source_layer)<>3
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=product)<>value_before
    THEN RAISE EXCEPTION 'WAC_ACTIVE manual IN did not remain unvalued'; END IF;

  -- WAC manual OUT consumes unvalued first; exact reversal restores the recorded value/allocation.
  result:=public.create_manual_stock_correction(outlet,'DAMAGED','Unvalued-first correction outflow fixture',
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity_delta',-2)));
  v_correction_id:=(result->>'id')::uuid; request_id:=gen_random_uuid();
  PERFORM public.post_manual_stock_correction(v_correction_id,request_id);
  IF (SELECT unvalued_quantity FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=product)<>1
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=product)<>value_before
    THEN RAISE EXCEPTION 'WAC manual OUT did not consume unvalued first'; END IF;
  SELECT m.id INTO STRICT movement_id FROM public.stock_movement_batches b JOIN public.stock_movements m ON m.batch_id=b.id
    WHERE b.operation_request_id=request_id;
  reversal_request:=public.issue_stock_operation_intent('REVERSE_MOVEMENT',jsonb_build_object('movement_id',movement_id,'reason','C3C exact inverse test'));
  result:=public.apply_stock_operation_intent(reversal_request);
  IF coalesce((result->>'ok')::boolean,false) IS NOT TRUE
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=product)<>value_before
    THEN RAISE EXCEPTION 'WAC reversal did not restore the original cost effect'; END IF;

  -- Exhaust the correction's unvalued layer, then deplete valued stock at aggregate WAC.
  result:=public.create_manual_stock_correction(outlet,'DAMAGED','Clear unvalued correction layer',
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity_delta',-3)));
  v_correction_id:=(result->>'id')::uuid; request_id:=gen_random_uuid();
  PERFORM public.post_manual_stock_correction(v_correction_id,request_id);
  IF (SELECT unvalued_quantity FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=product)<>0
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=product)<>value_before
    THEN RAISE EXCEPTION 'unvalued layer depletion changed value'; END IF;
  result:=public.create_manual_stock_correction(outlet,'DAMAGED','Valued stock uses current aggregate WAC',
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity_delta',-2)));
  v_correction_id:=(result->>'id')::uuid; request_id:=gen_random_uuid();
  PERFORM public.post_manual_stock_correction(v_correction_id,request_id);
  IF (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=product)<>value_before-2*500
    THEN RAISE EXCEPTION 'valued stock depletion did not use aggregate WAC'; END IF;
  SELECT m.id INTO STRICT movement_id FROM public.stock_movement_batches b JOIN public.stock_movements m ON m.batch_id=b.id
    WHERE b.operation_request_id=request_id;
  reversal_request:=public.issue_stock_operation_intent('REVERSE_MOVEMENT',jsonb_build_object('movement_id',movement_id,'reason','C3C aggregate WAC reversal test'));
  result:=public.apply_stock_operation_intent(reversal_request);
  IF coalesce((result->>'ok')::boolean,false) IS NOT TRUE
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=product)<>value_before
    THEN RAISE EXCEPTION 'valued correction reversal did not restore recorded value'; END IF;

  -- Distinct historical source prices prove financial depletion follows aggregate WAC.
  receipt_id:=pg_temp.c3c_post_estimated_receipt(outlet,product,5,8000);
  receipt_id:=pg_temp.c3c_post_estimated_receipt(outlet,product,5,12000);
  SELECT current_wac,inventory_value INTO wac_before,value_before FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=product;
  result:=public.create_manual_stock_correction(outlet,'DAMAGED','Proportional source allocation WAC fixture',
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity_delta',-2)));
  v_correction_id:=(result->>'id')::uuid; request_id:=gen_random_uuid();
  SELECT i.id INTO STRICT correction_item_id FROM public.manual_stock_correction_items i WHERE i.correction_id=v_correction_id;
  PERFORM public.post_manual_stock_correction(v_correction_id,request_id);
  SELECT * INTO STRICT original_cost_event FROM public.inventory_cost_events WHERE manual_stock_correction_item_id=correction_item_id;
  IF original_cost_event.inventory_value_delta IS DISTINCT FROM -round(2*wac_before,8)
    OR original_cost_event.inventory_value_delta IN (-16000,-24000)
    OR (SELECT sum(valued_quantity_delta) FROM public.inventory_cost_layer_allocations WHERE cost_event_id=original_cost_event.id)<>-2
    OR (SELECT sum(provisional_quantity_delta) FROM public.inventory_cost_layer_allocations WHERE cost_event_id=original_cost_event.id)<>original_cost_event.provisional_quantity_delta
    THEN RAISE EXCEPTION 'source acquisition values changed aggregate WAC depletion or provenance did not reconcile'; END IF;
  SELECT m.id INTO STRICT movement_id FROM public.stock_movement_batches b JOIN public.stock_movements m ON m.batch_id=b.id
    WHERE b.operation_request_id=request_id;
  receipt_id:=pg_temp.c3c_post_estimated_receipt(outlet,product,1,16000);
  SELECT inventory_value INTO value_after_later_receipt FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=product;
  reversal_request:=public.issue_stock_operation_intent('REVERSE_MOVEMENT',jsonb_build_object('movement_id',movement_id,'reason','C3C exact original valuation reversal'));
  result:=public.apply_stock_operation_intent(reversal_request);
  SELECT * INTO STRICT reversal_cost_event FROM public.inventory_cost_events WHERE reverses_cost_event_id=original_cost_event.id;
  IF reversal_cost_event.inventory_value_delta IS DISTINCT FROM -original_cost_event.inventory_value_delta
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=product)
      IS DISTINCT FROM value_after_later_receipt-original_cost_event.inventory_value_delta
    THEN RAISE EXCEPTION 'reversal used changed WAC instead of original event value' USING DETAIL=format(
      'original_delta=%s reversal_delta=%s after_later_receipt=%s after_reversal=%s',original_cost_event.inventory_value_delta,
      reversal_cost_event.inventory_value_delta,value_after_later_receipt,
      (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=product)); END IF;

  -- Later use of a source layer invalidates exact reversal of the earlier outflow.
  result:=public.create_manual_stock_correction(outlet,'DAMAGED','Dependent allocation reversal guard',
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity_delta',-1)));
  v_correction_id:=(result->>'id')::uuid; request_id:=gen_random_uuid();
  PERFORM public.post_manual_stock_correction(v_correction_id,request_id);
  SELECT m.id INTO STRICT movement_id FROM public.stock_movement_batches b JOIN public.stock_movements m ON m.batch_id=b.id
    WHERE b.operation_request_id=request_id;
  result:=public.create_manual_stock_correction(outlet,'DAMAGED','Later layer consumption fixture',
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity_delta',-1)));
  v_correction_id:=(result->>'id')::uuid; request_id:=gen_random_uuid();
  PERFORM public.post_manual_stock_correction(v_correction_id,request_id);
  SELECT m.id INTO STRICT movement_id_two FROM public.stock_movement_batches b JOIN public.stock_movements m ON m.batch_id=b.id
    WHERE b.operation_request_id=request_id;
  reversal_request:=public.issue_stock_operation_intent('REVERSE_MOVEMENT',jsonb_build_object('movement_id',movement_id,'reason','C3C dependent source use'));
  denied:=NULL;
  BEGIN PERFORM public.apply_stock_operation_intent(reversal_request);
  EXCEPTION WHEN SQLSTATE '55000' THEN denied:=SQLSTATE; END;
  IF denied IS DISTINCT FROM '55000' OR EXISTS(SELECT 1 FROM public.inventory_cost_events e JOIN public.stock_movements m
    ON m.id=e.source_stock_movement_id WHERE m.reverses_movement_id=movement_id AND e.reverses_cost_event_id IS NOT NULL)
    THEN RAISE EXCEPTION 'reversal should be blocked after dependent layer activity'; END IF;

  PERFORM set_config('request.jwt.claim.sub',admin_id::text,true);
  result:=public.create_manual_stock_correction(outlet,'OTHER','ADMIN manager access fixture',
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity_delta',1)));
  IF result->>'status'<>'DRAFT' THEN RAISE EXCEPTION 'ADMIN denied'; END IF;
  v_correction_id:=(result->>'id')::uuid;
  result:=public.post_manual_stock_correction(v_correction_id,gen_random_uuid());
  IF result->>'status'<>'POSTED' THEN RAISE EXCEPTION 'ADMIN post denied'; END IF;
  PERFORM set_config('request.jwt.claim.sub',gudang_id::text,true);
  IF (SELECT count(*) FROM public.manual_stock_corrections)<>0 OR (SELECT count(*) FROM public.inventory_cost_source_layers)<>0
    THEN RAISE EXCEPTION 'GUDANG reads protected correction or layer data'; END IF;
  PERFORM set_config('request.jwt.claim.sub',kasir_id::text,true);
  IF (SELECT count(*) FROM public.manual_stock_corrections)<>0 OR (SELECT count(*) FROM public.inventory_cost_source_layers)<>0
    THEN RAISE EXCEPTION 'KASIR reads protected correction or layer data'; END IF;
END; $matrix$;
ROLLBACK;
