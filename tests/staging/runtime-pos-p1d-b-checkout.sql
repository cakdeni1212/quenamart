\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database() NOT LIKE 'quena_p1d_b_staging_%'
     OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
     OR inet_server_port()<>55432
     OR current_setting('server_version_num')::integer/10000<>15
     OR (SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal DESC LIMIT 1)<>'20260929350000'
     OR to_regprocedure('public.pos_checkout_complete(uuid,uuid,bigint,public.pos_sale_payment_method,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'Refusing P1D-B runtime checks outside disposable local PostgreSQL 15 through 350000';
  END IF;
END; $guard$;

DO $security$
DECLARE checkout regprocedure:='public.pos_checkout_complete(uuid,uuid,bigint,public.pos_sale_payment_method,numeric,text)'::regprocedure;
  helper regprocedure:='public.inventory_cost_apply_pos_sale(uuid,uuid,uuid,uuid,uuid)'::regprocedure;
BEGIN
  IF NOT (SELECT prosecdef AND proconfig @> ARRAY['search_path=pg_catalog'] FROM pg_proc WHERE oid=checkout)
     OR NOT has_function_privilege('authenticated',checkout,'EXECUTE')
     OR has_function_privilege('anon',checkout,'EXECUTE')
     OR has_function_privilege('service_role',checkout,'EXECUTE') THEN
    RAISE EXCEPTION 'Checkout RPC security configuration/grants are incorrect';
  END IF;
  IF NOT (SELECT prosecdef AND proconfig @> ARRAY['search_path=pg_catalog'] FROM pg_proc WHERE oid=helper)
     OR has_function_privilege('authenticated',helper,'EXECUTE')
     OR has_function_privilege('anon',helper,'EXECUTE')
     OR has_function_privilege('service_role',helper,'EXECUTE') THEN
    RAISE EXCEPTION 'POS costing helper must remain private';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.stock_movements'::regclass
      AND tgname='stock_movement_no_pos_sale_reversal' AND NOT tgisinternal)
     OR NOT EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public' AND indexname='stock_movement_pos_sale_item_once')
     OR NOT EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public' AND indexname='stock_movement_batch_pos_sale_once') THEN
    RAISE EXCEPTION 'Normalized POS stock evidence or reversal guard is missing';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.stock_movements'::regclass
      AND conname='stock_movement_pos_item_fk' AND contype='f')
     OR NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.stock_movement_batches'::regclass
      AND conname='stock_movement_batch_pos_sale_fk' AND contype='f') THEN
    RAISE EXCEPTION 'Expected normalized sale foreign keys are missing';
  END IF;
END; $security$;

DO $capability$
DECLARE def text:=pg_get_functiondef('public.pos_checkout_complete(uuid,uuid,bigint,public.pos_sale_payment_method,numeric,text)'::regprocedure);
BEGIN
  IF to_regprocedure('public.pos_checkout_create(uuid)') IS NOT NULL
     OR to_regprocedure('public.pos_payment_record(uuid)') IS NOT NULL
     OR NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.inventory_cost_operation_requests'::regclass
       AND conname='inventory_cost_operation_requests_operation_key_check'
       AND pg_get_constraintdef(oid) LIKE '%POS_SALE%') THEN
    RAISE EXCEPTION 'Unexpected alternate writer or missing POS_SALE costing operation identity';
  END IF;
  IF def NOT ILIKE '%inventory_costing_outlet_authority%'
     OR def NOT ILIKE '%WAC_ACTIVE%' OR def NOT ILIKE '%POS_COSTING_NOT_ACTIVE%' THEN
    RAISE EXCEPTION 'Checkout is missing its fail-closed costing authority gate';
  END IF;
END; $capability$;

SELECT 'PASS: checkout grant boundary, private costing helper, normalized sale links, reversal guard, and WAC fail-closed gate verified' AS result;

