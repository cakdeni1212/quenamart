\set ON_ERROR_STOP on
\timing on
DO $guard$
BEGIN
  IF NOT ((current_database()='quena_stock_staging' AND inet_server_port()=5432)
      OR (current_database() LIKE 'quena_native_product_%' AND inet_server_port()=55432))
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR current_setting('server_version_num')::integer/10000<>15 OR current_setting('server_encoding')<>'UTF8'
    OR NOT EXISTS(SELECT 1 FROM quena_staging.environment WHERE name='quena_stock_staging')
    OR NOT EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929290000') THEN
    RAISE EXCEPTION 'Refusing C3A runtime matrix outside the guarded local PostgreSQL staging frontier';
  END IF;
END $guard$;

BEGIN;
SET LOCAL statement_timeout='90s';
SET LOCAL lock_timeout='10s';
SELECT id outlet_id FROM public.outlets WHERE code='QUENA-MART-1' AND is_active \gset
SELECT id product_a FROM public.products WHERE sku='STG-FULL-A' \gset
SELECT id product_b FROM public.products WHERE sku='STG-FULL-B' \gset
SELECT id product_zero FROM public.products WHERE sku='STG-STALE' \gset
SELECT id product_failure FROM public.products WHERE sku='STG-AMBIG-A' \gset
SELECT set_config('quena.c3a.outlet',:'outlet_id',true),set_config('quena.c3a.product_a',:'product_a',true),
  set_config('quena.c3a.product_b',:'product_b',true),set_config('quena.c3a.product_zero',:'product_zero',true),
  set_config('quena.c3a.product_failure',:'product_failure',true);
SELECT source_import_row_id source_a FROM public.product_costs WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_a'::uuid \gset
SELECT source_import_row_id source_zero FROM public.product_costs WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_zero'::uuid \gset

-- Rehearsal quantities and proof rows are transaction-local. No durable stock/HPP change survives ROLLBACK.
UPDATE public.stock_balance_projection SET unreconciled_movement_delta=-baseline_quantity,updated_at=now()
  WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_zero'::uuid;
UPDATE public.stock_balance_projection SET unreconciled_movement_delta=-baseline_quantity,updated_at=now()
  WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_failure'::uuid;
UPDATE public.product_costs SET hpp=NULL,updated_by='a0000000-0000-4000-8000-000000000001'
  WHERE outlet_id=:'outlet_id'::uuid AND product_id IN (:'product_b'::uuid,:'product_failure'::uuid);
INSERT INTO public.product_field_audit_reviews(product_id,outlet_id,field_key,status,source_import_row_id,
  reviewer_id,evidence_notes,request_id)
VALUES(:'product_a'::uuid,:'outlet_id'::uuid,'hpp','SUDAH_DIVERIFIKASI',:'source_a'::uuid,
  'a0000000-0000-4000-8000-000000000001','C3A rollback fixture',gen_random_uuid()),
  (:'product_zero'::uuid,:'outlet_id'::uuid,'hpp','SUDAH_DIVERIFIKASI',:'source_zero'::uuid,
  'a0000000-0000-4000-8000-000000000001','C3A rollback fixture',gen_random_uuid());

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_supplier_upsert(NULL,'C3A Staging Supplier',NULL,NULL,NULL,true) supplier_id \gset
SELECT (public.native_product_create(gen_random_uuid(),'NATIVE-RECEIPT-STAGING',
  'Native receipt staging product','Native','pcs',NULL,NULL,NULL,7500)->>'product_id')::uuid native_product \gset
SELECT set_config('quena.c3a.native_product',:'native_product',true);
RESET ROLE;

