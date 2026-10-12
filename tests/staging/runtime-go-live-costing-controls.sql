\set ON_ERROR_STOP on
\timing on

-- Disposable PostgreSQL 15 only. The shell wrapper pins localhost, port 55441,
-- database name, and the installed candidate migration before invoking this.
DO $guard$
BEGIN
  IF NOT ((current_database()='quena_stock_staging' AND inet_server_port()=55441)
      OR (current_database() LIKE 'quena_native_product_%' AND inet_server_port()=55432))
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR current_setting('server_version_num')::integer/10000<>15
    OR to_regprocedure('public.stock_opening_cutover(uuid,uuid,uuid,uuid,text)') IS NULL
    OR to_regprocedure('public.inventory_cost_bootstrap_outlet(uuid,uuid,uuid,text)') IS NULL
    OR to_regprocedure('public.inventory_cost_activate_wac(uuid,uuid,text)') IS NULL
    OR to_regprocedure('public.go_live_reset_preparation(uuid,uuid,text,text)') IS NULL
    OR NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conname='stock_opening_cutover_request_one_per_outlet') THEN
    RAISE EXCEPTION 'Refusing stock opening cutover test outside guarded local PostgreSQL 15 staging';
  END IF;
END $guard$;

-- A clean staging database has one pre-created outlet from the stock fixture
-- bootstrap. Auth/profile and import records below are disposable test data.
INSERT INTO auth.users(id) VALUES
 ('a0000000-0000-4000-8000-000000000001'),
 ('a0000000-0000-4000-8000-000000000002')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.profiles(id,full_name,role,is_active) VALUES
 ('a0000000-0000-4000-8000-000000000001','Cutover Owner','OWNER',true)
ON CONFLICT (id) DO UPDATE SET full_name=EXCLUDED.full_name,role=EXCLUDED.role,is_active=EXCLUDED.is_active;

SELECT id AS outlet_id FROM public.outlets WHERE code='QUENA-MART-1' AND is_active \gset
SELECT 'a0000000-0000-4000-8000-000000000001'::uuid AS owner_id \gset
SELECT gen_random_uuid() AS previous_request \gset
SELECT gen_random_uuid() AS previous_import_request \gset
SELECT gen_random_uuid() AS previous_batch \gset
SELECT gen_random_uuid() AS previous_commit \gset
SELECT gen_random_uuid() AS final_import_request \gset
SELECT gen_random_uuid() AS final_batch \gset
SELECT gen_random_uuid() AS final_commit \gset
SELECT gen_random_uuid() AS stock_operation_request \gset
SELECT gen_random_uuid() AS movement_batch \gset

SELECT id AS previous_period FROM public.stock_authority_periods
 WHERE outlet_id=:'outlet_id'::uuid AND ended_at IS NULL \gset
UPDATE public.stock_authority_periods SET mode='IPOS_SNAPSHOT_PLUS_QUENA_MOVEMENTS',
  created_by=:'owner_id'::uuid,created_reason='Disposable rehearsal period'
WHERE id=:'previous_period'::uuid;

-- Mix a real native zero baseline into this iPos cutover fixture. It must not
-- need a normalization row or appear in cutover item/source evidence.
SELECT set_config('request.jwt.claim.sub', :'owner_id', false);
SET ROLE authenticated;
SELECT (public.native_product_create(gen_random_uuid(),'CUTOVER-NATIVE-ZERO','Native zero baseline cutover fixture',
  'Native','pcs',NULL,NULL,NULL,12000,9000)->>'product_id')::uuid AS native_product_id \gset
RESET ROLE;
SELECT set_config('quena.native_product', :'native_product_id', false);

INSERT INTO public.ipos_import_requests(id,outlet_id,requested_by,storage_path,state,original_filename)
VALUES(:'previous_import_request'::uuid,:'outlet_id'::uuid,:'owner_id'::uuid,
  'cutover-test/previous.xlsx','QUEUED','previous.xlsx'),
 (:'final_import_request'::uuid,:'outlet_id'::uuid,:'owner_id'::uuid,
  'cutover-test/final.xlsx','QUEUED','final.xlsx');
UPDATE public.ipos_import_requests SET state='PROCESSING'
WHERE id IN (:'previous_import_request'::uuid,:'final_import_request'::uuid);
UPDATE public.ipos_import_requests SET state='COMPLETED'
WHERE id IN (:'previous_import_request'::uuid,:'final_import_request'::uuid);
INSERT INTO public.ipos_import_batches(id,outlet_id,original_filename,storage_bucket,storage_path,
  source_sheet,header_row_number,first_data_row_number,expected_data_row_count,actual_data_row_count,
  validation_errors,imported_by,status,started_at,completed_at,request_id)
VALUES(:'previous_batch'::uuid,:'outlet_id'::uuid,'previous.xlsx','quena-ipos-imports',
  'cutover-test/previous.xlsx','Products',1,2,6,6,'[]',:'owner_id'::uuid,'UPLOADED',NULL,NULL,
  :'previous_import_request'::uuid),
 (:'final_batch'::uuid,:'outlet_id'::uuid,'final.xlsx','quena-ipos-imports',
  'cutover-test/final.xlsx','Products',1,2,6,6,'[]',:'owner_id'::uuid,'UPLOADED',NULL,NULL,
  :'final_import_request'::uuid);
UPDATE public.ipos_import_batches SET status='PROCESSING'
WHERE id IN (:'previous_batch'::uuid,:'final_batch'::uuid);
UPDATE public.ipos_import_batches SET status='COMPLETED'
WHERE id=:'previous_batch'::uuid;
UPDATE public.ipos_import_batches SET status='COMPLETED'
WHERE id=:'final_batch'::uuid;
INSERT INTO public.ipos_normalization_commits(id,batch_id,outlet_id,normalization_version,status,
  started_at,completed_at,raw_row_count,linked_row_count,invalid_row_count,finding_counts,preflight_state_md5,result)
VALUES(:'previous_commit'::uuid,:'previous_batch'::uuid,:'outlet_id'::uuid,'ipos-v1-preflight','COMPLETED',
  now()-interval '2 days',now()-interval '2 days',6,6,0,'{}',md5('previous'),'{}'),
 (:'final_commit'::uuid,:'final_batch'::uuid,:'outlet_id'::uuid,'ipos-v1-preflight','COMPLETED',
  now()-interval '1 day',now()-interval '1 day',6,6,0,'{}',md5('final'),'{}');

CREATE TEMP TABLE cutover_fixture_products(n integer PRIMARY KEY,product_id uuid UNIQUE,
  sku text UNIQUE,old_qty numeric,old_delta numeric,opening_qty numeric) ON COMMIT PRESERVE ROWS;
INSERT INTO cutover_fixture_products VALUES
 (1,gen_random_uuid(),'CUTOVER-ZERO',10,3,0),
 (2,gen_random_uuid(),'CUTOVER-DECIMAL',3.125,-0.125,1.250),
 (3,gen_random_uuid(),'CUTOVER-MULTI',0,2,4.125),
 (4,gen_random_uuid(),'CUTOVER-OVERRIDE',2,1,2.500),
 (5,gen_random_uuid(),'CUTOVER-UNVALUED',3,1,3.000),
 (6,gen_random_uuid(),'CUTOVER-AUTHZERO',4,1,1.500);
INSERT INTO public.products(id,sku,name,unit_label,created_by,updated_by)
SELECT product_id,sku,'Cutover fixture '||n,'pcs',:'owner_id'::uuid,:'owner_id'::uuid
FROM cutover_fixture_products ORDER BY n;

-- The worker-only raw import insertion guard is bypassed only to construct
-- realistic immutable fixture rows in this disposable test database.
ALTER TABLE public.ipos_import_rows DISABLE TRIGGER ipos_import_rows_processing_only;
INSERT INTO public.ipos_import_rows(id,batch_id,outlet_id,source_row_number,raw_data,status,product_id,validation_errors)
SELECT gen_random_uuid(),:'previous_batch'::uuid,:'outlet_id'::uuid,2+n,
  jsonb_build_object('sku',sku,'STOK',old_qty::text),'VALID',product_id,'[]'
FROM cutover_fixture_products ORDER BY n;
CREATE TEMP TABLE previous_sources AS
SELECT r.product_id,r.id AS row_id FROM public.ipos_import_rows r
WHERE r.batch_id=:'previous_batch'::uuid;
INSERT INTO public.ipos_import_rows(id,batch_id,outlet_id,source_row_number,raw_data,status,product_id,validation_errors)
SELECT gen_random_uuid(),:'final_batch'::uuid,:'outlet_id'::uuid,2+n,
  jsonb_build_object('sku',sku,'STOK',opening_qty::text),'VALID',product_id,'[]'
