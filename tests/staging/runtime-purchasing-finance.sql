\set ON_ERROR_STOP on
\timing on
DO $guard$
BEGIN
  IF current_database()<>'quena_stock_staging' OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1') OR inet_server_port()<>5432
    OR current_setting('server_version_num')::integer/10000<>15 OR NOT EXISTS(SELECT 1 FROM quena_staging.environment WHERE name='quena_stock_staging')
    OR NOT EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929230000') THEN
    RAISE EXCEPTION 'Refusing purchasing finance matrix outside guarded local staging';
  END IF;
END $guard$;
BEGIN;
SET LOCAL statement_timeout='90s';
SET LOCAL lock_timeout='10s';
SELECT id outlet_id FROM public.outlets WHERE code='QUENA-MART-1' AND is_active \gset
SELECT id product_a FROM public.products WHERE sku='STG-FULL-A' \gset
SELECT id product_b FROM public.products WHERE sku='STG-FULL-B' \gset
SELECT effective_quantity stock_before,balance_version version_before FROM public.stock_balance_projection WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_a'::uuid \gset
SELECT quantity inventory_before FROM public.product_inventory WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_a'::uuid \gset
SELECT set_config('quena.test_outlet_id',:'outlet_id',true);
SELECT set_config('quena.test_product_a',:'product_a',true);
SELECT set_config('quena.test_product_b',:'product_b',true);
SELECT set_config('quena.test_stock_before',:'stock_before',true);
SELECT set_config('quena.test_version_before',:'version_before',true);
SELECT set_config('quena.test_inventory_before',:'inventory_before',true);

-- Owner creates a Tempo invoice, records an initial partial payment, then applies an exact retry.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_supplier_upsert(NULL,'Purchasing Finance Stage Supplier',NULL,'0812000000','Finance Matrix',true) supplier_id \gset
SELECT gen_random_uuid() request_create \gset
SELECT public.purchase_invoice_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,:'request_create'::uuid) invoice_id \gset
SELECT public.purchase_invoice_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,:'request_create'::uuid) replay_invoice_id \gset
SELECT public.purchase_invoice_save_draft(:'invoice_id'::uuid,1,'STG-TEMPO-01',current_date,current_date+30,'TEMPO',360,
  jsonb_build_array(jsonb_build_object('product_id',:'product_a','invoice_quantity',2.5,'purchase_unit_price',120),jsonb_build_object('product_id',:'product_b','invoice_quantity',1,'purchase_unit_price',50))) save_result \gset
SELECT gen_random_uuid() request_finalize \gset
SELECT public.purchase_invoice_finalize(:'invoice_id'::uuid,:'request_finalize'::uuid,2,100,'TRANSFER',current_date,'Bayar awal') finalize_result \gset
SELECT public.purchase_invoice_finalize(:'invoice_id'::uuid,:'request_finalize'::uuid,2,100,'TRANSFER',current_date,'Bayar awal') finalize_replay \gset
SELECT (:'finalize_result'::jsonb->>'payableId') payable_id \gset
SELECT public.purchase_invoice_financial_detail(:'invoice_id'::uuid) partial_detail \gset
SELECT gen_random_uuid() request_payment \gset
SELECT public.purchase_record_supplier_payment(:'request_payment'::uuid,:'supplier_id'::uuid,:'outlet_id'::uuid,current_date,260,'TRANSFER','Pelunasan',
  jsonb_build_array(jsonb_build_object('payable_id',:'payable_id','amount',260))) payment_result \gset
SELECT public.purchase_record_supplier_payment(:'request_payment'::uuid,:'supplier_id'::uuid,:'outlet_id'::uuid,current_date,260,'TRANSFER','Pelunasan',
  jsonb_build_array(jsonb_build_object('payable_id',:'payable_id','amount',260))) payment_replay \gset
SELECT set_config('quena.finance_invoice',:'invoice_id',true);
SELECT set_config('quena.test_supplier_id',:'supplier_id',true);
SELECT set_config('quena.finance_payable',:'payable_id',true);
SELECT set_config('quena.finance_finalize',:'finalize_result',true);
SELECT set_config('quena.finance_finalize_replay',:'finalize_replay',true);
SELECT set_config('quena.finance_partial_detail',:'partial_detail',true);
SELECT set_config('quena.finance_payment',:'payment_result',true);
SELECT set_config('quena.finance_payment_replay',:'payment_replay',true);
RESET ROLE;