-- Reference-only receipt is physical-only and is included in a later explicit bootstrap quantity.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),'C3A reference-only') reference_receipt \gset
SELECT public.purchase_receipt_save_draft(:'reference_receipt'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_a','accepted_quantity',1,'bonus_quantity',2,'rejected_quantity',0))) reference_save \gset
SELECT public.issue_purchase_receipt_post_intent(:'reference_receipt'::uuid) reference_request \gset
SELECT public.apply_purchase_receipt_post_intent(:'reference_request'::uuid)::text reference_result \gset
RESET ROLE;
SELECT set_config('quena.c3a.reference_receipt',:'reference_receipt',true);
SELECT set_config('quena.c3a.reference_request',:'reference_request',true);
SELECT set_config('quena.c3a.reference_result',:'reference_result',true);

-- Prepare another draft and its estimate before cutover; its issued request is held across the bootstrap gate.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),'C3A gate') gate_receipt \gset
SELECT public.purchase_receipt_save_draft(:'gate_receipt'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_zero','accepted_quantity',10,'bonus_quantity',2,'rejected_quantity',0))) gate_save \gset
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_acquisition_estimate_save(:'gate_receipt'::uuid,
  (SELECT id FROM public.purchase_receipt_items WHERE receipt_id=:'gate_receipt'::uuid),2,0,
  'MANAGER_ESTIMATE',10000,NULL,'C3A fixture') estimate_result \gset
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
SELECT public.issue_purchase_receipt_post_intent(:'gate_receipt'::uuid) gate_request \gset
RESET ROLE;
SELECT set_config('quena.c3a.gate_receipt',:'gate_receipt',true);
SELECT set_config('quena.c3a.gate_request',:'gate_request',true);

-- A private estimate revision remains hidden from GUDANG and direct client writes are denied.
SET LOCAL ROLE authenticated;
SELECT set_config('quena.c3a.gudang_estimate_rows',(
  SELECT count(*)::text FROM public.purchase_receipt_acquisition_estimate_revisions)::text,true);
DO $gudang_estimate_access$
DECLARE v_denied boolean:=false;
BEGIN
  BEGIN
    PERFORM public.purchase_receipt_acquisition_estimate_save(
      current_setting('quena.c3a.gate_receipt')::uuid,
      (SELECT id FROM public.purchase_receipt_items WHERE receipt_id=current_setting('quena.c3a.gate_receipt')::uuid),3,1,
      'MANAGER_ESTIMATE',9000,NULL,NULL);
  EXCEPTION WHEN insufficient_privilege THEN v_denied:=true; END;
  IF NOT v_denied OR current_setting('quena.c3a.gudang_estimate_rows')<>'0' THEN
    RAISE EXCEPTION 'GUDANG_CAN_READ_OR_WRITE_ACQUISITION_ESTIMATE';
  END IF;
  v_denied:=false;
  BEGIN EXECUTE 'INSERT INTO public.purchase_receipt_acquisition_estimate_revisions(outlet_id,receipt_id,receipt_item_identity,receipt_item_id,product_id,revision,evidence_kind,estimated_unit_price,created_by) VALUES (NULL,NULL,NULL,NULL,NULL,1,''MANAGER_ESTIMATE'',1,''a0000000-0000-4000-8000-000000000003'')';
  EXCEPTION WHEN insufficient_privilege THEN v_denied:=true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'GUDANG_DIRECT_ESTIMATE_DML_WAS_NOT_DENIED'; END IF;
END $gudang_estimate_access$;
RESET ROLE;

-- Bootstrap includes the reference-only receipt quantity; preparation itself never created a cost event.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT public.inventory_cost_bootstrap_outlet(:'outlet_id'::uuid,gen_random_uuid()) bootstrap_result \gset
RESET ROLE;
DO $reference_and_bootstrap$
BEGIN
  IF current_setting('quena.c3a.reference_result')::jsonb->>'code'<>'POSTED'
    OR (SELECT count(*) FROM public.inventory_cost_events WHERE receipt_id=current_setting('quena.c3a.reference_receipt')::uuid)<>0
    OR (SELECT physical_quantity FROM public.inventory_cost_projections WHERE outlet_id=current_setting('quena.c3a.outlet')::uuid AND product_id=current_setting('quena.c3a.product_a')::uuid)
      <>(SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=current_setting('quena.c3a.outlet')::uuid AND product_id=current_setting('quena.c3a.product_a')::uuid)
    OR (SELECT valuation_status FROM public.inventory_cost_projections WHERE outlet_id=current_setting('quena.c3a.outlet')::uuid AND product_id=current_setting('quena.c3a.product_b')::uuid)<>'UNVALUED'
    OR (SELECT physical_quantity FROM public.inventory_cost_projections WHERE outlet_id=current_setting('quena.c3a.outlet')::uuid AND product_id=current_setting('quena.c3a.product_zero')::uuid)<>0 THEN
    RAISE EXCEPTION 'REFERENCE_ONLY_OR_BOOTSTRAP_QUANTITY_CONTRACT_FAILED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.inventory_cost_events e JOIN public.stock_balance_projection sb
      ON sb.outlet_id=e.outlet_id AND sb.product_id=e.product_id
      WHERE e.outlet_id=current_setting('quena.c3a.outlet')::uuid
        AND e.product_id=current_setting('quena.c3a.product_a')::uuid AND e.event_type='OPENING'
        AND e.physical_quantity_after=sb.effective_quantity AND e.physical_quantity_delta=sb.effective_quantity
        AND e.receipt_id IS NULL AND e.receipt_item_id IS NULL AND e.valuation_basis='VERIFIED_IPOS_HPP') THEN
    RAISE EXCEPTION 'BOOTSTRAP_DID_NOT_SNAPSHOT_TOTAL_PHYSICAL_STOCK_AFTER_BONUS';
  END IF;
END $reference_and_bootstrap$;