FROM cutover_fixture_products ORDER BY n;
CREATE TEMP TABLE other_stock_products ON COMMIT PRESERVE ROWS AS
SELECT p.product_id,pr.sku,row_number() OVER(ORDER BY p.product_id)::integer AS n
FROM public.stock_balance_projection p JOIN public.products pr ON pr.id=p.product_id
WHERE p.outlet_id=:'outlet_id'::uuid
  AND p.native_zero_baseline_request_id IS NULL
  AND NOT EXISTS(SELECT 1 FROM cutover_fixture_products f WHERE f.product_id=p.product_id);
INSERT INTO public.ipos_import_rows(id,batch_id,outlet_id,source_row_number,raw_data,status,product_id,validation_errors)
SELECT gen_random_uuid(),:'final_batch'::uuid,:'outlet_id'::uuid,100+n,
  jsonb_build_object('sku',sku,'STOK','0'),'VALID',product_id,'[]'
FROM other_stock_products ORDER BY n;
CREATE TEMP TABLE final_sources AS
SELECT r.product_id,r.id AS row_id FROM public.ipos_import_rows r
WHERE r.batch_id=:'final_batch'::uuid;
GRANT SELECT ON cutover_fixture_products,final_sources TO authenticated;
ALTER TABLE public.ipos_import_rows ENABLE TRIGGER ipos_import_rows_processing_only;

INSERT INTO public.ipos_normalization_commit_rows(commit_id,batch_id,outlet_id,source_row_id,
  source_row_number,action,sku,expected_product_id,product_id,normalized_data,finding_codes,validation_errors,override_conflicts)
SELECT :'previous_commit'::uuid,:'previous_batch'::uuid,:'outlet_id'::uuid,s.row_id,2+p.n,'UPDATE',p.sku,
  p.product_id,p.product_id,jsonb_build_object('quantity',p.old_qty),'{}','[]','{}'
FROM cutover_fixture_products p JOIN previous_sources s USING(product_id) ORDER BY p.n;
INSERT INTO public.ipos_normalization_commit_rows(commit_id,batch_id,outlet_id,source_row_id,
  source_row_number,action,sku,expected_product_id,product_id,normalized_data,finding_codes,validation_errors,override_conflicts)
SELECT :'final_commit'::uuid,:'final_batch'::uuid,:'outlet_id'::uuid,s.row_id,2+p.n,'UPDATE',p.sku,
  p.product_id,p.product_id,jsonb_build_object('quantity',p.opening_qty,'hpp',CASE p.n WHEN 2 THEN 100 WHEN 3 THEN 0 WHEN 4 THEN 0 WHEN 5 THEN 0 WHEN 6 THEN 0 ELSE 50 END),'{}','[]','{}'
FROM cutover_fixture_products p JOIN final_sources s USING(product_id) ORDER BY p.n;
INSERT INTO public.ipos_normalization_commit_rows(commit_id,batch_id,outlet_id,source_row_id,
  source_row_number,action,sku,expected_product_id,product_id,normalized_data,finding_codes,validation_errors,override_conflicts)
SELECT :'final_commit'::uuid,:'final_batch'::uuid,:'outlet_id'::uuid,s.row_id,99+p.n,'UPDATE',p.sku,
  p.product_id,p.product_id,jsonb_build_object('quantity',0),'{}','[]','{}'
FROM other_stock_products p JOIN final_sources s USING(product_id) ORDER BY p.n;

INSERT INTO public.stock_balance_projection(product_id,outlet_id,authority_period_id,baseline_quantity,
  baseline_source_import_row_id,baseline_batch_id,baseline_commit_id,unreconciled_movement_delta,
  balance_version,last_observation_source_import_row_id,last_observation_status)
SELECT p.product_id,:'outlet_id'::uuid,:'previous_period'::uuid,p.old_qty,s.row_id,
  :'previous_batch'::uuid,:'previous_commit'::uuid,p.old_delta,1,s.row_id,'BOOTSTRAPPED'
FROM cutover_fixture_products p JOIN previous_sources s USING(product_id) ORDER BY p.n;
UPDATE public.stock_balance_projection p SET balance_version=2
FROM cutover_fixture_products f WHERE p.product_id=f.product_id AND p.outlet_id=:'outlet_id'::uuid;

-- Rehearsal ledger evidence is real and immutable; its delta is intentionally
-- non-zero so the test can prove the rebase does not add it a second time.
INSERT INTO public.stock_operation_requests(request_id,actor_id,operation_key,target_key,
  request_payload,payload_hash,state,result,completed_at)
VALUES(:'stock_operation_request'::uuid,:'owner_id'::uuid,'CUTOVER_FIXTURE','outlet:'||:'outlet_id',
  jsonb_build_object('fixture',true),md5('cutover-movement'), 'COMPLETED','{}',now());
INSERT INTO public.stock_movement_batches(id,authority_period_id,outlet_id,source_system,
  operation_request_id,created_by)
VALUES(:'movement_batch'::uuid,:'previous_period'::uuid,:'outlet_id'::uuid,'MANUAL',
  :'stock_operation_request'::uuid,:'owner_id'::uuid);
INSERT INTO public.stock_movements(id,batch_id,authority_period_id,outlet_id,product_id,
  movement_type,source_system,quantity_delta,balance_before,balance_after,source_reference,
  source_event_key,created_by)
SELECT gen_random_uuid(),:'movement_batch'::uuid,:'previous_period'::uuid,:'outlet_id'::uuid,p.product_id,
  CASE WHEN p.old_delta>0 THEN 'MANUAL_IN'::public.stock_movement_type ELSE 'MANUAL_OUT'::public.stock_movement_type END,
  'MANUAL'::public.stock_movement_source,p.old_delta,p.old_qty,p.old_qty+p.old_delta,
  'Disposable rehearsal movement','CUTOVER-FIXTURE-'||p.sku,:'owner_id'::uuid
FROM cutover_fixture_products p ORDER BY p.product_id;
INSERT INTO public.stock_balance_projection_events(product_id,outlet_id,authority_period_id,event_type,
  request_id,quantity_delta,balance_before,balance_after,balance_version,actor_id)
SELECT p.product_id,:'outlet_id'::uuid,:'previous_period'::uuid,'MOVEMENT_POSTED',
  :'stock_operation_request'::uuid,p.old_delta,p.old_qty,p.old_qty+p.old_delta,2,:'owner_id'::uuid
FROM cutover_fixture_products p ORDER BY p.product_id;

SELECT count(*)::integer AS old_movement_count FROM public.stock_movements m
JOIN cutover_fixture_products p USING(product_id) \gset
INSERT INTO public.outlets(id,code,name,is_active)
SELECT gen_random_uuid(),'CUTOVER-FOREIGN','Cutover foreign outlet',true
WHERE NOT EXISTS(SELECT 1 FROM public.outlets WHERE code='CUTOVER-FOREIGN');