BEGIN;
SET LOCAL statement_timeout='30s';
SET LOCAL lock_timeout='5s';
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
SET LOCAL ROLE authenticated;
DO $wac_gate$
DECLARE cart_id uuid; product_id uuid; revision bigint; response jsonb;
BEGIN
  IF EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE status='WAC_ACTIVE') THEN
    RAISE EXCEPTION 'The isolated source fixture must remain non-WAC_ACTIVE for the fail-closed test';
  END IF;
  SELECT id INTO STRICT product_id FROM public.products WHERE sku='STG-FULL-A';
  response:=public.pos_cart_create('f5000000-0000-4000-8000-000000000001'::uuid);
  cart_id:=(response->>'cart_id')::uuid;
  response:=public.pos_cart_add_item(cart_id,product_id,1,1,'f5000000-0000-4000-8000-000000000002'::uuid);
  revision:=(response->>'revision')::bigint;
  PERFORM set_config('quena.p1d_b.cart_id',cart_id::text,true);
  BEGIN
    PERFORM public.pos_checkout_complete('f5000000-0000-4000-8000-000000000003'::uuid,cart_id,revision,
      'CASH'::public.pos_sale_payment_method,1000,NULL);
    RAISE EXCEPTION 'checkout passed while costing authority was missing/inactive';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM<>'POS_COSTING_NOT_ACTIVE' THEN RAISE; END IF;
  END;
END; $wac_gate$;
RESET ROLE;
DO $rollback_check$
DECLARE cart_id uuid:=current_setting('quena.p1d_b.cart_id')::uuid;
BEGIN
  IF EXISTS(SELECT 1 FROM public.sales WHERE pos_cart_id=cart_id)
     OR (SELECT status FROM public.pos_carts WHERE id=cart_id)<>'ACTIVE' THEN
    RAISE EXCEPTION 'WAC-gated rejection left partial checkout evidence';
  END IF;
END; $rollback_check$;
ROLLBACK;
SELECT 'PASS: missing/inactive WAC rejects checkout with no sale or cart completion' AS result;

-- Successful end-to-end sale and the real generic reversal route. All rows,
-- including the temporary BOOTSTRAP_READY/WAC_ACTIVE authority, roll back.
BEGIN;
SET LOCAL statement_timeout='90s';
SET LOCAL lock_timeout='8s';
SELECT id AS outlet_id FROM public.outlets WHERE code='QUENA-MART-1' AND is_active \gset
SELECT id AS product_id FROM public.products WHERE sku='STG-BASE20' \gset
SELECT source_import_row_id AS hpp_source FROM public.product_costs
  WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_id'::uuid \gset
SELECT effective_quantity AS stock_before FROM public.stock_balance_projection
  WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_id'::uuid \gset
INSERT INTO public.product_field_audit_reviews(product_id,outlet_id,field_key,status,source_import_row_id,
  reviewer_id,evidence_notes,request_id)
VALUES(:'product_id'::uuid,:'outlet_id'::uuid,'hpp','SUDAH_DIVERIFIKASI',:'hpp_source'::uuid,
  'a0000000-0000-4000-8000-000000000001','P1D-B disposable valued checkout fixture',gen_random_uuid());
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT public.inventory_cost_bootstrap_outlet(:'outlet_id'::uuid,'f5000000-0000-4000-8000-000000000010'::uuid);
RESET ROLE;
UPDATE public.inventory_costing_outlet_authority SET status='WAC_ACTIVE',
  activated_by='a0000000-0000-4000-8000-000000000001',activated_at=now()
WHERE outlet_id=:'outlet_id'::uuid AND status='BOOTSTRAP_READY';
SELECT set_config('quena.p1d_b.outlet',:'outlet_id',true);
SELECT set_config('quena.p1d_b.product',:'product_id',true);
SELECT set_config('quena.p1d_b.stock_before',:'stock_before',true);
SELECT inventory_value::text AS cost_value_before,current_wac::text AS wac_before
  FROM public.inventory_cost_projections WHERE outlet_id=:'outlet_id'::uuid AND product_id=:'product_id'::uuid \gset
SELECT set_config('quena.p1d_b.cost_value_before',:'cost_value_before',true);
SELECT set_config('quena.p1d_b.wac_before',:'wac_before',true);
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
SET LOCAL ROLE authenticated;
DO $successful_checkout$
DECLARE cid uuid; revision bigint; added jsonb; result jsonb; replay jsonb; failure text; req uuid:='f5000000-0000-4000-8000-000000000011';
  product uuid:=current_setting('quena.p1d_b.product')::uuid;