-- BOOTSTRAP_READY blocks the already-issued request atomically and leaves it pending for the same request replay.
SELECT (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_zero'::uuid) gate_stock_before \gset
SELECT set_config('quena.c3a.gate_stock_before',:'gate_stock_before',true);
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
DO $bootstrap_ready_gate$
DECLARE v_blocked boolean:=false;
BEGIN
  BEGIN PERFORM public.apply_purchase_receipt_post_intent(current_setting('quena.c3a.gate_request')::uuid);
  EXCEPTION WHEN SQLSTATE '55000' THEN v_blocked:=true; END;
  IF NOT v_blocked OR (SELECT status FROM public.purchase_receipts WHERE id=current_setting('quena.c3a.gate_receipt')::uuid)<>'DRAFT'
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=current_setting('quena.c3a.outlet')::uuid AND product_id=current_setting('quena.c3a.product_zero')::uuid)
      <>current_setting('quena.c3a.gate_stock_before')::numeric THEN
    RAISE EXCEPTION 'BOOTSTRAP_READY_DID_NOT_BLOCK_RECEIPT_ATOMICALLY';
  END IF;
END $bootstrap_ready_gate$;
RESET ROLE;
DO $bootstrap_ready_request_state$
BEGIN
  IF (SELECT state FROM public.stock_operation_requests WHERE request_id=current_setting('quena.c3a.gate_request')::uuid)<>'PENDING' THEN
    RAISE EXCEPTION 'BOOTSTRAP_READY_DID_NOT_PRESERVE_REQUEST_FOR_REPLAY';
  END IF;
END $bootstrap_ready_request_state$;

-- Activation is a rollback-only staging fixture; production WAC is never touched by this matrix.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
UPDATE public.inventory_costing_outlet_authority SET status='WAC_ACTIVE',
  activated_by='a0000000-0000-4000-8000-000000000001',activated_at=now()
WHERE outlet_id=:'outlet_id'::uuid;

-- A native zero projection must be accepted by the unchanged Goods In stock
-- and acquisition-costing writers after bootstrap/WAC activation.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),
  'Native zero baseline receipt') native_receipt \gset
SELECT public.purchase_receipt_save_draft(:'native_receipt'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'native_product','accepted_quantity',10,'bonus_quantity',0,'rejected_quantity',0))) native_save \gset
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_acquisition_estimate_save(:'native_receipt'::uuid,
  (SELECT id FROM public.purchase_receipt_items WHERE receipt_id=:'native_receipt'::uuid),2,0,
  'MANAGER_ESTIMATE',5000,NULL,'Native post-bootstrap receipt fixture') native_estimate \gset
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SELECT public.issue_purchase_receipt_post_intent(:'native_receipt'::uuid) native_request \gset
SELECT public.apply_purchase_receipt_post_intent(:'native_request'::uuid) native_post \gset
RESET ROLE;
SELECT set_config('quena.c3a.native_receipt',:'native_receipt',true);
DO $native_receipt_assertion$
DECLARE v_stock numeric; v_cost public.inventory_cost_projections%rowtype; v_event public.inventory_cost_events%rowtype;
BEGIN
  SELECT effective_quantity INTO v_stock FROM public.stock_balance_projection
    WHERE outlet_id=current_setting('quena.c3a.outlet')::uuid
      AND product_id=current_setting('quena.c3a.native_product')::uuid;
  SELECT * INTO v_cost FROM public.inventory_cost_projections
    WHERE outlet_id=current_setting('quena.c3a.outlet')::uuid
      AND product_id=current_setting('quena.c3a.native_product')::uuid;
  SELECT * INTO v_event FROM public.inventory_cost_events
    WHERE receipt_id=current_setting('quena.c3a.native_receipt')::uuid;
  IF v_stock<>10 OR v_cost.physical_quantity<>10 OR v_cost.valued_quantity<>10
    OR v_cost.provisional_quantity<>10 OR v_cost.inventory_value<>50000 OR v_cost.current_wac<>5000
    OR v_cost.valuation_status<>'PROVISIONAL' OR v_event.valuation_basis<>'MANAGER_ESTIMATE'
    OR NOT EXISTS(SELECT 1 FROM public.stock_movements m
      WHERE m.product_id=current_setting('quena.c3a.native_product')::uuid
        AND m.movement_type='PURCHASE_RECEIPT' AND m.quantity_delta=10) THEN
    RAISE EXCEPTION 'NATIVE_ZERO_BASELINE_PURCHASE_RECEIPT_OR_PROVISIONAL_COSTING_FAILED';
  END IF;
END $native_receipt_assertion$;

