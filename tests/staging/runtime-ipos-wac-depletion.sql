\set ON_ERROR_STOP on
BEGIN;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
CREATE FUNCTION pg_temp.ipos_test_post_receipt(p_product uuid,p_quantity numeric,p_cost numeric) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_outlet uuid; v_supplier_id uuid; v_receipt_id uuid; v_item_id uuid; v_draft_rev integer; v_request_id uuid; v_result jsonb;
BEGIN
  SELECT id INTO STRICT v_outlet FROM public.outlets WHERE code='QUENA-MART-1';
  v_supplier_id:=public.purchase_supplier_upsert(NULL,'IPOS WAC Writer Staging Supplier',NULL,NULL,NULL,true);
  v_receipt_id:=public.purchase_receipt_create_draft(v_outlet,v_supplier_id,now(),'Disposable IPOS WAC writer fixture');
  v_result:=public.purchase_receipt_save_draft(v_receipt_id,1,now(),NULL,jsonb_build_array(jsonb_build_object(
    'product_id',p_product,'accepted_quantity',p_quantity,'bonus_quantity',0,'rejected_quantity',0)));
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'Fixture receipt draft failed: %',v_result; END IF;
  SELECT i.id INTO STRICT v_item_id FROM public.purchase_receipt_items i WHERE i.receipt_id=v_receipt_id;
  SELECT draft_revision INTO STRICT v_draft_rev FROM public.purchase_receipts WHERE id=v_receipt_id;
  v_result:=public.purchase_receipt_acquisition_estimate_save(v_receipt_id,v_item_id,v_draft_rev,0,
    'MANAGER_ESTIMATE',p_cost,'WAC source-layer writer staging test','fixture');
  IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'Fixture acquisition evidence failed: %',v_result; END IF;
  v_request_id:=public.issue_purchase_receipt_post_intent(v_receipt_id);
  v_result:=public.apply_purchase_receipt_post_intent(v_request_id);
  IF coalesce(v_result->>'code','')<>'POSTED' THEN RAISE EXCEPTION 'Fixture receipt posting failed: %',v_result; END IF;
END $$;
DO $$
DECLARE
  a uuid:='a0000000-0000-4000-8000-000000000001'; o uuid; p uuid; b uuid:=gen_random_uuid();
  t uuid:=gen_random_uuid(); l uuid:=gen_random_uuid(); request_id uuid:=gen_random_uuid(); v_product_id uuid;
  b2 uuid:=gen_random_uuid();t2 uuid:=gen_random_uuid();l2 uuid:=gen_random_uuid();request2 uuid:=gen_random_uuid();v_product2 uuid;v_sale2 uuid;
  outlet_mode public.stock_authority_mode; auth_status public.inventory_cost_authority_status;
  stock_before numeric; stock_after numeric; valued_before numeric; valued_after numeric;
  unvalued_before numeric; unvalued_after numeric; value_before numeric; value_after numeric;
  wac_before numeric; wac_after numeric; period_id uuid; tx_number text; result jsonb; replay jsonb;
  pooled_after_value numeric;pooled_after_wac numeric;
  report jsonb; dash jsonb; movement_id uuid; v_sale_id uuid; event_count bigint;
