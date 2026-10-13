\set ON_ERROR_STOP on
BEGIN;
SET LOCAL statement_timeout='90s';
SET LOCAL lock_timeout='10s';
DO $guard$
BEGIN
  IF current_database()<>'quena_stock_staging'
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR inet_server_port()<>55441
    OR current_setting('server_version_num')::integer/10000<>15
    OR NOT EXISTS(SELECT 1 FROM quena_staging.environment WHERE name='quena_stock_staging')
    OR to_regprocedure('public.supplier_workspace_page(text,text,text,integer,integer)') IS NULL
    OR to_regprocedure('public.supplier_workspace_detail(uuid,integer,integer)') IS NULL THEN
    RAISE EXCEPTION 'Refusing supplier runtime test outside guarded disposable PostgreSQL 15 staging';
  END IF;
END $guard$;

SELECT id outlet_id FROM public.outlets WHERE code='QUENA-MART-1' AND is_active \gset
SELECT id product_id FROM public.products WHERE sku='CUTOVER-DECIMAL' \gset
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT public.supplier_workspace_upsert(NULL,'Supplier Workspace Runtime A','Contact A','081234567890',
  'Alamat staging','Runtime validation fixture',true) supplier_id \gset
SELECT public.supplier_workspace_upsert(:'supplier_id'::uuid,'Supplier Workspace Runtime A Edited','Contact A','081234567890',
  'Alamat staging','Runtime validation fixture',true) owner_edit \gset
SELECT set_config('quena.supplier_id',:'supplier_id',true);
SELECT public.supplier_workspace_page('Runtime A Edited','','',1,100) name_search \gset
SELECT public.supplier_workspace_page('Contact A','','',1,20) contact_search \gset
SELECT public.supplier_workspace_page('081234567890','','',1,20) phone_search \gset
SELECT public.supplier_workspace_page('NO-SUCH-SUPPLIER','','',1,20) empty_search \gset
SELECT set_config('quena.name_search',:'name_search',true);
SELECT set_config('quena.contact_search',:'contact_search',true);
SELECT set_config('quena.phone_search',:'phone_search',true);
SELECT set_config('quena.empty_search',:'empty_search',true);
RESET ROLE;