-- The same request now posts once: 10 paid + 2 bonus at Rp10,000 values 12 units at Rp100,000.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SELECT public.apply_purchase_receipt_post_intent(:'gate_request'::uuid)::text gate_post_result \gset
SELECT public.apply_purchase_receipt_post_intent(:'gate_request'::uuid)::text gate_replay_result \gset
RESET ROLE;
SELECT set_config('quena.c3a.gate_post_result',:'gate_post_result',true);
SELECT set_config('quena.c3a.gate_replay_result',:'gate_replay_result',true);
DO $manager_estimate_assert$
DECLARE v_projection public.inventory_cost_projections%rowtype; v_event public.inventory_cost_events%rowtype;
BEGIN
  SELECT * INTO v_projection FROM public.inventory_cost_projections
    WHERE outlet_id=current_setting('quena.c3a.outlet')::uuid AND product_id=current_setting('quena.c3a.product_zero')::uuid;
  SELECT * INTO v_event FROM public.inventory_cost_events WHERE receipt_id=current_setting('quena.c3a.gate_receipt')::uuid;
  IF current_setting('quena.c3a.gate_post_result')::jsonb IS DISTINCT FROM current_setting('quena.c3a.gate_replay_result')::jsonb
    OR current_setting('quena.c3a.gate_post_result')::jsonb->>'code'<>'POSTED'
    OR v_projection.physical_quantity<>12 OR v_projection.valued_quantity<>12 OR v_projection.provisional_quantity<>12
    OR v_projection.unvalued_quantity<>0 OR v_projection.inventory_value<>100000 OR v_projection.current_wac<>8333.33333333
    OR v_projection.valuation_status<>'PROVISIONAL' OR v_event.valuation_basis<>'MANAGER_ESTIMATE'
    OR v_event.frozen_unit_cost<>10000 OR v_event.acquisition_evidence_revision<>1
    OR v_event.valued_quantity_delta<>12
    OR (SELECT count(*) FROM public.inventory_cost_events WHERE receipt_item_id=v_event.receipt_item_id)<>1
    OR current_setting('quena.c3a.gate_post_result')::jsonb ? 'inventoryValue' THEN
    RAISE EXCEPTION 'MANAGER_ESTIMATE_BONUS_OR_REPLAY_CONTRACT_FAILED';
  END IF;
END $manager_estimate_assert$;

