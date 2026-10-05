\set ON_ERROR_STOP on
\timing on
DO $guard$
BEGIN
  IF current_database() <> 'quena_stock_staging'
     OR coalesce(host(inet_server_addr()), '') NOT IN ('127.0.0.1','::1')
     OR inet_server_port() <> 5432
     OR current_setting('server_version_num')::integer / 10000 <> 15
     OR current_setting('server_encoding') <> 'UTF8'
     OR NOT EXISTS (SELECT 1 FROM quena_staging.environment WHERE name='quena_stock_staging') THEN
    RAISE EXCEPTION 'Refusing purchasing receipt matrix outside guarded local staging';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929220000') THEN
    RAISE EXCEPTION 'Purchasing migration is not recorded in local staging';
  END IF;
END;
$guard$;

BEGIN;
SET LOCAL statement_timeout='60s';
SET LOCAL lock_timeout='10s';

SELECT id AS outlet_id FROM public.outlets WHERE code='QUENA-MART-1' AND is_active \gset
SELECT id AS product_a FROM public.products WHERE sku='STG-FULL-A' \gset
SELECT id AS product_b FROM public.products WHERE sku='STG-FULL-B' \gset
SELECT effective_quantity AS before_a, balance_version AS version_a FROM public.stock_balance_projection WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_a'::uuid \gset
SELECT effective_quantity AS before_b, balance_version AS version_b FROM public.stock_balance_projection WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_b'::uuid \gset
SELECT quantity AS inventory_a FROM public.product_inventory WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_a'::uuid \gset

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_supplier_upsert(NULL,'Purchasing Stage Supplier','Stage Legal','0812000000','Receiving Contact',true) AS supplier_id \gset
RESET ROLE;

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_supplier_upsert(NULL,'Purchasing Admin Supplier',NULL,NULL,NULL,true) AS admin_supplier_id \gset
RESET ROLE;

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid, :'supplier_id'::uuid, now(), 'Synthetic receiving matrix') AS receipt_id \gset
SELECT set_config('quena.test_receipt_id', :'receipt_id', true);
SELECT set_config('quena.test_product_a', :'product_a', true);
SELECT public.purchase_receipt_save_draft(:'receipt_id'::uuid,1,now(),'Synthetic receiving matrix',jsonb_build_array(
  jsonb_build_object('product_id',:'product_a','accepted_quantity',1.250,'bonus_quantity',0.750,'rejected_quantity',3,'short_quantity',0.500,'operational_note','Kemasan rusak dipisahkan'),
  jsonb_build_object('product_id',:'product_b','accepted_quantity',1.500,'bonus_quantity',0,'rejected_quantity',0,'short_quantity',NULL,'operational_note',NULL)
)) AS save_result \gset
SELECT (:'save_result'::jsonb->>'ok')::boolean AS saved \gset
\if :saved
\else
  \echo 'FAIL: GUDANG could not save a valid draft'
  \quit 1