SELECT set_config('request.jwt.claim.sub',:'owner_id',false);
DO $precutover_denials$
DECLARE v_outlet uuid;v_foreign uuid;v_commit uuid;v_period uuid;v_request uuid;v_message text;
BEGIN
  SELECT id INTO v_outlet FROM public.outlets WHERE code='QUENA-MART-1';
  SELECT c.id INTO v_commit FROM public.ipos_normalization_commits c
    JOIN public.ipos_import_batches b ON b.id=c.batch_id WHERE b.storage_path='cutover-test/final.xlsx';
  SELECT id INTO v_period FROM public.stock_authority_periods WHERE outlet_id=v_outlet AND ended_at IS NULL;
  v_request:=gen_random_uuid();
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',false);
  BEGIN
    PERFORM public.stock_opening_cutover(v_outlet,v_commit,v_period,v_request,
      'OPENING-STOCK-CUTOVER:'||v_outlet::text||':'||v_commit::text);
    RAISE EXCEPTION 'Expected non-OWNER rejection';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'STOCK_CUTOVER_UNAUTHORIZED' THEN RAISE; END IF;
  END;
  IF EXISTS(SELECT 1 FROM public.stock_opening_cutover_requests WHERE request_id=v_request) THEN
    RAISE EXCEPTION 'Non-OWNER denial persisted a request';
  END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false);
  v_request:=gen_random_uuid();
  v_foreign:=gen_random_uuid();
  BEGIN
    PERFORM public.stock_opening_cutover(v_foreign,v_commit,v_period,v_request,
      'OPENING-STOCK-CUTOVER:'||v_foreign::text||':'||v_commit::text);
    RAISE EXCEPTION 'Expected wrong-outlet rejection';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'STOCK_CUTOVER_UNAUTHORIZED' THEN RAISE; END IF;
  END;
  IF EXISTS(SELECT 1 FROM public.stock_opening_cutover_requests WHERE request_id=v_request) THEN
    RAISE EXCEPTION 'Wrong-outlet denial persisted a request';
  END IF;
  SELECT id INTO v_foreign FROM public.outlets WHERE code='CUTOVER-FOREIGN';
  v_request:=gen_random_uuid();
  BEGIN
    PERFORM public.stock_opening_cutover(v_foreign,v_commit,v_period,v_request,
      'OPENING-STOCK-CUTOVER:'||v_foreign::text||':'||v_commit::text);
    RAISE EXCEPTION 'Expected mismatched snapshot/outlet rejection';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'STOCK_CUTOVER_SNAPSHOT_UNAVAILABLE' THEN RAISE; END IF;
  END;
  IF EXISTS(SELECT 1 FROM public.stock_opening_cutover_requests WHERE request_id=v_request) THEN
    RAISE EXCEPTION 'Mismatched snapshot/outlet persisted request evidence';
  END IF;
END $precutover_denials$;

DO $draft_blocker$
DECLARE v_outlet uuid;v_commit uuid;v_period uuid;v_request uuid;v_message text;
BEGIN
  SELECT id INTO v_outlet FROM public.outlets WHERE code='QUENA-MART-1';
  SELECT c.id INTO v_commit FROM public.ipos_normalization_commits c
    JOIN public.ipos_import_batches b ON b.id=c.batch_id WHERE b.storage_path='cutover-test/final.xlsx';
  SELECT id INTO v_period FROM public.stock_authority_periods WHERE outlet_id=v_outlet AND ended_at IS NULL;
  v_request:=gen_random_uuid();
  BEGIN
    INSERT INTO public.pos_carts(id,outlet_id,created_by,status,revision)
      VALUES(gen_random_uuid(),v_outlet,'a0000000-0000-4000-8000-000000000002','ACTIVE',1);
    PERFORM public.stock_opening_cutover(v_outlet,v_commit,v_period,v_request,
      'OPENING-STOCK-CUTOVER:'||v_outlet::text||':'||v_commit::text);
    RAISE EXCEPTION 'Expected open-cart blocker';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'STOCK_CUTOVER_OPERATIONAL_DRAFTS_OPEN' THEN RAISE; END IF;
  END;
  IF EXISTS(SELECT 1 FROM public.stock_opening_cutover_requests WHERE request_id=v_request)
    OR EXISTS(SELECT 1 FROM public.pos_carts WHERE outlet_id=v_outlet AND status IN ('ACTIVE','PARKED')) THEN
    RAISE EXCEPTION 'Draft blocker left persistent test state';
  END IF;
END $draft_blocker$;

DO $pending_operation_blocker$
DECLARE v_outlet uuid;v_commit uuid;v_period uuid;v_request uuid;v_message text;
BEGIN
  SELECT id INTO v_outlet FROM public.outlets WHERE code='QUENA-MART-1';
  SELECT c.id INTO v_commit FROM public.ipos_normalization_commits c
    JOIN public.ipos_import_batches b ON b.id=c.batch_id WHERE b.storage_path='cutover-test/final.xlsx';
  SELECT id INTO v_period FROM public.stock_authority_periods WHERE outlet_id=v_outlet AND ended_at IS NULL;
  v_request:=gen_random_uuid();
  BEGIN
    INSERT INTO public.stock_operation_requests(actor_id,operation_key,target_key,request_payload,payload_hash)
      VALUES('a0000000-0000-4000-8000-000000000001','CREATE_SESSION','outlet:'||v_outlet::text,
        jsonb_build_object('outlet_id',v_outlet),md5('pending-cutover-fixture'));
    PERFORM public.stock_opening_cutover(v_outlet,v_commit,v_period,v_request,
      'OPENING-STOCK-CUTOVER:'||v_outlet::text||':'||v_commit::text);
    RAISE EXCEPTION 'Expected pending stock-operation blocker';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'STOCK_CUTOVER_OPERATIONAL_DRAFTS_OPEN' THEN RAISE; END IF;
  END;
  IF EXISTS(SELECT 1 FROM public.stock_opening_cutover_requests WHERE request_id=v_request)
    OR EXISTS(SELECT 1 FROM public.stock_operation_requests WHERE state='PENDING'
      AND request_payload->>'outlet_id'=v_outlet::text) THEN
    RAISE EXCEPTION 'Pending operation blocker left persistent test state';
  END IF;
END $pending_operation_blocker$;

DO $wac_blocker$
DECLARE v_outlet uuid;v_commit uuid;v_period uuid;v_request uuid;v_message text;
  v_actor uuid:='a0000000-0000-4000-8000-000000000001';v_cost_request uuid;v_cost_batch uuid;
BEGIN
  SELECT id INTO v_outlet FROM public.outlets WHERE code='QUENA-MART-1';
  SELECT c.id INTO v_commit FROM public.ipos_normalization_commits c
    JOIN public.ipos_import_batches b ON b.id=c.batch_id WHERE b.storage_path='cutover-test/final.xlsx';
  SELECT id INTO v_period FROM public.stock_authority_periods WHERE outlet_id=v_outlet AND ended_at IS NULL;
  v_request:=gen_random_uuid();v_cost_request:=gen_random_uuid();v_cost_batch:=gen_random_uuid();
  BEGIN
    INSERT INTO public.inventory_cost_operation_requests(request_id,actor_id,operation_key,target_key,payload_hash,result,completed_at)
      VALUES(v_cost_request,v_actor,'BOOTSTRAP_OUTLET','outlet:'||v_outlet::text,md5('local-cutover-wac-test'),'{}',now());
    INSERT INTO public.inventory_cost_event_batches(id,outlet_id,batch_type,source_entity_type,source_entity_id,
      operation_request_id,created_by,applied_at)
      VALUES(v_cost_batch,v_outlet,'OPENING','TEST_BOOTSTRAP',gen_random_uuid(),v_cost_request,v_actor,now());
    INSERT INTO public.inventory_costing_outlet_authority(outlet_id,status,bootstrap_batch_id,bootstrapped_by,
      bootstrapped_at,activated_by,activated_at)
      VALUES(v_outlet,'WAC_ACTIVE',v_cost_batch,v_actor,now(),v_actor,now());
    PERFORM public.stock_opening_cutover(v_outlet,v_commit,v_period,v_request,
      'OPENING-STOCK-CUTOVER:'||v_outlet::text||':'||v_commit::text);
    RAISE EXCEPTION 'Expected WAC blocker';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'STOCK_CUTOVER_COSTING_ALREADY_STARTED' THEN RAISE; END IF;
  END;
  IF EXISTS(SELECT 1 FROM public.stock_opening_cutover_requests WHERE request_id=v_request)
    OR EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE outlet_id=v_outlet) THEN
    RAISE EXCEPTION 'WAC blocker left persistent test state';
  END IF;
END $wac_blocker$;