BEGIN
  added:=public.pos_cart_create('f5000000-0000-4000-8000-000000000012'::uuid);
  cid:=(added->>'cart_id')::uuid;
  added:=public.pos_cart_add_item(cid,product,2,1,'f5000000-0000-4000-8000-000000000013'::uuid);
  revision:=(added->>'revision')::bigint;
  result:=public.pos_checkout_complete(req,cid,revision,'CASH',50000,NULL);
  IF result->>'sale_id' IS NULL OR result->>'sale_number' NOT LIKE 'QPOS-%'
    OR result->>'cashier_label' IS DISTINCT FROM 'Stage Kasir'
    OR result->>'cash_received_amount' IS NULL OR (result->>'change_amount')::numeric<0
    OR result ?| ARRAY['resolved_cogs_amount','current_wac','inventory_value','cost_status','source_layers','margin'] THEN
    RAISE EXCEPTION 'Checkout receipt response is missing commercial fields or exposes costing: %',result;
  END IF;
  replay:=public.pos_checkout_complete(req,cid,revision,'CASH',50000,NULL);
  IF replay IS DISTINCT FROM result THEN RAISE EXCEPTION 'same-request retry did not replay exact stored receipt'; END IF;
  failure:=NULL;
  BEGIN PERFORM public.pos_checkout_complete(req,cid,revision,'CASH',50001,NULL);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN failure:=SQLERRM; END;
  IF failure IS DISTINCT FROM 'POS_CHECKOUT_CONFLICT' THEN RAISE EXCEPTION 'changed same-request payload did not conflict: %',failure; END IF;
  failure:=NULL;
  BEGIN PERFORM public.pos_checkout_complete('f5000000-0000-4000-8000-000000000014'::uuid,cid,revision,'CASH',50000,NULL);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN failure:=SQLERRM; END;
  IF failure IS DISTINCT FROM 'POS_ALREADY_COMPLETED' THEN RAISE EXCEPTION 'second request against completed cart did not reject: %',failure; END IF;
  PERFORM set_config('quena.p1d_b.sale',result->>'sale_id',true);
  PERFORM set_config('quena.p1d_b.cart',cid::text,true);
  PERFORM set_config('quena.p1d_b.request',req::text,true);
END; $successful_checkout$;
RESET ROLE;
DO $successful_assertions$
DECLARE sale uuid:=current_setting('quena.p1d_b.sale')::uuid; cid uuid:=current_setting('quena.p1d_b.cart')::uuid;
  outlet uuid:=current_setting('quena.p1d_b.outlet')::uuid; product uuid:=current_setting('quena.p1d_b.product')::uuid;
  req uuid:=current_setting('quena.p1d_b.request')::uuid; sale_movement uuid; batch uuid; event public.inventory_cost_events%ROWTYPE;
  unit_cost numeric; value_after numeric; price numeric;