-- Current WAC fallback uses the pre-event WAC snapshot and adds only accepted quantity value.
SELECT last_cost_event_id prior_wac_event,cost_version prior_wac_version,current_wac prior_wac
  FROM public.inventory_cost_projections WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_a'::uuid \gset
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),'C3A WAC fallback') current_wac_receipt \gset
SELECT public.purchase_receipt_save_draft(:'current_wac_receipt'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_a','accepted_quantity',10,'bonus_quantity',0,'rejected_quantity',0))) current_wac_save \gset
SELECT public.issue_purchase_receipt_post_intent(:'current_wac_receipt'::uuid) current_wac_request \gset
SELECT public.apply_purchase_receipt_post_intent(:'current_wac_request'::uuid) current_wac_result \gset
RESET ROLE;
SELECT set_config('quena.c3a.current_wac_receipt',:'current_wac_receipt',true);
SELECT set_config('quena.c3a.prior_wac_event',:'prior_wac_event',true);
SELECT set_config('quena.c3a.prior_wac_version',:'prior_wac_version',true);
SELECT set_config('quena.c3a.prior_wac',:'prior_wac',true);
DO $current_wac_assert$
DECLARE v_event public.inventory_cost_events%rowtype;
BEGIN
  SELECT * INTO v_event FROM public.inventory_cost_events WHERE receipt_id=current_setting('quena.c3a.current_wac_receipt')::uuid;
  IF v_event.valuation_basis<>'CURRENT_WAC' OR v_event.frozen_unit_cost<>current_setting('quena.c3a.prior_wac')::numeric
    OR v_event.cost_version_before<>current_setting('quena.c3a.prior_wac_version')::integer
    OR v_event.basis_cost_event_id<>current_setting('quena.c3a.prior_wac_event')::uuid
    OR v_event.inventory_value_delta<>round(10*v_event.wac_before,8)
    OR v_event.valued_quantity_delta<>10 OR v_event.valued_quantity_after<>v_event.valued_quantity_before+10 THEN
    RAISE EXCEPTION 'CURRENT_WAC_FALLBACK_SNAPSHOT_INVALID';
  END IF;
END $current_wac_assert$;

-- A bonus-only receipt has no paid acquisition basis; current WAC is not applied as zero cost.
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),'C3A bonus-only') bonus_only_receipt \gset
SELECT public.purchase_receipt_save_draft(:'bonus_only_receipt'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_a','accepted_quantity',0,'bonus_quantity',2,'rejected_quantity',0))) bonus_only_save \gset
SELECT public.issue_purchase_receipt_post_intent(:'bonus_only_receipt'::uuid) bonus_only_request \gset
SELECT public.apply_purchase_receipt_post_intent(:'bonus_only_request'::uuid) bonus_only_result \gset
RESET ROLE;
SELECT set_config('quena.c3a.bonus_only_receipt',:'bonus_only_receipt',true);
DO $bonus_only_assert$
DECLARE v_projection public.inventory_cost_projections%rowtype; v_event public.inventory_cost_events%rowtype;
BEGIN
  SELECT * INTO v_projection FROM public.inventory_cost_projections WHERE outlet_id=current_setting('quena.c3a.outlet')::uuid
    AND product_id=current_setting('quena.c3a.product_a')::uuid;
  SELECT * INTO v_event FROM public.inventory_cost_events WHERE receipt_id=current_setting('quena.c3a.bonus_only_receipt')::uuid;
  IF v_event.valuation_basis<>'UNVALUED' OR v_event.valued_quantity_delta<>0
    OR v_event.unvalued_quantity_delta<>2 OR v_projection.valuation_status<>'PARTIALLY_UNVALUED'
    OR v_projection.unvalued_quantity<2 OR v_projection.inventory_value<>v_event.inventory_value_before THEN
    RAISE EXCEPTION 'BONUS_ONLY_RECEIPT_MUST_NOT_FALL_THROUGH_TO_ZERO_COST';
  END IF;
END $bonus_only_assert$;
DO $historical_wac_basis_immutable$
DECLARE v_event public.inventory_cost_events%rowtype;
BEGIN
  SELECT * INTO v_event FROM public.inventory_cost_events
    WHERE receipt_id=current_setting('quena.c3a.current_wac_receipt')::uuid;
  IF v_event.basis_cost_event_id<>current_setting('quena.c3a.prior_wac_event')::uuid
    OR v_event.frozen_unit_cost<>current_setting('quena.c3a.prior_wac')::numeric
    OR (SELECT last_cost_event_id FROM public.inventory_cost_projections
        WHERE outlet_id=current_setting('quena.c3a.outlet')::uuid AND product_id=current_setting('quena.c3a.product_a')::uuid)=v_event.id THEN
    RAISE EXCEPTION 'HISTORICAL_CURRENT_WAC_BASIS_WAS_NOT_FROZEN';
  END IF;
END $historical_wac_basis_immutable$;

-- No usable WAC/HPP becomes fully unvalued; a later estimate creates an explicit partial state.
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),'C3A no basis') no_basis_receipt \gset
SELECT public.purchase_receipt_save_draft(:'no_basis_receipt'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_b','accepted_quantity',10,'bonus_quantity',0,'rejected_quantity',0))) no_basis_save \gset
SELECT public.issue_purchase_receipt_post_intent(:'no_basis_receipt'::uuid) no_basis_request \gset
SELECT public.apply_purchase_receipt_post_intent(:'no_basis_request'::uuid) no_basis_result \gset
SELECT id b_item FROM public.purchase_receipt_items WHERE receipt_id=:'no_basis_receipt'::uuid \gset
SELECT set_config('quena.c3a.no_basis_receipt',:'no_basis_receipt',true);
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),'C3A later valued receipt') partial_receipt \gset
SELECT public.purchase_receipt_save_draft(:'partial_receipt'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_b','accepted_quantity',10,'bonus_quantity',0,'rejected_quantity',0))) partial_save \gset
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_acquisition_estimate_save(:'partial_receipt'::uuid,
  (SELECT id FROM public.purchase_receipt_items WHERE receipt_id=:'partial_receipt'::uuid),2,0,
  'MANAGER_ESTIMATE',5000,NULL,NULL) partial_estimate \gset
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
SELECT public.issue_purchase_receipt_post_intent(:'partial_receipt'::uuid) partial_request \gset
SELECT public.apply_purchase_receipt_post_intent(:'partial_request'::uuid) partial_result \gset
RESET ROLE;
DO $partial_assert$
DECLARE v_projection public.inventory_cost_projections%rowtype; v_event public.inventory_cost_events%rowtype;
BEGIN
  SELECT * INTO v_projection FROM public.inventory_cost_projections WHERE outlet_id=current_setting('quena.c3a.outlet')::uuid AND product_id=current_setting('quena.c3a.product_b')::uuid;
  SELECT * INTO v_event FROM public.inventory_cost_events WHERE receipt_id=current_setting('quena.c3a.no_basis_receipt')::uuid;
  IF v_event.valuation_basis<>'UNVALUED' OR v_projection.valuation_status<>'PARTIALLY_UNVALUED'
    OR v_projection.valued_quantity<>10 OR v_projection.unvalued_quantity<>17 OR v_projection.physical_quantity<>27
    OR v_projection.inventory_value<>50000 OR v_projection.current_wac<>5000 THEN
    RAISE EXCEPTION 'UNVALUED_TO_PARTIAL_VALUATION_TRANSITION_INVALID';
  END IF;
END $partial_assert$;
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),'C3A fully unvalued') fully_unvalued_receipt \gset
SELECT public.purchase_receipt_save_draft(:'fully_unvalued_receipt'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_failure','accepted_quantity',10,'bonus_quantity',0,'rejected_quantity',0))) full_unvalued_save \gset
SELECT public.issue_purchase_receipt_post_intent(:'fully_unvalued_receipt'::uuid) full_unvalued_request \gset
SELECT public.apply_purchase_receipt_post_intent(:'full_unvalued_request'::uuid) full_unvalued_result \gset
RESET ROLE;
DO $fully_unvalued_assert$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.inventory_cost_projections WHERE outlet_id=current_setting('quena.c3a.outlet')::uuid
    AND product_id=current_setting('quena.c3a.product_failure')::uuid AND physical_quantity=10
    AND valued_quantity=0 AND unvalued_quantity=10 AND inventory_value IS NULL AND current_wac IS NULL
    AND valuation_status='UNVALUED') THEN RAISE EXCEPTION 'FULLY_UNVALUED_RECEIPT_SEMANTICS_FAILED'; END IF;