CREATE FUNCTION public.quena_test_fail_opening_cutover_item()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION USING MESSAGE='CUTOVER_TEST_FORCED_FAILURE_AFTER_PROJECTION'; END;
$$;
CREATE TRIGGER quena_test_fail_opening_cutover_item
BEFORE INSERT ON public.stock_opening_cutover_items
FOR EACH ROW EXECUTE FUNCTION public.quena_test_fail_opening_cutover_item();
DO $rollback_assertion$
DECLARE v_outlet uuid;v_commit uuid;v_period uuid;v_request uuid;v_message text;
BEGIN
  SELECT id INTO v_outlet FROM public.outlets WHERE code='QUENA-MART-1';
  SELECT c.id INTO v_commit FROM public.ipos_normalization_commits c
    JOIN public.ipos_import_batches b ON b.id=c.batch_id WHERE b.storage_path='cutover-test/final.xlsx';
  SELECT id INTO v_period FROM public.stock_authority_periods WHERE outlet_id=v_outlet AND ended_at IS NULL;
  v_request:=gen_random_uuid();
  BEGIN
    PERFORM public.stock_opening_cutover(v_outlet,v_commit,v_period,v_request,
      'OPENING-STOCK-CUTOVER:'||v_outlet::text||':'||v_commit::text);
    RAISE EXCEPTION 'Expected injected failure';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'CUTOVER_TEST_FORCED_FAILURE_AFTER_PROJECTION' THEN RAISE; END IF;
  END;
  IF EXISTS(SELECT 1 FROM public.stock_opening_cutover_requests WHERE request_id=v_request)
    OR EXISTS(SELECT 1 FROM public.stock_opening_cutover_items WHERE request_id=v_request)
    OR EXISTS(SELECT 1 FROM public.stock_balance_projection_events WHERE opening_cutover_request_id=v_request)
    OR NOT EXISTS(SELECT 1 FROM public.stock_authority_periods WHERE id=v_period AND ended_at IS NULL)
    OR (SELECT count(*) FROM public.stock_authority_periods WHERE outlet_id=v_outlet AND ended_at IS NULL)<>1
    OR EXISTS(SELECT 1 FROM cutover_fixture_products f JOIN public.stock_balance_projection s USING(product_id)
      WHERE s.outlet_id=v_outlet AND (s.baseline_quantity<>f.old_qty
        OR s.unreconciled_movement_delta<>f.old_delta OR s.authority_period_id<>v_period OR s.balance_version<>2)) THEN
    RAISE EXCEPTION 'Injected failure left partial cutover state';
  END IF;
END $rollback_assertion$;
DROP TRIGGER quena_test_fail_opening_cutover_item ON public.stock_opening_cutover_items;
DROP FUNCTION public.quena_test_fail_opening_cutover_item();

-- Reset preparation before final cutover cancels only the reversible active cart.
SELECT set_config('quena.test.outlet',:'outlet_id',false);
SELECT set_config('request.jwt.claim.sub',:'owner_id',false);
INSERT INTO public.pos_carts(id,outlet_id,created_by,status,revision)
VALUES(gen_random_uuid(),:'outlet_id'::uuid,:'owner_id'::uuid,'ACTIVE',1)
RETURNING id AS reset_cart_id \gset
INSERT INTO public.suppliers(display_name,created_by,updated_by)
VALUES('Go-live reset fixture supplier',:'owner_id'::uuid,:'owner_id'::uuid)
RETURNING id AS reset_supplier_id \gset
INSERT INTO public.purchase_receipts(outlet_id,supplier_id,received_at,created_by,updated_by)
VALUES(:'outlet_id'::uuid,:'reset_supplier_id'::uuid,clock_timestamp(),:'owner_id'::uuid,:'owner_id'::uuid)
RETURNING id AS reset_receipt_id \gset
INSERT INTO public.purchase_invoices(outlet_id,supplier_id,created_by,updated_by)
VALUES(:'outlet_id'::uuid,:'reset_supplier_id'::uuid,:'owner_id'::uuid,:'owner_id'::uuid)
RETURNING id AS reset_linked_invoice_id \gset
INSERT INTO public.purchase_invoice_receipts(invoice_id,receipt_id,linked_by)
VALUES(:'reset_linked_invoice_id'::uuid,:'reset_receipt_id'::uuid,:'owner_id'::uuid);
INSERT INTO public.purchase_invoices(outlet_id,supplier_id,created_by,updated_by)
VALUES(:'outlet_id'::uuid,:'reset_supplier_id'::uuid,:'owner_id'::uuid,:'owner_id'::uuid)
RETURNING id AS reset_standalone_invoice_id \gset
INSERT INTO auth.users(id) VALUES('a0000000-0000-4000-8000-000000000002') ON CONFLICT DO NOTHING;
INSERT INTO public.profiles(id,full_name,role,is_active)
VALUES('a0000000-0000-4000-8000-000000000002','Stage Admin','ADMIN',true)
ON CONFLICT(id) DO UPDATE SET role='ADMIN',is_active=true;
SELECT gen_random_uuid()::text AS reset_request \gset
-- The OWNER-only contract rejects wrong confirmation and non-OWNER calls
-- before writing durable request evidence.
SELECT set_config('quena.test.reset_request',:'reset_request',false);
SELECT set_config('quena.test.reset_cart_id',:'reset_cart_id',false);
CREATE FUNCTION public.quena_go_live_fail_cart_cancel() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status='CANCELLED' AND OLD.status IN ('ACTIVE','PARKED') THEN
    RAISE EXCEPTION USING MESSAGE='GO_LIVE_TEST_INJECTED_CART_CANCEL_FAILURE';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER quena_go_live_fail_cart_cancel BEFORE UPDATE OF status ON public.pos_carts
  FOR EACH ROW EXECUTE FUNCTION public.quena_go_live_fail_cart_cancel();
DO $reset_failure_rollback$
DECLARE o uuid:=current_setting('quena.test.outlet')::uuid;r uuid:=current_setting('quena.test.reset_request')::uuid;
  msg text;failed boolean:=false;
BEGIN
  BEGIN PERFORM public.go_live_reset_preparation(o,r,'PREPARE-GO-LIVE:'||o||':'||r,'Injected draft cancellation failure');
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR msg<>'GO_LIVE_TEST_INJECTED_CART_CANCEL_FAILURE'
    OR EXISTS(SELECT 1 FROM public.go_live_reset_preparation_requests WHERE request_id=r)
    OR (SELECT status FROM public.pos_carts WHERE id=current_setting('quena.test.reset_cart_id')::uuid)<>'ACTIVE' THEN
    RAISE EXCEPTION 'Reset-preparation failure did not roll back request and draft state'; END IF;
END $reset_failure_rollback$;
DROP TRIGGER quena_go_live_fail_cart_cancel ON public.pos_carts;
DROP FUNCTION public.quena_go_live_fail_cart_cancel();
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',false);
SET ROLE authenticated;
DO $reset_authorization_guards$
DECLARE o uuid:=current_setting('quena.test.outlet')::uuid;r uuid:=current_setting('quena.test.reset_request')::uuid;
  msg text;failed boolean:=false;
BEGIN
  BEGIN PERFORM public.go_live_reset_preparation(o,r,'PREPARE-GO-LIVE:'||o||':'||r,'Non-owner attempt');
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR msg<>'GO_LIVE_OWNER_REQUIRED' THEN RAISE EXCEPTION 'ADMIN was allowed go-live reset preparation: %',msg; END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false);failed:=false;
  BEGIN PERFORM public.go_live_reset_preparation(o,r,'wrong confirmation','Wrong confirmation attempt');
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR msg<>'GO_LIVE_PREPARATION_CONFIRMATION_REQUIRED'
    OR EXISTS(SELECT 1 FROM public.go_live_reset_preparation_requests WHERE request_id=r) THEN
    RAISE EXCEPTION 'Wrong reset confirmation persisted or was accepted'; END IF;
END $reset_authorization_guards$;
RESET ROLE;
SELECT set_config('request.jwt.claim.sub',:'owner_id',false);
SET ROLE authenticated;
SELECT public.go_live_reset_preparation(:'outlet_id'::uuid,:'reset_request'::uuid,
  'PREPARE-GO-LIVE:'||:'outlet_id'||':'||:'reset_request','Disposable reset preparation test') AS reset_result \gset
