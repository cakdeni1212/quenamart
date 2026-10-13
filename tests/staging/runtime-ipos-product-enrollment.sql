-- C3A post-WAC product identity, receipt initialization and explicit enrollment.
-- Rollback-only: disposable localhost PostgreSQL 15 only.
DO $guard$
BEGIN
  IF current_database()<>'quena_stock_staging'
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR inet_server_port() NOT IN (55441,55442) OR current_setting('server_version_num')::integer/10000<>15
    OR current_setting('server_encoding')<>'UTF8' THEN
    RAISE EXCEPTION 'Refusing C3 runtime test outside the guarded local PostgreSQL 15 staging DB';
  END IF;
END $guard$;
BEGIN;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
CREATE FUNCTION pg_temp.c3a_create_ipos_product(p_sku text,p_name text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE a uuid:=auth.uid();o uuid;rq uuid;ib uuid;rowid uuid:=gen_random_uuid();path text;expected jsonb;payload jsonb;result jsonb;pid uuid;
BEGIN
  SELECT id INTO STRICT o FROM public.outlets WHERE code='QUENA-MART-1';
  path:='incoming/'||a::text||'/'||gen_random_uuid()::text||'.xlsx';
  INSERT INTO storage.objects(bucket_id,name) VALUES('quena-ipos-imports',path);
  rq:=public.request_ipos_import(o,path,'C3A-Product-master-sync.xlsx');
  ib:=(public.claim_ipos_import_request(rq)->>'batch_id')::uuid;
  INSERT INTO public.ipos_import_rows(id,batch_id,outlet_id,source_row_number,raw_data,status)
  VALUES(rowid,ib,o,3,jsonb_build_object('KODEITEM',p_sku,'NAMAITEM',p_name,'SATUAN','PCS','STOK',777),'RAW_ONLY');
  IF public.complete_ipos_import_request(rq,ib,1)<>1 THEN RAISE EXCEPTION 'C3A product source import failed'; END IF;
  SELECT jsonb_build_object('products',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'sku',p.sku,'name',p.name) ORDER BY p.id)
    FROM public.products p),'[]'::jsonb),'barcodes','[]'::jsonb,'overrides','[]'::jsonb) INTO expected;
  payload:=jsonb_build_object('normalizationVersion','ipos-v1-preflight','batchId',ib::text,'outletId',o::text,
    'expectedState',expected,'rows',jsonb_build_array(jsonb_build_object('source_row_id',rowid::text,'source_row',3,
      'action','CREATE','sku',p_sku,'expected_product_id',NULL,
      'normalized_data',jsonb_build_object('sku',p_sku,'name',p_name,'categoryLabel','Minuman','brandLabel','Test',
        'unitLabel','PCS','departmentLabel','Minuman','sourceDescription','C3A Product master sync',
        'sourceReferenceCode',p_sku,'barcode',NULL,'barcodeState','BLANK','rackLabel',NULL,'quantity','777',
        'minimumQuantity','0','sellingPrice','12000','hpp','9000'),
      'audit_findings','[]'::jsonb,'issues','[]'::jsonb,'blocked_override_fields','[]'::jsonb)));
  result:=public.commit_ipos_normalization(ib,'ipos-v1-preflight',payload);
  IF result->>'linkedRows'<>'1' THEN RAISE EXCEPTION 'C3A normalization did not create identity: %',result; END IF;
  SELECT id INTO STRICT pid FROM public.products WHERE sku=p_sku;
  IF (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=pid) IS NOT NULL
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=pid) THEN
    RAISE EXCEPTION 'Product master import (including STOK=777/reference HPP) created authority'; END IF;
  RETURN pid;
END; $$;
DO $c3$
DECLARE
  v_actor uuid:='a0000000-0000-4000-8000-000000000001';
  v_outlet uuid; v_product uuid; v_sku text; v_name text; v_unit text; v_report jsonb;
  v_missing_batch uuid:=gen_random_uuid(); v_missing_tx uuid:=gen_random_uuid(); v_missing_line uuid:=gen_random_uuid();
  v_dup_batch uuid:=gen_random_uuid(); v_dup_tx1 uuid:=gen_random_uuid(); v_dup_tx2 uuid:=gen_random_uuid();
  v_dup_line1 uuid:=gen_random_uuid(); v_dup_line2 uuid:=gen_random_uuid();
  v_commit_batch uuid:=gen_random_uuid(); v_commit_tx uuid:=gen_random_uuid(); v_commit_line uuid:=gen_random_uuid();
  v_overlap_batch uuid:=gen_random_uuid(); v_overlap_tx uuid:=gen_random_uuid(); v_overlap_line uuid:=gen_random_uuid();
  v_product_import_request uuid; v_product_import_batch uuid; v_product_source_row uuid:=gen_random_uuid();
  v_product_expected jsonb; v_product_payload jsonb; v_product_result jsonb;
  v_request uuid:=gen_random_uuid(); v_revision integer; v_result jsonb; v_error text;
  v_supplier uuid;v_receipt uuid;v_receipt_item uuid;v_receipt_revision integer;v_receipt_request uuid;v_receipt_result jsonb;
  v_hash text; v_file_result jsonb; v_product_stock numeric; v_sales integer; v_moves integer; v_cost_events integer;
