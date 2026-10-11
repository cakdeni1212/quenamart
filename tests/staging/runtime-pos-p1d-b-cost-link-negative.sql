\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database() NOT LIKE 'quena_p1d_b_staging_%'
     OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
     OR inet_server_port()<>55432 OR current_setting('server_version_num')::integer/10000<>15
     OR to_regprocedure('public.guard_pos_sale_cost_event()') IS NULL THEN
    RAISE EXCEPTION 'Refusing cost-link negative tests outside P1D-B disposable local staging';
  END IF;
END; $guard$;
BEGIN;
CREATE TEMP TABLE p1d_b_invalid_link_movements(non_sale uuid NOT NULL);
DO $movement_fixture$
DECLARE e public.inventory_cost_events%ROWTYPE; period public.stock_authority_periods%ROWTYPE;
  req uuid:=gen_random_uuid(); batch uuid; movement uuid:=gen_random_uuid(); stock numeric;
BEGIN
  SELECT * INTO STRICT e FROM public.inventory_cost_events WHERE event_type='SALE_COGS' ORDER BY created_at DESC LIMIT 1;
  SELECT * INTO STRICT period FROM public.stock_authority_periods WHERE outlet_id=e.outlet_id AND ended_at IS NULL;
  SELECT effective_quantity INTO STRICT stock FROM public.stock_balance_projection
    WHERE outlet_id=e.outlet_id AND product_id=e.product_id;
  INSERT INTO public.stock_operation_requests(request_id,actor_id,operation_key,target_key,request_payload,payload_hash)
    VALUES(req,'a0000000-0000-4000-8000-000000000001','P1D_NEGATIVE_FIXTURE',gen_random_uuid()::text,'{}'::jsonb,md5(req::text));
  INSERT INTO public.stock_movement_batches(authority_period_id,outlet_id,source_system,operation_request_id,created_by)
    VALUES(period.id,e.outlet_id,'MANUAL',req,'a0000000-0000-4000-8000-000000000001') RETURNING id INTO batch;
  INSERT INTO public.stock_movements(id,batch_id,authority_period_id,outlet_id,product_id,movement_type,source_system,
    quantity_delta,balance_before,balance_after,source_reference,source_event_key,created_by)
  VALUES(movement,batch,period.id,e.outlet_id,e.product_id,'MANUAL_OUT','MANUAL',-0.001,greatest(stock,0.001),greatest(stock,0.001)-0.001,
    'temporary negative-link fixture','P1D-NEGATIVE-'||req,'a0000000-0000-4000-8000-000000000001');
  INSERT INTO p1d_b_invalid_link_movements VALUES(movement);
END; $movement_fixture$;
CREATE FUNCTION public.p1d_b_expect_bad_cost_event(p_label text,p_patch jsonb,p_expected text)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE e public.inventory_cost_events%ROWTYPE; payload jsonb; caught text;
BEGIN
  SELECT * INTO STRICT e FROM public.inventory_cost_events
    WHERE event_type='SALE_COGS' AND source_entity_type='POS_SALE_ITEM'
    ORDER BY created_at DESC LIMIT 1;
  payload:=to_jsonb(e)||p_patch||jsonb_build_object('id',gen_random_uuid());
  caught:=NULL;
  BEGIN
    INSERT INTO public.inventory_cost_events
    SELECT (jsonb_populate_record(NULL::public.inventory_cost_events,payload)).*;
  EXCEPTION WHEN OTHERS THEN caught:=SQLERRM;
  END;
  IF caught IS NULL OR caught NOT LIKE p_expected THEN
    RAISE EXCEPTION 'negative case % expected %, got %',p_label,p_expected,coalesce(caught,'accepted');
  END IF;
  RAISE NOTICE 'PASS: malformed cost event rejected: % (%).',p_label,caught;
END; $$;

SELECT public.p1d_b_expect_bad_cost_event('A missing movement',jsonb_build_object(
  'stock_movement_id',NULL,'source_stock_movement_id',NULL),'POS SALE_COGS linkage shape is invalid');