-- A second invoice exercises due-soon, unpaid and overdue derived statuses.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
SET LOCAL ROLE authenticated;
SELECT gen_random_uuid() due_create_req \gset
SELECT public.purchase_invoice_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,:'due_create_req'::uuid) due_invoice \gset
SELECT public.purchase_invoice_save_draft(:'due_invoice'::uuid,1,'STG-DUE-01',current_date,current_date+5,'TEMPO',90,
 jsonb_build_array(jsonb_build_object('product_id',:'product_a','invoice_quantity',1,'purchase_unit_price',80))) \gset
SELECT gen_random_uuid() due_finalize_req \gset
SELECT public.purchase_invoice_finalize(:'due_invoice'::uuid,:'due_finalize_req'::uuid,2,0,NULL,NULL,NULL) due_finalize_result \gset
SELECT gen_random_uuid() overdue_create_req \gset
SELECT public.purchase_invoice_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,:'overdue_create_req'::uuid) overdue_invoice \gset
SELECT public.purchase_invoice_save_draft(:'overdue_invoice'::uuid,1,'STG-OVERDUE-01',current_date,current_date-1,'TEMPO',75,
 jsonb_build_array(jsonb_build_object('product_id',:'product_b','invoice_quantity',1,'purchase_unit_price',75))) \gset
SELECT gen_random_uuid() overdue_finalize_req \gset
SELECT public.purchase_invoice_finalize(:'overdue_invoice'::uuid,:'overdue_finalize_req'::uuid,2,0,NULL,NULL,NULL) overdue_finalize_result \gset
SELECT gen_random_uuid() unpaid_create_req \gset
SELECT public.purchase_invoice_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,:'unpaid_create_req'::uuid) unpaid_invoice \gset
SELECT public.purchase_invoice_save_draft(:'unpaid_invoice'::uuid,1,'STG-UNPAID-01',current_date,current_date+20,'TEMPO',65,
 jsonb_build_array(jsonb_build_object('product_id',:'product_b','invoice_quantity',1,'purchase_unit_price',65))) \gset
SELECT gen_random_uuid() unpaid_finalize_req \gset
SELECT public.purchase_invoice_finalize(:'unpaid_invoice'::uuid,:'unpaid_finalize_req'::uuid,2,0,NULL,NULL,NULL) unpaid_finalize_result \gset
SELECT set_config('quena.finance_due_invoice',:'due_invoice',true);
SELECT set_config('quena.finance_overdue_invoice',:'overdue_invoice',true);
SELECT set_config('quena.finance_unpaid_invoice',:'unpaid_invoice',true);
RESET ROLE;