END $fully_unvalued_assert$;

-- Explicit zero is distinguishable from missing price and does not enter provisional quantity.
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),'C3A authoritative zero') zero_receipt \gset
SELECT public.purchase_receipt_save_draft(:'zero_receipt'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_a','accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',2,'short_quantity',3),
  jsonb_build_object('product_id',:'product_b','accepted_quantity',0,'bonus_quantity',0,'rejected_quantity',2))) zero_save \gset
SELECT id zero_item FROM public.purchase_receipt_items WHERE receipt_id=:'zero_receipt'::uuid AND product_id=:'product_a'::uuid \gset
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_acquisition_estimate_save(:'zero_receipt'::uuid,:'zero_item'::uuid,2,0,
  'AUTHORITATIVE_ZERO',0,'Supplier confirmed no charge',NULL) zero_estimate \gset
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
SELECT public.issue_purchase_receipt_post_intent(:'zero_receipt'::uuid) zero_request \gset
SELECT public.apply_purchase_receipt_post_intent(:'zero_request'::uuid) zero_result \gset
RESET ROLE;
SELECT set_config('quena.c3a.zero_receipt',:'zero_receipt',true);
SELECT set_config('quena.c3a.zero_item',:'zero_item',true);
DO $zero_and_exclusions$
DECLARE v_event public.inventory_cost_events%rowtype; v_item uuid;
BEGIN
  SELECT * INTO v_event FROM public.inventory_cost_events WHERE receipt_id=current_setting('quena.c3a.zero_receipt')::uuid;
  SELECT id INTO v_item FROM public.purchase_receipt_items WHERE receipt_id=current_setting('quena.c3a.zero_receipt')::uuid AND product_id=current_setting('quena.c3a.product_b')::uuid;
  IF v_event.valuation_basis<>'AUTHORITATIVE_ZERO' OR v_event.frozen_unit_cost<>0
    OR (SELECT count(*) FROM public.inventory_cost_events WHERE receipt_id=current_setting('quena.c3a.zero_receipt')::uuid)<>1
    OR EXISTS(SELECT 1 FROM public.stock_movements WHERE purchase_receipt_item_id=v_item)
    OR (SELECT count(*) FROM public.stock_movements WHERE purchase_receipt_item_id=v_event.receipt_item_id)<>1
    THEN RAISE EXCEPTION 'AUTHORITATIVE_ZERO_OR_REJECTED_ITEM_EXCLUSION_FAILED'; END IF;
END $zero_and_exclusions$;