BEGIN
  SELECT id INTO STRICT v_outlet FROM public.outlets WHERE code='QUENA-MART-1';
  SELECT p.id,p.sku,p.name,p.unit_label INTO STRICT v_product,v_sku,v_name,v_unit
    FROM public.products p WHERE p.sku='CUTOVER-MULTI';

  -- Missing real-fixture-derived SKU: this models QUENAEX line 25, transaction
  -- 047314/KSR/UTM/1026, with quantity/price/line total unchanged.
  INSERT INTO public.ipos_sales_import_batches(id,outlet_id,upload_request_id,original_filename,file_sha256,
    report_from,report_to,transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,reconciliation,uploaded_by)
  VALUES(v_missing_batch,v_outlet,gen_random_uuid(),'QUENAEX-c3-test-copy.xls',repeat('a',64),'2026-10-12','2026-10-12',
    1,1,2,21000,'{"quantity":"2","grandTotal":"21000"}',
    '{"isReconciled":true,"differences":[]}',v_actor);
  INSERT INTO public.ipos_sales_import_transactions(id,batch_id,source_row_number,source_transaction_number,
    source_occurred_at,raw_transaction_total,raw_data)
  VALUES(v_missing_tx,v_missing_batch,20,'047314/KSR/UTM/1026','2026-10-12 06:08:08+07',21000,
    '{"sourceRowNumber":20,"sourceTransactionNumber":"047314/KSR/UTM/1026"}');
  INSERT INTO public.ipos_sales_import_lines(id,batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,
    raw_quantity,raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data)
  VALUES(v_missing_line,v_missing_batch,v_missing_tx,25,'TEST-SKU-BARU-001','KOPI TOP PLUS RENTENG',2,'PCS',10500,0,21000,
    '{"rawSku":"TEST-SKU-BARU-001","rawQuantity":"2","rawUnitPrice":"10500","rawLineTotal":"21000"}');
  v_result:=public.ipos_sales_import_recheck(v_missing_batch,gen_random_uuid());
  IF v_result->>'status'<>'PREFLIGHT_BLOCKED' OR (v_result->>'missingSkuCount')::integer<>1
    OR (v_result->'reconciliation'->>'isReconciled')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Missing SKU fixture did not block independently of reconciliation: %',v_result;
  END IF;
  SELECT revision INTO v_revision FROM public.ipos_sales_import_batches WHERE id=v_missing_batch;
  BEGIN PERFORM public.ipos_sales_import_commit(v_missing_batch,v_revision,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT; END;
  IF v_error NOT LIKE '%IPOS_SALES_IMPORT_NOT_READY%' AND v_error NOT LIKE '%IPOS_SALES_IMPORT_SKU_UNRESOLVED%' THEN
    RAISE EXCEPTION 'Missing SKU commit was not rejected deterministically: %',v_error;
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales WHERE source_import_batch_id=v_missing_batch)
    OR EXISTS(SELECT 1 FROM public.stock_movement_batches WHERE ipos_sales_import_batch_id=v_missing_batch)
    OR EXISTS(SELECT 1 FROM public.stock_movements WHERE ipos_sales_import_line_id=v_missing_line)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_events WHERE source_entity_id=v_missing_line) THEN
    RAISE EXCEPTION 'Blocked missing SKU batch mutated sales, stock, or costing';
  END IF;
  IF (SELECT raw_data->>'rawSku' FROM public.ipos_sales_import_lines WHERE id=v_missing_line)<>'TEST-SKU-BARU-001'
    OR (SELECT raw_line_total FROM public.ipos_sales_import_lines WHERE id=v_missing_line)<>21000 THEN
    RAISE EXCEPTION 'Preflight modified immutable raw line evidence';
  END IF;
  RAISE NOTICE 'C3 missing-SKU fixture PASS: line 25 / 047314/KSR/UTM/1026 blocked, reconciliation exact, zero mutation';
  -- Simulate the independent Product iPos sync through its existing worker and
  -- normalization commit contracts. The sales batch/raw line is never edited.
  INSERT INTO storage.objects(bucket_id,name) VALUES('quena-ipos-imports',
    'incoming/'||v_actor::text||'/'||gen_random_uuid()::text||'.xlsx') RETURNING name INTO v_error;
  v_product_import_request:=public.request_ipos_import(v_outlet,v_error,'product-master-c3.xlsx');
  v_product_import_batch:=(public.claim_ipos_import_request(v_product_import_request)->>'batch_id')::uuid;
  INSERT INTO public.ipos_import_rows(id,batch_id,outlet_id,source_row_number,raw_data,status)
  VALUES(v_product_source_row,v_product_import_batch,v_outlet,3,
    '{"KODEITEM":"TEST-SKU-BARU-001","NAMAITEM":"KOPI TOP PLUS RENTENG","SATUAN":"PCS","STOK":0}',
    'RAW_ONLY');
  IF public.complete_ipos_import_request(v_product_import_request,v_product_import_batch,1)<>1 THEN
    RAISE EXCEPTION 'Product iPos staging request did not complete'; END IF;
  SELECT jsonb_build_object(
    'products',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'sku',p.sku,'name',p.name) ORDER BY p.id)
      FROM public.products p),'[]'::jsonb),
    'barcodes','[]'::jsonb,'overrides','[]'::jsonb) INTO v_product_expected;
  v_product_payload:=jsonb_build_object('normalizationVersion','ipos-v1-preflight',
    'batchId',v_product_import_batch::text,'outletId',v_outlet::text,'expectedState',v_product_expected,
    'rows',jsonb_build_array(jsonb_build_object('source_row_id',v_product_source_row::text,'source_row',3,
      'action','CREATE','sku','TEST-SKU-BARU-001','expected_product_id',NULL,
      'normalized_data',jsonb_build_object('sku','TEST-SKU-BARU-001','name','KOPI TOP PLUS RENTENG',
        'categoryLabel','Minuman','brandLabel','Test','unitLabel','PCS','departmentLabel','Minuman',
        'sourceDescription','Product master staging sync','sourceReferenceCode','TEST-SKU-BARU-001',
        'barcode',NULL,'barcodeState','BLANK','rackLabel',NULL,'quantity','0','minimumQuantity','0',
        'sellingPrice','12000','hpp','9000'),
      'audit_findings','[]'::jsonb,'issues','[]'::jsonb,'blocked_override_fields','[]'::jsonb)));
  v_product_result:=public.commit_ipos_normalization(v_product_import_batch,'ipos-v1-preflight',v_product_payload);
  SELECT id INTO STRICT v_product FROM public.products WHERE sku='TEST-SKU-BARU-001';
  IF v_product_result->>'linkedRows'<>'1' OR NOT EXISTS(SELECT 1 FROM public.ipos_import_rows
      WHERE id=v_product_source_row AND status='VALID' AND product_id=v_product) THEN
    RAISE EXCEPTION 'Product iPos normalization semantics did not create the missing SKU'; END IF;
  -- Product identity imported after WAC does not itself provide stock/cost authority.
  IF (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id=v_product AND outlet_id=v_outlet) IS NOT NULL
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections WHERE product_id=v_product AND outlet_id=v_outlet) THEN
    RAISE EXCEPTION 'Product master sync created stock or costing authority';
  END IF;
  -- A receipt timestamp later than the pending iPos sale cannot be used to
  -- claim an earlier inventory quantity; raw SKU matching catches the batch
  -- even before its blocked preflight has assigned product_id.
  v_supplier:=public.purchase_supplier_upsert(NULL,'C3A Pending Sale Supplier',NULL,NULL,NULL,true);
  v_receipt:=public.purchase_receipt_create_draft(v_outlet,v_supplier,'2026-10-12 06:15:00+07','C3A late receipt chronology probe');
  PERFORM public.purchase_receipt_save_draft(v_receipt,1,'2026-10-12 06:15:00+07',NULL,jsonb_build_array(jsonb_build_object(
    'product_id',v_product,'accepted_quantity',10,'bonus_quantity',0,'rejected_quantity',0)));
  SELECT id INTO STRICT v_receipt_item FROM public.purchase_receipt_items WHERE receipt_id=v_receipt;
  SELECT draft_revision INTO STRICT v_receipt_revision FROM public.purchase_receipts WHERE id=v_receipt;
  PERFORM public.purchase_receipt_acquisition_estimate_save(v_receipt,v_receipt_item,v_receipt_revision,0,
    'MANAGER_ESTIMATE',5000,'C3A chronology test','invoice');
  v_receipt_request:=public.issue_purchase_receipt_post_intent(v_receipt);v_error:=NULL;
  BEGIN PERFORM public.apply_purchase_receipt_post_intent(v_receipt_request);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT; END;
  IF v_error NOT LIKE '%POST_WAC_ENROLLMENT_PRE_RECEIPT_SALE_CONFLICT%'
    OR (SELECT status FROM public.purchase_receipts WHERE id=v_receipt)<>'DRAFT'
    OR EXISTS(SELECT 1 FROM public.stock_movements WHERE purchase_receipt_item_id=v_receipt_item)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections WHERE product_id=v_product AND outlet_id=v_outlet)
    OR EXISTS(SELECT 1 FROM public.post_wac_product_enrollments WHERE product_id=v_product AND outlet_id=v_outlet) THEN
    RAISE EXCEPTION 'Normal receipt ignored a pending pre-receipt iPos sale or partially mutated: %',v_error; END IF;
  RAISE NOTICE 'C3A receipt chronology guard PASS: pending raw-SKU sale before receipt blocks receipt baseline, no stock/cost mutation';
  -- The sale at 06:08 is already reflected in physical quantity 2 attested at 06:10.
  v_result:=public.enroll_post_wac_product(gen_random_uuid(),v_product,2,'VALUED',1000,
    '2026-10-12 06:10:00+07','Owner confirmed physical quantity after the 06:08 iPos sale.');
  IF v_result->>'ok'<>'true' OR (v_result->>'effectiveQuantity')::numeric<>2
    OR (v_result->>'inventoryValue')::numeric<>2000 OR (v_result->>'wac')::numeric<>1000 THEN
    RAISE EXCEPTION 'Transition enrollment valuation wrong: %',v_result;
  END IF;
  IF (SELECT count(*) FROM public.inventory_cost_source_layers WHERE product_id=v_product AND outlet_id=v_outlet)<>1 THEN
    RAISE EXCEPTION 'Enrollment did not open its authoritative source layer';
  END IF;
  RAISE NOTICE 'C3A Product master separation + valued transition enrollment PASS: quantity 2, value Rp2,000, WAC Rp1,000';
  RAISE NOTICE 'C3 new product projection period %, active period %',
    (SELECT authority_period_id FROM public.stock_balance_projection WHERE product_id=v_product AND outlet_id=v_outlet),
    (SELECT id FROM public.stock_authority_periods WHERE outlet_id=v_outlet AND ended_at IS NULL);
  v_result:=public.ipos_sales_import_recheck(v_missing_batch,gen_random_uuid());
  IF v_result->>'status'<>'READY' OR (v_result->>'missingSkuCount')::integer<>0
    OR (v_result->>'stockBlockerCount')::integer<>0
    OR (v_result->'reconciliation'->>'isReconciled')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Cek Ulang after Product sync + enrollment did not make the same batch READY: %',v_result;
  END IF;
  IF (SELECT raw_data->>'rawSku' FROM public.ipos_sales_import_lines WHERE id=v_missing_line)<>'TEST-SKU-BARU-001'
    OR (SELECT raw_line_total FROM public.ipos_sales_import_lines WHERE id=v_missing_line)<>21000
    OR (SELECT product_id FROM public.ipos_sales_import_lines WHERE id=v_missing_line) IS DISTINCT FROM v_product THEN
    RAISE EXCEPTION 'Cek Ulang altered raw evidence or failed to bind exact normalized product'; END IF;
  IF (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id=v_product AND outlet_id=v_outlet)<>2
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE product_id=v_product AND outlet_id=v_outlet)<>2000
    OR (SELECT current_wac FROM public.inventory_cost_projections WHERE product_id=v_product AND outlet_id=v_outlet)<>1000 THEN
    RAISE EXCEPTION 'Rechecked batch product does not have the explicitly enrolled quantity/value/WAC'; END IF;
  SELECT revision INTO v_revision FROM public.ipos_sales_import_batches WHERE id=v_missing_batch;
  v_result:=public.ipos_sales_import_commit(v_missing_batch,v_revision,gen_random_uuid());
  IF v_result->>'status'<>'COMMITTED' OR (SELECT count(*) FROM public.sales WHERE source_import_batch_id=v_missing_batch)<>1
    OR EXISTS(SELECT 1 FROM public.stock_movements WHERE ipos_sales_import_line_id=v_missing_line)
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id=v_product AND outlet_id=v_outlet)<>2
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE product_id=v_product AND outlet_id=v_outlet)<>2000
    OR NOT EXISTS(SELECT 1 FROM public.ipos_sales_import_stock_dispositions WHERE import_line_id=v_missing_line
      AND disposition='INCLUDED_IN_CONFIRMED_BASELINE') THEN
    RAISE EXCEPTION 'Persisted pre-enrollment sale did not commit exactly once as baseline-included: %',v_result;
  END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_cost_events e WHERE e.product_id=v_product AND e.event_type='SALE_COGS') THEN
    RAISE EXCEPTION 'IPOS import fabricated sale-time COGS'; END IF;
  RAISE NOTICE 'C3A persisted blocked batch lifecycle PASS: same raw batch rechecked READY; sale imported, baseline quantity/value unchanged, no fake COGS';

  -- Later iPos sale uses C1's normal stock-out/valuation writer.
  DECLARE
    b uuid:=gen_random_uuid();tx uuid:=gen_random_uuid();ln uuid:=gen_random_uuid(); rev integer;after_result jsonb;
  BEGIN
    INSERT INTO public.ipos_sales_import_batches(id,outlet_id,upload_request_id,original_filename,file_sha256,
      report_from,report_to,transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,reconciliation,uploaded_by)
    VALUES(b,v_outlet,gen_random_uuid(),'post-enrollment-sale.xls',repeat('e',64),'2026-10-12','2026-10-12',
      1,1,1,10000,'{"quantity":"1","grandTotal":"10000"}','{"isReconciled":true}',v_actor);
    INSERT INTO public.ipos_sales_import_transactions(id,batch_id,source_row_number,source_transaction_number,
      source_occurred_at,raw_transaction_total,raw_data)
    VALUES(tx,b,1,'047317/KSR/UTM/1026','2026-10-12 06:11:00+07',10000,'{}');
    INSERT INTO public.ipos_sales_import_lines(id,batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,
      raw_quantity,raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data)
    VALUES(ln,b,tx,2,'TEST-SKU-BARU-001','KOPI TOP PLUS RENTENG',1,'PCS',10000,0,10000,'{}');
    after_result:=public.ipos_sales_import_recheck(b,gen_random_uuid());
    IF after_result->>'status'<>'READY' THEN RAISE EXCEPTION 'Later post-enrollment sale not READY: %',after_result; END IF;
    SELECT revision INTO rev FROM public.ipos_sales_import_batches WHERE id=b;
    after_result:=public.ipos_sales_import_commit(b,rev,gen_random_uuid());
    IF after_result->>'status'<>'COMMITTED'
      OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id=v_product AND outlet_id=v_outlet)<>1
      OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE product_id=v_product AND outlet_id=v_outlet)<>1000
      OR (SELECT current_wac FROM public.inventory_cost_projections WHERE product_id=v_product AND outlet_id=v_outlet)<>1000
      OR (SELECT count(*) FROM public.inventory_cost_events WHERE product_id=v_product AND source_entity_type='IPOS_IMPORT_INVENTORY_DEPLETION')<>1
      OR EXISTS(SELECT 1 FROM public.inventory_cost_events WHERE product_id=v_product AND event_type='SALE_COGS') THEN
      RAISE EXCEPTION 'Post-enrollment C1 depletion did not reconcile or created COGS'; END IF;
    RAISE NOTICE 'C3A C1 post-enrollment regression PASS: later sale stock=1, value=Rp1,000, WAC=Rp1,000, sale COGS unresolved';
    v_report:=public.owner_reports_read('2026-10-12','2026-10-12','2026-10-11','2026-10-11');
    IF v_report#>>'{kpis,revenue}'<>'31000.00' OR v_report#>>'{kpis,transactions}'<>'2'
      OR v_report#>>'{kpis,profit_status}'<>'INCOMPLETE'
      OR v_report#>'{kpis,gross_profit}' IS DISTINCT FROM 'null'::jsonb
      OR v_report#>'{kpis,gross_margin}' IS DISTINCT FROM 'null'::jsonb
      OR v_report#>'{kpis,operating_profit}' IS DISTINCT FROM 'null'::jsonb
      OR v_report->'profit_trend' IS DISTINCT FROM 'null'::jsonb THEN
      RAISE EXCEPTION 'Owner Reports treated iPos inventory depletion as resolved COGS: %',v_report->'kpis'; END IF;
    RAISE NOTICE 'C3A Owner Reports PASS: revenue and transactions available; gross/operating profit and profit trend unavailable';
  END;
  RAISE NOTICE 'C3A same-batch Product sync, enrollment, recheck and import pass; raw line evidence unchanged';
