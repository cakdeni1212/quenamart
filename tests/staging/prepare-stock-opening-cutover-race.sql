\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database()<>'quena_stock_cutover_clean'
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR inet_server_port()<>55439 OR current_setting('server_version_num')::integer/10000<>15
    OR to_regprocedure('public.stock_opening_cutover(uuid,uuid,uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Refusing race fixture outside pinned disposable staging';
  END IF;
END $guard$;

INSERT INTO public.outlets(id,code,name,is_active)
VALUES('a0000000-0000-4000-8000-000000000200','CUTOVER-RACE','Cutover race outlet',true);
INSERT INTO public.products(id,sku,name,unit_label,created_by,updated_by)
VALUES('a0000000-0000-4000-8000-000000000201','CUTOVER-RACE-PRODUCT','Cutover race product','pcs',
  'a0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001');
INSERT INTO public.ipos_import_requests(id,outlet_id,requested_by,storage_path,state,original_filename)
VALUES('a0000000-0000-4000-8000-000000000202','a0000000-0000-4000-8000-000000000200',
  'a0000000-0000-4000-8000-000000000001','cutover-race/final.xlsx','QUEUED','final.xlsx');
UPDATE public.ipos_import_requests SET state='PROCESSING' WHERE id='a0000000-0000-4000-8000-000000000202';
UPDATE public.ipos_import_requests SET state='COMPLETED' WHERE id='a0000000-0000-4000-8000-000000000202';
INSERT INTO public.ipos_import_batches(id,outlet_id,original_filename,storage_bucket,storage_path,source_sheet,
  header_row_number,first_data_row_number,expected_data_row_count,actual_data_row_count,validation_errors,
  imported_by,status,request_id)
VALUES('a0000000-0000-4000-8000-000000000203','a0000000-0000-4000-8000-000000000200','final.xlsx',
  'quena-ipos-imports','cutover-race/final.xlsx','Products',1,2,1,1,'[]',
  'a0000000-0000-4000-8000-000000000001','UPLOADED','a0000000-0000-4000-8000-000000000202');
UPDATE public.ipos_import_batches SET status='PROCESSING' WHERE id='a0000000-0000-4000-8000-000000000203';
UPDATE public.ipos_import_batches SET status='COMPLETED' WHERE id='a0000000-0000-4000-8000-000000000203';
INSERT INTO public.ipos_normalization_commits(id,batch_id,outlet_id,normalization_version,status,completed_at,
  raw_row_count,linked_row_count,invalid_row_count,finding_counts,preflight_state_md5,result)
VALUES('a0000000-0000-4000-8000-000000000204','a0000000-0000-4000-8000-000000000203',
  'a0000000-0000-4000-8000-000000000200','ipos-v1-preflight','COMPLETED',now(),1,1,0,'{}',md5('race'), '{}');
ALTER TABLE public.ipos_import_rows DISABLE TRIGGER ipos_import_rows_processing_only;
INSERT INTO public.ipos_import_rows(id,batch_id,outlet_id,source_row_number,raw_data,status,product_id,validation_errors)
VALUES('a0000000-0000-4000-8000-000000000205','a0000000-0000-4000-8000-000000000203',
  'a0000000-0000-4000-8000-000000000200',3,'{"sku":"CUTOVER-RACE-PRODUCT","STOK":"7.500"}',
  'VALID','a0000000-0000-4000-8000-000000000201','[]');
ALTER TABLE public.ipos_import_rows ENABLE TRIGGER ipos_import_rows_processing_only;
INSERT INTO public.ipos_normalization_commit_rows(commit_id,batch_id,outlet_id,source_row_id,source_row_number,
  action,sku,expected_product_id,product_id,normalized_data,finding_codes,validation_errors,override_conflicts)
VALUES('a0000000-0000-4000-8000-000000000204','a0000000-0000-4000-8000-000000000203',
  'a0000000-0000-4000-8000-000000000200','a0000000-0000-4000-8000-000000000205',3,'CREATE',
  'CUTOVER-RACE-PRODUCT',NULL,'a0000000-0000-4000-8000-000000000201','{"quantity":7.5}','{}','[]','{}');
INSERT INTO public.stock_authority_periods(id,outlet_id,mode,created_by,created_reason)
VALUES('a0000000-0000-4000-8000-000000000206','a0000000-0000-4000-8000-000000000200',
  'IPOS_SNAPSHOT_PLUS_QUENA_MOVEMENTS','a0000000-0000-4000-8000-000000000001','Concurrent cutover test');
INSERT INTO public.stock_balance_projection(product_id,outlet_id,authority_period_id,baseline_quantity,
  baseline_source_import_row_id,baseline_batch_id,baseline_commit_id,unreconciled_movement_delta,balance_version,
  last_observation_source_import_row_id,last_observation_status)
VALUES('a0000000-0000-4000-8000-000000000201','a0000000-0000-4000-8000-000000000200',
  'a0000000-0000-4000-8000-000000000206',2,'a0000000-0000-4000-8000-000000000205',
  'a0000000-0000-4000-8000-000000000203','a0000000-0000-4000-8000-000000000204',1,1,
  'a0000000-0000-4000-8000-000000000205','BOOTSTRAPPED');