BEGIN
  SELECT current_wac,inventory_value INTO STRICT unit_cost,value_after FROM public.inventory_cost_projections
    WHERE outlet_id=outlet AND product_id=product;
  SELECT amount INTO STRICT price FROM public.product_selling_prices WHERE outlet_id=outlet AND product_id=product;
  IF (SELECT count(*) FROM public.sales WHERE id=sale AND status='COMPLETED' AND subtotal=round(2*price,2)
       AND grand_total=round(2*price,2))<>1
    OR (SELECT count(*) FROM public.sale_items WHERE sale_id=sale AND quantity=2 AND unit_selling_price=price)<>1
    OR (SELECT count(*) FROM public.sale_payments WHERE sale_id=sale AND method='CASH'
       AND applied_amount=round(2*price,2) AND received_amount=50000
       AND change_amount=50000-round(2*price,2))<>1
    OR (SELECT count(*) FROM public.stock_movement_batches WHERE pos_sale_id=sale AND pos_checkout_request_id=req)<>1
    OR (SELECT count(*) FROM public.stock_movements WHERE pos_sale_id=sale AND pos_checkout_request_id=req
       AND movement_type='SALE' AND source_system='QUENA_POS')<>1
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product)
       <>current_setting('quena.p1d_b.stock_before')::numeric-2
    OR (SELECT count(*) FROM public.stock_balance_projection_events WHERE request_id=req AND event_type='MOVEMENT_POSTED')<>1
    OR (SELECT count(*) FROM public.inventory_cost_event_batches WHERE operation_request_id=req AND batch_type='SALE_COGS')<>1
    OR (SELECT count(*) FROM public.inventory_cost_events WHERE operation_request_id=req AND event_type='SALE_COGS')<>1
    OR (SELECT count(*) FROM public.sale_item_cost_evidence WHERE sale_id=sale AND status='RESOLVED')<>1
    OR (SELECT count(*) FROM public.sale_item_cost_allocations WHERE sale_id=sale)<>1
    OR (SELECT status FROM public.pos_carts WHERE id=cid)<>'COMPLETED'
    OR (SELECT state FROM public.pos_checkout_requests WHERE request_id=req)<>'COMPLETED' THEN
    RAISE EXCEPTION 'Completed sale/payment/stock/cost/request evidence did not reconcile';
  END IF;
  SELECT id INTO STRICT sale_movement FROM public.stock_movements WHERE pos_sale_id=sale;
  SELECT id INTO STRICT batch FROM public.stock_movement_batches WHERE pos_sale_id=sale;
  SELECT * INTO STRICT event FROM public.inventory_cost_events WHERE operation_request_id=req AND event_type='SALE_COGS';
  IF event.inventory_value_delta<>-round(2*current_setting('quena.p1d_b.wac_before')::numeric,8)
    OR (SELECT resolved_cogs_amount FROM public.sale_item_cost_evidence WHERE sale_id=sale)<>abs(event.inventory_value_delta)
    OR value_after<>current_setting('quena.p1d_b.cost_value_before')::numeric+event.inventory_value_delta
    OR unit_cost<>current_setting('quena.p1d_b.wac_before')::numeric
    OR NOT EXISTS(SELECT 1 FROM public.stock_movements m JOIN public.sale_items si ON si.id=m.pos_sale_item_id
      JOIN public.sales s ON s.id=m.pos_sale_id AND s.checkout_request_id=m.pos_checkout_request_id
      JOIN public.stock_movement_batches b ON b.id=m.batch_id AND b.pos_sale_id=m.pos_sale_id
       AND b.pos_checkout_request_id=m.pos_checkout_request_id WHERE m.id=sale_movement AND b.id=batch) THEN
    RAISE EXCEPTION 'WAC/COGS math or normalized checkout linkage failed';
  END IF;
  PERFORM set_config('quena.p1d_b.sale_movement',sale_movement::text,true);
  PERFORM set_config('quena.p1d_b.stock_after',(SELECT effective_quantity::text FROM public.stock_balance_projection
    WHERE outlet_id=outlet AND product_id=product),true);
  PERFORM set_config('quena.p1d_b.value_after',(SELECT inventory_value::text FROM public.inventory_cost_projections
    WHERE outlet_id=outlet AND product_id=product),true);
END; $successful_assertions$;

-- Prove the installed trigger through the existing generic reversal route.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
DO $reversal_route$
DECLARE req uuid; result jsonb; denied text;
BEGIN
  req:=public.issue_stock_operation_intent('REVERSE_MOVEMENT',jsonb_build_object(
    'movement_id',current_setting('quena.p1d_b.sale_movement')::uuid,'reason','P1D-B staging generic reversal test'));
  denied:=NULL;
  BEGIN PERFORM public.apply_stock_operation_intent(req);
  EXCEPTION WHEN SQLSTATE '55000' THEN denied:=SQLERRM; END;
  IF denied IS DISTINCT FROM 'POS_COMPLETED_SALE_REVERSAL_FORBIDDEN' THEN
    RAISE EXCEPTION 'generic reversal route did not reject native POS SALE: %',denied;
  END IF;
END; $reversal_route$;
RESET ROLE;
DO $reversal_assertions$
DECLARE sale uuid:=current_setting('quena.p1d_b.sale')::uuid; movement uuid:=current_setting('quena.p1d_b.sale_movement')::uuid;
  outlet uuid:=current_setting('quena.p1d_b.outlet')::uuid; product uuid:=current_setting('quena.p1d_b.product')::uuid;