END $c3$;

DO $normal_receipt$
DECLARE
  a uuid:='a0000000-0000-4000-8000-000000000001';o uuid;p uuid;supplier uuid;receipt uuid;item uuid;rev integer;req uuid;r jsonb;
  b uuid;tx uuid;ln uuid;batch_rev integer;report jsonb;late_batch uuid;late_tx uuid;late_line uuid;late_error text;
  received timestamptz:=transaction_timestamp()-interval '5 minutes';
BEGIN
  SELECT id INTO STRICT o FROM public.outlets WHERE code='QUENA-MART-1';
  p:=pg_temp.c3a_create_ipos_product('TEST-RECEIPT-001','C3A Receipt Product');
  IF (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p) IS NOT NULL
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=p) THEN
    RAISE EXCEPTION 'Receipt product master sync supplied authority before receiving'; END IF;
  supplier:=public.purchase_supplier_upsert(NULL,'C3A First Receipt Supplier',NULL,NULL,NULL,true);
  receipt:=public.purchase_receipt_create_draft(o,supplier,received,'C3A normal first receipt');
  r:=public.purchase_receipt_save_draft(receipt,1,received,NULL,jsonb_build_array(jsonb_build_object(
    'product_id',p,'accepted_quantity',10,'bonus_quantity',0,'rejected_quantity',0)));
  SELECT i.id INTO STRICT item FROM public.purchase_receipt_items i WHERE i.receipt_id=receipt;
  SELECT draft_revision INTO STRICT rev FROM public.purchase_receipts WHERE id=receipt;
  r:=public.purchase_receipt_acquisition_estimate_save(receipt,item,rev,0,'MANAGER_ESTIMATE',5000,'C3A receipt runtime','actual invoice');
  IF r->>'ok'<>'true' THEN RAISE EXCEPTION 'Receipt acquisition evidence failed: %',r; END IF;
  req:=public.issue_purchase_receipt_post_intent(receipt);
  r:=public.apply_purchase_receipt_post_intent(req);
  IF r->>'code'<>'POSTED' THEN RAISE EXCEPTION 'Normal post-WAC receipt failed: %',r; END IF;
  IF (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p)<>10
    OR (SELECT physical_quantity FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=p)<>10
    OR (SELECT valued_quantity FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=p)<>10
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=p)<>50000
    OR (SELECT current_wac FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=p)<>5000
    OR (SELECT count(*) FROM public.inventory_cost_source_layers WHERE outlet_id=o AND product_id=p)<>2
    OR (SELECT sum(original_source_amount) FROM public.inventory_cost_source_layers WHERE outlet_id=o AND product_id=p)<>50000 THEN
    RAISE EXCEPTION 'Normal first-receipt stock/cost/source-layer result diverged'; END IF;
  b:=gen_random_uuid();tx:=gen_random_uuid();ln:=gen_random_uuid();
  INSERT INTO public.ipos_sales_import_batches(id,outlet_id,upload_request_id,original_filename,file_sha256,
    report_from,report_to,transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,reconciliation,uploaded_by)
  VALUES(b,o,gen_random_uuid(),'receipt-following-sale.xls',repeat('9',64),timezone('Asia/Jakarta',received)::date,
    timezone('Asia/Jakarta',received)::date,1,1,2,20000,'{"quantity":"2","grandTotal":"20000"}',
    '{"isReconciled":true}',a);
  INSERT INTO public.ipos_sales_import_transactions(id,batch_id,source_row_number,source_transaction_number,
    source_occurred_at,raw_transaction_total,raw_data)
  VALUES(tx,b,1,'047318/KSR/UTM/1026',received+interval '1 minute',20000,'{}');
  INSERT INTO public.ipos_sales_import_lines(id,batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,
    raw_quantity,raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data,resolution,product_id)
  VALUES(ln,b,tx,2,'TEST-RECEIPT-001','C3A Receipt Product',2,'PCS',10000,0,20000,'{}','MATCHED',p);
  r:=public.ipos_sales_import_recheck(b,gen_random_uuid());
  IF r->>'status'<>'READY' THEN RAISE EXCEPTION 'Receipt-following iPos sale not READY: %',r; END IF;
  SELECT revision INTO batch_rev FROM public.ipos_sales_import_batches WHERE id=b;
  r:=public.ipos_sales_import_commit(b,batch_rev,gen_random_uuid());
  IF r->>'status'<>'COMMITTED'
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p)<>8
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=p)<>40000
    OR (SELECT current_wac FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=p)<>5000
    OR EXISTS(SELECT 1 FROM public.inventory_cost_events WHERE product_id=p AND event_type='SALE_COGS') THEN
    RAISE EXCEPTION 'Normal receipt followed by iPos sale diverged or fabricated COGS'; END IF;
  report:=public.owner_reports_read(timezone('Asia/Jakarta',received)::date,timezone('Asia/Jakarta',received)::date,
    timezone('Asia/Jakarta',received)::date-1,timezone('Asia/Jakarta',received)::date-1);
  IF report#>>'{kpis,profit_status}'<>'INCOMPLETE' OR report#>'{kpis,gross_profit}' IS DISTINCT FROM 'null'::jsonb
    OR report#>'{kpis,operating_profit}' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'Normal-receipt iPos sale profit should remain unavailable: %',report->'kpis'; END IF;
  late_batch:=gen_random_uuid();late_tx:=gen_random_uuid();late_line:=gen_random_uuid();
  INSERT INTO public.ipos_sales_import_batches(id,outlet_id,upload_request_id,original_filename,file_sha256,
    report_from,report_to,transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,reconciliation,uploaded_by)
  VALUES(late_batch,o,gen_random_uuid(),'pre-receipt-late-sale.xls',repeat('7',64),timezone('Asia/Jakarta',received)::date,
    timezone('Asia/Jakarta',received)::date,1,1,1,10000,'{"quantity":"1","grandTotal":"10000"}',
    '{"isReconciled":true}',a);
  INSERT INTO public.ipos_sales_import_transactions(id,batch_id,source_row_number,source_transaction_number,
    source_occurred_at,raw_transaction_total,raw_data)
  VALUES(late_tx,late_batch,1,'047321/KSR/UTM/1026',received-interval '1 minute',10000,'{}');
  INSERT INTO public.ipos_sales_import_lines(id,batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,
    raw_quantity,raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data,resolution,product_id)
  VALUES(late_line,late_batch,late_tx,2,'TEST-RECEIPT-001','C3A Receipt Product',1,'PCS',10000,0,10000,'{}','MATCHED',p);
  report:=public.ipos_sales_import_recheck(late_batch,gen_random_uuid());
  IF report->>'status'<>'PREFLIGHT_BLOCKED' OR (report->>'receiptChronologyConflictCount')::integer<>1 THEN
    RAISE EXCEPTION 'Late-arriving pre-receipt sale did not become a chronology blocker: %',report; END IF;
  SELECT revision INTO batch_rev FROM public.ipos_sales_import_batches WHERE id=late_batch;
  BEGIN PERFORM public.ipos_sales_import_commit(late_batch,batch_rev,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS late_error=MESSAGE_TEXT; END;
  IF late_error NOT LIKE '%IPOS_SALES_IMPORT_RECEIPT_CHRONOLOGY_CONFLICT%'
    OR EXISTS(SELECT 1 FROM public.sales WHERE source_import_batch_id=late_batch)
    OR EXISTS(SELECT 1 FROM public.stock_movements WHERE ipos_sales_import_line_id=late_line)
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p)<>8
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=p)<>40000 THEN
    RAISE EXCEPTION 'Late pre-receipt batch was not blocked atomically: %',late_error; END IF;
  RAISE NOTICE 'C3A normal Barang Masuk → IPOS_IMPORT PASS: 10 @ Rp5,000 then sale 2 → stock 8, value Rp40,000, WAC Rp5,000; historical COGS unavailable';