-- Stable item IDs survive ordinary edits. Removing an item writes a tombstone and deletes the live item row.
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),'C3A stable items') stable_receipt \gset
SELECT public.purchase_receipt_save_draft(:'stable_receipt'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_a','accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0),
  jsonb_build_object('product_id',:'product_b','accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0))) stable_save \gset
SELECT id stable_item FROM public.purchase_receipt_items WHERE receipt_id=:'stable_receipt'::uuid AND product_id=:'product_a'::uuid \gset
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_acquisition_estimate_save(:'stable_receipt'::uuid,:'stable_item'::uuid,2,0,
  'MANAGER_ESTIMATE',1234,NULL,NULL) stable_estimate \gset
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_save_draft(:'stable_receipt'::uuid,3,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_a','accepted_quantity',2,'bonus_quantity',0,'rejected_quantity',0),
  jsonb_build_object('product_id',:'product_b','accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0))) stable_update \gset
SELECT public.purchase_receipt_save_draft(:'stable_receipt'::uuid,4,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_b','accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0))) stable_remove \gset
RESET ROLE;
SELECT set_config('quena.c3a.stable_receipt',:'stable_receipt',true);
SELECT set_config('quena.c3a.stable_item',:'stable_item',true);
DO $stable_item_assert$
BEGIN
  IF EXISTS(SELECT 1 FROM public.purchase_receipt_items WHERE id=current_setting('quena.c3a.stable_item')::uuid)
    OR (SELECT evidence_kind FROM public.purchase_receipt_acquisition_estimate_revisions
        WHERE receipt_item_identity=current_setting('quena.c3a.stable_item')::uuid ORDER BY revision DESC LIMIT 1)<>'REMOVED'
    OR (SELECT receipt_item_id FROM public.purchase_receipt_acquisition_estimate_revisions
        WHERE receipt_item_identity=current_setting('quena.c3a.stable_item')::uuid ORDER BY revision DESC LIMIT 1)
      IS DISTINCT FROM current_setting('quena.c3a.stable_item')::uuid
    OR (SELECT id FROM public.purchase_receipt_items WHERE receipt_id=current_setting('quena.c3a.stable_receipt')::uuid AND product_id=current_setting('quena.c3a.product_b')::uuid)
      IS NULL THEN RAISE EXCEPTION 'DRAFT_ITEM_ID_STABILITY_OR_REMOVAL_TOMBSTONE_FAILED'; END IF;
END $stable_item_assert$;

-- Remove then re-add gets a fresh item identity and cannot inherit the old estimate.
SELECT current_wac stable_readd_expected_wac FROM public.inventory_cost_projections
  WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_a'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_save_draft(:'stable_receipt'::uuid,5,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_a','accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0),
  jsonb_build_object('product_id',:'product_b','accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0))) stable_readd \gset
SELECT id stable_readded_item FROM public.purchase_receipt_items WHERE receipt_id=:'stable_receipt'::uuid AND product_id=:'product_a'::uuid \gset
SELECT id stable_readded_b_item FROM public.purchase_receipt_items WHERE receipt_id=:'stable_receipt'::uuid AND product_id=:'product_b'::uuid \gset
SELECT public.issue_purchase_receipt_post_intent(:'stable_receipt'::uuid) stable_readd_request \gset
SELECT public.apply_purchase_receipt_post_intent(:'stable_readd_request'::uuid) stable_readd_result \gset
RESET ROLE;
SELECT set_config('quena.c3a.stable_readded_item',:'stable_readded_item',true);
SELECT set_config('quena.c3a.stable_readded_b_item',:'stable_readded_b_item',true);
SELECT set_config('quena.c3a.stable_readd_request',:'stable_readd_request',true);
SELECT set_config('quena.c3a.stable_readd_expected_wac',:'stable_readd_expected_wac',true);
DO $removed_item_not_inherited$
DECLARE v_event public.inventory_cost_events%rowtype;
BEGIN
  SELECT * INTO v_event FROM public.inventory_cost_events
    WHERE receipt_id=current_setting('quena.c3a.stable_receipt')::uuid
      AND receipt_item_id=current_setting('quena.c3a.stable_readded_item')::uuid;
  IF current_setting('quena.c3a.stable_readded_item')::uuid=current_setting('quena.c3a.stable_item')::uuid
    OR EXISTS(SELECT 1 FROM public.purchase_receipt_acquisition_estimate_revisions
      WHERE receipt_item_identity=current_setting('quena.c3a.stable_readded_item')::uuid)
    OR v_event.valuation_basis<>'CURRENT_WAC' OR v_event.acquisition_evidence_revision IS NOT NULL
    OR v_event.frozen_unit_cost IS DISTINCT FROM current_setting('quena.c3a.stable_readd_expected_wac')::numeric
    OR (SELECT count(*) FROM public.inventory_cost_events WHERE receipt_item_id=current_setting('quena.c3a.stable_item')::uuid)<>0
    OR current_setting('quena.c3a.stable_readd_request') IS NULL THEN
    RAISE EXCEPTION 'REMOVED_ITEM_ESTIMATE_INHERITED_AFTER_READD';
  END IF;
END $removed_item_not_inherited$;

-- KASIR cannot manage estimates. ADMIN can create evidence above, but the protected relation remains unavailable to KASIR.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
DO $kasir_denied$
DECLARE v_denied boolean:=false;
BEGIN
  BEGIN PERFORM public.purchase_receipt_acquisition_estimate_save(
    current_setting('quena.c3a.stable_receipt',true)::uuid,current_setting('quena.c3a.stable_item',true)::uuid,4,0,
    'MANAGER_ESTIMATE',1,NULL,NULL);
  EXCEPTION WHEN insufficient_privilege THEN v_denied:=true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'KASIR_ACQUISITION_ESTIMATE_PERMISSION_NOT_DENIED'; END IF;
END $kasir_denied$;
RESET ROLE;

-- Missing WAC projection forces the costing writer to fail; the receipt stock transaction rolls back as a unit.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_receipt_create_draft(:'outlet_id'::uuid,:'supplier_id'::uuid,now(),'C3A forced rollback') failure_receipt \gset
SELECT public.purchase_receipt_save_draft(:'failure_receipt'::uuid,1,now(),NULL,jsonb_build_array(
  jsonb_build_object('product_id',:'product_failure','accepted_quantity',1,'bonus_quantity',0,'rejected_quantity',0))) failure_save \gset
SELECT public.issue_purchase_receipt_post_intent(:'failure_receipt'::uuid) failure_request \gset
RESET ROLE;
SELECT effective_quantity failure_stock_before FROM public.stock_balance_projection WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_failure'::uuid \gset
SELECT set_config('quena.c3a.failure_request',:'failure_request',true);
SELECT set_config('quena.c3a.failure_receipt',:'failure_receipt',true);
SELECT set_config('quena.c3a.failure_stock_before',:'failure_stock_before',true);
DELETE FROM public.inventory_cost_projections WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_failure'::uuid;
SET LOCAL ROLE authenticated;
DO $atomic_failure$
DECLARE v_failed boolean:=false;
BEGIN
  BEGIN PERFORM public.apply_purchase_receipt_post_intent(current_setting('quena.c3a.failure_request')::uuid);
  EXCEPTION WHEN SQLSTATE '55000' THEN v_failed:=true; END;
  IF NOT v_failed OR (SELECT effective_quantity FROM public.stock_balance_projection
      WHERE outlet_id=current_setting('quena.c3a.outlet')::uuid AND product_id=current_setting('quena.c3a.product_failure')::uuid)<>current_setting('quena.c3a.failure_stock_before')::numeric
    OR (SELECT status FROM public.purchase_receipts WHERE id=current_setting('quena.c3a.failure_receipt')::uuid)<>'DRAFT'
    OR EXISTS(SELECT 1 FROM public.stock_movements WHERE purchase_receipt_item_id=
      (SELECT id FROM public.purchase_receipt_items WHERE receipt_id=current_setting('quena.c3a.failure_receipt')::uuid)) THEN
    RAISE EXCEPTION 'COST_FAILURE_DID_NOT_ROLL_BACK_STOCK_AND_RECEIPT';
  END IF;
END $atomic_failure$;
RESET ROLE;

-- A fresh request UUID cannot bypass the source-level one-cost-event-per-receipt-item guard.
DO $different_request_duplicate_source$
DECLARE v_event public.inventory_cost_events%rowtype; v_stock numeric; v_blocked boolean:=false;
BEGIN
  SELECT * INTO v_event FROM public.inventory_cost_events
    WHERE receipt_id=current_setting('quena.c3a.current_wac_receipt')::uuid;
  SELECT effective_quantity INTO v_stock FROM public.stock_balance_projection
    WHERE outlet_id=v_event.outlet_id AND product_id=v_event.product_id;
  UPDATE public.inventory_cost_projections SET
    physical_quantity=v_event.physical_quantity_before,
    valued_quantity=v_event.valued_quantity_before,
    provisional_quantity=v_event.provisional_quantity_before,
    unvalued_quantity=v_event.unvalued_quantity_before,
    inventory_value=v_event.inventory_value_before,current_wac=v_event.wac_before,
    valuation_status=v_event.valuation_status_before,cost_version=v_event.cost_version_before,
    stock_balance_version=v_event.stock_balance_version-1,
    last_cost_event_id=v_event.basis_cost_event_id,updated_at=now()
  WHERE outlet_id=v_event.outlet_id AND product_id=v_event.product_id;
  BEGIN
    PERFORM public.inventory_cost_apply_purchase_receipt(gen_random_uuid(),v_event.receipt_id,
      (SELECT batch_id FROM public.stock_movements WHERE id=v_event.stock_movement_id),v_event.stock_authority_period_id);
  EXCEPTION WHEN unique_violation THEN v_blocked:=true;
  END;
  IF NOT v_blocked
    OR (SELECT count(*) FROM public.inventory_cost_events WHERE receipt_item_id=v_event.receipt_item_id)<>1
    OR (SELECT inventory_value_delta FROM public.inventory_cost_events WHERE id=v_event.id) IS DISTINCT FROM v_event.inventory_value_delta
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=v_event.outlet_id AND product_id=v_event.product_id)<>v_stock THEN
    RAISE EXCEPTION 'NEW_REQUEST_BYPASSED_RECEIPT_ITEM_COST_EVENT_UNIQUENESS';
  END IF;
END $different_request_duplicate_source$;

ROLLBACK;