\endif
DO $lookup_contract$
DECLARE v_match jsonb; v_missing jsonb; v_ambiguous jsonb; v_search jsonb; v_duplicate_rejected boolean:=false;
BEGIN
  v_match:=public.purchase_receipt_resolve_barcode('STG-FULL-A-BC');
  v_missing:=public.purchase_receipt_resolve_barcode('STG-BARCODE-NOT-FOUND');
  v_ambiguous:=public.purchase_receipt_resolve_barcode('STG-DUP-AMBIG');
  v_search:=public.purchase_receipt_product_search('STG-FULL-A',1);
  IF v_match->>'code'<>'BARCODE_MATCH' OR v_match#>>'{product,sku}'<>'STG-FULL-A'
    OR v_missing->>'code'<>'BARCODE_NOT_FOUND' OR v_ambiguous->>'code'<>'BARCODE_AMBIGUOUS'
    OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_search->'rows') row WHERE row->>'sku'='STG-FULL-A')
    THEN RAISE EXCEPTION 'FAIL: exact barcode/manual search contract did not distinguish match, missing, and ambiguity'; END IF;
  BEGIN
    PERFORM public.purchase_receipt_save_draft(current_setting('quena.test_receipt_id',true)::uuid,2,now(),NULL,
      jsonb_build_array(
        jsonb_build_object('product_id',current_setting('quena.test_product_a'),'accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0),
        jsonb_build_object('product_id',current_setting('quena.test_product_a'),'accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0)));
  EXCEPTION WHEN SQLSTATE '22023' THEN v_duplicate_rejected:=true;
  END;
  IF NOT v_duplicate_rejected THEN RAISE EXCEPTION 'FAIL: duplicate product lines were accepted'; END IF;
END;
$lookup_contract$;
SELECT public.issue_purchase_receipt_post_intent(:'receipt_id'::uuid) AS request_id \gset
SELECT public.apply_purchase_receipt_post_intent(:'request_id'::uuid)::text AS first_result \gset
SELECT public.apply_purchase_receipt_post_intent(:'request_id'::uuid)::text AS replay_result \gset
RESET ROLE;

SELECT set_config('quena.test_receipt_id', :'receipt_id', true);
SELECT set_config('quena.test_request_id', :'request_id', true);
SELECT set_config('quena.test_product_a', :'product_a', true);
SELECT set_config('quena.test_product_b', :'product_b', true);
SELECT set_config('quena.test_outlet_id', :'outlet_id', true);
SELECT set_config('quena.test_first_result', :'first_result', true);
SELECT set_config('quena.test_replay_result', :'replay_result', true);
SELECT set_config('quena.test_before_a', :'before_a', true);
SELECT set_config('quena.test_before_b', :'before_b', true);
SELECT set_config('quena.test_version_a', :'version_a', true);
SELECT set_config('quena.test_version_b', :'version_b', true);
SELECT set_config('quena.test_inventory_a', :'inventory_a', true);

DO $assert_post$
DECLARE v_receipt uuid:=current_setting('quena.test_receipt_id')::uuid; v_request uuid:=current_setting('quena.test_request_id')::uuid;
  v_a uuid:=current_setting('quena.test_product_a')::uuid; v_b uuid:=current_setting('quena.test_product_b')::uuid;
  v_outlet uuid:=current_setting('quena.test_outlet_id')::uuid; v_first jsonb:=current_setting('quena.test_first_result')::jsonb;
  v_replay jsonb:=current_setting('quena.test_replay_result')::jsonb; v_batch uuid; v_item_count integer;
BEGIN
  IF v_first IS DISTINCT FROM v_replay OR v_first->>'code'<>'POSTED' OR (v_first->>'movementCount')::integer<>2 THEN
    RAISE EXCEPTION 'FAIL: exact request UUID replay did not return the original POSTED result';
  END IF;
  IF (SELECT status FROM public.purchase_receipts WHERE id=v_receipt)<>'POSTED' THEN RAISE EXCEPTION 'FAIL: receipt did not become POSTED'; END IF;
  SELECT id INTO STRICT v_batch FROM public.stock_movement_batches WHERE operation_request_id=v_request AND source_system='PURCHASING';
  IF (SELECT count(*) FROM public.stock_movement_batches WHERE operation_request_id=v_request)<>1
    OR (SELECT count(*) FROM public.stock_movements WHERE batch_id=v_batch)<>2 THEN RAISE EXCEPTION 'FAIL: expected one movement batch and two product movements'; END IF;
  IF EXISTS (SELECT 1 FROM public.stock_movements WHERE batch_id=v_batch AND (movement_type<>'PURCHASE_RECEIPT' OR source_system<>'PURCHASING'))
    OR (SELECT count(*) FROM public.stock_movements WHERE batch_id=v_batch AND purchase_receipt_item_id IS NOT NULL)<>2
    THEN RAISE EXCEPTION 'FAIL: movement type/source/receipt-item link is incorrect'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE batch_id=v_batch AND product_id=v_a AND quantity_delta=2
    AND balance_before=current_setting('quena.test_before_a')::numeric AND balance_after=current_setting('quena.test_before_a')::numeric+2)
    OR NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE batch_id=v_batch AND product_id=v_b AND quantity_delta=1.5
    AND balance_before=current_setting('quena.test_before_b')::numeric AND balance_after=current_setting('quena.test_before_b')::numeric+1.5)
    THEN RAISE EXCEPTION 'FAIL: accepted plus bonus stock deltas or movement balances are wrong'; END IF;
  IF (SELECT balance_version FROM public.stock_balance_projection WHERE product_id=v_a AND outlet_id=v_outlet)<>current_setting('quena.test_version_a')::bigint+1
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id=v_a AND outlet_id=v_outlet)<>current_setting('quena.test_before_a')::numeric+2
    OR (SELECT balance_version FROM public.stock_balance_projection WHERE product_id=v_b AND outlet_id=v_outlet)<>current_setting('quena.test_version_b')::bigint+1
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id=v_b AND outlet_id=v_outlet)<>current_setting('quena.test_before_b')::numeric+1.5
    THEN RAISE EXCEPTION 'FAIL: projection quantity/version did not advance exactly once'; END IF;
  IF (SELECT count(*) FROM public.stock_balance_projection_events WHERE request_id=v_request)<>2
    OR (SELECT count(*) FROM public.purchase_receipt_events WHERE receipt_id=v_receipt AND event_type='POSTED')<>1
    THEN RAISE EXCEPTION 'FAIL: expected two projection events and one receipt POSTED event'; END IF;
  SELECT count(*) INTO v_item_count FROM public.purchase_receipt_items WHERE receipt_id=v_receipt;
  IF v_item_count<>2 OR (SELECT accepted_quantity+bonus_quantity FROM public.purchase_receipt_items WHERE receipt_id=v_receipt AND product_id=v_a)<>2
    OR (SELECT rejected_quantity FROM public.purchase_receipt_items WHERE receipt_id=v_receipt AND product_id=v_a)<>3
    OR (SELECT short_quantity FROM public.purchase_receipt_items WHERE receipt_id=v_receipt AND product_id=v_a)<>0.5
    THEN RAISE EXCEPTION 'FAIL: operational quantities were not preserved'; END IF;
  IF (SELECT quantity FROM public.product_inventory WHERE outlet_id=v_outlet AND product_id=v_a)<>current_setting('quena.test_inventory_a')::numeric
    THEN RAISE EXCEPTION 'FAIL: product_inventory changed'; END IF;
