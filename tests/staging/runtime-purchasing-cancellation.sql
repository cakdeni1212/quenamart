\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database()<>'quena_stock_staging' OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR inet_server_port()<>5432 OR current_setting('server_version_num')::integer/10000<>15
    OR NOT EXISTS(SELECT 1 FROM quena_staging.environment WHERE name='quena_stock_staging')
    OR NOT EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929240000') THEN
    RAISE EXCEPTION 'Refusing purchasing cancellation runtime outside guarded local staging';
  END IF;
END $guard$;

BEGIN;
SET LOCAL statement_timeout='60s';
SET LOCAL lock_timeout='10s';
SELECT id AS outlet_id FROM public.outlets WHERE code='QUENA-MART-1' AND is_active \gset
SELECT id AS product_a FROM public.products WHERE sku='STG-FULL-A' \gset
SELECT id AS owner_id FROM auth.users WHERE id='a0000000-0000-4000-8000-000000000001' \gset
SELECT coalesce(string_agg(product_id::text||':'||effective_quantity::text||':'||balance_version::text,',' ORDER BY product_id),'') AS before_projection
  FROM public.stock_balance_projection WHERE outlet_id=:'outlet_id'::uuid \gset
SELECT coalesce(string_agg(product_id::text||':'||quantity::text,',' ORDER BY product_id),'') AS before_inventory
  FROM public.product_inventory WHERE outlet_id=:'outlet_id'::uuid \gset
SELECT set_config('quena.test_outlet_id',:'outlet_id',true);
SELECT set_config('quena.before_projection',:'before_projection',true);
SELECT set_config('quena.before_inventory',:'before_inventory',true);

SELECT set_config('request.jwt.claim.sub',:'owner_id',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_supplier_upsert(NULL,'Purchasing Cancellation Stage Supplier',NULL,NULL,NULL,true) AS supplier_id \gset
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),NULL) AS empty_receipt \gset
SELECT public.purchase_receipt_cancel_draft(:'empty_receipt'::uuid) AS empty_cancel \gset
SELECT public.purchase_receipt_cancel_draft(:'empty_receipt'::uuid) AS empty_retry \gset
RESET ROLE;
SELECT set_config('quena.empty_receipt',:'empty_receipt',true);
SELECT set_config('quena.empty_cancel',:'empty_cancel',true);
SELECT set_config('quena.empty_retry',:'empty_retry',true);

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),'Populated cancellation fixture') AS populated_receipt \gset
SELECT public.purchase_receipt_save_draft(:'populated_receipt'::uuid,1,now(),'Populated cancellation fixture',jsonb_build_array(
  jsonb_build_object('product_id',:'product_a','accepted_quantity',2,'bonus_quantity',1,'rejected_quantity',1,'short_quantity',0.5))) AS populated_save \gset
RESET ROLE;
SELECT set_config('quena.populated_receipt',:'populated_receipt',true);
SELECT set_config('request.jwt.claim.sub',:'owner_id',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_cancel_draft(:'populated_receipt'::uuid) AS populated_cancel \gset
RESET ROLE;

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
DO $gudang_cannot_read_cancelled$
BEGIN
  IF EXISTS(SELECT 1 FROM public.purchase_receipts WHERE id=current_setting('quena.populated_receipt')::uuid)
    OR EXISTS(SELECT 1 FROM public.purchase_receipt_items WHERE receipt_id=current_setting('quena.populated_receipt')::uuid)
    OR EXISTS(SELECT 1 FROM public.purchase_receipt_events WHERE receipt_id=current_setting('quena.populated_receipt')::uuid) THEN
    RAISE EXCEPTION 'GUDANG can read a cancelled receipt or its retained audit rows';
  END IF;
END $gudang_cannot_read_cancelled$;
RESET ROLE;

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),NULL) AS admin_receipt \gset
SELECT public.purchase_receipt_cancel_draft(:'admin_receipt'::uuid) AS admin_cancel \gset
RESET ROLE;
SELECT set_config('quena.admin_receipt',:'admin_receipt',true);

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),NULL) AS gudang_draft \gset
SELECT set_config('quena.gudang_draft',:'gudang_draft',true);
DO $gudang_denied$
BEGIN
  BEGIN PERFORM public.purchase_receipt_cancel_draft(current_setting('quena.gudang_draft')::uuid); RAISE EXCEPTION 'GUDANG cancellation was allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $gudang_denied$;