BEGIN
  IF (SELECT status FROM public.sales WHERE id=sale)<>'COMPLETED'
     OR (SELECT count(*) FROM public.sale_payments WHERE sale_id=sale)<>1
     OR (SELECT count(*) FROM public.stock_movements WHERE reverses_movement_id=movement)<>0
     OR (SELECT effective_quantity::text FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product)
        IS DISTINCT FROM current_setting('quena.p1d_b.stock_after')
     OR (SELECT inventory_value::text FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=product)
        IS DISTINCT FROM current_setting('quena.p1d_b.value_after')
     OR EXISTS(SELECT 1 FROM public.inventory_cost_events WHERE event_type='REVERSAL'
        AND reverses_stock_movement_id=movement) THEN RAISE EXCEPTION 'rejected generic reversal changed sale/payment/stock/cost'; END IF;
END; $reversal_assertions$;
COMMIT;
SELECT 'PASS: committed WAC_ACTIVE valued CASH checkout, idempotent replay/conflict behavior, normalized evidence, and real generic reversal rejection' AS result;

-- Disposable-clone-only failure injection. These triggers are installed and
-- removed in this test transaction; the runtime harness drops the clone.
BEGIN;
SELECT set_config('quena.p1d_b.outlet',:'outlet_id',true);
SELECT set_config('quena.p1d_b.product',:'product_id',true);
CREATE FUNCTION public.p1d_b_staging_failpoint() RETURNS trigger
  LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF current_setting('quena.p1d_b.failpoint',true)=TG_ARGV[0] THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STAGING_POS_FAIL:'||TG_ARGV[0];
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER p1d_b_fail_sale AFTER INSERT ON public.sales
  FOR EACH ROW EXECUTE FUNCTION public.p1d_b_staging_failpoint('A_SALE');
CREATE TRIGGER p1d_b_fail_items AFTER INSERT ON public.sale_items
  FOR EACH ROW EXECUTE FUNCTION public.p1d_b_staging_failpoint('B_ITEMS');
CREATE TRIGGER p1d_b_fail_payment AFTER INSERT ON public.sale_payments
  FOR EACH ROW EXECUTE FUNCTION public.p1d_b_staging_failpoint('C_PAYMENT');
CREATE TRIGGER p1d_b_fail_movement AFTER INSERT ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.p1d_b_staging_failpoint('D_MOVEMENT');
CREATE TRIGGER p1d_b_fail_projection AFTER UPDATE ON public.stock_balance_projection
  FOR EACH ROW EXECUTE FUNCTION public.p1d_b_staging_failpoint('E_PROJECTION');
CREATE TRIGGER p1d_b_fail_layer_allocation AFTER INSERT ON public.inventory_cost_layer_allocations
  FOR EACH ROW WHEN (NEW.allocation_kind IN ('OUTFLOW_UNVALUED','OUTFLOW_VALUED'))
  EXECUTE FUNCTION public.p1d_b_staging_failpoint('F_LAYER');
CREATE TRIGGER p1d_b_fail_cost_evidence AFTER INSERT ON public.sale_item_cost_evidence
  FOR EACH ROW EXECUTE FUNCTION public.p1d_b_staging_failpoint('G_COST_EVIDENCE');
CREATE TRIGGER p1d_b_fail_cart AFTER UPDATE ON public.pos_carts
  FOR EACH ROW WHEN (NEW.status='COMPLETED')
  EXECUTE FUNCTION public.p1d_b_staging_failpoint('H_CART');

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
DO $failure_atomicity$
DECLARE cart_id uuid; v_product_id uuid:=current_setting('quena.p1d_b.product')::uuid;
  v_outlet_id uuid:=current_setting('quena.p1d_b.outlet')::uuid;
  rev bigint; result jsonb; stage text; req uuid; failure text; failed boolean;
  stock_before numeric; value_before numeric; version_before bigint; layer_alloc_before bigint;
  layers_before jsonb;