END;
$assert_post$;

-- OWNER and ADMIN are also authorized to post receipts through the same guarded RPC path.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid, :'supplier_id'::uuid, now(), 'OWNER post role fixture') AS owner_receipt_id \gset
SELECT public.purchase_receipt_save_draft(:'owner_receipt_id'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_a','accepted_quantity',0.001,'bonus_quantity',0,'rejected_quantity',0))) AS owner_save_result \gset
SELECT public.issue_purchase_receipt_post_intent(:'owner_receipt_id'::uuid) AS owner_request_id \gset
SELECT public.apply_purchase_receipt_post_intent(:'owner_request_id'::uuid)::text AS owner_post_result \gset
RESET ROLE;
SELECT set_config('quena.owner_post_result', :'owner_post_result', true);
SELECT set_config('quena.owner_receipt_id', :'owner_receipt_id', true);
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid, :'admin_supplier_id'::uuid, now(), 'ADMIN post role fixture') AS admin_receipt_id \gset
SELECT public.purchase_receipt_save_draft(:'admin_receipt_id'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_b','accepted_quantity',0.001,'bonus_quantity',0,'rejected_quantity',0))) AS admin_save_result \gset
SELECT public.issue_purchase_receipt_post_intent(:'admin_receipt_id'::uuid) AS admin_request_id \gset
SELECT public.apply_purchase_receipt_post_intent(:'admin_request_id'::uuid)::text AS admin_post_result \gset
RESET ROLE;
SELECT set_config('quena.admin_post_result', :'admin_post_result', true);
SELECT set_config('quena.admin_receipt_id', :'admin_receipt_id', true);
DO $manager_post_roles$
BEGIN
  IF current_setting('quena.owner_post_result')::jsonb->>'code'<>'POSTED'
    OR (current_setting('quena.owner_post_result')::jsonb->>'movementCount')::integer<>1
    OR current_setting('quena.admin_post_result')::jsonb->>'code'<>'POSTED'
    OR (current_setting('quena.admin_post_result')::jsonb->>'movementCount')::integer<>1
    OR (SELECT status FROM public.purchase_receipts WHERE id=current_setting('quena.owner_receipt_id')::uuid)<>'POSTED'
    OR (SELECT status FROM public.purchase_receipts WHERE id=current_setting('quena.admin_receipt_id')::uuid)<>'POSTED' THEN
    RAISE EXCEPTION 'FAIL: OWNER/ADMIN receipt posting was not completed';
  END IF;
END;
$manager_post_roles$;

-- Historical operational receipt detail retains supplier identity after deactivation;
-- the active supplier lookup itself still filters inactive rows in the application.
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_supplier_upsert(:'supplier_id'::uuid,'Purchasing Stage Supplier','Stage Legal','0812000000','Receiving Contact',false);
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
DO $historical_supplier_visibility$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.purchase_receipts r JOIN public.suppliers s ON s.id=r.supplier_id
    WHERE r.id=current_setting('quena.test_receipt_id')::uuid AND s.display_name='Purchasing Stage Supplier' AND NOT s.is_active) THEN
    RAISE EXCEPTION 'FAIL: GUDANG cannot read inactive supplier identity used by receipt history';
  END IF;