BEGIN
  SELECT id INTO STRICT o FROM public.outlets WHERE code='QUENA-MART-1';
  SELECT status INTO STRICT auth_status FROM public.inventory_costing_outlet_authority WHERE outlet_id=o;
  IF auth_status<>'WAC_ACTIVE' THEN RAISE EXCEPTION 'Fixture must be WAC_ACTIVE'; END IF;
  SELECT id,mode INTO STRICT period_id,outlet_mode FROM public.stock_authority_periods WHERE outlet_id=o AND ended_at IS NULL;
  IF outlet_mode<>'QUENA_MOVEMENT_LEDGER' THEN RAISE EXCEPTION 'Unexpected stock authority mode %',outlet_mode; END IF;
  SELECT id INTO STRICT v_product_id FROM public.products WHERE sku='CUTOVER-MULTI';
  PERFORM pg_temp.ipos_test_post_receipt(v_product_id,2,200);
  PERFORM pg_temp.ipos_test_post_receipt(v_product_id,1,80);
  SELECT pr.id,s.effective_quantity,c.valued_quantity,c.unvalued_quantity,c.inventory_value,c.current_wac
    INTO STRICT v_product_id,stock_before,valued_before,unvalued_before,value_before,wac_before
  FROM public.products pr JOIN public.stock_balance_projection s ON s.product_id=pr.id AND s.outlet_id=o
  JOIN public.inventory_cost_projections c ON c.product_id=pr.id AND c.outlet_id=o
  WHERE pr.sku='CUTOVER-MULTI';
  IF stock_before<0.125 OR valued_before<0.125 OR wac_before IS NULL OR
    (SELECT count(*) FROM public.inventory_cost_source_layers WHERE product_id=v_product_id AND outlet_id=o)<3 THEN
    RAISE EXCEPTION 'CUTOVER-MULTI lacks multiple valued source layers'; END IF;
  tx_number:='981234/KSR/UTM/1026';
  INSERT INTO public.ipos_sales_import_batches(outlet_id,upload_request_id,original_filename,file_sha256,report_from,report_to,
    transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,reconciliation,preflight_result,status,revision,uploaded_by)
  VALUES(o,gen_random_uuid(),'wac-depletion-staging.xls',md5(gen_random_uuid()::text)||md5(gen_random_uuid()::text),timezone('Asia/Jakarta',now())::date,
    timezone('Asia/Jakarta',now())::date,1,1,0.125,15,'{"quantity":"0.125","grandTotal":"15"}',
    '{"isReconciled":true,"differences":[]}','{"ready":true}','READY',1,a) RETURNING id INTO b;
  INSERT INTO public.ipos_sales_import_transactions(id,batch_id,source_row_number,source_transaction_number,
    source_occurred_at,raw_transaction_total,raw_data)
  VALUES(t,b,1,tx_number,now()-interval '1 hour',15,'{"payment":"unavailable"}');
  INSERT INTO public.ipos_sales_import_lines(id,batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,
    raw_quantity,raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data,resolution,product_id)
  SELECT l,b,t,2,pr.sku,pr.name,0.125,pr.unit_label,120,0,15,'{}','MATCHED',pr.id
    FROM public.products pr WHERE pr.id=v_product_id;

  result:=public.ipos_sales_import_commit(b,1,request_id);
  SELECT s.id INTO STRICT v_sale_id FROM public.sales s WHERE s.source_import_batch_id=b;
  SELECT m.id INTO STRICT movement_id FROM public.stock_movements m WHERE m.ipos_sales_import_line_id=l;
  SELECT s.effective_quantity,c.valued_quantity,c.unvalued_quantity,c.inventory_value,c.current_wac
    INTO STRICT stock_after,valued_after,unvalued_after,value_after,wac_after
  FROM public.stock_balance_projection s JOIN public.inventory_cost_projections c
    ON c.product_id=s.product_id AND c.outlet_id=s.outlet_id WHERE s.product_id=v_product_id AND s.outlet_id=o;
  IF stock_after<>stock_before-0.125 OR valued_after<>valued_before-0.125 OR unvalued_after<>unvalued_before
    OR value_after<>value_before-round(0.125*wac_before,8) OR wac_after<>wac_before THEN
    RAISE EXCEPTION 'Valuation arithmetic mismatch: stock %->%, valued %->%, value %->%, WAC %->%',
      stock_before,stock_after,valued_before,valued_after,value_before,value_after,wac_before,wac_after;
  END IF;
  IF (SELECT count(*) FROM public.sale_item_cost_evidence e WHERE e.sale_id=v_sale_id)<>0 THEN
    RAISE EXCEPTION 'Imported iPos sale unexpectedly has sale-time COGS evidence';
  END IF;
  SELECT count(*) INTO event_count FROM public.inventory_cost_events e
    WHERE e.source_entity_type='IPOS_IMPORT_INVENTORY_DEPLETION' AND e.source_entity_id=l
      AND e.event_type='CORRECTION'::public.inventory_cost_event_type;
  IF event_count<>1 THEN RAISE EXCEPTION 'Expected one distinct valuation-only cost event, found %',event_count; END IF;
  IF (SELECT count(*) FROM public.inventory_cost_layer_allocations a JOIN public.inventory_cost_events e ON e.id=a.cost_event_id
      WHERE e.source_entity_type='IPOS_IMPORT_INVENTORY_DEPLETION' AND e.source_entity_id=l AND a.allocation_kind='OUTFLOW_VALUED')<>3 THEN
    RAISE EXCEPTION 'The outflow planner did not allocate the sale over all three valued source layers';
  END IF;
  IF (SELECT sum(remaining_valued_quantity+remaining_unvalued_quantity)
      FROM public.inventory_cost_source_layer_balances WHERE product_id=v_product_id AND outlet_id=o)<>stock_after THEN
    RAISE EXCEPTION 'Source-layer quantity does not reconcile with physical stock';
  END IF;
  replay:=public.inventory_cost_apply_ipos_sale_depletion(l,movement_id,a);
  IF replay->>'saleCogsResolved'<>'false' OR
    (SELECT count(*) FROM public.inventory_cost_events e WHERE e.source_entity_type='IPOS_IMPORT_INVENTORY_DEPLETION' AND e.source_entity_id=l)<>1 THEN
    RAISE EXCEPTION 'Cost writer replay was not idempotent';
  END IF;
  IF public.ipos_sales_import_commit(b,1,request_id) IS DISTINCT FROM result THEN
    RAISE EXCEPTION 'Import commit replay did not return the stored result';
  END IF;
  report:=public.owner_reports_read(timezone('Asia/Jakarta',now())::date,timezone('Asia/Jakarta',now())::date,
    timezone('Asia/Jakarta',now())::date-1,timezone('Asia/Jakarta',now())::date-1);
  IF report->>'profit_status'<>'INCOMPLETE' OR report->>'gross_profit' IS NOT NULL
    OR report->>'gross_margin' IS NOT NULL OR report->>'operating_profit' IS NOT NULL THEN
    RAISE EXCEPTION 'Owner Reports must leave profit unavailable for iPos import: %',report;
  END IF;
  dash:=public.owner_dashboard_read(7);
  IF dash#>>'{profit,status}'<>'INCOMPLETE' OR coalesce(dash#>'{profit,gross_profit}'='null'::jsonb,false)=false THEN
    RAISE EXCEPTION 'Dashboard must leave profit unavailable for iPos import: %',dash#>'{profit}';
  END IF;
  pooled_after_value:=value_after;pooled_after_wac:=wac_after;

  SELECT id INTO STRICT v_product2 FROM public.products WHERE sku='CUTOVER-OVERRIDE';
  INSERT INTO public.ipos_sales_import_batches(outlet_id,upload_request_id,original_filename,file_sha256,report_from,report_to,
    transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,reconciliation,preflight_result,status,revision,uploaded_by)
  VALUES(o,gen_random_uuid(),'wac-unvalued-staging.xls',md5(gen_random_uuid()::text)||md5(gen_random_uuid()::text),
    timezone('Asia/Jakarta',now())::date,timezone('Asia/Jakarta',now())::date,1,1,0.5,5,'{"quantity":"0.5","grandTotal":"5"}',
    '{"isReconciled":true,"differences":[]}','{"ready":true}','READY',1,a) RETURNING id INTO b2;
  INSERT INTO public.ipos_sales_import_transactions(id,batch_id,source_row_number,source_transaction_number,source_occurred_at,
    raw_transaction_total,raw_data) VALUES(t2,b2,1,'981235/KSR/UTM/1026',now()-interval '20 minutes',5,'{}');
  INSERT INTO public.ipos_sales_import_lines(id,batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,raw_quantity,
    raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data,resolution,product_id)
  SELECT l2,b2,t2,2,pr.sku,pr.name,0.5,pr.unit_label,10,0,5,'{}','MATCHED',pr.id
    FROM public.products pr WHERE pr.id=v_product2;
  PERFORM public.ipos_sales_import_commit(b2,1,request2);
  SELECT s.id INTO STRICT v_sale2 FROM public.sales s WHERE s.source_import_batch_id=b2;
  SELECT s.effective_quantity,c.valued_quantity,c.unvalued_quantity,c.inventory_value,c.current_wac
    INTO STRICT stock_after,valued_after,unvalued_after,value_after,wac_after
  FROM public.stock_balance_projection s JOIN public.inventory_cost_projections c
    ON c.product_id=s.product_id AND c.outlet_id=s.outlet_id WHERE s.product_id=v_product2 AND s.outlet_id=o;
  IF stock_after<>2 OR valued_after<>0 OR unvalued_after<>2 OR value_after IS NOT NULL OR wac_after IS NOT NULL
    OR (SELECT sum(remaining_unvalued_quantity) FROM public.inventory_cost_source_layer_balances WHERE product_id=v_product2 AND outlet_id=o)<>2
    OR EXISTS(SELECT 1 FROM public.sale_item_cost_evidence e WHERE e.sale_id=v_sale2) THEN
    RAISE EXCEPTION 'Unvalued import assigned a value/COGS or source layers did not reconcile';
  END IF;
  RAISE NOTICE 'IPOS WAC DEPLETION PASS: pooled WAC %, inventory value delta %, 3 layer allocations; unvalued remains NULL-valued; reports unavailable',
    wac_before,pooled_after_value-value_before;