BEGIN
  result:=public.pos_cart_create(gen_random_uuid()); cart_id:=(result->>'cart_id')::uuid;
  result:=public.pos_cart_add_item(cart_id,v_product_id,1,1,gen_random_uuid()); rev:=(result->>'revision')::bigint;
  SELECT effective_quantity INTO STRICT stock_before FROM public.stock_balance_projection
    WHERE outlet_id=v_outlet_id AND product_id=v_product_id;
  SELECT inventory_value,cost_version INTO STRICT value_before,version_before FROM public.inventory_cost_projections
    WHERE outlet_id=v_outlet_id AND product_id=v_product_id;
  SELECT count(*) INTO layer_alloc_before FROM public.inventory_cost_layer_allocations;
  SELECT jsonb_agg(jsonb_build_array(b.layer_id,b.remaining_valued_quantity,b.remaining_provisional_quantity,
    b.remaining_unvalued_quantity,b.last_cost_version) ORDER BY b.layer_id) INTO layers_before
    FROM public.inventory_cost_source_layer_balances b WHERE b.outlet_id=v_outlet_id AND b.product_id=v_product_id;
  FOREACH stage IN ARRAY ARRAY['A_SALE','B_ITEMS','C_PAYMENT','D_MOVEMENT','E_PROJECTION','F_LAYER','G_COST_EVIDENCE','H_CART'] LOOP
    req:=gen_random_uuid(); failed:=false; failure:=NULL;
    PERFORM set_config('quena.p1d_b.failpoint',stage,true);
    BEGIN
      PERFORM public.pos_checkout_complete(req,cart_id,rev,'CASH',50000,NULL);
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
      failure:=SQLERRM; failed:=failure='STAGING_POS_FAIL:'||stage;
      IF NOT failed THEN RAISE; END IF;
    END;
    PERFORM set_config('quena.p1d_b.failpoint','',true);
    IF NOT failed OR EXISTS(SELECT 1 FROM public.sales WHERE pos_cart_id=cart_id)
      OR EXISTS(SELECT 1 FROM public.sale_items WHERE pos_cart_id=cart_id)
      OR EXISTS(SELECT 1 FROM public.sale_payments p JOIN public.sales s ON s.id=p.sale_id WHERE s.pos_cart_id=cart_id)
      OR EXISTS(SELECT 1 FROM public.stock_movement_batches WHERE pos_sale_id IN(SELECT id FROM public.sales WHERE pos_cart_id=cart_id))
      OR (SELECT effective_quantity FROM public.stock_balance_projection
        WHERE outlet_id=v_outlet_id AND product_id=v_product_id)<>stock_before
      OR (SELECT inventory_value FROM public.inventory_cost_projections
        WHERE outlet_id=v_outlet_id AND product_id=v_product_id)<>value_before
      OR (SELECT cost_version FROM public.inventory_cost_projections
        WHERE outlet_id=v_outlet_id AND product_id=v_product_id)<>version_before
      OR (SELECT count(*) FROM public.inventory_cost_layer_allocations)<>layer_alloc_before
      OR (SELECT jsonb_agg(jsonb_build_array(b.layer_id,b.remaining_valued_quantity,b.remaining_provisional_quantity,
        b.remaining_unvalued_quantity,b.last_cost_version) ORDER BY b.layer_id) FROM public.inventory_cost_source_layer_balances b
        WHERE b.outlet_id=v_outlet_id AND b.product_id=v_product_id) IS DISTINCT FROM layers_before
      OR EXISTS(SELECT 1 FROM public.inventory_cost_events WHERE operation_request_id=req)
      OR EXISTS(SELECT 1 FROM public.sale_item_cost_evidence WHERE checkout_request_id=req)
      OR (SELECT status FROM public.pos_carts WHERE id=cart_id)<>'ACTIVE'
      OR EXISTS(SELECT 1 FROM public.pos_checkout_requests WHERE request_id=req) THEN
      RAISE EXCEPTION 'Failure injection % did not roll back every business effect: %',stage,failure;
    END IF;
    RAISE NOTICE 'PASS: rollback injection %',stage;
  END LOOP;
END; $failure_atomicity$;

DROP TRIGGER p1d_b_fail_sale ON public.sales;
DROP TRIGGER p1d_b_fail_items ON public.sale_items;
DROP TRIGGER p1d_b_fail_payment ON public.sale_payments;
DROP TRIGGER p1d_b_fail_movement ON public.stock_movements;
DROP TRIGGER p1d_b_fail_projection ON public.stock_balance_projection;
DROP TRIGGER p1d_b_fail_layer_allocation ON public.inventory_cost_layer_allocations;
DROP TRIGGER p1d_b_fail_cost_evidence ON public.sale_item_cost_evidence;
DROP TRIGGER p1d_b_fail_cart ON public.pos_carts;
DROP FUNCTION public.p1d_b_staging_failpoint();
COMMIT;
SELECT 'PASS: failure injection A-H left no partial checkout state' AS result;