END;
$historical_supplier_visibility$;
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_supplier_upsert(:'supplier_id'::uuid,'Purchasing Stage Supplier','Stage Legal','0812000000','Receiving Contact',true);
RESET ROLE;

-- Deliberately make the second product overflow after the first projection
-- update would have succeeded. The exception subtransaction proves the entire
-- request's ledger/projection effects and receipt transition roll back.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid, :'supplier_id'::uuid, now(), 'Atomic failure fixture') AS atomic_receipt_id \gset
SELECT public.purchase_receipt_save_draft(:'atomic_receipt_id'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_a','accepted_quantity',0.001,'bonus_quantity',0,'rejected_quantity',0),
  jsonb_build_object('product_id',:'product_b','accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0)
)) AS atomic_save_result \gset
SELECT public.issue_purchase_receipt_post_intent(:'atomic_receipt_id'::uuid) AS atomic_request_id \gset
RESET ROLE;
UPDATE public.stock_balance_projection SET unreconciled_movement_delta=99999999992.999
  WHERE product_id=:'product_b'::uuid AND outlet_id=:'outlet_id'::uuid;
SELECT set_config('quena.test_atomic_receipt', :'atomic_receipt_id', true);
SELECT set_config('quena.test_atomic_request', :'atomic_request_id', true);
SELECT set_config('quena.test_atomic_a', :'product_a', true);
SELECT set_config('quena.test_atomic_b', :'product_b', true);
SELECT set_config('quena.test_atomic_outlet', :'outlet_id', true);
SELECT effective_quantity AS atomic_before_a FROM public.stock_balance_projection WHERE product_id=:'product_a'::uuid AND outlet_id=:'outlet_id'::uuid \gset
SELECT effective_quantity AS atomic_before_b FROM public.stock_balance_projection WHERE product_id=:'product_b'::uuid AND outlet_id=:'outlet_id'::uuid \gset
SELECT set_config('quena.test_atomic_before_a', :'atomic_before_a', true);
SELECT set_config('quena.test_atomic_before_b', :'atomic_before_b', true);
SET LOCAL ROLE authenticated;
DO $atomic_apply_failure$
DECLARE v_failed boolean:=false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
  BEGIN
    PERFORM public.apply_purchase_receipt_post_intent(current_setting('quena.test_atomic_request')::uuid);
  EXCEPTION WHEN SQLSTATE '22023' THEN v_failed:=true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: high-volume projection fixture did not cause a database-rejected post'; END IF;
END;
$atomic_apply_failure$;
RESET ROLE;
DO $atomic_assert$
DECLARE v_receipt uuid:=current_setting('quena.test_atomic_receipt')::uuid; v_request uuid:=current_setting('quena.test_atomic_request')::uuid;
  v_a uuid:=current_setting('quena.test_atomic_a')::uuid; v_b uuid:=current_setting('quena.test_atomic_b')::uuid;
  v_outlet uuid:=current_setting('quena.test_atomic_outlet')::uuid;
