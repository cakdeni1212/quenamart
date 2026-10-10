-- Rollback-only C3B integration smoke matrix. Uses synthetic guarded staging only.
\set ON_ERROR_STOP on
\timing on

DO $guard$
BEGIN
  IF current_database()<>'quena_stock_staging'
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR inet_server_port()<>5432
    OR current_setting('server_version_num')::integer/10000<>15
    OR current_setting('server_encoding')<>'UTF8' THEN
    RAISE EXCEPTION 'Refusing C3B runtime checks outside guarded local PostgreSQL 15 staging';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929300000')
    OR to_regclass('public.inventory_cost_source_layers') IS NULL THEN
    RAISE EXCEPTION 'C3B migration is not installed in guarded staging';
  END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_event_batches)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections) THEN
    RAISE EXCEPTION 'C3B runtime fixture requires an unbootstrapped costing outlet';
  END IF;
END;
$guard$;

CREATE FUNCTION pg_temp.c3b_create_reviewed_post(p_outlet uuid,p_product uuid,p_count numeric)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_request uuid; v_result jsonb; v_session uuid; v_revision integer;
BEGIN
  v_request:=public.issue_stock_operation_intent('CREATE_SESSION',jsonb_build_object(
    'outlet_id',p_outlet,'scope_type','PARTIAL','product_ids',jsonb_build_array(p_product)));
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'C3B fixture session creation failed: %',v_result; END IF;
  v_session:=(v_result->>'sessionId')::uuid;
  SELECT i.revision_no INTO STRICT v_revision FROM public.stock_opname_items i
    WHERE i.session_id=v_session AND i.product_id=p_product;
  v_request:=public.issue_stock_operation_intent('RECORD_COUNT',jsonb_build_object(
    'session_id',v_session,'product_id',p_product,'physical_quantity',p_count,'expected_revision',v_revision));
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'C3B fixture count failed: %',v_result; END IF;
  v_request:=public.issue_stock_operation_intent('SUBMIT_REVIEW',jsonb_build_object('session_id',v_session));
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'C3B fixture review submission failed: %',v_result; END IF;
  RETURN public.issue_stock_operation_intent('POST_SESSION',jsonb_build_object('session_id',v_session));
END;
$$;

CREATE FUNCTION pg_temp.c3b_create_multi_reviewed_post(p_outlet uuid,p_products uuid[],p_counts numeric[])
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_request uuid;v_result jsonb;v_session uuid;v_revision integer;v_idx integer;
BEGIN
  IF cardinality(p_products)<>cardinality(p_counts) OR cardinality(p_products)<2 THEN
    RAISE EXCEPTION 'C3B multi-product fixture arrays are invalid';
  END IF;
  v_request:=public.issue_stock_operation_intent('CREATE_SESSION',jsonb_build_object(
    'outlet_id',p_outlet,'scope_type','PARTIAL','product_ids',to_jsonb(p_products)));
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'C3B multi session creation failed: %',v_result; END IF;
  v_session:=(v_result->>'sessionId')::uuid;
  FOR v_idx IN 1..cardinality(p_products) LOOP
    SELECT i.revision_no INTO STRICT v_revision FROM public.stock_opname_items i
      WHERE i.session_id=v_session AND i.product_id=p_products[v_idx];
    v_request:=public.issue_stock_operation_intent('RECORD_COUNT',jsonb_build_object(
      'session_id',v_session,'product_id',p_products[v_idx],
      'physical_quantity',p_counts[v_idx],'expected_revision',v_revision));
    v_result:=public.apply_stock_operation_intent(v_request);
    IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'C3B multi count failed: %',v_result; END IF;
  END LOOP;
  v_request:=public.issue_stock_operation_intent('SUBMIT_REVIEW',jsonb_build_object('session_id',v_session));
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'C3B multi review submission failed: %',v_result; END IF;
  RETURN public.issue_stock_operation_intent('POST_SESSION',jsonb_build_object('session_id',v_session));
END;
$$;

