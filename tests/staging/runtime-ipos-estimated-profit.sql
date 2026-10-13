-- Rollback-only PostgreSQL 15 runtime coverage for frozen IPOS estimates.
-- Uses the isolated quena_stock_staging database only; no production data.
\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database()<>'quena_stock_staging'
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR inet_server_port() NOT IN (55441,55446)
    OR current_setting('server_version_num')::integer/10000<>15
    OR (SELECT count(*) FROM public.inventory_costing_outlet_authority)<>1
    OR NOT EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE status='WAC_ACTIVE')
  THEN RAISE EXCEPTION 'Refusing iPos estimate runtime outside disposable PostgreSQL 15 WAC_ACTIVE staging'; END IF;
END $guard$;
BEGIN;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);

CREATE FUNCTION pg_temp.estimate_batch(p_items jsonb,p_number text)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE o uuid;actor uuid:='a0000000-0000-4000-8000-000000000001';b uuid:=gen_random_uuid();t uuid:=gen_random_uuid();
  n integer;qty numeric;rev numeric;item jsonb;product uuid;
BEGIN
  SELECT id INTO STRICT o FROM public.outlets WHERE code='QUENA-MART-1';
  SELECT count(*),sum((x->>'quantity')::numeric),sum((x->>'revenue')::numeric)
    INTO n,qty,rev FROM jsonb_array_elements(p_items) x;
  INSERT INTO public.ipos_sales_import_batches(id,outlet_id,upload_request_id,original_filename,file_sha256,
    report_from,report_to,transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,
    reconciliation,uploaded_by)
  VALUES(b,o,gen_random_uuid(),p_number||'.xls',md5(gen_random_uuid()::text)||md5(gen_random_uuid()::text),
    '2026-10-12','2026-10-12',1,n,qty,rev,jsonb_build_object('quantity',qty,'grandTotal',rev),
    '{"isReconciled":true,"differences":[]}',actor);
  INSERT INTO public.ipos_sales_import_transactions(id,batch_id,source_row_number,source_transaction_number,
    source_occurred_at,raw_transaction_total,raw_data)
  VALUES(t,b,1,p_number,'2026-10-12 12:00:00+07',rev,jsonb_build_object('sourceTransactionNumber',p_number));
  FOR item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    SELECT id INTO product FROM public.products WHERE sku=item->>'sku';
    INSERT INTO public.ipos_sales_import_lines(batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,
      raw_quantity,raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data,product_id,resolution)
    SELECT b,t,(item->>'row')::integer,item->>'sku',coalesce(p.name,item->>'name'),
      (item->>'quantity')::numeric,coalesce(p.unit_label,'PCS'),
      round((item->>'revenue')::numeric/(item->>'quantity')::numeric,2),0,(item->>'revenue')::numeric,
      item,product,CASE WHEN product IS NULL THEN 'PENDING' ELSE 'MATCHED' END
    FROM (SELECT 1) seed LEFT JOIN public.products p ON p.id=product;
  END LOOP;
  RETURN b;
END $$;

DO $matrix$
DECLARE o uuid;wac_sku text;unvalued_sku text;hpp_sku text;missing_batch uuid;frozen_batch uuid;new_product uuid;mixed_batch uuid;
  result jsonb;snap uuid;summary record;raw_before jsonb;raw_after jsonb;revenue numeric;profit numeric;
  error_message text;reports jsonb;estimate jsonb;stock_before numeric;value_before numeric;layer_before numeric;
  frozen_profit numeric;wac_batch uuid;wac_snapshot uuid;
