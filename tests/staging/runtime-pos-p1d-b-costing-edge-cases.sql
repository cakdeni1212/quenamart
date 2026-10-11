\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database() NOT LIKE 'quena_p1d_b_staging_%'
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR inet_server_port()<>55432 OR current_setting('server_version_num')::integer/10000<>15
    OR NOT EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE status='WAC_ACTIVE') THEN
    RAISE EXCEPTION 'Refusing costing edge cases outside disposable WAC_ACTIVE PostgreSQL 15 staging';
  END IF;
END; $guard$;
BEGIN;
DO $edge_cases$
DECLARE outlet uuid; valued_product uuid; provisional_product uuid; price numeric;
  before_cost public.inventory_cost_projections%ROWTYPE; after_cost public.inventory_cost_projections%ROWTYPE;
  result jsonb; cart jsonb; added jsonb; cart_id uuid; revision bigint; sale uuid; item uuid;
  stock_request uuid; op_result jsonb; v_session_id uuid; item_revision integer;
  supplier_id uuid; v_receipt_id uuid; v_receipt_item_id uuid; old_stock numeric; final_qty numeric; initial_unvalued numeric;
  cashier constant uuid:='a0000000-0000-4000-8000-000000000004';
BEGIN
  SELECT outlet_id INTO STRICT outlet FROM public.inventory_costing_outlet_authority WHERE status='WAC_ACTIVE';
  SELECT id INTO STRICT valued_product FROM public.products WHERE sku='STG-BASE20';
  SELECT id INTO STRICT provisional_product FROM public.products WHERE sku='STG-AMBIG-B';

  -- Create a legitimate unvalued gain through the stock-opname domain workflow.
  SELECT * INTO STRICT before_cost FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=valued_product;
  SELECT effective_quantity INTO STRICT old_stock FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=valued_product;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
  stock_request:=public.issue_stock_operation_intent('CREATE_SESSION',jsonb_build_object(
    'outlet_id',outlet,'scope_type','PARTIAL','product_ids',jsonb_build_array(valued_product)));
  op_result:=public.apply_stock_operation_intent(stock_request);
  IF coalesce((op_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'mixed fixture opname session failed: %',op_result; END IF;
  v_session_id:=(op_result->>'sessionId')::uuid;
  SELECT i.revision_no INTO STRICT item_revision FROM public.stock_opname_items i WHERE i.session_id=v_session_id AND i.product_id=valued_product;
  stock_request:=public.issue_stock_operation_intent('RECORD_COUNT',jsonb_build_object(
    'session_id',v_session_id,'product_id',valued_product,'physical_quantity',old_stock+2,'expected_revision',item_revision));
  op_result:=public.apply_stock_operation_intent(stock_request);
  IF coalesce((op_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'mixed fixture count failed: %',op_result; END IF;
  stock_request:=public.issue_stock_operation_intent('SUBMIT_REVIEW',jsonb_build_object('session_id',v_session_id));
  op_result:=public.apply_stock_operation_intent(stock_request);
  IF coalesce((op_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'mixed fixture review failed: %',op_result; END IF;
  stock_request:=public.issue_stock_operation_intent('POST_SESSION',jsonb_build_object('session_id',v_session_id));
  op_result:=public.apply_stock_operation_intent(stock_request);
  IF op_result->>'code'<>'POSTED' THEN RAISE EXCEPTION 'mixed fixture post failed: %',op_result; END IF;
  SELECT * INTO STRICT after_cost FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=valued_product;
  IF after_cost.unvalued_quantity<>before_cost.unvalued_quantity+2
    OR after_cost.valued_quantity<>before_cost.valued_quantity
    OR after_cost.inventory_value IS DISTINCT FROM before_cost.inventory_value THEN
    RAISE EXCEPTION 'opname did not create the expected unvalued component';
  END IF;

  PERFORM set_config('request.jwt.claim.sub',cashier::text,true);
  SELECT amount INTO STRICT price FROM public.product_selling_prices WHERE outlet_id=outlet AND product_id=valued_product;
  cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
  added:=public.pos_cart_add_item(cart_id,valued_product,3,1,gen_random_uuid()); revision:=(added->>'revision')::bigint;
  result:=public.pos_checkout_complete(gen_random_uuid(),cart_id,revision,'CASH',price*3,NULL); sale:=(result->>'sale_id')::uuid;
  SELECT id INTO STRICT item FROM public.sale_items WHERE sale_id=sale;
  IF NOT EXISTS(SELECT 1 FROM public.sale_item_cost_evidence e WHERE e.sale_item_id=item
      AND e.valued_quantity=1 AND e.unvalued_quantity=2 AND e.resolved_cogs_amount IS NOT NULL
      AND e.status='PARTIALLY_UNRESOLVED')
    OR NOT EXISTS(SELECT 1 FROM public.sale_item_cost_allocations a WHERE a.sale_item_id=item
      AND a.bucket='UNVALUED' AND a.unvalued_quantity=2)
    OR NOT EXISTS(SELECT 1 FROM public.sale_item_cost_allocations a WHERE a.sale_item_id=item
      AND a.bucket='VALUED' AND a.valued_quantity=1) THEN
    RAISE EXCEPTION 'mixed sale did not consume two unvalued then one valued unit with partial-unresolved evidence';
  END IF;
  RAISE NOTICE 'PASS: mixed valued/unvalued checkout consumes unvalued first; known COGS retained and status PARTIALLY_UNRESOLVED';

  -- Post a manager-estimated receipt via the ordinary contract to create provisional-only stock.
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
  supplier_id:=public.purchase_supplier_upsert(NULL,'P1D-B provisional fixture supplier',NULL,NULL,NULL,true);
  v_receipt_id:=public.purchase_receipt_create_draft(outlet,supplier_id,now(),'P1D-B provisional checkout fixture');
  PERFORM public.purchase_receipt_save_draft(v_receipt_id,1,now(),NULL,jsonb_build_array(jsonb_build_object(
    'product_id',provisional_product,'accepted_quantity',2,'bonus_quantity',0,'rejected_quantity',0)));
  SELECT i.id INTO STRICT v_receipt_item_id FROM public.purchase_receipt_items i WHERE i.receipt_id=v_receipt_id AND i.product_id=provisional_product;
  PERFORM public.purchase_receipt_acquisition_estimate_save(v_receipt_id,v_receipt_item_id,2,0,
    'MANAGER_ESTIMATE',1000,NULL,'P1D-B runtime fixture');
  stock_request:=public.issue_purchase_receipt_post_intent(v_receipt_id);
  op_result:=public.apply_purchase_receipt_post_intent(stock_request);
  IF op_result->>'code'<>'POSTED' THEN RAISE EXCEPTION 'provisional receipt fixture failed: %',op_result; END IF;

  -- Consume all original unvalued units, then sell the remaining provisional unit.
  PERFORM set_config('request.jwt.claim.sub',cashier::text,true);
  SELECT amount INTO STRICT price FROM public.product_selling_prices WHERE outlet_id=outlet AND product_id=provisional_product;
  SELECT unvalued_quantity INTO STRICT initial_unvalued FROM public.inventory_cost_projections
    WHERE outlet_id=outlet AND product_id=provisional_product;
  cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
  added:=public.pos_cart_add_item(cart_id,provisional_product,initial_unvalued,1,gen_random_uuid()); revision:=(added->>'revision')::bigint;
  result:=public.pos_checkout_complete(gen_random_uuid(),cart_id,revision,'CASH',price*initial_unvalued,NULL); sale:=(result->>'sale_id')::uuid;
  IF NOT EXISTS(SELECT 1 FROM public.sale_item_cost_evidence WHERE sale_id=sale AND status='UNRESOLVED'
    AND unvalued_quantity=initial_unvalued AND resolved_cogs_amount IS NULL AND provisional_cogs_amount IS NULL) THEN
    RAISE EXCEPTION 'fully unvalued sale fabricated cost or lost unresolved status';
  END IF;
  cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
  added:=public.pos_cart_add_item(cart_id,provisional_product,1,1,gen_random_uuid()); revision:=(added->>'revision')::bigint;
  result:=public.pos_checkout_complete(gen_random_uuid(),cart_id,revision,'CASH',price,NULL); sale:=(result->>'sale_id')::uuid;
  IF NOT EXISTS(SELECT 1 FROM public.sale_item_cost_evidence WHERE sale_id=sale AND status='PROVISIONAL'
    AND valued_quantity=1 AND provisional_quantity=1 AND resolved_cogs_amount IS NULL
    AND provisional_cogs_amount=1000)
    OR NOT EXISTS(SELECT 1 FROM public.sale_item_cost_allocations WHERE sale_id=sale
      AND bucket='VALUED' AND provisional_quantity=1) THEN
    RAISE EXCEPTION 'provisional sale evidence was not preserved';
  END IF;
  RAISE NOTICE 'PASS: fully unvalued remains NULL/UNRESOLVED and provisional source consumption remains PROVISIONAL';

  -- Consume the final valued quantity at exact remaining inventory value.
  SELECT * INTO STRICT before_cost FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=valued_product;
  final_qty:=before_cost.valued_quantity;
  IF final_qty<=0 OR before_cost.unvalued_quantity<>0 THEN RAISE EXCEPTION 'last-valued fixture is not isolated: %',before_cost; END IF;
  SELECT amount INTO STRICT price FROM public.product_selling_prices WHERE outlet_id=outlet AND product_id=valued_product;
  cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
  added:=public.pos_cart_add_item(cart_id,valued_product,final_qty,1,gen_random_uuid()); revision:=(added->>'revision')::bigint;
  result:=public.pos_checkout_complete(gen_random_uuid(),cart_id,revision,'CASH',price*final_qty,NULL); sale:=(result->>'sale_id')::uuid;
  SELECT * INTO STRICT after_cost FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=valued_product;
  IF after_cost.valued_quantity<>0 OR after_cost.inventory_value<>0 OR after_cost.current_wac IS NOT NULL
    OR NOT EXISTS(SELECT 1 FROM public.sale_item_cost_evidence e WHERE e.sale_id=sale
      AND e.valued_quantity=final_qty AND e.status='RESOLVED'
      AND e.resolved_cogs_amount=before_cost.inventory_value)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_source_layer_balances b WHERE b.outlet_id=outlet
      AND b.product_id=valued_product AND (b.remaining_valued_quantity<>0 OR b.remaining_provisional_quantity<>0)) THEN
    RAISE EXCEPTION 'last-valued-unit depletion left monetary/source residue';
  END IF;
  RAISE NOTICE 'PASS: final valued depletion reaches zero inventory value with no monetary/source residue';
END; $edge_cases$;
COMMIT;
SELECT 'PASS: mixed, fully unvalued, provisional, and final-valued-unit runtime cases committed in disposable staging' AS result;