END $normal_receipt$;

DO $unvalued_zero_roles$
DECLARE
  a uuid:='a0000000-0000-4000-8000-000000000001';o uuid;p_unvalued uuid;p_zero uuid;p_role uuid;
  request_id uuid:=gen_random_uuid();r jsonb;replay jsonb;failed boolean;batch uuid;tx uuid;line_id uuid;rev integer;v_profile uuid;
BEGIN
  SELECT id INTO STRICT o FROM public.outlets WHERE code='QUENA-MART-1';
  p_unvalued:=pg_temp.c3a_create_ipos_product('TEST-UNVALUED-001','C3A Unvalued Product');
  p_zero:=pg_temp.c3a_create_ipos_product('TEST-ZERO-001','C3A Zero Product');
  p_role:=pg_temp.c3a_create_ipos_product('TEST-ROLE-001','C3A Role Product');
  -- OWNER is the only caller allowed to create the transition enrollment.
  FOR v_profile IN SELECT id FROM public.profiles WHERE id IN (
    'a0000000-0000-4000-8000-000000000002'::uuid,
    'a0000000-0000-4000-8000-000000000003'::uuid,
    'a0000000-0000-4000-8000-000000000004'::uuid)
  LOOP
    PERFORM set_config('request.jwt.claim.sub',v_profile::text,true);failed:=false;
    BEGIN PERFORM public.enroll_post_wac_product(gen_random_uuid(),p_role,1,'VALUED',1,now()-interval '1 minute','role denial test');
    EXCEPTION WHEN SQLSTATE '42501' THEN failed:=true; END;
    IF NOT failed THEN RAISE EXCEPTION 'ADMIN/KASIR/GUDANG unexpectedly enrolled a post-WAC product: %',v_profile; END IF;
  END LOOP;
  PERFORM set_config('request.jwt.claim.sub',a::text,true);

  r:=public.enroll_post_wac_product(request_id,p_unvalued,10,'UNVALUED',NULL,now()-interval '1 hour','Owner confirms 10 units; actual cost unavailable.');
  replay:=public.enroll_post_wac_product(request_id,p_unvalued,10,'UNVALUED',NULL,now()-interval '1 hour','Owner confirms 10 units; actual cost unavailable.');
  IF replay IS DISTINCT FROM r OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id=p_unvalued AND outlet_id=o)<>10
    OR (SELECT unvalued_quantity FROM public.inventory_cost_projections WHERE product_id=p_unvalued AND outlet_id=o)<>10
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE product_id=p_unvalued AND outlet_id=o) IS NOT NULL
    OR (SELECT current_wac FROM public.inventory_cost_projections WHERE product_id=p_unvalued AND outlet_id=o) IS NOT NULL THEN
    RAISE EXCEPTION 'UNVALUED enrollment or same-request replay is wrong'; END IF;
  failed:=false;
  BEGIN PERFORM public.enroll_post_wac_product(gen_random_uuid(),p_unvalued,10,'VALUED',5000,now()-interval '1 hour','second enrollment');
  EXCEPTION WHEN SQLSTATE '23505' THEN failed:=true; END;
  IF NOT failed THEN RAISE EXCEPTION 'Second independent enrollment was allowed'; END IF;
  batch:=gen_random_uuid();tx:=gen_random_uuid();line_id:=gen_random_uuid();
  INSERT INTO public.ipos_sales_import_batches(id,outlet_id,upload_request_id,original_filename,file_sha256,
    report_from,report_to,transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,reconciliation,uploaded_by)
  VALUES(batch,o,gen_random_uuid(),'unvalued-depletion.xls',repeat('8',64),'2026-10-13','2026-10-13',1,1,2,200,
    '{"quantity":"2","grandTotal":"200"}','{"isReconciled":true}',a);
  INSERT INTO public.ipos_sales_import_transactions(id,batch_id,source_row_number,source_transaction_number,
    source_occurred_at,raw_transaction_total,raw_data)
  VALUES(tx,batch,1,'047320/KSR/UTM/1026',now(),200,'{}');
  INSERT INTO public.ipos_sales_import_lines(id,batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,
    raw_quantity,raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data,resolution,product_id)
  VALUES(line_id,batch,tx,2,'TEST-UNVALUED-001','C3A Unvalued Product',2,'PCS',100,0,200,'{}','MATCHED',p_unvalued);
  r:=public.ipos_sales_import_recheck(batch,gen_random_uuid());
  IF r->>'status'<>'READY' THEN RAISE EXCEPTION 'Post-enrollment unvalued iPos sale not READY: %',r; END IF;
  SELECT revision INTO rev FROM public.ipos_sales_import_batches WHERE id=batch;
  r:=public.ipos_sales_import_commit(batch,rev,gen_random_uuid());
  IF r->>'status'<>'COMMITTED'
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id=p_unvalued AND outlet_id=o)<>8
    OR (SELECT unvalued_quantity FROM public.inventory_cost_projections WHERE product_id=p_unvalued AND outlet_id=o)<>8
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE product_id=p_unvalued AND outlet_id=o) IS NOT NULL
    OR (SELECT current_wac FROM public.inventory_cost_projections WHERE product_id=p_unvalued AND outlet_id=o) IS NOT NULL
    OR EXISTS(SELECT 1 FROM public.inventory_cost_events WHERE product_id=p_unvalued AND event_type='SALE_COGS') THEN
    RAISE EXCEPTION 'UNVALUED-first depletion fabricated value/COGS or failed quantity reconciliation'; END IF;
  RAISE NOTICE 'C3A UNVALUED enrollment PASS: quantity 10, no inventory value/WAC; replay same result, second enrollment denied';

  r:=public.enroll_post_wac_product(gen_random_uuid(),p_zero,0,'VALUED',5000,now()-interval '1 minute','Owner confirmed physical zero.');
  IF (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id=p_zero AND outlet_id=o) IS DISTINCT FROM 0
    OR (SELECT valued_quantity FROM public.inventory_cost_projections WHERE product_id=p_zero AND outlet_id=o) IS DISTINCT FROM 0
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE product_id=p_zero AND outlet_id=o) IS DISTINCT FROM 0
    OR (SELECT current_wac FROM public.inventory_cost_projections WHERE product_id=p_zero AND outlet_id=o) IS NOT NULL THEN
    RAISE EXCEPTION 'Authoritative zero differs from NULL or has fabricated WAC'; END IF;
  RAISE NOTICE 'C3A NULL versus authoritative zero PASS: NULL before enrollment; effective zero and valued quantity zero afterward';

  -- A positive sale against authoritative zero is blocked by preflight and commit.
  batch:=gen_random_uuid();tx:=gen_random_uuid();line_id:=gen_random_uuid();
  INSERT INTO public.ipos_sales_import_batches(id,outlet_id,upload_request_id,original_filename,file_sha256,
    report_from,report_to,transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,reconciliation,uploaded_by)
  VALUES(batch,o,gen_random_uuid(),'zero-stock-block.xls',repeat('f',64),'2026-10-13','2026-10-13',1,1,1,10,
    '{"quantity":"1","grandTotal":"10"}','{"isReconciled":true}',a);
  INSERT INTO public.ipos_sales_import_transactions(id,batch_id,source_row_number,source_transaction_number,
    source_occurred_at,raw_transaction_total,raw_data)
  VALUES(tx,batch,1,'047319/KSR/UTM/1026',now(),10,'{}');
  INSERT INTO public.ipos_sales_import_lines(id,batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,
    raw_quantity,raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data,resolution,product_id)
  VALUES(line_id,batch,tx,2,'TEST-ZERO-001','C3A Zero Product',1,'PCS',10,0,10,'{}','MATCHED',p_zero);
  r:=public.ipos_sales_import_recheck(batch,gen_random_uuid());
  IF r->>'status'<>'PREFLIGHT_BLOCKED' OR (r->>'stockBlockerCount')::integer<>1 THEN
    RAISE EXCEPTION 'Sale against authoritative zero was not blocked: %',r; END IF;
  SELECT revision INTO rev FROM public.ipos_sales_import_batches WHERE id=batch;failed:=false;
  BEGIN PERFORM public.ipos_sales_import_commit(batch,rev,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN failed:=true; END;
  IF NOT failed OR EXISTS(SELECT 1 FROM public.sales WHERE source_import_batch_id=batch)
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id=p_zero AND outlet_id=o)<>0 THEN
    RAISE EXCEPTION 'Positive sale mutated authoritative zero stock'; END IF;