RESET ROLE;

SELECT set_config('request.jwt.claim.sub',:'owner_id',true);
SET LOCAL ROLE authenticated;
DO $kasir_denied$
BEGIN
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
  BEGIN PERFORM public.purchase_receipt_cancel_draft(current_setting('quena.gudang_draft')::uuid); RAISE EXCEPTION 'KASIR cancellation was allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $kasir_denied$;
RESET ROLE;

-- A linked invoice draft is terminalized and its document is queued, never deleted.
SELECT set_config('request.jwt.claim.sub',:'owner_id',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),NULL) AS document_receipt \gset
SELECT public.purchase_receipt_save_draft(:'document_receipt'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_a','accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0))) AS document_receipt_save \gset
SELECT public.purchase_invoice_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,gen_random_uuid()) AS draft_invoice \gset
SELECT public.purchase_invoice_link_receipt(:'draft_invoice'::uuid,:'document_receipt'::uuid,true) AS invoice_link \gset
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),NULL) AS shared_invoice_receipt \gset
SELECT public.purchase_invoice_link_receipt(:'draft_invoice'::uuid,:'shared_invoice_receipt'::uuid,true) AS shared_invoice_link \gset
SELECT set_config('quena.shared_invoice_receipt',:'shared_invoice_receipt',true);
SELECT public.purchase_invoice_save_draft(:'draft_invoice'::uuid,1,'CANCEL-STAGE-1',current_date,current_date+14,'TEMPO',100,
  jsonb_build_array(jsonb_build_object('product_id',:'product_a','invoice_quantity',1,'purchase_unit_price',100))) AS invoice_save \gset