CREATE FUNCTION pg_temp.c3b_post_estimated_receipt(p_outlet uuid,p_product uuid,p_quantity numeric,p_unit_price numeric)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_supplier uuid;v_receipt uuid;v_item uuid;v_result jsonb;v_request uuid;
BEGIN
  v_supplier:=public.purchase_supplier_upsert(NULL,'C3B Source Layer Fixture Supplier',NULL,NULL,NULL,true);
  v_receipt:=public.purchase_receipt_create_draft(p_outlet,v_supplier,now(),'C3B provisional source-layer fixture');
  PERFORM public.purchase_receipt_save_draft(v_receipt,1,now(),NULL,jsonb_build_array(jsonb_build_object(
    'product_id',p_product,'accepted_quantity',p_quantity,'bonus_quantity',0,'rejected_quantity',0)));
  SELECT i.id INTO STRICT v_item FROM public.purchase_receipt_items i WHERE i.receipt_id=v_receipt AND i.product_id=p_product;
  PERFORM public.purchase_receipt_acquisition_estimate_save(v_receipt,v_item,2,0,
    'MANAGER_ESTIMATE',p_unit_price,NULL,'C3B provisional source-layer test');
  v_request:=public.issue_purchase_receipt_post_intent(v_receipt);
  v_result:=public.apply_purchase_receipt_post_intent(v_request);
  IF coalesce((v_result->>'code'),'')<>'POSTED' THEN RAISE EXCEPTION 'C3B provisional receipt posting failed: %',v_result; END IF;
  RETURN v_receipt;
END;
$$;

BEGIN;
SET LOCAL statement_timeout='90s';
SET LOCAL lock_timeout='8s';
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);

DO $matrix$
DECLARE
  v_owner uuid:='a0000000-0000-4000-8000-000000000001';
  v_outlet uuid; v_product uuid; v_valued_product uuid; v_multi_product uuid; v_before numeric; v_multi_before numeric; v_initial_unvalued numeric;
  v_valued_before numeric; v_initial_valued numeric; v_initial_value numeric; v_layer uuid; v_initial_layer uuid;
  v_receipt uuid;v_receipt_event public.inventory_cost_events%rowtype;v_receipt_layer uuid;
  v_value_after_receipt numeric;v_wac_after_receipt numeric;v_wac_current numeric;v_value_after_mixed numeric;
  v_products uuid[];v_counts numeric[];v_baselines numeric[];v_trigger_product uuid;v_failed boolean;
  v_request uuid; v_gate_request uuid; v_result jsonb; v_movement uuid; v_reversal_request uuid;
  v_gate_reversal_request uuid;v_gate_reversal_movement uuid;
  v_event public.inventory_cost_events%rowtype; v_count_before bigint; v_count_after bigint;
  v_denied_sqlstate text; v_authority_status public.inventory_cost_authority_status;