DO $manager_assertions$
DECLARE v_detail jsonb; v_count bigint; v_before numeric; v_inventory numeric;
BEGIN
  IF current_setting('quena.finance_finalize')::jsonb IS DISTINCT FROM current_setting('quena.finance_finalize_replay')::jsonb
    OR current_setting('quena.finance_payment')::jsonb IS DISTINCT FROM current_setting('quena.finance_payment_replay')::jsonb
    OR current_setting('quena.finance_finalize')::jsonb->>'code'<>'FINALIZED'
    OR current_setting('quena.finance_payment')::jsonb->>'code'<>'PAYMENT_RECORDED'
    THEN RAISE EXCEPTION 'FAIL: invoice/payment exact request replay did not return original result'; END IF;
  IF current_setting('quena.finance_partial_detail')::jsonb#>>'{payable,status}'<>'SEBAGIAN'
    OR (current_setting('quena.finance_partial_detail')::jsonb#>>'{payable,paid}')::numeric<>100
    THEN RAISE EXCEPTION 'FAIL: Tempo partial payment was not derived correctly'; END IF;
  SELECT public.purchase_invoice_financial_detail(current_setting('quena.finance_invoice')::uuid) INTO v_detail;
  IF v_detail#>>'{payable,status}'<>'LUNAS' OR (v_detail#>>'{payable,amount}')::numeric<>360 OR (v_detail#>>'{payable,paid}')::numeric<>360
    OR (SELECT sum(line_subtotal) FROM public.purchase_invoice_items WHERE invoice_id=current_setting('quena.finance_invoice')::uuid)<>350
    OR jsonb_array_length(v_detail->'payments')<>2 THEN RAISE EXCEPTION 'FAIL: invoice system total, printed invoice total, initial/full payment history, or paid status mismatch'; END IF;
  SELECT count(*) INTO v_count FROM public.supplier_payments WHERE request_id IS NOT NULL;
  IF v_count<>2 THEN RAISE EXCEPTION 'FAIL: replay created duplicate supplier payments'; END IF;
  SELECT public.purchase_invoice_financial_detail(current_setting('quena.finance_due_invoice')::uuid) INTO v_detail;
  IF v_detail#>>'{payable,status}'<>'JATUH_TEMPO_SEGERA' THEN RAISE EXCEPTION 'FAIL: due-soon status was not derived'; END IF;
  SELECT public.purchase_invoice_financial_detail(current_setting('quena.finance_overdue_invoice')::uuid) INTO v_detail;
  IF v_detail#>>'{payable,status}'<>'TERLAMBAT' THEN RAISE EXCEPTION 'FAIL: overdue status was not derived'; END IF;
  SELECT public.purchase_invoice_financial_detail(current_setting('quena.finance_unpaid_invoice')::uuid) INTO v_detail;
  IF v_detail#>>'{payable,status}'<>'BELUM_DIBAYAR' OR (v_detail#>>'{payable,paid}')::numeric<>0
    THEN RAISE EXCEPTION 'FAIL: unpaid Tempo status was not derived'; END IF;
  IF (SELECT count(*) FROM public.supplier_payables WHERE invoice_id=current_setting('quena.finance_invoice')::uuid)<>1 THEN RAISE EXCEPTION 'FAIL: duplicate payable was created'; END IF;
  SELECT effective_quantity, balance_version INTO v_before, v_count FROM public.stock_balance_projection WHERE product_id=current_setting('quena.test_product_a')::uuid AND outlet_id=current_setting('quena.test_outlet_id')::uuid;
  IF v_before<>current_setting('quena.test_stock_before')::numeric OR v_count<>current_setting('quena.test_version_before')::bigint THEN RAISE EXCEPTION 'FAIL: invoice finalization/payment changed stock projection'; END IF;
  SELECT quantity INTO v_inventory FROM public.product_inventory WHERE product_id=current_setting('quena.test_product_a')::uuid AND outlet_id=current_setting('quena.test_outlet_id')::uuid;
  IF v_inventory<>current_setting('quena.test_inventory_before')::numeric THEN RAISE EXCEPTION 'FAIL: invoice/payment changed product_inventory'; END IF;
  IF (SELECT count(*) FROM public.stock_movement_batches WHERE created_at>=transaction_timestamp() AND source_system='PURCHASING')<>0 THEN
    RAISE EXCEPTION 'FAIL: financial workflow created a stock movement batch'; END IF;
END $manager_assertions$;

-- GUDANG can still physically receive and post, but financial tables and RPCs are denied.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
DO $gudang_denied$
DECLARE v_denied boolean:=false;
BEGIN
  IF public.current_active_user_role() IS DISTINCT FROM 'GUDANG'::public.user_role THEN RAISE EXCEPTION 'IDENTITY_MISMATCH: expected GUDANG'; END IF;
  IF (SELECT count(*) FROM public.purchase_invoices)<>0 OR (SELECT count(*) FROM public.purchase_invoice_items)<>0
    OR (SELECT count(*) FROM public.supplier_payables)<>0 OR (SELECT count(*) FROM public.supplier_payments)<>0
    OR (SELECT count(*) FROM public.supplier_payment_allocations)<>0 OR (SELECT count(*) FROM public.purchase_invoice_documents)<>0 THEN
    RAISE EXCEPTION 'FAIL: GUDANG can read financial purchasing tables'; END IF;
  BEGIN PERFORM public.purchase_invoice_financial_detail(current_setting('quena.finance_invoice')::uuid);
  EXCEPTION WHEN SQLSTATE '42501' THEN v_denied:=true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL: GUDANG financial detail RPC not denied'; END IF;
  v_denied:=false;
  BEGIN PERFORM public.purchase_invoice_create_draft(current_setting('quena.test_outlet_id')::uuid,
    current_setting('quena.test_supplier_id')::uuid,gen_random_uuid());
  EXCEPTION WHEN SQLSTATE '42501' THEN v_denied:=true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL: GUDANG financial invoice mutation not denied'; END IF;
END $gudang_denied$;
RESET ROLE;

-- KASIR has no purchasing read or mutation access.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
SET LOCAL ROLE authenticated;
DO $kasir_denied$
DECLARE v_denied boolean:=false;
BEGIN
  IF public.current_active_user_role() IS DISTINCT FROM 'KASIR'::public.user_role THEN RAISE EXCEPTION 'IDENTITY_MISMATCH: expected KASIR'; END IF;
  IF (SELECT count(*) FROM public.purchase_receipts)<>0 OR (SELECT count(*) FROM public.suppliers)<>0
    OR (SELECT count(*) FROM public.purchase_invoices)<>0 THEN RAISE EXCEPTION 'FAIL: KASIR can read purchasing tables'; END IF;
  BEGIN PERFORM public.purchase_invoice_financial_detail(current_setting('quena.finance_invoice')::uuid);
  EXCEPTION WHEN SQLSTATE '42501' THEN v_denied:=true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL: KASIR financial read RPC not denied'; END IF;
END $kasir_denied$;
RESET ROLE;

-- GOODS-FIRST: the normal Phase 1 operation posts stock once; later invoice linkage/finalization never changes it again.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),'Goods first finance matrix') goods_receipt \gset
SELECT public.purchase_receipt_save_draft(:'goods_receipt'::uuid,1,now(),NULL,
 jsonb_build_array(jsonb_build_object('product_id',:'product_a','accepted_quantity',1,'bonus_quantity',1,'rejected_quantity',2))) goods_save \gset