END $unvalued_zero_roles$;

DO $opname_boundary$
DECLARE
  a uuid:='a0000000-0000-4000-8000-000000000001';o uuid;p_active uuid;p_posted uuid;s uuid;r jsonb;failed boolean;
BEGIN
  SELECT id INTO STRICT o FROM public.outlets WHERE code='QUENA-MART-1';
  p_active:=pg_temp.c3a_create_ipos_product('TEST-ACTIVE-OPNAME-001','C3A Active Opname Product');
  s:=gen_random_uuid();
  INSERT INTO public.stock_opname_sessions(id,outlet_id,scope_type,status,note,created_by)
  VALUES(s,o,'PARTIAL','COUNTING','C3A active session conflict',a);
  INSERT INTO public.stock_opname_items(session_id,outlet_id,product_id,active_scope)
  VALUES(s,o,p_active,true);
  failed:=false;
  BEGIN PERFORM public.enroll_post_wac_product(gen_random_uuid(),p_active,2,'VALUED',1000,now()-interval '1 minute','active opname conflict');
  EXCEPTION WHEN SQLSTATE '55000' THEN failed:=true; END;
  IF NOT failed OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p_active) IS NOT NULL
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=p_active) THEN
    RAISE EXCEPTION 'Enrollment bypassed active opname or mutated state'; END IF;

  p_posted:=pg_temp.c3a_create_ipos_product('TEST-POSTED-OPNAME-001','C3A Posted Opname Product');
  s:=gen_random_uuid();
  INSERT INTO public.stock_opname_sessions(id,outlet_id,scope_type,status,note,created_by,submitted_by,submitted_at,
    approved_by,approved_at,posted_at)
  VALUES(s,o,'PARTIAL','POSTED','C3A immutable posted session',a,a,now()-interval '90 minutes',a,
    now()-interval '60 minutes',now()-interval '60 minutes');
  INSERT INTO public.stock_opname_items(session_id,outlet_id,product_id,physical_quantity,last_counted_by,last_counted_at,active_scope)
  VALUES(s,o,p_posted,0,a,now()-interval '2 hours',false);
  failed:=false;
  BEGIN PERFORM public.enroll_post_wac_product(gen_random_uuid(),p_posted,3,'VALUED',1000,now()-interval '3 hours','before posted count');
  EXCEPTION WHEN SQLSTATE '55000' THEN failed:=true; END;
  IF NOT failed OR (SELECT status FROM public.stock_opname_sessions WHERE id=s)<>'POSTED'
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p_posted) IS NOT NULL THEN
    RAISE EXCEPTION 'Enrollment rewrote or crossed back through posted opname'; END IF;
  r:=public.enroll_post_wac_product(gen_random_uuid(),p_posted,3,'VALUED',1000,now()-interval '30 minutes',
    'Owner confirmed quantity after finalized physical count.');
  IF r->>'ok'<>'true' OR (SELECT status FROM public.stock_opname_sessions WHERE id=s)<>'POSTED'
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p_posted)<>3 THEN
    RAISE EXCEPTION 'Chronologically later enrollment was not safely accepted'; END IF;
  RAISE NOTICE 'C3A Opname boundary PASS: active conflict denied; pre-count posted enrollment denied; later as-of enrollment accepted without rewriting POSTED history';
END $opname_boundary$;
ROLLBACK;