RESET ROLE;
SELECT set_config('quena.test.reset_result', :'reset_result', false);
SELECT set_config('quena.test.reset_request', :'reset_request', false);
SELECT set_config('quena.test.reset_receipt_id', :'reset_receipt_id', false);
SELECT set_config('quena.test.reset_linked_invoice_id', :'reset_linked_invoice_id', false);
SELECT set_config('quena.test.reset_standalone_invoice_id', :'reset_standalone_invoice_id', false);
DO $reset_prep_assert$
BEGIN
  IF current_setting('quena.test.reset_result')::jsonb->>'code'<>'READY_FOR_FINAL_IMPORT'
    OR current_setting('quena.test.reset_result')::jsonb->'cancelledDrafts'->>'carts'<>'1'
    OR current_setting('quena.test.reset_result')::jsonb->'cancelledDrafts'->>'receipts'<>'1'
    OR current_setting('quena.test.reset_result')::jsonb->'cancelledDrafts'->>'invoices'<>'2'
    OR (SELECT status FROM public.pos_carts WHERE outlet_id=(SELECT id FROM public.outlets WHERE code='QUENA-MART-1') ORDER BY created_at DESC,id DESC LIMIT 1)<>'CANCELLED'
    OR (SELECT status FROM public.purchase_receipts WHERE id=current_setting('quena.test.reset_receipt_id')::uuid)<>'CANCELLED'
    OR (SELECT status FROM public.purchase_invoices WHERE id=current_setting('quena.test.reset_linked_invoice_id')::uuid)<>'CANCELLED'
    OR (SELECT status FROM public.purchase_invoices WHERE id=current_setting('quena.test.reset_standalone_invoice_id')::uuid)<>'CANCELLED'
    OR NOT EXISTS(SELECT 1 FROM public.purchase_receipt_events WHERE receipt_id=current_setting('quena.test.reset_receipt_id')::uuid AND event_type='CANCELLED')
    OR (SELECT count(*) FROM public.purchase_invoice_events WHERE invoice_id IN (current_setting('quena.test.reset_linked_invoice_id')::uuid,current_setting('quena.test.reset_standalone_invoice_id')::uuid) AND event_type='CANCELLED')<>2
    OR (SELECT count(*) FROM public.go_live_reset_preparation_requests WHERE request_id=(current_setting('quena.test.reset_result')::jsonb->>'requestId')::uuid)<>1 THEN
    RAISE EXCEPTION 'Reset preparation failed to cancel/audit only the reversible draft';
  END IF;
END $reset_prep_assert$;
SET ROLE authenticated;
SELECT public.go_live_reset_preparation(:'outlet_id'::uuid,:'reset_request'::uuid,
  'PREPARE-GO-LIVE:'||:'outlet_id'||':'||:'reset_request','Disposable reset preparation test') AS reset_replay \gset
RESET ROLE;
SELECT set_config('quena.test.reset_replay', :'reset_replay', false);
DO $reset_replay_assert$
BEGIN
  IF current_setting('quena.test.reset_replay')::jsonb IS DISTINCT FROM current_setting('quena.test.reset_result')::jsonb THEN RAISE EXCEPTION 'Reset replay was not exact'; END IF;
END $reset_replay_assert$;
SELECT set_config('request.jwt.claim.sub',:'owner_id',false);
SET ROLE authenticated;
SELECT gen_random_uuid()::text AS request_id \gset
SELECT :'request_id'::uuid AS request_id,
  public.stock_opening_cutover(:'outlet_id'::uuid,:'final_commit'::uuid,:'previous_period'::uuid,
  :'request_id'::uuid,'OPENING-STOCK-CUTOVER:'||:'outlet_id'||':'||:'final_commit') AS result
  INTO TEMP TABLE cutover_test_result;
RESET ROLE;

DO $success_assertions$
DECLARE v_outlet uuid;
  v_previous uuid;
  v_new uuid;
  v_request uuid;
  v_product record;
  v_result jsonb;
BEGIN
  SELECT request_id,result INTO v_request,v_result FROM cutover_test_result;
  v_outlet:=(v_result->>'outletId')::uuid;
  v_previous:=(v_result->>'previousAuthorityPeriodId')::uuid;
  v_new:=(v_result->>'newAuthorityPeriodId')::uuid;
  IF (SELECT count(*) FROM public.stock_opening_cutover_items WHERE request_id=v_request)<3 THEN
    RAISE EXCEPTION 'Expected immutable opening line records for imported products';
  END IF;
  IF (SELECT count(*) FROM public.stock_movements m JOIN cutover_fixture_products f USING(product_id)
      WHERE m.authority_period_id=v_previous)<>6 THEN
    RAISE EXCEPTION 'Old rehearsal movements were not preserved';
  END IF;
  FOR v_product IN SELECT p.product_id,p.opening_qty,s.effective_quantity,s.unreconciled_movement_delta,
      s.authority_period_id,s.balance_version
    FROM cutover_fixture_products p JOIN public.stock_balance_projection s USING(product_id)
    ORDER BY p.product_id
  LOOP
    IF v_product.effective_quantity<>v_product.opening_qty OR v_product.unreconciled_movement_delta<>0
      OR v_product.authority_period_id IS DISTINCT FROM v_new OR v_product.balance_version<>3 THEN
      RAISE EXCEPTION 'Opening mismatch for %: %, expected %, delta %, period %, version %',
        v_product.product_id,v_product.effective_quantity,v_product.opening_qty,
        v_product.unreconciled_movement_delta,v_product.authority_period_id,v_product.balance_version;
    END IF;
  END LOOP;
  IF NOT EXISTS(SELECT 1 FROM public.stock_authority_periods WHERE id=v_previous AND ended_at IS NOT NULL)
    OR NOT EXISTS(SELECT 1 FROM public.stock_authority_periods WHERE id=v_new
      AND ended_at IS NULL AND mode='QUENA_MOVEMENT_LEDGER') THEN
    RAISE EXCEPTION 'Old/new period cutover state is invalid';
  END IF;
  IF (SELECT count(*) FROM public.stock_balance_projection_events WHERE opening_cutover_request_id=v_request)
       < (SELECT count(*) FROM public.stock_opening_cutover_items WHERE request_id=v_request)+1
    OR (SELECT count(*) FROM public.stock_opening_cutover_items WHERE request_id=v_request)
       <> (SELECT count(*) FROM public.stock_balance_projection WHERE outlet_id=v_outlet)-1 THEN
    RAISE EXCEPTION 'Expected one iPos opening item per imported projection and a native period-advance event';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.stock_balance_projection p
      JOIN public.stock_native_zero_baselines b ON b.request_id=p.native_zero_baseline_request_id
        AND b.product_id=p.product_id AND b.outlet_id=p.outlet_id
      WHERE p.product_id=current_setting('quena.native_product')::uuid AND p.outlet_id=v_outlet
        AND p.authority_period_id=v_new AND p.baseline_quantity=0
        AND p.unreconciled_movement_delta=0 AND p.effective_quantity=0
        AND p.baseline_source_import_row_id IS NULL AND p.baseline_batch_id IS NULL
        AND p.baseline_commit_id IS NULL AND b.source_system='QUENA_NATIVE'
        AND b.accepted_baseline_quantity=0)
    OR EXISTS(SELECT 1 FROM public.stock_opening_cutover_items i
      WHERE i.request_id=v_request AND i.product_id=current_setting('quena.native_product')::uuid)
    OR EXISTS(SELECT 1 FROM public.ipos_normalization_commit_rows cr
      WHERE cr.commit_id=(SELECT normalization_commit_id FROM public.stock_opening_cutover_requests
        WHERE request_id=v_request) AND cr.product_id=current_setting('quena.native_product')::uuid) THEN
    RAISE EXCEPTION 'Native zero baseline was altered, deleted, or given iPos provenance during cutover';
  END IF;
END $success_assertions$;

-- Same request/payload returns the exact immutable stored result.
SET ROLE authenticated;
SELECT public.stock_opening_cutover(:'outlet_id'::uuid,:'final_commit'::uuid,:'previous_period'::uuid,
  :'request_id'::uuid,'OPENING-STOCK-CUTOVER:'||:'outlet_id'||':'||:'final_commit') AS replay_result
  INTO TEMP TABLE cutover_test_replay;
RESET ROLE;
DO $replay_assertion$
BEGIN
  IF (SELECT result FROM cutover_test_result) IS DISTINCT FROM (SELECT replay_result FROM cutover_test_replay) THEN
    RAISE EXCEPTION 'Same request replay did not return the original result';
  END IF;
END $replay_assertion$;

-- The deployed POS safety gate remains closed after stock cutover but before
-- costing bootstrap/WAC; rejection rolls back checkout request evidence.
SELECT set_config('request.jwt.claim.sub',:'owner_id',false);
RESET ROLE;
DO $pos_pre_wac_gate$
DECLARE o uuid:=current_setting('quena.test.outlet')::uuid;cart_result jsonb;cart_id uuid;message text;failed boolean:=false;
  v_request_id uuid:=gen_random_uuid();product uuid;product_row record;