SELECT public.p1d_b_expect_bad_cost_event('B missing stock request',jsonb_build_object(
  'stock_request_id',NULL),'POS SALE_COGS linkage shape is invalid');
SELECT public.p1d_b_expect_bad_cost_event('C receipt identity on POS event',jsonb_build_object(
  'receipt_id',gen_random_uuid()),'POS SALE_COGS linkage shape is invalid');

SELECT public.p1d_b_expect_bad_cost_event('D non-SALE movement',jsonb_build_object(
  'stock_movement_id',(SELECT non_sale FROM p1d_b_invalid_link_movements),
  'source_stock_movement_id',(SELECT non_sale FROM p1d_b_invalid_link_movements),
  'source_event_id',(SELECT non_sale FROM p1d_b_invalid_link_movements)),
  'POS SALE_COGS event does not match completed sale evidence');

SELECT public.p1d_b_expect_bad_cost_event('F mismatched outlet',jsonb_build_object(
  'outlet_id',(SELECT id FROM public.outlets WHERE id<>(SELECT outlet_id FROM public.inventory_cost_events
    WHERE event_type='SALE_COGS' ORDER BY created_at DESC LIMIT 1) ORDER BY id LIMIT 1)),
  'POS SALE_COGS event does not match completed sale evidence');
SELECT public.p1d_b_expect_bad_cost_event('G mismatched product',jsonb_build_object(
  'product_id',(SELECT id FROM public.products WHERE id<>(SELECT product_id FROM public.inventory_cost_events
    WHERE event_type='SALE_COGS' ORDER BY created_at DESC LIMIT 1) ORDER BY id LIMIT 1)),
  'POS SALE_COGS event does not match completed sale evidence');
SELECT public.p1d_b_expect_bad_cost_event('H mismatched sale item',jsonb_build_object(
  'source_entity_id',gen_random_uuid()),'POS SALE_COGS event does not match completed sale evidence');
SELECT public.p1d_b_expect_bad_cost_event('I mismatched checkout/cost request',jsonb_build_object(
  'operation_request_id',(SELECT request_id FROM public.inventory_cost_operation_requests
    WHERE operation_key<>'POS_SALE' ORDER BY created_at LIMIT 1)),
  'POS SALE_COGS event does not match completed sale evidence');

DO $receipt_shape$
DECLARE e public.inventory_cost_events%ROWTYPE; payload jsonb; caught text;
BEGIN
  SELECT * INTO STRICT e FROM public.inventory_cost_events ORDER BY created_at DESC LIMIT 1;
  payload:=to_jsonb(e)||jsonb_build_object('id',gen_random_uuid(),'event_type','PURCHASE_RECEIPT',
    'source_entity_type','PURCHASE_RECEIPT','source_entity_id',gen_random_uuid(),
    'receipt_id',NULL,'receipt_item_id',NULL,'stock_movement_id',NULL,'stock_request_id',NULL);
  caught:=NULL;
  BEGIN INSERT INTO public.inventory_cost_events SELECT (jsonb_populate_record(NULL::public.inventory_cost_events,payload)).*;
  EXCEPTION WHEN check_violation THEN caught:=SQLERRM; END;
  IF caught IS NULL OR caught NOT LIKE '%inventory_cost_event_projection_state_valid%' THEN
    RAISE EXCEPTION 'receipt with missing identity was not rejected by the explicit shape constraint: %',coalesce(caught,'accepted');
  END IF;
  payload:=payload||jsonb_build_object('stock_movement_id',e.stock_movement_id,'stock_request_id',e.stock_request_id);
  caught:=NULL;
  BEGIN INSERT INTO public.inventory_cost_events SELECT (jsonb_populate_record(NULL::public.inventory_cost_events,payload)).*;
  EXCEPTION WHEN check_violation THEN caught:=SQLERRM; END;
  IF caught IS NULL OR caught NOT LIKE '%inventory_cost_event_projection_state_valid%' THEN
    RAISE EXCEPTION 'receipt masquerading with POS-like links was not rejected: %',coalesce(caught,'accepted');
  END IF;
  RAISE NOTICE 'PASS: incomplete and POS-like purchase receipt evidence rejected';