BEGIN
  SELECT o.id INTO STRICT v_outlet FROM public.outlets o WHERE o.code='QUENA-MART-1' AND o.is_active;
  SELECT p.id INTO STRICT v_valued_product FROM public.products p WHERE p.sku='STG-BASE20';
  SELECT p.id INTO STRICT v_product FROM public.products p WHERE p.sku='STG-FULL-B';
  SELECT p.id INTO STRICT v_multi_product FROM public.products p WHERE p.sku='STG-AMBIG-B';
  SELECT p.effective_quantity INTO STRICT v_valued_before FROM public.stock_balance_projection p
    WHERE p.outlet_id=v_outlet AND p.product_id=v_valued_product;
  SELECT p.effective_quantity INTO STRICT v_before FROM public.stock_balance_projection p
    WHERE p.outlet_id=v_outlet AND p.product_id=v_product;
  SELECT p.effective_quantity INTO STRICT v_multi_before FROM public.stock_balance_projection p
    WHERE p.outlet_id=v_outlet AND p.product_id=v_multi_product;
  IF v_before IS NULL THEN RAISE EXCEPTION 'C3B fixture needs an accepted synthetic stock baseline'; END IF;
  IF EXISTS(SELECT 1 FROM public.stock_opname_items i WHERE i.product_id=v_product AND i.active_scope) THEN
    RAISE EXCEPTION 'C3B product already has active opname coverage';
  END IF;

  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  PERFORM set_config('role','authenticated',true);
  -- REFERENCE_ONLY still posts physical stock/reversals without costing state.
  v_request:=pg_temp.c3b_create_reviewed_post(v_outlet,v_valued_product,v_valued_before-1);
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE
    OR EXISTS(SELECT 1 FROM public.inventory_cost_event_batches)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_events)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_source_layers) THEN
    RAISE EXCEPTION 'REFERENCE_ONLY opname changed costing state or failed';
  END IF;
  SELECT m.id INTO STRICT v_movement FROM public.stock_movement_batches b
    JOIN public.stock_movements m ON m.batch_id=b.id WHERE b.operation_request_id=v_request;
  v_reversal_request:=public.issue_stock_operation_intent('REVERSE_MOVEMENT',jsonb_build_object(
    'movement_id',v_movement,'reason','C3B reference-only reverse'));
  v_result:=public.apply_stock_operation_intent(v_reversal_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=v_outlet AND product_id=v_valued_product)<>v_valued_before
    OR EXISTS(SELECT 1 FROM public.inventory_cost_events) THEN
    RAISE EXCEPTION 'REFERENCE_ONLY reversal changed costing or failed to restore stock';
  END IF;
  v_request:=pg_temp.c3b_create_reviewed_post(v_outlet,v_multi_product,v_multi_before-1);
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'REFERENCE_ONLY reversal-gate fixture post failed'; END IF;
  SELECT m.id INTO STRICT v_gate_reversal_movement FROM public.stock_movement_batches b
    JOIN public.stock_movements m ON m.batch_id=b.id WHERE b.operation_request_id=v_request;
  v_multi_before:=v_multi_before-1;
  PERFORM set_config('role','none',true);
  -- This local-only review fixture makes one opening product valued; other
  -- products intentionally remain UNVALUED for the mixed-population cases.
  INSERT INTO public.product_field_audit_reviews(product_id,outlet_id,field_key,status,
    source_import_row_id,reviewer_id,evidence_notes,request_id)
  SELECT v_valued_product,v_outlet,'hpp','SUDAH_DIVERIFIKASI',pc.source_import_row_id,
    v_owner,'C3B local source-layer valued fixture',gen_random_uuid()
  FROM public.product_costs pc WHERE pc.product_id=v_valued_product AND pc.outlet_id=v_outlet;
  PERFORM set_config('role','authenticated',true);
  PERFORM public.inventory_cost_bootstrap_outlet(v_outlet,'d0000000-0000-4000-8000-000000000301');
  PERFORM set_config('role','none',true);

  SELECT cp.unvalued_quantity INTO STRICT v_initial_unvalued FROM public.inventory_cost_projections cp
    WHERE cp.outlet_id=v_outlet AND cp.product_id=v_product;
  IF v_initial_unvalued<>v_before THEN
    RAISE EXCEPTION 'Expected the strict fixture bootstrap to mark this product UNVALUED; got % of %',v_initial_unvalued,v_before;
  END IF;
  SELECT l.id INTO STRICT v_initial_layer FROM public.inventory_cost_source_layers l
    JOIN public.inventory_cost_events e ON e.id=l.opening_cost_event_id
    WHERE l.product_id=v_product AND e.event_type='OPENING';
  SELECT cp.valued_quantity,cp.inventory_value INTO STRICT v_initial_valued,v_initial_value
    FROM public.inventory_cost_projections cp WHERE cp.outlet_id=v_outlet AND cp.product_id=v_valued_product;
  IF v_initial_valued<>v_valued_before OR v_initial_value<>v_valued_before*500
    OR NOT EXISTS(SELECT 1 FROM public.inventory_cost_source_layers l
      JOIN public.inventory_cost_source_layer_balances b ON b.layer_id=l.id
      WHERE l.product_id=v_valued_product AND l.source_event_type='OPENING'
        AND l.original_valued_quantity=v_valued_before AND b.remaining_valued_quantity=v_valued_before) THEN
    RAISE EXCEPTION 'Valued bootstrap did not create an OPENING layer reconciled to its event/projection';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  PERFORM set_config('role','authenticated',true);
  v_gate_reversal_request:=public.issue_stock_operation_intent('REVERSE_MOVEMENT',jsonb_build_object(
    'movement_id',v_gate_reversal_movement,'reason','C3B BOOTSTRAP_READY reverse gate'));
  v_denied_sqlstate:=NULL;
  BEGIN
    PERFORM public.apply_stock_operation_intent(v_gate_reversal_request);
  EXCEPTION WHEN SQLSTATE '55000' THEN v_denied_sqlstate:=SQLSTATE;
  END;
  PERFORM set_config('role','none',true);
  IF v_denied_sqlstate IS DISTINCT FROM '55000'
    OR (SELECT state::text FROM public.stock_operation_requests WHERE request_id=v_gate_reversal_request)<>'PENDING'
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=v_outlet AND product_id=v_multi_product)<>v_multi_before THEN
    RAISE EXCEPTION 'BOOTSTRAP_READY reversal gate mutated stock or terminalized the request';
  END IF;

  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
  PERFORM set_config('role','authenticated',true);
  IF (SELECT count(*) FROM public.inventory_cost_source_layers)<>0
    OR (SELECT count(*) FROM public.inventory_cost_source_layer_balances)<>0
    OR (SELECT count(*) FROM public.inventory_cost_layer_allocations)<>0
    OR (SELECT count(*) FROM public.inventory_cost_projections)<>0
    OR has_table_privilege('authenticated','public.inventory_cost_layer_allocations','INSERT')
    OR has_function_privilege('authenticated','public.inventory_cost_apply_stock_movement_operation(uuid,text,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'GUDANG can read financial layers or execute internal costing writers';
  END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
  IF (SELECT count(*) FROM public.inventory_cost_source_layers)<>0
    OR (SELECT count(*) FROM public.inventory_cost_projections)<>0 THEN
    RAISE EXCEPTION 'KASIR can read protected costing data';
  END IF;
  PERFORM set_config('role','none',true);
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);

  -- The pending post survives BOOTSTRAP_READY and succeeds with the same ID after activation.
  PERFORM set_config('role','authenticated',true);
  v_gate_request:=pg_temp.c3b_create_reviewed_post(v_outlet,v_product,v_before-2);
  v_denied_sqlstate:=NULL;
  BEGIN
    PERFORM public.apply_stock_operation_intent(v_gate_request);
  EXCEPTION WHEN SQLSTATE '55000' THEN v_denied_sqlstate:=SQLSTATE;
  END;
  PERFORM set_config('role','none',true);
  IF v_denied_sqlstate IS DISTINCT FROM '55000'
    OR (SELECT state::text FROM public.stock_operation_requests WHERE request_id=v_gate_request)<>'PENDING'
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=v_outlet AND product_id=v_product)<>v_before THEN
    RAISE EXCEPTION 'BOOTSTRAP_READY must reject without stock mutation or terminalizing the pending request';
  END IF;

  UPDATE public.inventory_costing_outlet_authority SET status='WAC_ACTIVE',activated_by=v_owner,activated_at=now()
    WHERE outlet_id=v_outlet;
  PERFORM set_config('role','authenticated',true);

  -- Inject a local-only failure on the second product after the first cost
  -- event is written. The entire multi-product stock+cost operation must roll back.
  SELECT array_agg(x.product_id ORDER BY x.product_id) INTO STRICT v_products
    FROM (VALUES(v_valued_product),(v_multi_product)) x(product_id);
  SELECT array_agg(CASE WHEN x.product_id=v_valued_product THEN v_valued_before-1 ELSE v_multi_before-1 END
      ORDER BY x.product_id),
    array_agg(CASE WHEN x.product_id=v_valued_product THEN v_valued_before ELSE v_multi_before END ORDER BY x.product_id)
    INTO STRICT v_counts,v_baselines FROM unnest(v_products) x(product_id);
  v_trigger_product:=v_products[2];
  v_request:=pg_temp.c3b_create_multi_reviewed_post(v_outlet,v_products,v_counts);
  PERFORM set_config('role','none',true);
  EXECUTE format('CREATE FUNCTION public.c3b_staging_fail_cost_event() RETURNS trigger LANGUAGE plpgsql AS %L',
    format('BEGIN IF NEW.product_id=%L::uuid THEN RAISE EXCEPTION USING ERRCODE=%L,MESSAGE=%L; END IF; RETURN NEW; END',
      v_trigger_product,'55000','C3B injected second-product costing failure'));
  EXECUTE format('CREATE TRIGGER c3b_staging_fail_cost_event BEFORE INSERT ON public.inventory_cost_events FOR EACH ROW WHEN (NEW.product_id=%L::uuid) EXECUTE FUNCTION public.c3b_staging_fail_cost_event()',v_trigger_product);
  PERFORM set_config('role','authenticated',true);
  v_failed:=false;
  BEGIN
    PERFORM public.apply_stock_operation_intent(v_request);
  EXCEPTION WHEN SQLSTATE '55000' THEN v_failed:=true;
  END;
  PERFORM set_config('role','none',true);
  DROP TRIGGER c3b_staging_fail_cost_event ON public.inventory_cost_events;
  DROP FUNCTION public.c3b_staging_fail_cost_event();
  PERFORM set_config('role','none',true);
  IF NOT v_failed OR EXISTS(SELECT 1 FROM public.stock_movement_batches WHERE operation_request_id=v_request)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_event_batches WHERE operation_request_id=v_request)
    OR (SELECT state::text FROM public.stock_operation_requests WHERE request_id=v_request)<>'PENDING'
    OR (SELECT count(*) FROM public.stock_balance_projection p WHERE p.outlet_id=v_outlet
      AND p.product_id=ANY(v_products) AND p.effective_quantity=ANY(v_baselines))<>2 THEN
    RAISE EXCEPTION 'Costing failure did not atomically roll back multi-product stock and preserve retry';
  END IF;
  PERFORM set_config('role','authenticated',true);
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE
    OR (SELECT count(*) FROM public.inventory_cost_events WHERE operation_request_id=v_request)<>2 THEN
    RAISE EXCEPTION 'Same multi-product request did not succeed after injected failure was removed';
  END IF;
  FOR v_movement IN SELECT m.id FROM public.stock_movement_batches b JOIN public.stock_movements m ON m.batch_id=b.id
    WHERE b.operation_request_id=v_request ORDER BY m.product_id LOOP
    v_reversal_request:=public.issue_stock_operation_intent('REVERSE_MOVEMENT',jsonb_build_object(
      'movement_id',v_movement,'reason','C3B multi-product fixture cleanup reversal'));
    v_result:=public.apply_stock_operation_intent(v_reversal_request);
    IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'C3B multi-product cleanup reversal failed'; END IF;
  END LOOP;

  -- Fully valued shrinkage removes value at aggregate WAC, then exact reversal
  -- restores the original event value rather than repricing the source layer.
  v_request:=pg_temp.c3b_create_reviewed_post(v_outlet,v_valued_product,v_valued_before-2);
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'Valued opname failed: %',v_result; END IF;
  SELECT m.id INTO STRICT v_movement FROM public.stock_movement_batches b
    JOIN public.stock_movements m ON m.batch_id=b.id WHERE b.operation_request_id=v_request;
  SELECT e.* INTO STRICT v_event FROM public.inventory_cost_events e WHERE e.source_stock_movement_id=v_movement;
  IF v_event.valued_quantity_delta<>-2 OR v_event.unvalued_quantity_delta<>0
    OR v_event.inventory_value_delta<>-1000
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=v_valued_product)
      <>v_initial_value-1000 THEN
    RAISE EXCEPTION 'Valued shrinkage mismatch: %',jsonb_build_object(
      'requestId',v_request,'requestResult',v_result,'movementId',v_movement,
      'movement', (SELECT jsonb_build_object('product',m.product_id,'request',b.operation_request_id,'session',i.session_id)
        FROM public.stock_movements m JOIN public.stock_movement_batches b ON b.id=m.batch_id
        LEFT JOIN public.stock_opname_items i ON i.id=m.opname_item_id WHERE m.id=v_movement),
      'eventSession',v_event.opname_session_id,'eventProduct',v_event.product_id,
      'targetProduct',v_valued_product,'physicalDelta',v_event.physical_quantity_delta,
      'valuedBefore',v_event.valued_quantity_before,'valuedDelta',v_event.valued_quantity_delta,
      'valuedAfter',v_event.valued_quantity_after,'unvaluedBefore',v_event.unvalued_quantity_before,
      'unvaluedDelta',v_event.unvalued_quantity_delta,'valueDelta',v_event.inventory_value_delta,
      'projection',(SELECT jsonb_build_object('valued',cp.valued_quantity,'unvalued',cp.unvalued_quantity,'value',cp.inventory_value)
        FROM public.inventory_cost_projections cp WHERE cp.outlet_id=v_outlet AND cp.product_id=v_valued_product),
      'initialValue',v_initial_value);
  END IF;
  v_reversal_request:=public.issue_stock_operation_intent('REVERSE_MOVEMENT',jsonb_build_object(
    'movement_id',v_movement,'reason','C3B valued exact inverse'));
  v_receipt:=pg_temp.c3b_post_estimated_receipt(v_outlet,v_valued_product,4,10000);
  SELECT e.* INTO STRICT v_receipt_event FROM public.inventory_cost_events e WHERE e.receipt_id=v_receipt;
  SELECT l.id INTO STRICT v_receipt_layer FROM public.inventory_cost_source_layers l
    WHERE l.opening_cost_event_id=v_receipt_event.id;
  SELECT cp.inventory_value,cp.current_wac INTO STRICT v_value_after_receipt,v_wac_after_receipt
    FROM public.inventory_cost_projections cp WHERE cp.outlet_id=v_outlet AND cp.product_id=v_valued_product;
  IF v_receipt_event.event_type<>'PURCHASE_RECEIPT' OR v_receipt_event.valued_quantity_delta<>4
    OR v_receipt_event.provisional_quantity_delta<>4 OR v_receipt_event.unvalued_quantity_delta<>0
    OR v_receipt_event.inventory_value_delta<>40000
    OR (SELECT original_provisional_quantity FROM public.inventory_cost_source_layers WHERE id=v_receipt_layer)<>4
    OR (SELECT remaining_provisional_quantity FROM public.inventory_cost_source_layer_balances WHERE layer_id=v_receipt_layer)<>4
    OR v_value_after_receipt<>v_initial_value-1000+40000 THEN
    RAISE EXCEPTION 'C3A provisional receipt did not create a matching protected quantity-provenance layer';
  END IF;
  v_result:=public.apply_stock_operation_intent(v_reversal_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=v_valued_product)<>v_value_after_receipt+1000
    OR (SELECT valued_quantity FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=v_valued_product)<>v_initial_valued+4
    OR (SELECT inventory_value_delta FROM public.inventory_cost_events WHERE reverses_stock_movement_id=v_movement)<>1000 THEN
    RAISE EXCEPTION 'Valued reversal after a later WAC-changing receipt did not restore the frozen original value delta';
  END IF;
  SELECT current_wac INTO STRICT v_wac_current FROM public.inventory_cost_projections
    WHERE outlet_id=v_outlet AND product_id=v_valued_product;

  -- The source-layer ratio consumes provisional and final quantities
  -- proportionally, while financial depletion uses aggregate WAC.
  v_request:=pg_temp.c3b_create_reviewed_post(v_outlet,v_valued_product,v_valued_before+1);
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'Provisional source outflow failed: %',v_result; END IF;
  SELECT m.id INTO STRICT v_movement FROM public.stock_movement_batches b
    JOIN public.stock_movements m ON m.batch_id=b.id WHERE b.operation_request_id=v_request;
  SELECT e.* INTO STRICT v_event FROM public.inventory_cost_events e WHERE e.source_stock_movement_id=v_movement;
  v_value_after_mixed:=v_initial_value+40000-round(3*v_wac_current,8);
  IF v_event.valued_quantity_delta<>-3 OR v_event.provisional_quantity_delta<>-0.500
    OR v_event.inventory_value_delta<>-round(3*v_wac_current,8)
    OR (SELECT provisional_quantity_delta FROM public.inventory_cost_layer_allocations
      WHERE cost_event_id=v_event.id AND source_layer_id=v_receipt_layer)<>-0.500
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=v_valued_product)<>v_value_after_mixed THEN
    RAISE EXCEPTION 'Provisional depletion was not proportional or financial value did not use aggregate WAC';
  END IF;
  v_reversal_request:=public.issue_stock_operation_intent('REVERSE_MOVEMENT',jsonb_build_object(
    'movement_id',v_movement,'reason','C3B provisional allocation exact inverse'));
  v_result:=public.apply_stock_operation_intent(v_reversal_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE
    OR (SELECT provisional_quantity FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=v_valued_product)<>4
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=v_valued_product)<>v_value_after_receipt+1000 THEN
    RAISE EXCEPTION 'Provisional allocation reversal did not restore source buckets and original WAC value';
  END IF;

  v_request:=v_gate_request;
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'WAC_ACTIVE opname retry failed: %',v_result; END IF;
  IF v_result ?| ARRAY['inventoryValue','currentWac','sourceUnitCost','valuation'] THEN
    RAISE EXCEPTION 'Operational stock response leaked financial costing fields';
  END IF;
  SELECT m.id INTO STRICT v_movement FROM public.stock_movement_batches b
    JOIN public.stock_movements m ON m.batch_id=b.id WHERE b.operation_request_id=v_request;
  SELECT e.* INTO STRICT v_event FROM public.inventory_cost_events e WHERE e.source_stock_movement_id=v_movement;
  IF v_event.event_type::text<>'OPNAME_ADJUSTMENT' OR v_event.physical_quantity_delta<>-2
    OR v_event.valued_quantity_delta<>0 OR v_event.unvalued_quantity_delta<>-2
    OR v_event.inventory_value_delta IS NOT NULL THEN
    RAISE EXCEPTION 'Unvalued-first negative variance event mismatch: type %, physical %, valued %, unvalued %, value %',
      v_event.event_type,v_event.physical_quantity_delta,v_event.valued_quantity_delta,
      v_event.unvalued_quantity_delta,v_event.inventory_value_delta;
  END IF;
  SELECT count(*) INTO v_count_before FROM public.inventory_cost_events WHERE outlet_id=v_outlet;
  PERFORM public.apply_stock_operation_intent(v_request);
  SELECT count(*) INTO v_count_after FROM public.inventory_cost_events WHERE outlet_id=v_outlet;
  IF v_count_after<>v_count_before THEN RAISE EXCEPTION 'Same-request replay duplicated costing evidence'; END IF;

  -- Exact movement reversal restores the original unvalued layer allocation.
  v_reversal_request:=public.issue_stock_operation_intent('REVERSE_MOVEMENT',jsonb_build_object(
    'movement_id',v_movement,'reason','C3B local reverse test'));
  v_result:=public.apply_stock_operation_intent(v_reversal_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'WAC_ACTIVE reversal failed: %',v_result; END IF;
  IF (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=v_outlet AND product_id=v_product)<>v_before
    OR (SELECT physical_quantity FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=v_product)<>v_before
    OR (SELECT unvalued_quantity FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=v_product)<>v_initial_unvalued THEN
    RAISE EXCEPTION 'Reversal did not restore original physical and unvalued quantities';
  END IF;
  IF (SELECT count(*) FROM public.inventory_cost_events WHERE reverses_cost_event_id=v_event.id)<>1 THEN
    RAISE EXCEPTION 'Expected exactly one cost reversal for the original event';
  END IF;

  -- With two UNVALUED source layers (7 and 3 units), a one-unit outflow is
  -- apportioned 0.700/0.300 by largest remainder, independent of source value.
  v_request:=pg_temp.c3b_create_reviewed_post(v_outlet,v_product,v_before+3);
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'Second unvalued layer creation failed: %',v_result; END IF;
  SELECT m.id INTO STRICT v_movement FROM public.stock_movement_batches b
    JOIN public.stock_movements m ON m.batch_id=b.id WHERE b.operation_request_id=v_request;
  SELECT e.* INTO STRICT v_event FROM public.inventory_cost_events e WHERE e.source_stock_movement_id=v_movement;
  SELECT l.id INTO STRICT v_layer FROM public.inventory_cost_source_layers l WHERE l.opening_cost_event_id=v_event.id;
  v_request:=pg_temp.c3b_create_reviewed_post(v_outlet,v_product,v_before+2);
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'Proportional unvalued outflow failed: %',v_result; END IF;
  SELECT m.id INTO STRICT v_movement FROM public.stock_movement_batches b
    JOIN public.stock_movements m ON m.batch_id=b.id WHERE b.operation_request_id=v_request;
  SELECT e.* INTO STRICT v_event FROM public.inventory_cost_events e WHERE e.source_stock_movement_id=v_movement;
  IF (SELECT count(*) FROM public.inventory_cost_layer_allocations a WHERE a.cost_event_id=v_event.id
        AND a.allocation_kind='OUTFLOW_UNVALUED')<>2
    OR (SELECT abs(a.physical_quantity_delta) FROM public.inventory_cost_layer_allocations a
        WHERE a.cost_event_id=v_event.id AND a.source_layer_id=v_initial_layer)<>0.700
    OR (SELECT abs(a.physical_quantity_delta) FROM public.inventory_cost_layer_allocations a
        WHERE a.cost_event_id=v_event.id AND a.source_layer_id=v_layer)<>0.300
    OR (SELECT remaining_unvalued_quantity FROM public.inventory_cost_source_layer_balances WHERE layer_id=v_layer)<>2.700 THEN
    RAISE EXCEPTION 'Proportional unvalued allocation or largest-remainder tie behavior is incorrect';
  END IF;

  -- Positive variance opens an unvalued layer; its immediate reversal is exact.
  v_request:=pg_temp.c3b_create_reviewed_post(v_outlet,v_valued_product,v_valued_before+7);
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'Positive opname failed: %',v_result; END IF;
  SELECT m.id INTO STRICT v_movement FROM public.stock_movement_batches b
    JOIN public.stock_movements m ON m.batch_id=b.id WHERE b.operation_request_id=v_request;
  SELECT e.* INTO STRICT v_event FROM public.inventory_cost_events e WHERE e.source_stock_movement_id=v_movement;
  IF v_event.physical_quantity_delta<>3 OR v_event.valued_quantity_delta<>0
    OR v_event.unvalued_quantity_delta<>3 OR v_event.inventory_value_delta<>0
    OR NOT EXISTS(SELECT 1 FROM public.inventory_cost_source_layers l WHERE l.opening_cost_event_id=v_event.id
      AND l.opname_session_id=v_event.opname_session_id AND l.opname_item_id=v_event.opname_item_id
      AND l.source_stock_movement_id=v_movement AND l.original_unvalued_quantity=3) THEN
    RAISE EXCEPTION 'Positive unexplained variance did not create its unvalued source layer';
  END IF;
  SELECT l.id INTO STRICT v_layer FROM public.inventory_cost_source_layers l
    WHERE l.opening_cost_event_id=v_event.id;
  v_request:=pg_temp.c3b_create_reviewed_post(v_outlet,v_valued_product,v_valued_before+6);
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'Unvalued-first follow-up outflow failed: %',v_result; END IF;
  IF (SELECT remaining_unvalued_quantity FROM public.inventory_cost_source_layer_balances WHERE layer_id=v_layer)<>2
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=v_valued_product)<>v_value_after_receipt+1000 THEN
    RAISE EXCEPTION 'Positive variance layer did not retain two unvalued units after a one-unit outflow';
  END IF;
  v_reversal_request:=public.issue_stock_operation_intent('REVERSE_MOVEMENT',jsonb_build_object(
    'movement_id',v_movement,'reason','C3B dependent layer allocation guard'));
  v_denied_sqlstate:=NULL;
  BEGIN
    PERFORM public.apply_stock_operation_intent(v_reversal_request);
  EXCEPTION WHEN SQLSTATE '55000' THEN v_denied_sqlstate:=SQLSTATE;
  END;
  IF v_denied_sqlstate IS DISTINCT FROM '55000' THEN
    RAISE EXCEPTION 'Reversal should be blocked after dependent source-layer activity';
  END IF;

  -- The next five-unit shortage consumes the remaining two unvalued units,
  -- then three valued units at aggregate WAC (never source-layer price).
  v_request:=pg_temp.c3b_create_reviewed_post(v_outlet,v_valued_product,v_valued_before+1);
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'Mixed-bucket opname failed: %',v_result; END IF;
  SELECT m.id INTO STRICT v_movement FROM public.stock_movement_batches b
    JOIN public.stock_movements m ON m.batch_id=b.id WHERE b.operation_request_id=v_request;
  SELECT e.* INTO STRICT v_event FROM public.inventory_cost_events e WHERE e.source_stock_movement_id=v_movement;
  IF v_event.physical_quantity_delta<>-5 OR v_event.valued_quantity_delta<>-3
    OR v_event.unvalued_quantity_delta<>-2 OR v_event.inventory_value_delta<>-round(3*v_wac_current,8)
    OR (SELECT valued_quantity FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=v_valued_product)<>v_valued_before+4-3
    OR (SELECT unvalued_quantity FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=v_valued_product)<>0
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=v_valued_product)<>v_value_after_mixed THEN
    RAISE EXCEPTION 'Mixed unvalued-first then valued-WAC shortage did not reconcile: %',jsonb_build_object(
      'event',jsonb_build_object('physical',v_event.physical_quantity_delta,'valued',v_event.valued_quantity_delta,
        'provisional',v_event.provisional_quantity_delta,'unvalued',v_event.unvalued_quantity_delta,
        'valueDelta',v_event.inventory_value_delta),'wac',v_wac_current,'expectedValue',v_value_after_mixed,
      'projection',(SELECT jsonb_build_object('physical',cp.physical_quantity,'valued',cp.valued_quantity,
        'provisional',cp.provisional_quantity,'unvalued',cp.unvalued_quantity,'value',cp.inventory_value)
        FROM public.inventory_cost_projections cp WHERE cp.outlet_id=v_outlet AND cp.product_id=v_valued_product));
  END IF;

  -- Exhausting all remaining valued quantity removes the exact residual value.
  v_request:=pg_temp.c3b_create_reviewed_post(v_outlet,v_valued_product,0);
  v_result:=public.apply_stock_operation_intent(v_request);
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'Final valued exhaustion failed: %',v_result; END IF;
  SELECT m.id INTO STRICT v_movement FROM public.stock_movement_batches b
    JOIN public.stock_movements m ON m.batch_id=b.id WHERE b.operation_request_id=v_request;
  SELECT e.* INTO STRICT v_event FROM public.inventory_cost_events e WHERE e.source_stock_movement_id=v_movement;
  IF v_event.inventory_value_delta<>-v_value_after_mixed
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=v_valued_product)<>0
    OR (SELECT current_wac FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=v_valued_product) IS NOT NULL
    OR (SELECT valued_quantity FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=v_valued_product)<>0 THEN
    RAISE EXCEPTION 'Last-valued-unit depletion retained a value rounding residual or WAC';
  END IF;

  IF (SELECT status FROM public.inventory_costing_outlet_authority WHERE outlet_id=v_outlet)<>'WAC_ACTIVE' THEN
    RAISE EXCEPTION 'Local runtime scenario did not enter the intended test authority state';
  END IF;
END;
$matrix$;

SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