BEGIN
  SELECT p.id,p.sku,p.name,p.unit_label INTO product_row FROM public.products p WHERE p.sku='CUTOVER-DECIMAL';
  product:=product_row.id;
  cart_result:=public.pos_cart_create(gen_random_uuid());
  cart_id:=(cart_result->>'cart_id')::uuid;
  INSERT INTO public.pos_cart_items(cart_id,outlet_id,product_id,quantity,observed_unit_price,
    observed_price_at,product_sku_snapshot,product_name_snapshot,unit_snapshot)
  VALUES(cart_id,o,product,0.250,500,clock_timestamp(),product_row.sku,product_row.name,product_row.unit_label);
  BEGIN PERFORM public.pos_checkout_complete(v_request_id,cart_id,(cart_result->>'revision')::bigint,'CASH',0,NULL);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS message=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR message<>'POS_COSTING_NOT_ACTIVE'
    OR EXISTS(SELECT 1 FROM public.pos_checkout_requests WHERE pos_checkout_requests.request_id=v_request_id)
    OR EXISTS(SELECT 1 FROM public.sales WHERE outlet_id=o) THEN
    RAISE EXCEPTION 'Checkout was not safely blocked before WAC: %',message; END IF;
  PERFORM public.pos_cart_cancel(cart_id,(cart_result->>'revision')::bigint,gen_random_uuid());
END $pos_pre_wac_gate$;

DO $conflict_assertions$
DECLARE v_outlet uuid;v_commit uuid;v_old_period uuid;v_request uuid;v_message text;
BEGIN
  SELECT outlet_id,normalization_commit_id,expected_previous_period_id,request_id
    INTO v_outlet,v_commit,v_old_period,v_request FROM public.stock_opening_cutover_requests;
  BEGIN
    PERFORM public.stock_opening_cutover(v_outlet,v_commit,gen_random_uuid(),v_request,
      'OPENING-STOCK-CUTOVER:'||v_outlet::text||':'||v_commit::text);
    RAISE EXCEPTION 'Expected same-request payload conflict';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'STOCK_CUTOVER_REQUEST_CONFLICT' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.stock_opening_cutover(v_outlet,v_commit,v_old_period,gen_random_uuid(),
      'OPENING-STOCK-CUTOVER:'||v_outlet::text||':'||v_commit::text);
    RAISE EXCEPTION 'Expected different-request replay rejection';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'STOCK_CUTOVER_ALREADY_COMPLETED' THEN RAISE; END IF;
  END;
  IF (SELECT count(*) FROM public.stock_opening_cutover_requests WHERE outlet_id=v_outlet)<>1 THEN
    RAISE EXCEPTION 'Conflict paths created extra request evidence';
  END IF;
END $conflict_assertions$;

DO $local_costing_cleanliness$
DECLARE v_outlet uuid;
BEGIN
  SELECT id INTO v_outlet FROM public.outlets WHERE code='QUENA-MART-1';
  IF EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE outlet_id=v_outlet)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections WHERE outlet_id=v_outlet)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_event_batches WHERE outlet_id=v_outlet)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_events WHERE outlet_id=v_outlet)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_source_layers WHERE outlet_id=v_outlet)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_hpp_acceptance_batches WHERE outlet_id=v_outlet)
    OR EXISTS(SELECT 1 FROM public.sales WHERE outlet_id=v_outlet) THEN
    RAISE EXCEPTION 'Disposable fixture unexpectedly contains costing/bootstrap/sale evidence';
  END IF;
END $local_costing_cleanliness$;
SELECT set_config('quena.test.outlet', :'outlet_id', false);
SELECT set_config('quena.test.owner', :'owner_id', false);
-- Populate reference HPP and price evidence tied to the final import snapshot.
INSERT INTO public.product_costs(product_id,outlet_id,hpp,source_import_row_id,created_by,updated_by)
SELECT f.product_id,:'outlet_id'::uuid,CASE f.n WHEN 2 THEN 100 ELSE 0 END,s.row_id,:'owner_id'::uuid,:'owner_id'::uuid
FROM cutover_fixture_products f JOIN final_sources s USING(product_id) WHERE f.opening_qty>0;
INSERT INTO public.product_cost_history(product_id,outlet_id,hpp,source_import_row_id,changed_by)
SELECT c.product_id,c.outlet_id,c.hpp,c.source_import_row_id,:'owner_id'::uuid FROM public.product_costs c
JOIN cutover_fixture_products f USING(product_id) WHERE c.outlet_id=:'outlet_id'::uuid;
INSERT INTO public.product_selling_prices(product_id,outlet_id,amount,source_import_row_id,created_by,updated_by)
SELECT f.product_id,:'outlet_id'::uuid,500,s.row_id,:'owner_id'::uuid,:'owner_id'::uuid
FROM cutover_fixture_products f JOIN final_sources s USING(product_id) WHERE f.opening_qty>0;
INSERT INTO public.product_selling_price_history(product_id,outlet_id,amount,source_import_row_id,changed_by)
SELECT sp.product_id,sp.outlet_id,sp.amount,sp.source_import_row_id,:'owner_id'::uuid FROM public.product_selling_prices sp WHERE sp.outlet_id=:'outlet_id'::uuid;
SELECT set_config('request.jwt.claim.sub',:'owner_id',false);
SET ROLE authenticated;
SELECT public.go_live_readiness(:'outlet_id'::uuid) AS readiness_after_cutover \gset
RESET ROLE;
SELECT set_config('quena.test.readiness', :'readiness_after_cutover', false);
DO $readiness_assert$
BEGIN
  IF current_setting('quena.test.readiness')::jsonb->>'stockAuthority'<>'QUENA_MOVEMENT_LEDGER'
    OR current_setting('quena.test.readiness')::jsonb->>'stockCutoverCompleted'<>'true'
    OR current_setting('quena.test.readiness')::jsonb->>'readyForFinalImport'<>'false' THEN RAISE EXCEPTION 'Post-cutover readiness state incorrect'; END IF;
END $readiness_assert$;

-- Explicit PREPARED -> INVALIDATED, immutable reason, and request replay.
SELECT gen_random_uuid()::text prep_one \gset
SET ROLE authenticated;
SELECT public.prepare_initial_hpp_acceptance(:'outlet_id'::uuid,:'prep_one'::uuid) AS prepared_one \gset
SELECT public.go_live_readiness(:'outlet_id'::uuid) AS readiness_with_prepared_hpp \gset
RESET ROLE;
SELECT (:'prepared_one'::jsonb->>'batchId') hpp_one \gset
SELECT set_config('quena.test.hpp_one',:'hpp_one',false);
SELECT set_config('quena.test.readiness_with_prepared_hpp',:'readiness_with_prepared_hpp',false);
DO $prepared_hpp_readiness$
BEGIN
  IF current_setting('quena.test.readiness_with_prepared_hpp')::jsonb->>'readyForFinalImport'<>'false'
    OR current_setting('quena.test.readiness_with_prepared_hpp')::jsonb->>'preparedHppBatchCount'<>'1' THEN
    RAISE EXCEPTION 'Readiness reported final import ready with an active PREPARED HPP batch'; END IF;
END $prepared_hpp_readiness$;
SELECT gen_random_uuid()::text invalidation_one \gset
SELECT set_config('quena.test.invalidation_one',:'invalidation_one',false);
SET ROLE authenticated;
DO $prepared_bootstrap_denial$
DECLARE v_req uuid:=gen_random_uuid();v_message text;v_failed boolean:=false;v_batch uuid:=current_setting('quena.test.hpp_one')::uuid;v_outlet uuid:=current_setting('quena.test.outlet')::uuid;
BEGIN
  BEGIN PERFORM public.inventory_cost_bootstrap_outlet(v_outlet,v_batch,v_req,'COSTING-BOOTSTRAP:'||v_outlet||':'||v_batch||':'||v_req);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;v_failed:=true;END;
  IF NOT v_failed OR v_message<>'GO_LIVE_APPROVED_HPP_REQUIRED' OR EXISTS(SELECT 1 FROM public.go_live_bootstrap_evidence WHERE request_id=v_req) THEN
    RAISE EXCEPTION 'PREPARED HPP was not rejected before bootstrap'; END IF;
END $prepared_bootstrap_denial$;
DO $hpp_invalidate$
DECLARE v_batch uuid:=current_setting('quena.test.hpp_one')::uuid;v_req uuid:=current_setting('quena.test.invalidation_one')::uuid;v_result jsonb;v_replay jsonb;
BEGIN
  v_result:=public.inventory_cost_hpp_invalidate_prepared(v_batch,v_req,'Rehearsal batch replaced');
  v_replay:=public.inventory_cost_hpp_invalidate_prepared(v_batch,v_req,'Rehearsal batch replaced');
  IF v_result->>'code'<>'INVALIDATED' OR v_result IS DISTINCT FROM v_replay
    OR (SELECT status FROM public.inventory_cost_hpp_acceptance_batches WHERE id=v_batch)<>'INVALIDATED'
    OR (SELECT count(*) FROM public.inventory_cost_hpp_acceptance_events WHERE batch_id=v_batch AND event_type='INVALIDATED')<>1 THEN
    RAISE EXCEPTION 'Prepared invalidation/history/replay failed'; END IF;