RESET ROLE;
INSERT INTO public.purchase_invoice_documents(invoice_id,storage_path,uploaded_by)
VALUES(:'draft_invoice'::uuid,'invoices/'||:'draft_invoice'||'/c0000000-0000-4000-8000-000000000001.jpg',:'owner_id'::uuid);
SELECT set_config('request.jwt.claim.sub',:'owner_id',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_cancel_draft(:'document_receipt'::uuid) AS document_cancel \gset
RESET ROLE;
SELECT set_config('quena.document_receipt',:'document_receipt',true);
SELECT set_config('quena.draft_invoice',:'draft_invoice',true);
SELECT set_config('quena.document_cancel',:'document_cancel',true);
SELECT set_config('request.jwt.claim.role','service_role',true);
SET LOCAL ROLE service_role;
SELECT public.purchase_invoice_document_cleanup_mark(
  (current_setting('quena.document_cancel')::jsonb#>>'{documents,0,documentId}')::uuid,false) AS failed_cleanup \gset
RESET ROLE;
SELECT set_config('request.jwt.claim.sub',:'owner_id',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_cancel_draft(current_setting('quena.document_receipt')::uuid) AS cleanup_retry \gset
RESET ROLE;
SELECT set_config('quena.cleanup_retry',:'cleanup_retry',true);
SELECT set_config('request.jwt.claim.role','service_role',true);
SET LOCAL ROLE service_role;
SELECT public.purchase_invoice_document_cleanup_mark(
  (current_setting('quena.cleanup_retry')::jsonb#>>'{documents,0,documentId}')::uuid,true) AS successful_cleanup \gset
RESET ROLE;
SELECT set_config('request.jwt.claim.sub',:'owner_id',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_invoice_finalize(current_setting('quena.draft_invoice')::uuid,gen_random_uuid(),2,0,NULL,NULL,NULL) AS cancelled_finalize \gset
RESET ROLE;
SELECT set_config('quena.cancelled_finalize',:'cancelled_finalize',true);

-- A finalized invoice/payable blocks cancellation; a posted receipt is always terminal.
SELECT set_config('request.jwt.claim.sub',:'owner_id',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),NULL) AS finalized_receipt \gset
SELECT set_config('quena.finalized_receipt',:'finalized_receipt',true);
SELECT public.purchase_receipt_save_draft(:'finalized_receipt'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_a','accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0))) AS finalized_receipt_save \gset
SELECT public.purchase_invoice_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,gen_random_uuid()) AS finalized_invoice \gset
SELECT public.purchase_invoice_link_receipt(:'finalized_invoice'::uuid,:'finalized_receipt'::uuid,true) AS finalized_link \gset
SELECT public.purchase_invoice_save_draft(:'finalized_invoice'::uuid,1,'CANCEL-STAGE-2',current_date,NULL,'CASH',100,
  jsonb_build_array(jsonb_build_object('product_id',:'product_a','invoice_quantity',1,'purchase_unit_price',100))) AS finalized_invoice_save \gset
SELECT public.purchase_invoice_finalize(:'finalized_invoice'::uuid,gen_random_uuid(),2,0,NULL,NULL,NULL) AS finalized_result \gset
DO $financial_denied$
BEGIN
  BEGIN PERFORM public.purchase_receipt_cancel_draft(current_setting('quena.finalized_receipt')::uuid); RAISE EXCEPTION 'Finalized invoice receipt cancellation was allowed';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
END $financial_denied$;

-- Simulate a linked stock movement while the receipt still says DRAFT. The
-- cancellation guard must reject the inconsistent state instead of trusting status.
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),NULL) AS movement_receipt \gset
SELECT set_config('quena.movement_receipt',:'movement_receipt',true);
SELECT public.purchase_receipt_save_draft(:'movement_receipt'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_a','accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0))) AS movement_receipt_save \gset
SELECT public.issue_purchase_receipt_post_intent(:'movement_receipt'::uuid) AS movement_request \gset
RESET ROLE;
SELECT id AS movement_item FROM public.purchase_receipt_items WHERE receipt_id=:'movement_receipt'::uuid \gset
SELECT id AS authority_period_id FROM public.stock_authority_periods WHERE outlet_id=:'outlet_id'::uuid AND ended_at IS NULL \gset
SELECT effective_quantity AS movement_before FROM public.stock_balance_projection WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_a'::uuid \gset
INSERT INTO public.stock_movement_batches(authority_period_id,outlet_id,source_system,operation_request_id,created_by)
VALUES(:'authority_period_id'::uuid,:'outlet_id'::uuid,'PURCHASING',:'movement_request'::uuid,:'owner_id'::uuid);
SELECT id AS movement_batch_id FROM public.stock_movement_batches WHERE operation_request_id=:'movement_request'::uuid \gset
INSERT INTO public.stock_movements(batch_id,authority_period_id,outlet_id,product_id,movement_type,source_system,quantity_delta,
  balance_before,balance_after,purchase_receipt_item_id,source_reference,source_event_key,created_by)
VALUES(:'movement_batch_id'::uuid,:'authority_period_id'::uuid,:'outlet_id'::uuid,:'product_a'::uuid,'PURCHASE_RECEIPT','PURCHASING',0.001,
  :'movement_before'::numeric,:'movement_before'::numeric+0.001,:'movement_item'::uuid,:'movement_receipt',
  :'movement_receipt'||':'||:'movement_item',:'owner_id'::uuid);
SELECT set_config('request.jwt.claim.sub',:'owner_id',true);
SET LOCAL ROLE authenticated;
DO $movement_denied$
BEGIN
  BEGIN PERFORM public.purchase_receipt_cancel_draft(current_setting('quena.movement_receipt')::uuid); RAISE EXCEPTION 'Receipt with stock movement was cancellable';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
  IF (SELECT status FROM public.purchase_receipts WHERE id=current_setting('quena.movement_receipt')::uuid)<>'DRAFT' THEN
    RAISE EXCEPTION 'Rejected movement-backed cancellation changed receipt state';
  END IF;
END $movement_denied$;

DO $no_stock_effects_from_cancellation$
DECLARE v_projection text; v_inventory text;
BEGIN
  SELECT coalesce(string_agg(product_id::text||':'||effective_quantity::text||':'||balance_version::text,',' ORDER BY product_id),'') INTO v_projection
    FROM public.stock_balance_projection WHERE outlet_id=current_setting('quena.test_outlet_id',true)::uuid;
  SELECT coalesce(string_agg(product_id::text||':'||quantity::text,',' ORDER BY product_id),'') INTO v_inventory
    FROM public.product_inventory WHERE outlet_id=current_setting('quena.test_outlet_id',true)::uuid;
  IF v_projection<>current_setting('quena.before_projection') OR v_inventory<>current_setting('quena.before_inventory') THEN
    RAISE EXCEPTION 'Cancellation changed projection or product_inventory';
  END IF;
