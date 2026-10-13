-- C3B duplicate, overlap, stale READY, replay and role matrix.
-- Rollback-only on disposable localhost PostgreSQL 15 WAC_ACTIVE staging.
DO $guard$ BEGIN
 IF current_database()<>'quena_stock_staging' OR inet_server_port()<>55442
   OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
   OR current_setting('server_version_num')::integer/10000<>15
   OR NOT EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE status='WAC_ACTIVE')
 THEN RAISE EXCEPTION 'Refusing C3B dedupe runtime outside disposable PostgreSQL 15 WAC_ACTIVE staging'; END IF;
END $guard$;
BEGIN;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
CREATE FUNCTION pg_temp.c3b_batch(p_ids text[],p_sku text,p_hash text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE o uuid;a uuid:='a0000000-0000-4000-8000-000000000001';p uuid;b uuid:=gen_random_uuid();tx uuid;line uuid;source_id text;
BEGIN
 SELECT id INTO STRICT o FROM public.outlets WHERE code='QUENA-MART-1';
 SELECT id INTO STRICT p FROM public.products WHERE sku=p_sku;
 INSERT INTO public.ipos_sales_import_batches(id,outlet_id,upload_request_id,original_filename,file_sha256,
   report_from,report_to,transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,reconciliation,uploaded_by)
 VALUES(b,o,gen_random_uuid(),'c3b-runtime.xls',p_hash,'2026-10-12','2026-10-12',cardinality(p_ids),cardinality(p_ids),
   cardinality(p_ids)*.001,cardinality(p_ids),'{}','{"isReconciled":true,"differences":[]}',a);
 FOREACH source_id IN ARRAY p_ids LOOP
   tx:=gen_random_uuid();line:=gen_random_uuid();
   INSERT INTO public.ipos_sales_import_transactions(id,batch_id,source_row_number,source_transaction_number,
     source_occurred_at,raw_transaction_total,raw_data)
   VALUES(tx,b,20,source_id,'2026-10-12 12:00:00+07',1,jsonb_build_object('sourceTransactionNumber',source_id));
   INSERT INTO public.ipos_sales_import_lines(id,batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,
     raw_quantity,raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data)
   SELECT line,b,tx,22,p_sku,prod.name,.001,prod.unit_label,1000,0,1,jsonb_build_object('rawSku',p_sku)
   FROM public.products prod WHERE prod.id=p;
 END LOOP;
 RETURN b;
END $$;
DO $matrix$
DECLARE
  product_sku text;prefix integer:=700000+floor(random()*10000)::integer;
  overlap_a uuid;overlap_b uuid;stale_a uuid;stale_b uuid;inside uuid;admin_batch uuid;
  r jsonb;revision_no integer;error_text text;before_sales bigint;before_moves bigint;before_cost bigint;
  v_request uuid;actor uuid;denied_upload jsonb;
BEGIN
 SELECT sku INTO STRICT product_sku FROM public.products WHERE sku='CUTOVER-MULTI';
 overlap_a:=pg_temp.c3b_batch(ARRAY[lpad((prefix+1)::text,6,'0')||'/C3B/UTM/1026',lpad((prefix+2)::text,6,'0')||'/C3B/UTM/1026',lpad((prefix+3)::text,6,'0')||'/C3B/UTM/1026'],product_sku,repeat('1',64));
 overlap_b:=pg_temp.c3b_batch(ARRAY[lpad((prefix+3)::text,6,'0')||'/C3B/UTM/1026',lpad((prefix+4)::text,6,'0')||'/C3B/UTM/1026',lpad((prefix+5)::text,6,'0')||'/C3B/UTM/1026'],product_sku,repeat('2',64));
 r:=public.ipos_sales_import_recheck(overlap_a,gen_random_uuid());
 IF r->>'status'<>'READY' THEN RAISE EXCEPTION 'overlap A not ready: %',r; END IF;
 r:=public.ipos_sales_import_recheck(overlap_b,gen_random_uuid());
 IF r->>'status'<>'READY' THEN RAISE EXCEPTION 'overlap B not ready before A commit: %',r; END IF;
 SELECT revision INTO revision_no FROM public.ipos_sales_import_batches WHERE id=overlap_a;
 PERFORM public.ipos_sales_import_commit(overlap_a,revision_no,gen_random_uuid());
 r:=public.ipos_sales_import_recheck(overlap_b,gen_random_uuid());
 IF r->>'status'<>'PREFLIGHT_BLOCKED' OR (r->>'duplicateTransactionCount')::integer<>1 THEN
   RAISE EXCEPTION 'overlap B did not block only the shared transaction identity: %',r; END IF;
 SELECT count(*) INTO before_sales FROM public.sales;
 SELECT count(*) INTO before_moves FROM public.stock_movements;
 SELECT count(*) INTO before_cost FROM public.inventory_cost_events;
 SELECT revision INTO revision_no FROM public.ipos_sales_import_batches WHERE id=overlap_b;error_text:=NULL;
 BEGIN PERFORM public.ipos_sales_import_commit(overlap_b,revision_no,gen_random_uuid());
 EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS error_text=MESSAGE_TEXT; END;
 IF error_text NOT LIKE '%IPOS_SALES_IMPORT_NOT_READY%' OR (SELECT count(*) FROM public.sales)<>before_sales
   OR (SELECT count(*) FROM public.stock_movements)<>before_moves OR (SELECT count(*) FROM public.inventory_cost_events)<>before_cost
   OR EXISTS(SELECT 1 FROM public.sales WHERE source_import_batch_id=overlap_b)
 THEN RAISE EXCEPTION 'overlapping batch partially mutated or failed with unexpected error: %',error_text; END IF;
 RAISE NOTICE 'C3B overlap A(1,2,3) / B(3,4,5) PASS: B blocked as a whole; zero sale/stock/cost mutation from B';

 stale_a:=pg_temp.c3b_batch(ARRAY[lpad((prefix+6)::text,6,'0')||'/C3B/UTM/1026'],product_sku,repeat('3',64));
 stale_b:=pg_temp.c3b_batch(ARRAY[lpad((prefix+6)::text,6,'0')||'/C3B/UTM/1026'],product_sku,repeat('4',64));
 IF (public.ipos_sales_import_recheck(stale_a,gen_random_uuid())->>'status')<>'READY'
   OR (public.ipos_sales_import_recheck(stale_b,gen_random_uuid())->>'status')<>'READY' THEN
   RAISE EXCEPTION 'stale-preflight batches were not both initially READY'; END IF;
 SELECT revision INTO revision_no FROM public.ipos_sales_import_batches WHERE id=stale_a;
 PERFORM public.ipos_sales_import_commit(stale_a,revision_no,gen_random_uuid());
 SELECT count(*) INTO before_sales FROM public.sales;
 SELECT count(*) INTO before_moves FROM public.stock_movements;
 SELECT count(*) INTO before_cost FROM public.inventory_cost_events;
 SELECT revision INTO revision_no FROM public.ipos_sales_import_batches WHERE id=stale_b;error_text:=NULL;
 BEGIN PERFORM public.ipos_sales_import_commit(stale_b,revision_no,gen_random_uuid());
 EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS error_text=MESSAGE_TEXT; END;
 IF error_text NOT LIKE '%IPOS_SALES_DUPLICATE_TRANSACTION%' OR (SELECT count(*) FROM public.sales)<>before_sales
   OR (SELECT count(*) FROM public.stock_movements)<>before_moves OR (SELECT count(*) FROM public.inventory_cost_events)<>before_cost
   OR EXISTS(SELECT 1 FROM public.sales WHERE source_import_batch_id=stale_b)
 THEN RAISE EXCEPTION 'stale READY commit was not atomically rejected: %',error_text; END IF;
 RAISE NOTICE 'C3B stale READY pass: A and B initially READY; B commit without recheck revalidated unique transaction and made zero mutation';

 inside:=pg_temp.c3b_batch(ARRAY[lpad((prefix+7)::text,6,'0')||'/C3B/UTM/1026',lpad((prefix+7)::text,6,'0')||'/C3B/UTM/1026'],product_sku,repeat('5',64));
 r:=public.ipos_sales_import_recheck(inside,gen_random_uuid());
 IF r->>'status'<>'PREFLIGHT_BLOCKED' OR (r->>'duplicateTransactionCount')::integer<>1
   OR (SELECT count(*) FROM public.ipos_sales_import_transactions WHERE batch_id=inside AND duplicate)<>2 THEN
   RAISE EXCEPTION 'within-batch duplicate identity evidence was not persisted: %',r; END IF;
 SELECT count(*) INTO before_sales FROM public.sales;SELECT count(*) INTO before_moves FROM public.stock_movements;
 SELECT count(*) INTO before_cost FROM public.inventory_cost_events;SELECT revision INTO revision_no FROM public.ipos_sales_import_batches WHERE id=inside;
 error_text:=NULL;BEGIN PERFORM public.ipos_sales_import_commit(inside,revision_no,gen_random_uuid());
 EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS error_text=MESSAGE_TEXT; END;
 IF error_text NOT LIKE '%IPOS_SALES_IMPORT_NOT_READY%' OR (SELECT count(*) FROM public.sales)<>before_sales
   OR (SELECT count(*) FROM public.stock_movements)<>before_moves OR (SELECT count(*) FROM public.inventory_cost_events)<>before_cost
 THEN RAISE EXCEPTION 'in-file duplicate commit mutated or returned unexpected result: %',error_text; END IF;
 RAISE NOTICE 'C3B duplicate inside one file PASS: both raw transaction rows flagged; commit blocked with zero mutation';

 admin_batch:=pg_temp.c3b_batch(ARRAY[lpad((prefix+8)::text,6,'0')||'/C3B/UTM/1026'],product_sku,repeat('6',64));
 PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
 r:=public.ipos_sales_import_recheck(admin_batch,gen_random_uuid());
 IF r->>'status'<>'READY' THEN RAISE EXCEPTION 'ADMIN import recheck denied contrary to current policy: %',r; END IF;
 SELECT revision INTO revision_no FROM public.ipos_sales_import_batches WHERE id=admin_batch;
 IF (public.ipos_sales_import_commit(admin_batch,revision_no,gen_random_uuid())->>'status')<>'COMMITTED' THEN
   RAISE EXCEPTION 'ADMIN import commit denied contrary to current policy'; END IF;
 PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
 FOREACH actor IN ARRAY ARRAY['a0000000-0000-4000-8000-000000000003'::uuid,'a0000000-0000-4000-8000-000000000004'::uuid] LOOP
   PERFORM set_config('request.jwt.claim.sub',actor::text,true);error_text:=NULL;
   BEGIN PERFORM public.ipos_sales_import_recheck(admin_batch,gen_random_uuid());
   EXCEPTION WHEN SQLSTATE '42501' THEN error_text:='DENIED'; END;
   IF error_text IS DISTINCT FROM 'DENIED' THEN RAISE EXCEPTION 'KASIR/GUDANG import recheck was not denied: %',actor; END IF;
 END LOOP;
 PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
 RAISE NOTICE 'C3B authorization PASS: OWNER and ADMIN recheck allowed; KASIR and GUDANG denied';
 FOREACH actor IN ARRAY ARRAY['a0000000-0000-4000-8000-000000000003'::uuid,'a0000000-0000-4000-8000-000000000004'::uuid] LOOP
   PERFORM set_config('request.jwt.claim.sub',actor::text,true);error_text:=NULL;
   BEGIN PERFORM public.ipos_sales_import_commit(admin_batch,revision_no,gen_random_uuid());
   EXCEPTION WHEN SQLSTATE '42501' THEN error_text:='DENIED'; END;
   IF error_text IS DISTINCT FROM 'DENIED' THEN RAISE EXCEPTION 'KASIR/GUDANG import commit was not denied: %',actor; END IF;
   error_text:=NULL;
   BEGIN denied_upload:=public.ipos_sales_import_upload(actor,gen_random_uuid(),'role-denied.xls',repeat('9',64),
     jsonb_build_object('reportFrom','2026-10-12','reportTo','2026-10-12',
       'summary',jsonb_build_object('transactionCount',1,'saleLineCount',1,'totalQuantity','0.001','totalAmount','1'),
       'footer','{}'::jsonb,'reconciliation','{"isReconciled":true}'::jsonb,
       'transactions',jsonb_build_array(jsonb_build_object('sourceRowNumber',1,'sourceTransactionNumber','700099/C3B/UTM/1026',
         'sourceOccurredAt','2026-10-12T05:00:00Z','sourceTransactionTotal','1','sourceDiscountTotal','0',
         'sourceTaxTotal','0','sourceFeeTotal','0','lines',jsonb_build_array(jsonb_build_object('sourceRowNumber',2,
           'rawSku',product_sku,'rawItemName','Fixture','rawQuantity','0.001','rawUnit','PCS','rawUnitPrice','1000',
           'rawDiscountPercent','0','rawLineTotal','1'))))));
   EXCEPTION WHEN SQLSTATE '42501' THEN error_text:='DENIED'; END;
   IF error_text IS DISTINCT FROM 'DENIED' THEN RAISE EXCEPTION 'KASIR/GUDANG upload was not denied before batch creation: %',actor; END IF;
 END LOOP;
 PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
 RAISE NOTICE 'C3B backend role matrix PASS: OWNER and ADMIN can import; KASIR and GUDANG denied upload/recheck/commit; enrollment remains OWNER-only in C3A';
END $matrix$;
ROLLBACK;