END $hpp_invalidate$;
RESET ROLE;

-- A changed live HPP invalidates a PREPARED batch; no approval can consume stale evidence.
SELECT gen_random_uuid()::text prep_two \gset
SET ROLE authenticated;
SELECT public.prepare_initial_hpp_acceptance(:'outlet_id'::uuid,:'prep_two'::uuid) AS prepared_two \gset
RESET ROLE;
SELECT (:'prepared_two'::jsonb->>'batchId') hpp_two \gset
SELECT set_config('quena.test.hpp_two',:'hpp_two',false);
UPDATE public.product_costs c SET hpp=101,updated_at=clock_timestamp(),updated_by=:'owner_id'::uuid
FROM cutover_fixture_products f WHERE f.n=2 AND c.product_id=f.product_id AND c.outlet_id=:'outlet_id'::uuid;
SELECT gen_random_uuid()::text stale_approve_request \gset
SELECT set_config('quena.test.stale_approve_request',:'stale_approve_request',false);
SET ROLE authenticated;
SELECT public.approve_initial_hpp_acceptance(:'hpp_two'::uuid,:'stale_approve_request'::uuid) stale_approval \gset
RESET ROLE;
SELECT set_config('quena.test.stale_approval',:'stale_approval',false);
DO $stale_hpp_assert$
BEGIN
  IF current_setting('quena.test.stale_approval')::jsonb->>'code'<>'STALE_BATCH'
    OR (SELECT status FROM public.inventory_cost_hpp_acceptance_batches WHERE id=current_setting('quena.test.hpp_two')::uuid)<>'INVALIDATED' THEN RAISE EXCEPTION 'Stale HPP batch was not invalidated'; END IF;
END $stale_hpp_assert$;
UPDATE public.product_costs c SET hpp=CASE f.n WHEN 2 THEN 100 ELSE 0 END,updated_at=clock_timestamp(),updated_by=:'owner_id'::uuid
FROM cutover_fixture_products f WHERE f.opening_qty>0 AND c.product_id=f.product_id AND c.outlet_id=:'outlet_id'::uuid;
INSERT INTO public.product_cost_history(product_id,outlet_id,hpp,source_import_row_id,changed_by)
SELECT c.product_id,c.outlet_id,c.hpp,c.source_import_row_id,:'owner_id'::uuid FROM public.product_costs c
JOIN cutover_fixture_products f USING(product_id) WHERE c.outlet_id=:'outlet_id'::uuid AND f.opening_qty>0;

-- Final batch, explicit exception dispositions, owner approval.
SELECT gen_random_uuid()::text prep_final \gset
SET ROLE authenticated;
SELECT public.prepare_initial_hpp_acceptance(:'outlet_id'::uuid,:'prep_final'::uuid) prepared_final \gset
RESET ROLE;
SELECT (:'prepared_final'::jsonb->>'batchId') hpp_final \gset
SELECT set_config('quena.test.hpp_final',:'hpp_final',false);
SELECT gen_random_uuid()::text notapproved_request \gset
SELECT set_config('quena.test.notapproved_request',:'notapproved_request',false);
SET ROLE authenticated;
DO $final_prepared_denial$
DECLARE v_request uuid:=current_setting('quena.test.notapproved_request')::uuid;v_batch uuid:=current_setting('quena.test.hpp_final')::uuid;v_outlet uuid:=current_setting('quena.test.outlet')::uuid;v_message text;v_failed boolean:=false;
BEGIN
  BEGIN PERFORM public.inventory_cost_bootstrap_outlet(v_outlet,v_batch,v_request,'COSTING-BOOTSTRAP:'||v_outlet||':'||v_batch||':'||v_request);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;v_failed:=true;END;
  IF NOT v_failed OR v_message<>'GO_LIVE_APPROVED_HPP_REQUIRED' THEN RAISE EXCEPTION 'PREPARED final HPP was bootstrapped'; END IF;
END $final_prepared_denial$;
DO $wrong_outlet_denial$
DECLARE v_batch uuid:=current_setting('quena.test.hpp_final')::uuid;v_outlet uuid;v_req uuid:=gen_random_uuid();v_message text;v_failed boolean:=false;
BEGIN
  SELECT id INTO v_outlet FROM public.outlets WHERE code='CUTOVER-FOREIGN';
  IF v_outlet IS NULL THEN RAISE EXCEPTION 'Wrong outlet fixture missing'; END IF;
  BEGIN PERFORM public.inventory_cost_bootstrap_outlet(v_outlet,v_batch,v_req,'COSTING-BOOTSTRAP:'||v_outlet||':'||v_batch||':'||v_req);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;v_failed:=true;END;
  IF NOT v_failed OR v_message<>'GO_LIVE_APPROVED_HPP_REQUIRED' OR EXISTS(SELECT 1 FROM public.go_live_bootstrap_evidence WHERE request_id=v_req) THEN
    RAISE EXCEPTION 'Cross-outlet bootstrap was not rejected safely'; END IF;
END $wrong_outlet_denial$;
RESET ROLE;
SELECT gen_random_uuid()::text resolve_override \gset
SELECT gen_random_uuid()::text resolve_unvalued \gset
SELECT gen_random_uuid()::text resolve_zero \gset
SELECT gen_random_uuid()::text resolve_zero_two \gset
SET ROLE authenticated;
SELECT public.resolve_initial_hpp_acceptance_exception(:'hpp_final'::uuid,(SELECT product_id FROM cutover_fixture_products WHERE n=3),
  'OPENING_HPP_OVERRIDE',120,'Owner approved explicit opening override',:'resolve_override'::uuid);
SELECT public.resolve_initial_hpp_acceptance_exception(:'hpp_final'::uuid,(SELECT product_id FROM cutover_fixture_products WHERE n=4),
  'LEAVE_UNVALUED',NULL,'Unknown source cost remains unvalued',:'resolve_unvalued'::uuid);
SELECT public.resolve_initial_hpp_acceptance_exception(:'hpp_final'::uuid,(SELECT product_id FROM cutover_fixture_products WHERE n=5),
  'AUTHORITATIVE_ZERO',NULL,'Owner confirmed authoritative zero HPP',:'resolve_zero'::uuid);
SELECT public.resolve_initial_hpp_acceptance_exception(:'hpp_final'::uuid,(SELECT product_id FROM cutover_fixture_products WHERE n=6),
  'AUTHORITATIVE_ZERO',NULL,'Owner confirmed authoritative zero HPP',:'resolve_zero_two'::uuid);
SELECT gen_random_uuid()::text approve_final_request \gset
SELECT public.approve_initial_hpp_acceptance(:'hpp_final'::uuid,:'approve_final_request'::uuid) approved_final \gset
RESET ROLE;
SELECT set_config('quena.test.approved_final',:'approved_final',false);
DO $approved_hpp_assert$
BEGIN
  IF current_setting('quena.test.approved_final')::jsonb->>'code'<>'APPROVED'
    OR (SELECT status FROM public.inventory_cost_hpp_acceptance_batches WHERE id=current_setting('quena.test.hpp_final')::uuid)<>'APPROVED'
    OR (SELECT accepted_opening_hpp FROM public.inventory_cost_hpp_acceptance_items WHERE batch_id=current_setting('quena.test.hpp_final')::uuid AND product_id=(SELECT product_id FROM cutover_fixture_products WHERE n=2))<>100
    OR (SELECT accepted_opening_hpp FROM public.inventory_cost_hpp_acceptance_items WHERE batch_id=current_setting('quena.test.hpp_final')::uuid AND product_id=(SELECT product_id FROM cutover_fixture_products WHERE n=3))<>120 THEN
    RAISE EXCEPTION 'Approved HPP amounts/dispositions did not freeze'; END IF;
END $approved_hpp_assert$;
UPDATE public.product_costs c SET hpp=999,updated_at=clock_timestamp(),updated_by=:'owner_id'::uuid
FROM cutover_fixture_products f WHERE f.n=2 AND c.product_id=f.product_id AND c.outlet_id=:'outlet_id'::uuid;
UPDATE public.product_costs c SET hpp=888,updated_at=clock_timestamp(),updated_by=:'owner_id'::uuid
FROM cutover_fixture_products f WHERE f.n=3 AND c.product_id=f.product_id AND c.outlet_id=:'outlet_id'::uuid;