END $no_stock_effects_from_cancellation$;

SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),NULL) AS posted_receipt \gset
SELECT set_config('quena.posted_receipt',:'posted_receipt',true);
SELECT public.purchase_receipt_save_draft(:'posted_receipt'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_a','accepted_quantity',0.001,'bonus_quantity',0,'rejected_quantity',0))) AS posted_receipt_save \gset
SELECT public.issue_purchase_receipt_post_intent(:'posted_receipt'::uuid) AS posted_request \gset
SELECT public.apply_purchase_receipt_post_intent(:'posted_request'::uuid) AS posted_result \gset
DO $posted_denied$
BEGIN
  BEGIN PERFORM public.purchase_receipt_cancel_draft(current_setting('quena.posted_receipt')::uuid); RAISE EXCEPTION 'POSTED receipt cancellation was allowed';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
  BEGIN PERFORM public.purchase_receipt_cancel_draft(current_setting('quena.empty_receipt')::uuid); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF (current_setting('quena.empty_cancel')::jsonb->>'code')<>'CANCELLED'
    OR (current_setting('quena.empty_retry')::jsonb->>'code')<>'ALREADY_CANCELLED'
    OR (SELECT count(*) FROM public.purchase_receipt_events WHERE receipt_id=current_setting('quena.empty_receipt')::uuid AND event_type='CANCELLED')<>1
    OR (SELECT status FROM public.purchase_receipts WHERE id=current_setting('quena.populated_receipt')::uuid)<>'CANCELLED'
    OR (SELECT count(*) FROM public.purchase_receipt_items WHERE receipt_id=current_setting('quena.populated_receipt')::uuid)<>1
    OR (SELECT status FROM public.purchase_receipts WHERE id=current_setting('quena.admin_receipt')::uuid)<>'CANCELLED'
    OR (SELECT status FROM public.purchase_receipts WHERE id=current_setting('quena.document_receipt')::uuid)<>'CANCELLED'
    OR (SELECT status FROM public.purchase_invoices WHERE id=current_setting('quena.draft_invoice')::uuid)<>'CANCELLED'
    OR (SELECT count(*) FROM public.purchase_invoice_events WHERE invoice_id=current_setting('quena.draft_invoice')::uuid AND event_type='CANCELLED')<>1
    OR (SELECT count(*) FROM public.purchase_invoice_events WHERE invoice_id=current_setting('quena.draft_invoice')::uuid AND event_type='RECEIPT_UNLINKED')<>1
    OR (SELECT count(*) FROM public.purchase_invoice_receipts WHERE invoice_id=current_setting('quena.draft_invoice')::uuid)<>1
    OR NOT EXISTS(SELECT 1 FROM public.purchase_invoice_receipts WHERE invoice_id=current_setting('quena.draft_invoice')::uuid AND receipt_id=current_setting('quena.document_receipt')::uuid)
    OR (SELECT status FROM public.purchase_receipts WHERE id=current_setting('quena.shared_invoice_receipt')::uuid)<>'DRAFT'
    OR (SELECT cleanup_status FROM public.purchase_invoice_documents WHERE invoice_id=current_setting('quena.draft_invoice')::uuid)<>'CLEANED'
    OR (SELECT cleanup_attempts FROM public.purchase_invoice_documents WHERE invoice_id=current_setting('quena.draft_invoice')::uuid)<>2
    OR (current_setting('quena.cleanup_retry')::jsonb->>'code')<>'ALREADY_CANCELLED'
    OR (current_setting('quena.cleanup_retry')::jsonb#>>'{documents,0,storagePath}') IS NULL
    OR (current_setting('quena.cancelled_finalize')::jsonb->>'code')<>'INVOICE_CHANGED'
    OR (SELECT count(*) FROM public.supplier_payables WHERE invoice_id=current_setting('quena.draft_invoice')::uuid)<>0 THEN
    RAISE EXCEPTION 'Purchasing cancellation state, audit preservation, or cleanup retry assertion failed';
  END IF;
END $posted_denied$;
ROLLBACK;
