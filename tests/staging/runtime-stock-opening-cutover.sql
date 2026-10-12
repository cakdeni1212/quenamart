\set ON_ERROR_STOP on
\timing on

-- Disposable PostgreSQL 15 only. The shell wrapper pins localhost, port 55439,
-- database name, and the installed candidate migration before invoking this.
DO $guard$
BEGIN
  IF NOT ((current_database()='quena_stock_cutover_clean' AND inet_server_port()=55439)
      OR (current_database() LIKE 'quena_native_product_%' AND inet_server_port()=55432))
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR current_setting('server_version_num')::integer/10000<>15
    OR to_regprocedure('public.stock_opening_cutover(uuid,uuid,uuid,uuid,text)') IS NULL
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
  'Native','pcs',NULL,NULL,NULL,9000)->>'product_id')::uuid AS native_product_id \gset
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
  'cutover-test/previous.xlsx','Products',1,2,3,3,'[]',:'owner_id'::uuid,'UPLOADED',NULL,NULL,
  :'previous_import_request'::uuid),
 (:'final_batch'::uuid,:'outlet_id'::uuid,'final.xlsx','quena-ipos-imports',
  'cutover-test/final.xlsx','Products',1,2,3,3,'[]',:'owner_id'::uuid,'UPLOADED',NULL,NULL,
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
  now()-interval '2 days',now()-interval '2 days',3,3,0,'{}',md5('previous'),'{}'),
 (:'final_commit'::uuid,:'final_batch'::uuid,:'outlet_id'::uuid,'ipos-v1-preflight','COMPLETED',
  now()-interval '1 day',now()-interval '1 day',3,3,0,'{}',md5('final'),'{}');

CREATE TEMP TABLE cutover_fixture_products(n integer PRIMARY KEY,product_id uuid UNIQUE,
  sku text UNIQUE,old_qty numeric,old_delta numeric,opening_qty numeric) ON COMMIT PRESERVE ROWS;
INSERT INTO cutover_fixture_products VALUES
 (1,gen_random_uuid(),'CUTOVER-ZERO',10,3,0),
 (2,gen_random_uuid(),'CUTOVER-DECIMAL',3.125,-0.125,1.250),
 (3,gen_random_uuid(),'CUTOVER-MULTI',0,2,4.125);
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
ALTER TABLE public.ipos_import_rows ENABLE TRIGGER ipos_import_rows_processing_only;

INSERT INTO public.ipos_normalization_commit_rows(commit_id,batch_id,outlet_id,source_row_id,
  source_row_number,action,sku,expected_product_id,product_id,normalized_data,finding_codes,validation_errors,override_conflicts)
SELECT :'previous_commit'::uuid,:'previous_batch'::uuid,:'outlet_id'::uuid,s.row_id,2+p.n,'UPDATE',p.sku,
  p.product_id,p.product_id,jsonb_build_object('quantity',p.old_qty),'{}','[]','{}'
FROM cutover_fixture_products p JOIN previous_sources s USING(product_id) ORDER BY p.n;
INSERT INTO public.ipos_normalization_commit_rows(commit_id,batch_id,outlet_id,source_row_id,
  source_row_number,action,sku,expected_product_id,product_id,normalized_data,finding_codes,validation_errors,override_conflicts)
SELECT :'final_commit'::uuid,:'final_batch'::uuid,:'outlet_id'::uuid,s.row_id,2+p.n,'UPDATE',p.sku,
  p.product_id,p.product_id,jsonb_build_object('quantity',p.opening_qty),'{}','[]','{}'
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
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
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
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
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
      WHERE m.authority_period_id=v_previous)<>3 THEN
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

-- Future ordinary balance deltas begin from accepted opening quantity.
SELECT product_id FROM cutover_fixture_products WHERE sku='CUTOVER-DECIMAL' \gset
SELECT * INTO TEMP TABLE cutover_delta_result FROM public.stock_apply_balance_delta(
  :'product_id'::uuid,:'outlet_id'::uuid,-0.250);
DO $future_movement_assertion$
DECLARE v_before numeric;v_after numeric;
BEGIN
  SELECT balance_before,balance_after INTO v_before,v_after FROM cutover_delta_result;
  IF v_before<>1.250 OR v_after<>1.000 THEN
    RAISE EXCEPTION 'Post-cutover movement did not start from accepted stock: % -> %',v_before,v_after;
  END IF;
END $future_movement_assertion$;

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