-- Inject a failure after bootstrap event inserts; the RPC statement must rollback all its effects.
CREATE FUNCTION public.quena_go_live_fail_cost_projection() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION USING MESSAGE='GO_LIVE_TEST_INJECTED_COST_PROJECTION_FAILURE'; END; $$;
CREATE TRIGGER quena_go_live_fail_cost_projection BEFORE INSERT ON public.inventory_cost_projections FOR EACH ROW EXECUTE FUNCTION public.quena_go_live_fail_cost_projection();
SELECT gen_random_uuid()::text bootstrap_request \gset
SELECT set_config('quena.test.bootstrap_request',:'bootstrap_request',false);
SET ROLE authenticated;
DO $bootstrap_failure_rollback$
DECLARE v_outlet uuid:=current_setting('quena.test.outlet')::uuid;v_batch uuid:=current_setting('quena.test.hpp_final')::uuid;v_req uuid:=current_setting('quena.test.bootstrap_request')::uuid;v_message text;v_failed boolean:=false;
BEGIN
  BEGIN PERFORM public.inventory_cost_bootstrap_outlet(v_outlet,v_batch,v_req,'COSTING-BOOTSTRAP:'||v_outlet||':'||v_batch||':'||v_req);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;v_failed:=true;END;
  IF NOT v_failed OR v_message<>'GO_LIVE_TEST_INJECTED_COST_PROJECTION_FAILURE'
    OR EXISTS(SELECT 1 FROM public.go_live_bootstrap_evidence WHERE request_id=v_req)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_event_batches WHERE operation_request_id=v_req)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections WHERE outlet_id=v_outlet)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_hpp_bootstrap_consumptions WHERE acceptance_batch_id=v_batch)
    OR EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE outlet_id=v_outlet)
    OR (SELECT status FROM public.inventory_cost_hpp_acceptance_batches WHERE id=v_batch)<>'APPROVED' THEN RAISE EXCEPTION 'Bootstrap failure did not rollback'; END IF;
END $bootstrap_failure_rollback$;
RESET ROLE;
DROP TRIGGER quena_go_live_fail_cost_projection ON public.inventory_cost_projections;
DROP FUNCTION public.quena_go_live_fail_cost_projection();

-- Retry same request after rollback succeeds, producing BOOTSTRAP_READY only.
SET ROLE authenticated;
SELECT public.inventory_cost_bootstrap_outlet(:'outlet_id'::uuid,:'hpp_final'::uuid,:'bootstrap_request'::uuid,
  'COSTING-BOOTSTRAP:'||:'outlet_id'||':'||:'hpp_final'||':'||:'bootstrap_request') bootstrap_result \gset
SELECT public.inventory_cost_bootstrap_outlet(:'outlet_id'::uuid,:'hpp_final'::uuid,:'bootstrap_request'::uuid,
  'COSTING-BOOTSTRAP:'||:'outlet_id'||':'||:'hpp_final'||':'||:'bootstrap_request') bootstrap_replay \gset
RESET ROLE;
SELECT set_config('quena.test.bootstrap_result',:'bootstrap_result',false);
SELECT set_config('quena.test.bootstrap_replay',:'bootstrap_replay',false);
DO $bootstrap_assertions$
DECLARE v_outlet uuid:=current_setting('quena.test.outlet')::uuid;v_batch uuid:=current_setting('quena.test.hpp_final')::uuid;v_result jsonb:=current_setting('quena.test.bootstrap_result')::jsonb;
BEGIN
  IF v_result->>'authorityStatus'<>'BOOTSTRAP_READY' OR v_result->>'inventoryValue' IS NOT NULL
    OR (v_result->>'knownValuedInventoryValue')::numeric<>620 OR (v_result->>'valuedQuantity')::numeric<>9.875
    OR (v_result->>'unvaluedQuantity')::numeric<>2.5 OR (v_result->>'provisionalQuantity')::numeric<>0
    OR (SELECT status FROM public.inventory_costing_outlet_authority WHERE outlet_id=v_outlet)<>'BOOTSTRAP_READY'
    OR (SELECT status FROM public.inventory_cost_hpp_acceptance_batches WHERE id=v_batch)<>'CONSUMED'
    OR current_setting('quena.test.bootstrap_result')::jsonb IS DISTINCT FROM current_setting('quena.test.bootstrap_replay')::jsonb
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=(SELECT product_id FROM cutover_fixture_products WHERE n=1)
      AND (physical_quantity<>0 OR valued_quantity<>0 OR inventory_value<>0)) THEN RAISE EXCEPTION 'Bootstrap aggregate/zero semantics failed: %',v_result; END IF;
  IF (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=(SELECT product_id FROM cutover_fixture_products WHERE n=2))<>125
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=(SELECT product_id FROM cutover_fixture_products WHERE n=3))<>495
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=(SELECT product_id FROM cutover_fixture_products WHERE n=4)) IS NOT NULL
    OR (SELECT unvalued_quantity FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=(SELECT product_id FROM cutover_fixture_products WHERE n=4))<>2.5
    OR (SELECT valued_quantity FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=(SELECT product_id FROM cutover_fixture_products WHERE n=5))<>3
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=(SELECT product_id FROM cutover_fixture_products WHERE n=5))<>0
    OR (SELECT valued_quantity FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=(SELECT product_id FROM cutover_fixture_products WHERE n=6))<>1.5
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=v_outlet AND product_id=(SELECT product_id FROM cutover_fixture_products WHERE n=6))<>0 THEN
    RAISE EXCEPTION 'Per-product frozen, override, unvalued or authoritative-zero behavior failed'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.inventory_cost_events e WHERE e.outlet_id=v_outlet AND e.product_id=(SELECT product_id FROM cutover_fixture_products WHERE n=2)
      AND e.opening_hpp_acceptance_batch_id=v_batch AND e.opening_hpp_disposition='ACCEPT_CURRENT_HPP' AND e.frozen_unit_cost=100)
    OR NOT EXISTS(SELECT 1 FROM public.inventory_cost_events e WHERE e.outlet_id=v_outlet AND e.product_id=(SELECT product_id FROM cutover_fixture_products WHERE n=3)
      AND e.opening_hpp_acceptance_batch_id=v_batch AND e.opening_hpp_disposition='OPENING_HPP_OVERRIDE' AND e.frozen_unit_cost=120)
    OR NOT EXISTS(SELECT 1 FROM public.inventory_cost_events e WHERE e.outlet_id=v_outlet AND e.product_id=(SELECT product_id FROM cutover_fixture_products WHERE n=4)
      AND e.opening_hpp_acceptance_batch_id=v_batch AND e.opening_hpp_disposition='LEAVE_UNVALUED' AND e.frozen_unit_cost IS NULL)
    OR (SELECT count(*) FROM public.inventory_cost_source_layers WHERE outlet_id=v_outlet)<>(SELECT count(*) FROM public.stock_balance_projection WHERE outlet_id=v_outlet) THEN
    RAISE EXCEPTION 'Bootstrap event/disposition/source-layer evidence mismatch'; END IF;
END $bootstrap_assertions$;
SELECT gen_random_uuid()::text second_bootstrap_request \gset
SELECT set_config('quena.test.second_bootstrap_request',:'second_bootstrap_request',false);
SET ROLE authenticated;
DO $second_bootstrap_guard$
DECLARE v_outlet uuid:=current_setting('quena.test.outlet')::uuid;v_batch uuid:=current_setting('quena.test.hpp_final')::uuid;v_req uuid:=current_setting('quena.test.second_bootstrap_request')::uuid;v_message text;v_failed boolean:=false;
BEGIN
  BEGIN PERFORM public.inventory_cost_bootstrap_outlet(v_outlet,v_batch,v_req,'COSTING-BOOTSTRAP:'||v_outlet||':'||v_batch||':'||v_req);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;v_failed:=true;END;
  IF NOT v_failed OR v_message<>'GO_LIVE_APPROVED_HPP_REQUIRED' OR (SELECT count(*) FROM public.go_live_bootstrap_evidence WHERE outlet_id=v_outlet)<>1 THEN
    RAISE EXCEPTION 'Second bootstrap was not rejected'; END IF;
END $second_bootstrap_guard$;
RESET ROLE;
SELECT 'BOOTSTRAP_READY' AS go_live_lifecycle_state;