END; $receipt_shape$;

DO $nonpos_sale$
DECLARE period public.stock_authority_periods%ROWTYPE; req uuid:=gen_random_uuid(); batch uuid; caught text;
  outlet uuid; product uuid; actor uuid:='a0000000-0000-4000-8000-000000000001';
BEGIN
  SELECT s.outlet_id,s.product_id INTO STRICT outlet,product FROM public.inventory_cost_events s
    WHERE s.event_type='SALE_COGS' ORDER BY s.created_at DESC LIMIT 1;
  SELECT * INTO STRICT period FROM public.stock_authority_periods WHERE outlet_id=outlet AND ended_at IS NULL;
  INSERT INTO public.stock_operation_requests(request_id,actor_id,operation_key,target_key,request_payload,payload_hash)
    VALUES(req,actor,'P1D_NEGATIVE_FIXTURE',gen_random_uuid()::text,'{}'::jsonb,md5(req::text));
  INSERT INTO public.stock_movement_batches(authority_period_id,outlet_id,source_system,operation_request_id,created_by)
    VALUES(period.id,outlet,'MANUAL',req,actor) RETURNING id INTO batch;
  caught:=NULL;
  BEGIN
    INSERT INTO public.stock_movements(batch_id,authority_period_id,outlet_id,product_id,movement_type,source_system,
      quantity_delta,balance_before,balance_after,source_event_key,created_by)
    VALUES(batch,period.id,outlet,product,'SALE','MANUAL',-0.001,1,0.999,'P1D-NONPOS-SALE-'||req,actor);
  EXCEPTION WHEN check_violation THEN caught:=SQLERRM; END;
  IF caught IS NULL OR caught NOT LIKE '%stock_movement_reason_source_valid%' THEN
    RAISE EXCEPTION 'stock ledger accepted non-QUENA_POS SALE movement: %',coalesce(caught,'accepted');
  END IF;
  RAISE NOTICE 'PASS: stock ledger rejects a non-QUENA_POS SALE movement before it can be used by SALE_COGS';
END; $nonpos_sale$;

DO $arbitrary_link$
DECLARE e public.inventory_cost_events%ROWTYPE; payload jsonb; caught text;
BEGIN
  SELECT * INTO STRICT e FROM public.inventory_cost_events WHERE event_type='SALE_COGS' ORDER BY created_at DESC LIMIT 1;
  payload:=to_jsonb(e)||jsonb_build_object('id',gen_random_uuid(),'event_type','CORRECTION',
    'source_entity_type','UNRELATED_TEST','receipt_id',NULL,'receipt_item_id',NULL,
    'stock_movement_id',e.stock_movement_id,'stock_request_id',e.stock_request_id);
  caught:=NULL;
  BEGIN INSERT INTO public.inventory_cost_events SELECT (jsonb_populate_record(NULL::public.inventory_cost_events,payload)).*;
  EXCEPTION WHEN check_violation THEN caught:=SQLERRM; END;
  IF caught IS NULL OR caught NOT LIKE '%inventory_cost_event_projection_state_valid%' THEN
    RAISE EXCEPTION 'non-POS event accepted arbitrary POS stock links: %',coalesce(caught,'accepted');
  END IF;
  RAISE NOTICE 'PASS: non-POS event with arbitrary stock links rejected';
END; $arbitrary_link$;

DROP FUNCTION public.p1d_b_expect_bad_cost_event(text,jsonb,text);
ROLLBACK;
SELECT 'PASS: malformed POS A-I and receipt/non-POS linkage constraints rejected without persistent state' AS result;