-- Post a real receiving operation through the existing GUDANG contracts.
SELECT id gudang_user FROM public.profiles WHERE role='GUDANG' AND is_active ORDER BY id LIMIT 1 \gset
SELECT set_config('request.jwt.claim.sub',:'gudang_user',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),'Supplier workspace staging receipt') receipt_id \gset
SELECT public.purchase_receipt_save_draft(:'receipt_id'::uuid,1,now(),NULL,
  jsonb_build_array(jsonb_build_object('product_id',:'product_id','accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0))) \gset
SELECT public.issue_purchase_receipt_post_intent(:'receipt_id'::uuid) receipt_request \gset
SELECT public.apply_purchase_receipt_post_intent(:'receipt_request'::uuid) \gset
SELECT set_config('quena.receipt_id',:'receipt_id',true);
RESET ROLE;

-- Finalize a payable linked to the posted receipt and apply a partial payment.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT gen_random_uuid() invoice_create_request \gset
SELECT public.purchase_invoice_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,:'invoice_create_request'::uuid) invoice_id \gset
SELECT public.purchase_invoice_link_receipt(:'invoice_id'::uuid,:'receipt_id'::uuid,true) \gset
SELECT public.purchase_invoice_save_draft(:'invoice_id'::uuid,1,'SUPPLIER-STAGE-001',current_date,current_date+14,'TEMPO',100,
  jsonb_build_array(jsonb_build_object('product_id',:'product_id','invoice_quantity',1,'purchase_unit_price',100))) \gset
SELECT gen_random_uuid() finalize_request \gset
SELECT public.purchase_invoice_finalize(:'invoice_id'::uuid,:'finalize_request'::uuid,2,0,NULL,NULL,NULL) finalized \gset
SELECT (:'finalized'::jsonb->>'payableId') payable_id \gset
SELECT gen_random_uuid() partial_payment_request \gset
SELECT public.purchase_record_supplier_payment(:'partial_payment_request'::uuid,:'supplier_id'::uuid,:'outlet_id'::uuid,current_date,40,
  'TRANSFER','Supplier workspace partial payment',jsonb_build_array(jsonb_build_object('payable_id',:'payable_id','amount',40))) \gset
SELECT public.supplier_workspace_page('Supplier Workspace Runtime A Edited','ACTIVE','HAS_TEMPO',1,20) active_tempo \gset
SELECT public.supplier_workspace_page('Supplier Workspace Runtime A Edited','ACTIVE','NO_TEMPO',1,20) no_tempo \gset
SELECT public.supplier_workspace_page('Supplier Workspace Runtime A Edited','','',1,100) page_bound \gset
SELECT public.supplier_workspace_detail(:'supplier_id'::uuid,1,20) partial_detail \gset
SELECT set_config('quena.invoice_id',:'invoice_id',true);
SELECT set_config('quena.payable_id',:'payable_id',true);
SELECT set_config('quena.active_tempo',:'active_tempo',true);
SELECT set_config('quena.no_tempo',:'no_tempo',true);
SELECT set_config('quena.page_bound',:'page_bound',true);
SELECT set_config('quena.partial_detail',:'partial_detail',true);
DO $partial_assertions$
DECLARE p jsonb:=current_setting('quena.active_tempo')::jsonb; d jsonb:=current_setting('quena.partial_detail')::jsonb;
  v_supplier uuid:=current_setting('quena.supplier_id')::uuid; v_invoice uuid:=current_setting('quena.invoice_id')::uuid;
  v_receipt uuid:=current_setting('quena.receipt_id')::uuid;
BEGIN
  IF (p->>'total')::integer<>1 OR (p->>'financialAccess')::boolean IS DISTINCT FROM true
    OR (p#>>'{rows,0,outstanding}')::numeric<>60 OR (p#>>'{rows,0,open_count}')::integer<>1
    OR (current_setting('quena.no_tempo')::jsonb->>'total')::integer<>0 THEN
    RAISE EXCEPTION 'Supplier list partial-payable filter/amount mismatch: %',p; END IF;
  IF d#>>'{supplier,id}'<>v_supplier::text OR (d->>'purchaseCount')::integer<>1
    OR (d#>>'{summary,totalPurchases}')::numeric<>100 OR (d#>>'{summary,outstanding}')::numeric<>60
    OR (d#>>'{summary,openInvoices}')::integer<>1 OR (d#>>'{purchases,0,total}')::numeric<>100
    OR (d#>>'{purchases,0,paid}')::numeric<>40 OR (d#>>'{purchases,0,outstanding}')::numeric<>60
    OR jsonb_array_length(d#>'{purchases,0,receipts}')<>1 OR d#>>'{purchases,0,receipts,0,id}'<>v_receipt::text
    THEN RAISE EXCEPTION 'Supplier detail/receipt-invoice de-duplication mismatch: %',d; END IF;
  IF (SELECT count(*) FROM public.purchase_invoices WHERE id=v_invoice AND status='FINALIZED')<>1
    OR (SELECT count(*) FROM public.purchase_invoice_receipts WHERE invoice_id=v_invoice AND receipt_id=v_receipt)<>1
    OR (SELECT count(*) FROM public.supplier_payables WHERE invoice_id=v_invoice)<>1
    OR (current_setting('quena.page_bound')::jsonb->>'pageSize')::integer<>30
    OR (current_setting('quena.empty_search')::jsonb->>'total')::integer<>0
    OR (current_setting('quena.contact_search')::jsonb->>'total')::integer<>1
    OR (current_setting('quena.phone_search')::jsonb->>'total')::integer<>1
    OR (current_setting('quena.name_search')::jsonb->>'total')::integer<>1 THEN
    RAISE EXCEPTION 'Supplier read/search/page bounds or valid purchase evidence mismatch'; END IF;
END $partial_assertions$;

-- A draft supplier invoice must not change the finalized payable summary.
SELECT gen_random_uuid() draft_create_request \gset
SELECT public.purchase_invoice_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,:'draft_create_request'::uuid) \gset
SELECT public.supplier_workspace_page('Supplier Workspace Runtime A Edited','ACTIVE','HAS_TEMPO',1,20) with_draft \gset
SELECT set_config('quena.with_draft',:'with_draft',true);
DO $draft_assertion$
BEGIN
  IF (current_setting('quena.with_draft')::jsonb->>'total')::integer<>1
    OR (current_setting('quena.with_draft')::jsonb#>>'{rows,0,outstanding}')::numeric<>60
    THEN RAISE EXCEPTION 'Draft invoice changed payable summary'; END IF;
END $draft_assertion$;

-- Finish payment and prove exact reconciliation to zero outstanding.
SELECT gen_random_uuid() final_payment_request \gset
SELECT public.purchase_record_supplier_payment(:'final_payment_request'::uuid,:'supplier_id'::uuid,:'outlet_id'::uuid,current_date,60,
  'TRANSFER','Supplier workspace final payment',jsonb_build_array(jsonb_build_object('payable_id',:'payable_id','amount',60))) \gset
SELECT public.supplier_workspace_detail(:'supplier_id'::uuid,1,20) paid_detail \gset
SELECT public.supplier_workspace_page('Supplier Workspace Runtime A Edited','ACTIVE','HAS_TEMPO',1,20) paid_tempo \gset
SELECT public.supplier_workspace_page('Supplier Workspace Runtime A Edited','ACTIVE','NO_TEMPO',1,20) paid_no_tempo \gset
SELECT set_config('quena.paid_detail',:'paid_detail',true);
SELECT set_config('quena.paid_tempo',:'paid_tempo',true);
SELECT set_config('quena.paid_no_tempo',:'paid_no_tempo',true);
DO $paid_assertion$
BEGIN
  IF (current_setting('quena.paid_detail')::jsonb#>>'{summary,totalPurchases}')::numeric<>100
    OR (current_setting('quena.paid_detail')::jsonb#>>'{summary,outstanding}')::numeric<>0
    OR (current_setting('quena.paid_detail')::jsonb#>>'{summary,openInvoices}')::integer<>0
    OR (current_setting('quena.paid_detail')::jsonb#>>'{purchases,0,paid}')::numeric<>100
    OR (current_setting('quena.paid_detail')::jsonb#>>'{purchases,0,outstanding}')::numeric<>0
    OR (current_setting('quena.paid_tempo')::jsonb->>'total')::integer<>0
    OR (current_setting('quena.paid_no_tempo')::jsonb->>'total')::integer<>1
    THEN RAISE EXCEPTION 'Final payment did not reconcile: %',current_setting('quena.paid_detail')::jsonb; END IF;
END $paid_assertion$;

-- Deactivation keeps history, removes the supplier from receipt creation, and can be reversed.
SELECT public.supplier_workspace_upsert(:'supplier_id'::uuid,'Supplier Workspace Runtime A Edited','Contact A','081234567890',
  'Alamat staging','Runtime validation fixture',false) \gset
SELECT public.supplier_workspace_page('Supplier Workspace Runtime A Edited','INACTIVE','',1,20) inactive_page \gset
SELECT public.supplier_workspace_detail(:'supplier_id'::uuid,1,20) inactive_detail \gset
SELECT set_config('quena.inactive_page',:'inactive_page',true);
SELECT set_config('quena.inactive_detail',:'inactive_detail',true);
DO $inactive_assertion$
DECLARE denied boolean:=false; msg text;
BEGIN
  IF (current_setting('quena.inactive_page')::jsonb->>'total')::integer<>1
    OR (current_setting('quena.inactive_page')::jsonb#>>'{rows,0,is_active}')::boolean
    OR (current_setting('quena.inactive_detail')::jsonb#>>'{supplier,is_active}')::boolean
    OR (current_setting('quena.inactive_detail')::jsonb->>'purchaseCount')::integer<>1
    OR (current_setting('quena.inactive_detail')::jsonb#>>'{summary,outstanding}')::numeric<>0
    OR (SELECT count(*) FROM public.purchase_receipts WHERE id=current_setting('quena.receipt_id')::uuid AND status='POSTED')<>1
    OR (SELECT count(*) FROM public.purchase_invoices WHERE id=current_setting('quena.invoice_id')::uuid AND status='FINALIZED')<>1
    OR (SELECT count(*) FROM public.supplier_payment_allocations WHERE payable_id=current_setting('quena.payable_id')::uuid)<>2 THEN
    RAISE EXCEPTION 'Deactivation hid/deleted historical evidence'; END IF;
  BEGIN PERFORM public.purchase_receipt_create_draft(
    (SELECT id FROM public.outlets WHERE code='QUENA-MART-1'),current_setting('quena.supplier_id')::uuid,now(),'Must reject inactive supplier');
  EXCEPTION WHEN SQLSTATE '22023' THEN denied:=true; GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT; END;
  IF NOT denied OR msg<>'Receipt header is invalid' THEN RAISE EXCEPTION 'Inactive supplier was selectable for new receipt'; END IF;
END $inactive_assertion$;
SELECT public.supplier_workspace_upsert(:'supplier_id'::uuid,'Supplier Workspace Runtime A Edited','Contact A','081234567890',
  'Alamat staging','Runtime validation fixture',true) \gset

RESET ROLE;
SELECT set_config('request.jwt.claim.sub',:'gudang_user',true);
SET LOCAL ROLE authenticated;
SELECT public.supplier_workspace_page('Supplier Workspace Runtime A Edited','','',1,20) gudang_page \gset
SELECT set_config('quena.gudang_page',:'gudang_page',true);
DO $gudang_assertion$
DECLARE denied boolean:=false;
BEGIN
  IF (current_setting('quena.gudang_page')::jsonb->>'financialAccess')::boolean IS DISTINCT FROM false
    OR (current_setting('quena.gudang_page')::jsonb#>'{rows,0}') ?| ARRAY['open_count','outstanding','nearest_due','last_purchase']
    OR (current_setting('quena.gudang_page')::jsonb#>>'{rows,0,display_name}')<>'Supplier Workspace Runtime A Edited'
    THEN RAISE EXCEPTION 'GUDANG supplier lookup leaked financial data or failed'; END IF;
  BEGIN PERFORM public.supplier_workspace_detail(current_setting('quena.supplier_id')::uuid,1,20);
    EXCEPTION WHEN SQLSTATE '42501' THEN denied:=true; END;
  IF NOT denied THEN RAISE EXCEPTION 'GUDANG financial detail was allowed'; END IF;
  denied:=false;
  BEGIN PERFORM public.supplier_workspace_upsert(current_setting('quena.supplier_id')::uuid,'Privilege Escalation',NULL,NULL,NULL,NULL,true);
    EXCEPTION WHEN SQLSTATE '42501' THEN denied:=true; END;
  IF NOT denied THEN RAISE EXCEPTION 'GUDANG mutation was allowed'; END IF;
END $gudang_assertion$;
RESET ROLE;

SELECT id admin_user FROM public.profiles WHERE role='ADMIN' AND is_active ORDER BY id LIMIT 1 \gset
SELECT set_config('request.jwt.claim.sub',:'admin_user',true);
SET LOCAL ROLE authenticated;
SELECT public.supplier_workspace_detail(:'supplier_id'::uuid,1,20) admin_detail \gset
SELECT public.supplier_workspace_upsert(NULL,'Supplier Workspace Runtime Admin','Admin Contact','081234567891',NULL,NULL,true) admin_created \gset
SELECT public.supplier_workspace_upsert(:'supplier_id'::uuid,'Supplier Workspace Runtime A Admin Edit','Contact A','081234567890',
  'Alamat staging','Runtime validation fixture',true) \gset
SELECT set_config('quena.admin_detail',:'admin_detail',true);
SELECT set_config('quena.admin_created',:'admin_created',true);
DO $admin_assertion$
BEGIN
  IF (current_setting('quena.admin_detail')::jsonb->>'purchaseCount')::integer<>1
    OR (SELECT count(*) FROM public.suppliers WHERE id=current_setting('quena.admin_created')::uuid AND is_active)<>1
    OR (SELECT display_name FROM public.suppliers WHERE id=current_setting('quena.supplier_id')::uuid)<>'Supplier Workspace Runtime A Admin Edit'
    THEN RAISE EXCEPTION 'ADMIN expected supplier list/detail/create/edit permission'; END IF;
END $admin_assertion$;
RESET ROLE;

SELECT id kasir_user FROM public.profiles WHERE role='KASIR' AND is_active ORDER BY id LIMIT 1 \gset
SELECT set_config('request.jwt.claim.sub',:'kasir_user',true);
SET LOCAL ROLE authenticated;
DO $kasir_assertion$
DECLARE denied boolean:=false;
BEGIN
  BEGIN PERFORM public.supplier_workspace_page('','','',1,20); EXCEPTION WHEN SQLSTATE '42501' THEN denied:=true; END;
  IF NOT denied THEN RAISE EXCEPTION 'KASIR supplier list was allowed'; END IF;
  denied:=false;
  BEGIN PERFORM public.supplier_workspace_detail(current_setting('quena.supplier_id')::uuid,1,20); EXCEPTION WHEN SQLSTATE '42501' THEN denied:=true; END;
  IF NOT denied THEN RAISE EXCEPTION 'KASIR supplier detail was allowed'; END IF;
  denied:=false;
  BEGIN PERFORM public.supplier_workspace_upsert(NULL,'KASIR Injection',NULL,NULL,NULL,NULL,true); EXCEPTION WHEN SQLSTATE '42501' THEN denied:=true; END;
  IF NOT denied THEN RAISE EXCEPTION 'KASIR supplier mutation was allowed'; END IF;
END $kasir_assertion$;
RESET ROLE;

-- Controlled error proves the supplier creation transaction leaves no partial row.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
DO $rollback_assertion$
DECLARE failed boolean:=false;
BEGIN
  BEGIN
    PERFORM public.supplier_workspace_upsert(NULL,'Supplier Workspace Rollback Only',NULL,NULL,NULL,NULL,true);
    RAISE EXCEPTION 'INJECTED_SUPPLIER_FAILURE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='INJECTED_SUPPLIER_FAILURE' THEN failed:=true; ELSE RAISE; END IF;
  END;
  IF NOT failed OR EXISTS(SELECT 1 FROM public.suppliers WHERE display_name='Supplier Workspace Rollback Only')
    THEN RAISE EXCEPTION 'Supplier rollback injection failed'; END IF;
END $rollback_assertion$;
RESET ROLE;
ROLLBACK;
\echo 'PASS: Supplier Workspace PostgreSQL runtime assertions passed; fixture transaction rolled back'