END $$;
CREATE FUNCTION pg_temp.c1_inject_ipos_cost_failure() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.source_entity_type='IPOS_IMPORT_INVENTORY_DEPLETION'
    AND NEW.product_id::text=current_setting('quena.c1_fail_product',true) THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='C1_INJECTED_COST_FAILURE';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER c1_inject_ipos_cost_failure BEFORE INSERT ON public.inventory_cost_events
  FOR EACH ROW EXECUTE FUNCTION pg_temp.c1_inject_ipos_cost_failure();
DO $$
DECLARE
  a uuid:='a0000000-0000-4000-8000-000000000001';o uuid; p1 uuid;p2 uuid;b uuid:=gen_random_uuid();
  t uuid:=gen_random_uuid();l1 uuid:=gen_random_uuid();l2 uuid:=gen_random_uuid();request_id uuid:=gen_random_uuid();
  r1 numeric;r2 numeric;c1 numeric;c2 numeric;v1 numeric;v2 numeric;u1 numeric;u2 numeric;error_code text;tx_number text;
BEGIN
  SELECT id INTO STRICT o FROM public.outlets WHERE code='QUENA-MART-1';
  SELECT id INTO STRICT p1 FROM public.products WHERE sku='CUTOVER-MULTI';
  SELECT id INTO STRICT p2 FROM public.products WHERE sku='CUTOVER-DECIMAL';
  SELECT effective_quantity INTO STRICT r1 FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p1;
  SELECT effective_quantity INTO STRICT r2 FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p2;
  SELECT inventory_value INTO STRICT v1 FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=p1;
  SELECT inventory_value INTO STRICT v2 FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=p2;
  SELECT sum(remaining_valued_quantity+remaining_unvalued_quantity) INTO STRICT c1
    FROM public.inventory_cost_source_layer_balances WHERE outlet_id=o AND product_id=p1;
  SELECT sum(remaining_valued_quantity+remaining_unvalued_quantity) INTO STRICT c2
    FROM public.inventory_cost_source_layer_balances WHERE outlet_id=o AND product_id=p2;
  SELECT sum(remaining_unvalued_quantity) INTO STRICT u1 FROM public.inventory_cost_source_layer_balances WHERE outlet_id=o AND product_id=p1;
  SELECT sum(remaining_unvalued_quantity) INTO STRICT u2 FROM public.inventory_cost_source_layer_balances WHERE outlet_id=o AND product_id=p2;
  tx_number:='981236/KSR/UTM/1026';
  INSERT INTO public.ipos_sales_import_batches(outlet_id,upload_request_id,original_filename,file_sha256,report_from,report_to,
    transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,reconciliation,preflight_result,status,revision,uploaded_by)
  VALUES(o,gen_random_uuid(),'rollback.xls',md5(gen_random_uuid()::text)||md5(gen_random_uuid()::text),
    timezone('Asia/Jakarta',now())::date,timezone('Asia/Jakarta',now())::date,1,2,0.225,22.5,'{}',
    '{"isReconciled":true}','{"ready":true}','READY',1,a) RETURNING id INTO b;
  INSERT INTO public.ipos_sales_import_transactions(id,batch_id,source_row_number,source_transaction_number,
    source_occurred_at,raw_transaction_total,raw_data)
  VALUES(t,b,1,tx_number,now()-interval '10 minutes',22.5,'{}');
  INSERT INTO public.ipos_sales_import_lines(id,batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,raw_quantity,
    raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data,resolution,product_id)
  SELECT l1,b,t,2,p.sku,p.name,0.125,p.unit_label,100,0,12.5,'{}'::jsonb,'MATCHED',p.id FROM public.products p WHERE p.id=p1
  UNION ALL
  SELECT l2,b,t,3,p.sku,p.name,0.1,p.unit_label,100,0,10,'{}'::jsonb,'MATCHED',p.id FROM public.products p WHERE p.id=p2;
  PERFORM set_config('quena.c1_fail_product',p2::text,true);
  BEGIN
    PERFORM public.ipos_sales_import_commit(b,1,request_id);
    RAISE EXCEPTION 'Rollback test failed: import commit unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS error_code=MESSAGE_TEXT;
    IF error_code<>'C1_INJECTED_COST_FAILURE' THEN RAISE; END IF;
  END;
  IF EXISTS(SELECT 1 FROM public.sales WHERE source_import_batch_id=b)
    OR EXISTS(SELECT 1 FROM public.stock_movement_batches WHERE ipos_sales_import_batch_id=b)
    OR EXISTS(SELECT 1 FROM public.stock_movements WHERE ipos_sales_import_line_id IN (l1,l2))
    OR EXISTS(SELECT 1 FROM public.inventory_cost_events WHERE source_entity_id IN (l1,l2)
      AND source_entity_type='IPOS_IMPORT_INVENTORY_DEPLETION')
    OR (SELECT status FROM public.ipos_sales_import_batches WHERE id=b)<>'READY'
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p1)<>r1
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p2)<>r2
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=p1) IS DISTINCT FROM v1
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=p2) IS DISTINCT FROM v2
    OR (SELECT sum(remaining_valued_quantity+remaining_unvalued_quantity) FROM public.inventory_cost_source_layer_balances WHERE outlet_id=o AND product_id=p1)<>c1
    OR (SELECT sum(remaining_valued_quantity+remaining_unvalued_quantity) FROM public.inventory_cost_source_layer_balances WHERE outlet_id=o AND product_id=p2)<>c2
    OR (SELECT sum(remaining_unvalued_quantity) FROM public.inventory_cost_source_layer_balances WHERE outlet_id=o AND product_id=p1)<>u1
    OR (SELECT sum(remaining_unvalued_quantity) FROM public.inventory_cost_source_layer_balances WHERE outlet_id=o AND product_id=p2)<>u2 THEN
    RAISE EXCEPTION 'Injected writer failure left partial sales, movements, valuation, or layer changes';
  END IF;
  RAISE NOTICE 'IPOS WAC MULTI-ITEM FAILURE ROLLBACK PASS';
END $$;
ROLLBACK;