BEGIN
  IF (SELECT status FROM public.purchase_receipts WHERE id=v_receipt)<>'DRAFT'
    OR (SELECT state FROM public.stock_operation_requests WHERE request_id=v_request)<>'PENDING'
    OR EXISTS(SELECT 1 FROM public.stock_movement_batches WHERE operation_request_id=v_request)
    OR EXISTS(SELECT 1 FROM public.stock_movements WHERE source_event_key LIKE v_receipt::text || ':%')
    OR EXISTS(SELECT 1 FROM public.stock_balance_projection_events WHERE request_id=v_request)
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id=v_a AND outlet_id=v_outlet)<>current_setting('quena.test_atomic_before_a')::numeric
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id=v_b AND outlet_id=v_outlet)<>current_setting('quena.test_atomic_before_b')::numeric
    THEN RAISE EXCEPTION 'FAIL: rejected multi-product posting left partial stock or ledger effects'; END IF;
END;
$atomic_assert$;

-- A newly issued operation against POSTED must be a known rejection.
SET LOCAL ROLE authenticated;
DO $new_request_rejected$
BEGIN
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
  BEGIN
    PERFORM public.issue_purchase_receipt_post_intent(current_setting('quena.test_receipt_id')::uuid);
    RAISE EXCEPTION 'FAIL: new post request against POSTED receipt was accepted';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
  END;
END;
$new_request_rejected$;
RESET ROLE;

-- KASIR must neither read purchasing rows nor issue/apply a post request.
SET LOCAL ROLE authenticated;
DO $kasir_denied$
DECLARE v_denied boolean:=false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
  IF public.current_active_user_role() IS DISTINCT FROM 'KASIR'::public.user_role THEN RAISE EXCEPTION 'FAIL: staging identity is not KASIR'; END IF;
  IF (SELECT count(*) FROM public.purchase_receipts)<>0 OR (SELECT count(*) FROM public.suppliers)<>0
    THEN RAISE EXCEPTION 'FAIL: KASIR can read purchasing rows'; END IF;
  BEGIN
    PERFORM public.purchase_receipt_create_draft(current_setting('quena.test_outlet_id')::uuid,
      current_setting('quena.test_receipt_id')::uuid,now(),NULL);
  EXCEPTION WHEN SQLSTATE '42501' THEN v_denied:=true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL: KASIR was not denied purchase RPC'; END IF;
END;
$kasir_denied$;
RESET ROLE;

-- Inactive profile must be explicitly denied (NULL role is not an allow case).
UPDATE public.profiles SET is_active=false WHERE id='a0000000-0000-4000-8000-000000000003';
SET LOCAL ROLE authenticated;
DO $inactive_profile_denied$
DECLARE v_denied boolean:=false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
  IF public.current_active_user_role() IS NOT NULL THEN RAISE EXCEPTION 'FAIL: inactive staging actor still has active role'; END IF;
  BEGIN
    PERFORM public.purchase_receipt_create_draft(current_setting('quena.test_outlet_id')::uuid,
      current_setting('quena.test_receipt_id')::uuid,now(),NULL);
  EXCEPTION WHEN SQLSTATE '42501' THEN v_denied:=true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL: inactive profile was allowed to mutate purchasing'; END IF;
END;
$inactive_profile_denied$;
RESET ROLE;

-- Posted header/item writes must fail even when attempted by the local test owner.
DO $immutable$
DECLARE v_rejected boolean:=false;
BEGIN
  BEGIN
    UPDATE public.purchase_receipts SET operational_note='must not change' WHERE id=current_setting('quena.test_receipt_id')::uuid;
  EXCEPTION WHEN SQLSTATE '55000' THEN v_rejected:=true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'FAIL: posted receipt was mutable'; END IF;
END;
$immutable$;

ROLLBACK;
\echo 'PASS: local purchasing receipt posting, role boundary, ledger/projection effects, replay, and rollback assertions'