BEGIN
  SELECT id INTO STRICT o FROM public.outlets WHERE code='QUENA-MART-1';
  SELECT pr.sku INTO STRICT wac_sku FROM public.products pr JOIN public.inventory_cost_projections cp
    ON cp.product_id=pr.id AND cp.outlet_id=o WHERE cp.valuation_status='VALUED' AND cp.current_wac>0
    AND cp.physical_quantity>=0.5 LIMIT 1;
  SELECT pr.sku INTO STRICT unvalued_sku FROM public.products pr JOIN public.inventory_cost_projections cp
    ON cp.product_id=pr.id AND cp.outlet_id=o WHERE cp.valuation_status='UNVALUED' AND cp.physical_quantity>=0.2 LIMIT 1;
  SELECT pr.sku INTO STRICT hpp_sku FROM public.products pr JOIN public.inventory_cost_projections cp
    ON cp.product_id=pr.id AND cp.outlet_id=o WHERE cp.valuation_status='UNVALUED' AND cp.physical_quantity>=0.2 LIMIT 1;
  INSERT INTO public.product_costs(product_id,outlet_id,hpp,created_by,updated_by)
    SELECT p.id,o,2000,'a0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001'
    FROM public.products p WHERE p.sku=hpp_sku ON CONFLICT(product_id,outlet_id) DO UPDATE SET hpp=2000,
      updated_by='a0000000-0000-4000-8000-000000000001';

  SELECT effective_quantity INTO stock_before FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=(SELECT id FROM public.products WHERE sku=wac_sku);
  SELECT inventory_value INTO value_before FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=(SELECT id FROM public.products WHERE sku=wac_sku);
  SELECT coalesce(sum(remaining_valued_quantity+remaining_unvalued_quantity),0) INTO layer_before
    FROM public.inventory_cost_source_layer_balances WHERE outlet_id=o AND product_id=(SELECT id FROM public.products WHERE sku=wac_sku);

  -- Mixed WAC/HPP/missing coverage. Missing SKU is unknown, never a zero-cost line.
  missing_batch:=pg_temp.estimate_batch(jsonb_build_array(
    jsonb_build_object('row',2,'sku',wac_sku,'name','WAC product','quantity',0.1,'revenue',10000),
    jsonb_build_object('row',3,'sku',hpp_sku,'name','Unvalued with reference HPP','quantity',0.1,'revenue',5000),
    jsonb_build_object('row',4,'sku','EST-MISSING-001','name','Unresolved identity','quantity',1,'revenue',2000)
  ),'123001/EST/UTM/1026');
  result:=public.ipos_sales_import_recheck(missing_batch,gen_random_uuid());
  SELECT current_estimate_snapshot_id INTO snap FROM public.ipos_sales_import_batches WHERE id=missing_batch;
  SELECT report_revenue,covered_revenue,uncovered_revenue,estimated_cost,estimated_profit,estimated_margin,
    revenue_coverage,covered_line_count,uncovered_line_count,uncovered_sku_count
    INTO STRICT summary FROM public.ipos_sales_estimate_snapshots WHERE id=snap;
  IF result->>'status'<>'PREFLIGHT_BLOCKED' OR result->>'missingSkuCount'<>'1'
    OR summary.report_revenue<>17000 OR summary.covered_revenue<>15000 OR summary.uncovered_revenue<>2000
    OR summary.estimated_cost IS NULL OR summary.estimated_profit IS NULL OR summary.revenue_coverage<=88
    OR summary.covered_line_count<>2 OR summary.uncovered_line_count<>1 OR summary.uncovered_sku_count<>1 THEN
    RAISE EXCEPTION 'Mixed coverage/WAC/HPP/missing SKU summary mismatch: %, %',result,row_to_json(summary); END IF;
  IF (SELECT count(*) FROM public.ipos_sales_estimate_lines WHERE snapshot_id=snap AND cost_source='WAC')<>1
    OR (SELECT count(*) FROM public.ipos_sales_estimate_lines WHERE snapshot_id=snap AND cost_source='REFERENCE_HPP')<>1
    OR (SELECT count(*) FROM public.ipos_sales_estimate_lines WHERE snapshot_id=snap AND cost_source='UNAVAILABLE')<>1 THEN
    RAISE EXCEPTION 'Cost source priority/fallback classification mismatch'; END IF;
  SELECT jsonb_agg(jsonb_build_object('sku',raw_sku,'qty',raw_quantity,'revenue',raw_line_total) ORDER BY source_row_number)
    INTO raw_before FROM public.ipos_sales_import_lines WHERE batch_id=missing_batch;
  -- Simulate the existing Product iPos master sync: create identity and a
  -- reference HPP, but deliberately create no stock projection/enrollment.
  new_product:=gen_random_uuid();
  INSERT INTO public.products(id,sku,name,unit_label,created_by,updated_by)
    VALUES(new_product,'EST-MISSING-001','Synced identity without stock','pcs',
      'a0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001');
  INSERT INTO public.product_costs(product_id,outlet_id,hpp,created_by,updated_by)
    VALUES(new_product,o,500,'a0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001');
  result:=public.ipos_sales_import_recheck(missing_batch,gen_random_uuid());
  SELECT current_estimate_snapshot_id INTO snap FROM public.ipos_sales_import_batches WHERE id=missing_batch;
  IF result->>'missingSkuCount'<>'0' OR result->>'stockBlockerCount'<>'1'
    OR (SELECT revenue_coverage FROM public.ipos_sales_estimate_snapshots WHERE id=snap)<>100
    OR (SELECT count(*) FROM public.stock_balance_projection WHERE product_id=new_product AND outlet_id=o)<>0 THEN
    RAISE EXCEPTION 'Product identity sync did not resolve estimate independently of stock readiness: %',result; END IF;
  RAISE NOTICE 'Product master identity sync resolves missing SKU; stock blocker remains, no stock authority created PASS';
  UPDATE public.product_costs SET hpp=2500,updated_by='a0000000-0000-4000-8000-000000000001'
    WHERE product_id=(SELECT id FROM public.products WHERE sku=hpp_sku) AND outlet_id=o;
  result:=public.ipos_sales_import_recheck(missing_batch,gen_random_uuid());
  SELECT current_estimate_snapshot_id INTO snap FROM public.ipos_sales_import_batches WHERE id=missing_batch;
  IF result->>'status'<>'PREFLIGHT_BLOCKED' OR result->>'missingSkuCount'<>'0'
    OR (SELECT estimated_cost FROM public.ipos_sales_estimate_snapshots WHERE id=snap) IS NULL
    OR abs((SELECT estimated_cost FROM public.ipos_sales_estimate_snapshots WHERE id=snap)-
      (0.1*(SELECT current_wac FROM public.inventory_cost_projections WHERE product_id=(SELECT id FROM public.products WHERE sku=wac_sku) AND outlet_id=o)
       +250+500))>0.00000001 THEN RAISE EXCEPTION 'Recheck did not refresh current HPP/WAC estimate: result %, cost %, expected %',result,
        (SELECT estimated_cost FROM public.ipos_sales_estimate_snapshots WHERE id=snap),
        0.1*(SELECT current_wac FROM public.inventory_cost_projections WHERE product_id=(SELECT id FROM public.products WHERE sku=wac_sku) AND outlet_id=o)+250+500; END IF;
  SELECT jsonb_agg(jsonb_build_object('sku',raw_sku,'qty',raw_quantity,'revenue',raw_line_total) ORDER BY source_row_number)
    INTO raw_after FROM public.ipos_sales_import_lines WHERE batch_id=missing_batch;
  IF raw_before IS DISTINCT FROM raw_after THEN RAISE EXCEPTION 'Recheck mutated persisted raw sale evidence'; END IF;
  RAISE NOTICE 'Partial WAC+reference HPP+missing SKU, recheck refresh, raw immutability PASS';

  -- Zero coverage exposes no fabricated zero HPP/profit.
  missing_batch:=pg_temp.estimate_batch(jsonb_build_array(
    jsonb_build_object('row',2,'sku','EST-MISSING-ONLY','name','No product','quantity',1,'revenue',1000)
  ),'123002/EST/UTM/1026');
  PERFORM public.ipos_sales_import_recheck(missing_batch,gen_random_uuid());
  SELECT current_estimate_snapshot_id INTO snap FROM public.ipos_sales_import_batches WHERE id=missing_batch;
  IF (SELECT estimated_cost FROM public.ipos_sales_estimate_snapshots WHERE id=snap) IS NOT NULL
    OR (SELECT estimated_profit FROM public.ipos_sales_estimate_snapshots WHERE id=snap) IS NOT NULL
    OR (SELECT revenue_coverage FROM public.ipos_sales_estimate_snapshots WHERE id=snap)<>0 THEN
    RAISE EXCEPTION 'Zero-coverage estimate was rendered as known zero cost/profit'; END IF;
  RAISE NOTICE 'Zero coverage unavailable semantics PASS';

  wac_batch:=pg_temp.estimate_batch(jsonb_build_array(
    jsonb_build_object('row',2,'sku',wac_sku,'name','WAC product','quantity',0.1,'revenue',1000)
  ),'123004/EST/UTM/1026');
  result:=public.ipos_sales_import_recheck(wac_batch,gen_random_uuid());
  SELECT current_estimate_snapshot_id INTO wac_snapshot FROM public.ipos_sales_import_batches WHERE id=wac_batch;
  IF result->>'status'<>'READY'
    OR (SELECT revenue_coverage FROM public.ipos_sales_estimate_snapshots WHERE id=wac_snapshot)<>100
    OR (SELECT estimated_cost FROM public.ipos_sales_estimate_snapshots WHERE id=wac_snapshot)
      IS DISTINCT FROM (SELECT current_wac*0.1 FROM public.inventory_cost_projections cp
        JOIN public.products p ON p.id=cp.product_id WHERE cp.outlet_id=o AND p.sku=wac_sku) THEN
    RAISE EXCEPTION '100 percent WAC coverage/cost did not reconcile: %',result; END IF;
  RAISE NOTICE '100%% authoritative WAC coverage arithmetic PASS';

  -- Loss estimate remains negative; commit freezes the estimate and does not create sale COGS.
  frozen_batch:=pg_temp.estimate_batch(jsonb_build_array(
    jsonb_build_object('row',2,'sku',hpp_sku,'name','Unvalued reference-cost product','quantity',0.1,'revenue',100)
  ),'123003/EST/UTM/1026');
  result:=public.ipos_sales_import_recheck(frozen_batch,gen_random_uuid());
  IF result->>'status'<>'READY' THEN RAISE EXCEPTION 'Sale fixture did not preflight READY: %',result; END IF;
  SELECT revision INTO STRICT summary FROM public.ipos_sales_import_batches WHERE id=frozen_batch;
  SELECT current_estimate_snapshot_id INTO snap FROM public.ipos_sales_import_batches WHERE id=frozen_batch;
  IF (SELECT estimated_profit FROM public.ipos_sales_estimate_snapshots WHERE id=snap)>=0 THEN
    RAISE EXCEPTION 'Negative estimate was clipped or rounded to zero'; END IF;
  SELECT estimated_profit INTO STRICT frozen_profit FROM public.ipos_sales_estimate_snapshots WHERE id=snap;
  result:=public.ipos_sales_import_commit(frozen_batch,summary.revision,gen_random_uuid());
  IF result->>'status'<>'COMMITTED' THEN RAISE EXCEPTION 'Estimate fixture commit failed: %',result; END IF;
  IF (SELECT frozen_estimate_snapshot_id FROM public.ipos_sales_import_batches WHERE id=frozen_batch) IS DISTINCT FROM snap
    OR (SELECT frozen_at FROM public.ipos_sales_estimate_snapshots WHERE id=snap) IS NULL
    OR EXISTS(SELECT 1 FROM public.sale_item_cost_evidence e JOIN public.sales s ON s.id=e.sale_id WHERE s.source_import_batch_id=frozen_batch) THEN
    RAISE EXCEPTION 'Commit did not freeze estimate or unexpectedly created historical sale COGS'; END IF;
  UPDATE public.product_costs SET hpp=3000,updated_by='a0000000-0000-4000-8000-000000000001'
    WHERE product_id=(SELECT id FROM public.products WHERE sku=hpp_sku) AND outlet_id=o;
  IF (SELECT estimated_profit FROM public.ipos_sales_estimate_snapshots WHERE id=snap)
     IS DISTINCT FROM frozen_profit
    OR (SELECT frozen_estimate_snapshot_id FROM public.ipos_sales_import_batches WHERE id=frozen_batch) IS DISTINCT FROM snap THEN
    RAISE EXCEPTION 'Committed estimate snapshot changed after reference HPP update'; END IF;
  SELECT public.ipos_estimated_profit_read('2026-10-12','2026-10-12') INTO estimate;
  IF (estimate->>'revenue')::numeric<>100 OR (estimate->>'estimatedProfit')::numeric>=0 THEN
    RAISE EXCEPTION 'Period estimate read did not use frozen negative estimate: %',estimate; END IF;
  -- A second committed batch has stock authority but no usable cost reference.
  -- Coverage must be revenue-weighted (100 / 400 = 25%), not an average of
  -- batch percentages (which would misleadingly report 50%).
  UPDATE public.product_costs SET hpp=NULL,updated_by='a0000000-0000-4000-8000-000000000001'
    WHERE product_id=(SELECT id FROM public.products WHERE sku=hpp_sku) AND outlet_id=o;
  mixed_batch:=pg_temp.estimate_batch(jsonb_build_array(
    jsonb_build_object('row',2,'sku',hpp_sku,'name','Unvalued without reference cost','quantity',0.1,'revenue',300)
  ),'123005/EST/UTM/1026');
  result:=public.ipos_sales_import_recheck(mixed_batch,gen_random_uuid());
  IF result->>'status'<>'READY' THEN RAISE EXCEPTION 'Unvalued/no-HPP sale was not importable with stock authority: %',result; END IF;
  SELECT revision INTO STRICT summary FROM public.ipos_sales_import_batches WHERE id=mixed_batch;
  result:=public.ipos_sales_import_commit(mixed_batch,summary.revision,gen_random_uuid());
  SELECT public.ipos_estimated_profit_read('2026-10-12','2026-10-12') INTO estimate;
  IF (estimate->>'revenue')::numeric<>400 OR (estimate->>'coveredRevenue')::numeric<>100
    OR (estimate->>'revenueCoverage')::numeric<>25 OR (estimate->>'estimatedCost')::numeric<>250
    OR (estimate->>'estimatedProfit')::numeric<>-150 THEN
    RAISE EXCEPTION 'Multi-batch estimate aggregation was not weighted by revenue: %',estimate; END IF;
  RAISE NOTICE 'Multiple committed snapshots aggregate with revenue-weighted 25%% coverage PASS';
  SELECT public.owner_reports_read('2026-10-12','2026-10-12','2026-10-11','2026-10-11') INTO reports;
  IF reports->'kpis'->>'profit_status' NOT IN ('INCOMPLETE','COSTING_INACTIVE')
    OR reports->'kpis'->>'gross_profit' IS NOT NULL OR reports->'kpis'->>'operating_profit' IS NOT NULL THEN
    RAISE EXCEPTION 'Official profit became available due to iPos estimate: %',reports->'kpis'; END IF;
  RAISE NOTICE 'Commit freeze, negative estimate, report estimate, official profit unavailable, no sale COGS PASS';

  IF (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=(SELECT id FROM public.products WHERE sku=wac_sku))<>stock_before
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=(SELECT id FROM public.products WHERE sku=wac_sku)) IS DISTINCT FROM value_before
    OR (SELECT coalesce(sum(remaining_valued_quantity+remaining_unvalued_quantity),0) FROM public.inventory_cost_source_layer_balances WHERE outlet_id=o AND product_id=(SELECT id FROM public.products WHERE sku=wac_sku))<>layer_before THEN
    RAISE EXCEPTION 'Estimate calculation mutated unrelated WAC stock/value/source layers'; END IF;

  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
  PERFORM public.ipos_estimated_profit_read('2026-10-12','2026-10-12');
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
  error_message:=NULL;BEGIN PERFORM public.ipos_estimated_profit_read('2026-10-12','2026-10-12');
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS error_message=MESSAGE_TEXT;END;
  IF error_message NOT LIKE '%IPOS_SALES_ESTIMATE_UNAUTHORIZED%' THEN RAISE EXCEPTION 'GUDANG could read estimates: %',error_message; END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
  error_message:=NULL;BEGIN PERFORM public.ipos_estimated_profit_read('2026-10-12','2026-10-12');
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS error_message=MESSAGE_TEXT;END;
  IF error_message NOT LIKE '%IPOS_SALES_ESTIMATE_UNAUTHORIZED%' THEN RAISE EXCEPTION 'KASIR could read estimates: %',error_message; END IF;
  RAISE NOTICE 'Role matrix OWNER/ADMIN allowed, GUDANG/KASIR denied PASS';
END $matrix$;
ROLLBACK;