SELECT public.issue_purchase_receipt_post_intent(:'goods_receipt'::uuid) goods_request \gset
SELECT public.apply_purchase_receipt_post_intent(:'goods_request'::uuid) goods_post \gset
SELECT set_config('quena.goods_receipt',:'goods_receipt',true);
SELECT set_config('quena.goods_request',:'goods_request',true);
RESET ROLE;
SELECT effective_quantity goods_posted_quantity,balance_version goods_posted_version FROM public.stock_balance_projection WHERE product_id=:'product_a'::uuid AND outlet_id=:'outlet_id'::uuid \gset
SELECT set_config('quena.goods_posted_quantity',:'goods_posted_quantity',true);
SELECT set_config('quena.goods_posted_version',:'goods_posted_version',true);
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT gen_random_uuid() late_invoice_req \gset
SELECT public.purchase_invoice_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,:'late_invoice_req'::uuid) late_invoice \gset
SELECT public.purchase_invoice_link_receipt(:'late_invoice'::uuid,current_setting('quena.goods_receipt')::uuid,true) \gset
SELECT public.purchase_invoice_save_draft(:'late_invoice'::uuid,1,'STG-LATE-01',current_date,NULL,'CASH',50,
 jsonb_build_array(jsonb_build_object('product_id',:'product_a','invoice_quantity',2,'purchase_unit_price',25))) \gset
SELECT gen_random_uuid() late_finalize_req \gset
SELECT public.purchase_invoice_finalize(:'late_invoice'::uuid,:'late_finalize_req'::uuid,2,50,'CASH',current_date,NULL) \gset
SELECT set_config('quena.late_invoice',:'late_invoice',true);
RESET ROLE;
DO $goods_first_assert$
DECLARE v_detail jsonb;
BEGIN
  IF (SELECT status FROM public.purchase_receipts WHERE id=current_setting('quena.goods_receipt')::uuid)<>'POSTED'
    OR (SELECT count(*) FROM public.stock_movement_batches WHERE operation_request_id=current_setting('quena.goods_request')::uuid)<>1
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id=current_setting('quena.test_product_a')::uuid AND outlet_id=current_setting('quena.test_outlet_id')::uuid)<>current_setting('quena.goods_posted_quantity')::numeric
    OR (SELECT balance_version FROM public.stock_balance_projection WHERE product_id=current_setting('quena.test_product_a')::uuid AND outlet_id=current_setting('quena.test_outlet_id')::uuid)<>current_setting('quena.goods_posted_version')::bigint
    OR NOT EXISTS(SELECT 1 FROM public.purchase_invoice_receipts WHERE invoice_id=current_setting('quena.late_invoice')::uuid AND receipt_id=current_setting('quena.goods_receipt')::uuid)
    THEN RAISE EXCEPTION 'FAIL: invoice-after-goods changed/reposted stock or failed to link'; END IF;
  SELECT public.purchase_invoice_financial_detail(current_setting('quena.late_invoice')::uuid) INTO v_detail;
  IF v_detail#>>'{payable,status}'<>'LUNAS' OR (v_detail#>>'{payable,paid}')::numeric<>50
    THEN RAISE EXCEPTION 'FAIL: fully paid CASH invoice was not derived as LUNAS'; END IF;
END $goods_first_assert$;
ROLLBACK;
\echo 'PASS: purchasing financial workflow matrix assertions completed; transaction rolled back'
