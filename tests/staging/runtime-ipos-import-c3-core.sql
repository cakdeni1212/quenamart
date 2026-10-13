-- C3 backend persistence/idempotency smoke matrix. Rollback-only; run only
-- against the disposable local PostgreSQL 15 staging database.
DO $guard$
BEGIN
  IF current_database()<>'quena_stock_staging'
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR inet_server_port()<>55441 OR current_setting('server_version_num')::integer/10000<>15
    OR current_setting('server_encoding')<>'UTF8' THEN
    RAISE EXCEPTION 'Refusing C3 runtime test outside the guarded local PostgreSQL 15 staging DB';
  END IF;
END $guard$;
BEGIN;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
DO $c3$
DECLARE
  v_actor uuid:='a0000000-0000-4000-8000-000000000001';
  v_outlet uuid; v_product uuid; v_sku text; v_name text; v_unit text;
  v_missing_batch uuid:=gen_random_uuid(); v_missing_tx uuid:=gen_random_uuid(); v_missing_line uuid:=gen_random_uuid();
  v_dup_batch uuid:=gen_random_uuid(); v_dup_tx1 uuid:=gen_random_uuid(); v_dup_tx2 uuid:=gen_random_uuid();
  v_dup_line1 uuid:=gen_random_uuid(); v_dup_line2 uuid:=gen_random_uuid();
  v_commit_batch uuid:=gen_random_uuid(); v_commit_tx uuid:=gen_random_uuid(); v_commit_line uuid:=gen_random_uuid();
  v_overlap_batch uuid:=gen_random_uuid(); v_overlap_tx uuid:=gen_random_uuid(); v_overlap_line uuid:=gen_random_uuid();
  v_product_import_request uuid; v_product_import_batch uuid; v_product_source_row uuid:=gen_random_uuid();
  v_product_expected jsonb; v_product_payload jsonb; v_product_result jsonb;
  v_request uuid:=gen_random_uuid(); v_revision integer; v_result jsonb; v_error text;
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
  v_file_result:=public.ipos_sales_import_upload(v_actor,gen_random_uuid(),'QUENAEX-c3-test-copy.xls',
    repeat('a',64),'{}'::jsonb);
  IF v_file_result->>'code'<>'IPOS_SALES_DUPLICATE_FILE' OR (v_file_result->>'batchId')::uuid<>v_missing_batch THEN
    RAISE EXCEPTION 'Exact file hash retry did not return existing batch: %',v_file_result; END IF;
  RAISE NOTICE 'C3 exact file hash dedupe PASS: upload resolved existing persisted batch';

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
  RAISE NOTICE 'C3 new product projection period %, active period %',
    (SELECT authority_period_id FROM public.stock_balance_projection WHERE product_id=v_product AND outlet_id=v_outlet),
    (SELECT id FROM public.stock_authority_periods WHERE outlet_id=v_outlet AND ended_at IS NULL);
  v_result:=public.ipos_sales_import_recheck(v_missing_batch,gen_random_uuid());
  IF v_result->>'status'<>'PREFLIGHT_BLOCKED' OR (v_result->>'missingSkuCount')::integer<>0
    OR (v_result->>'stockBlockerCount')::integer<>1
    OR (v_result->'reconciliation'->>'isReconciled')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Cek Ulang did not resolve SKU independently of the stock blocker: %',v_result;
  END IF;
  IF (SELECT raw_data->>'rawSku' FROM public.ipos_sales_import_lines WHERE id=v_missing_line)<>'TEST-SKU-BARU-001'
    OR (SELECT raw_line_total FROM public.ipos_sales_import_lines WHERE id=v_missing_line)<>21000
    OR (SELECT product_id FROM public.ipos_sales_import_lines WHERE id=v_missing_line) IS DISTINCT FROM v_product THEN
    RAISE EXCEPTION 'Cek Ulang altered raw evidence or failed to bind exact normalized product'; END IF;
  IF (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id=v_product AND outlet_id=v_outlet) IS NOT NULL
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections WHERE product_id=v_product AND outlet_id=v_outlet) THEN
    RAISE EXCEPTION 'Fresh post-WAC iPos product unexpectedly has a trusted quantity/cost projection'; END IF;
  SELECT revision INTO v_revision FROM public.ipos_sales_import_batches WHERE id=v_missing_batch;
  BEGIN PERFORM public.ipos_sales_import_commit(v_missing_batch,v_revision,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT; END;
  IF v_error NOT LIKE '%IPOS_SALES_IMPORT_NOT_READY%' THEN
    RAISE EXCEPTION 'Missing-SKU batch bypassed unresolved stock readiness: %',v_error; END IF;
  IF EXISTS(SELECT 1 FROM public.sales WHERE source_import_batch_id=v_missing_batch)
    OR EXISTS(SELECT 1 FROM public.stock_movements WHERE ipos_sales_import_line_id=v_missing_line)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_events WHERE source_entity_id=v_missing_line) THEN
    RAISE EXCEPTION 'Stock-blocked post-recheck batch mutated sales, stock, or costing'; END IF;
  RAISE NOTICE 'C3 Product normalization + same-batch Cek Ulang PASS for exact SKU/raw evidence; HIGH: new post-WAC SKU lacks authoritative quantity/cost projection and commit is blocked';
  SELECT p.id,p.sku,p.name,p.unit_label INTO STRICT v_product,v_sku,v_name,v_unit
    FROM public.products p WHERE p.sku='CUTOVER-MULTI';

  -- Same transaction identity repeated within one source file is persisted and
  -- counted as one duplicate identity, so reviewers can inspect the blocker.
  INSERT INTO public.ipos_sales_import_batches(id,outlet_id,upload_request_id,original_filename,file_sha256,
    report_from,report_to,transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,reconciliation,uploaded_by)
  VALUES(v_dup_batch,v_outlet,gen_random_uuid(),'duplicate-source-transaction.xls',repeat('b',64),'2026-10-12','2026-10-12',
    2,2,0.002,2,'{"quantity":"0.002","grandTotal":"2"}',
    '{"isReconciled":true,"differences":[]}',v_actor);
  INSERT INTO public.ipos_sales_import_transactions(id,batch_id,source_row_number,source_transaction_number,
    source_occurred_at,raw_transaction_total,raw_data)
  VALUES(v_dup_tx1,v_dup_batch,20,'047315/KSR/UTM/1026',now(),1,'{}'),
        (v_dup_tx2,v_dup_batch,28,'047315/KSR/UTM/1026',now(),1,'{}');
  INSERT INTO public.ipos_sales_import_lines(id,batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,
    raw_quantity,raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data,resolution,product_id)
  VALUES(v_dup_line1,v_dup_batch,v_dup_tx1,22,v_sku,v_name,.001,v_unit,1000,0,1,'{}','MATCHED',v_product),
        (v_dup_line2,v_dup_batch,v_dup_tx2,30,v_sku,v_name,.001,v_unit,1000,0,1,'{}','MATCHED',v_product);
  v_result:=public.ipos_sales_import_recheck(v_dup_batch,gen_random_uuid());
  IF v_result->>'status'<>'PREFLIGHT_BLOCKED' OR (v_result->>'duplicateTransactionCount')::integer<>1
    OR (SELECT count(*) FROM public.ipos_sales_import_transactions WHERE batch_id=v_dup_batch AND duplicate)<>2 THEN
    RAISE EXCEPTION 'Duplicate source transaction inside one file was not persisted as a blocker: %',v_result;
  END IF;
  RAISE NOTICE 'C3 in-file duplicate PASS: batch persists, duplicate transaction identity blocks whole batch';

  -- Valid WAC import establishes source transaction identity; a changed-hash
  -- overlapping batch must then be blocked by exact source number.
  SELECT effective_quantity INTO STRICT v_product_stock FROM public.stock_balance_projection
    WHERE outlet_id=v_outlet AND product_id=v_product;
  IF v_product_stock<.003 THEN RAISE EXCEPTION 'C3 fixture product lacks safe staging stock'; END IF;
  INSERT INTO public.ipos_sales_import_batches(id,outlet_id,upload_request_id,original_filename,file_sha256,
    report_from,report_to,transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,reconciliation,
    preflight_result,status,uploaded_by)
  VALUES(v_commit_batch,v_outlet,gen_random_uuid(),'c3-first-commit.xls',repeat('c',64),'2026-10-12','2026-10-12',
    1,1,.001,1,'{"quantity":"0.001","grandTotal":"1"}','{"isReconciled":true,"differences":[]}',
    '{"ready":true}','READY',v_actor);
  INSERT INTO public.ipos_sales_import_transactions(id,batch_id,source_row_number,source_transaction_number,
    source_occurred_at,raw_transaction_total,raw_data)
  VALUES(v_commit_tx,v_commit_batch,20,'047316/KSR/UTM/1026',now(),1,'{}');
  INSERT INTO public.ipos_sales_import_lines(id,batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,
    raw_quantity,raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data,resolution,product_id)
  VALUES(v_commit_line,v_commit_batch,v_commit_tx,22,v_sku,v_name,.001,v_unit,1000,0,1,'{}','MATCHED',v_product);
  SELECT revision INTO v_revision FROM public.ipos_sales_import_batches WHERE id=v_commit_batch;
  v_result:=public.ipos_sales_import_commit(v_commit_batch,v_revision,v_request);
  IF v_result->>'status'<>'COMMITTED' THEN RAISE EXCEPTION 'Valid first import failed: %',v_result; END IF;
  IF public.ipos_sales_import_commit(v_commit_batch,v_revision,v_request) IS DISTINCT FROM v_result THEN
    RAISE EXCEPTION 'Same request replay did not return stored result';
  END IF;
  BEGIN PERFORM public.ipos_sales_import_commit(v_commit_batch,v_revision,gen_random_uuid());
    RAISE EXCEPTION 'New request replayed an already committed batch';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL; END;

  INSERT INTO public.ipos_sales_import_batches(id,outlet_id,upload_request_id,original_filename,file_sha256,
    report_from,report_to,transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,reconciliation,
    preflight_result,status,uploaded_by)
  VALUES(v_overlap_batch,v_outlet,gen_random_uuid(),'c3-overlap-different-hash.xls',repeat('d',64),'2026-10-12','2026-10-12',
    1,1,.001,1,'{"quantity":"0.001","grandTotal":"1"}','{"isReconciled":true,"differences":[]}',
    '{"ready":true}','READY',v_actor);
  INSERT INTO public.ipos_sales_import_transactions(id,batch_id,source_row_number,source_transaction_number,
    source_occurred_at,raw_transaction_total,raw_data)
  VALUES(v_overlap_tx,v_overlap_batch,20,'047316/KSR/UTM/1026',now(),1,'{}');
  INSERT INTO public.ipos_sales_import_lines(id,batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,
    raw_quantity,raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data,resolution,product_id)
  VALUES(v_overlap_line,v_overlap_batch,v_overlap_tx,22,v_sku,v_name,.001,v_unit,1000,0,1,'{}','MATCHED',v_product);
  v_result:=public.ipos_sales_import_recheck(v_overlap_batch,gen_random_uuid());
  IF v_result->>'status'<>'PREFLIGHT_BLOCKED' OR (v_result->>'duplicateTransactionCount')::integer<>1 THEN
    RAISE EXCEPTION 'Changed-hash overlapping transaction was not blocked: %',v_result;
  END IF;
  IF (SELECT count(*) FROM public.sales WHERE source_transaction_number='047316/KSR/UTM/1026' AND source_system='IPOS_IMPORT')<>1
    OR (SELECT count(*) FROM public.stock_movements WHERE ipos_sales_import_transaction_id=v_commit_tx)<>1 THEN
    RAISE EXCEPTION 'First import replay or overlap duplicated sales/stock';
  END IF;
  RAISE NOTICE 'C3 source-identity/replay PASS: changed-hash overlap blocked, same request replay once';

  -- Direct READY payloads are also transactionally revalidated against sales;
  -- stale upload-time READY cannot bypass the unique source transaction rule.
  BEGIN PERFORM public.ipos_sales_import_commit(v_overlap_batch,1,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT; END;
  IF v_error NOT LIKE '%IPOS_SALES_IMPORT_NOT_READY%' AND v_error NOT LIKE '%IPOS_SALES_DUPLICATE_TRANSACTION%' THEN
    RAISE EXCEPTION 'Stale preflight was not denied safely: %',v_error;
  END IF;

  -- Backend role checks are based on active profile, not caller-supplied role.
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
  BEGIN PERFORM public.ipos_sales_import_recheck(v_missing_batch,gen_random_uuid());
    RAISE EXCEPTION 'KASIR was allowed to recheck import';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  RAISE NOTICE 'C3 commit/replay/overlap/role-denial smoke PASS';
END $c3$;
ROLLBACK;
