\set ON_ERROR_STOP on
SELECT id outlet_id FROM public.outlets WHERE code='QUENA-MART-1' \gset
SELECT id hpp_batch FROM public.inventory_cost_hpp_acceptance_batches WHERE status='CONSUMED' \gset
INSERT INTO auth.users(id) VALUES
 ('a0000000-0000-4000-8000-000000000003'),('a0000000-0000-4000-8000-000000000004') ON CONFLICT DO NOTHING;
INSERT INTO public.profiles(id,full_name,role,is_active) VALUES
 ('a0000000-0000-4000-8000-000000000003','Stage Kasir','KASIR',true),
 ('a0000000-0000-4000-8000-000000000004','Stage Gudang','GUDANG',true)
ON CONFLICT(id) DO UPDATE SET full_name=EXCLUDED.full_name,role=EXCLUDED.role,is_active=true;
SELECT set_config('quena.test.outlet',:'outlet_id',false);
SELECT set_config('quena.test.hpp_batch',:'hpp_batch',false);
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',false);
SET ROLE authenticated;
DO $role_and_replay_checks$
DECLARE o uuid:=current_setting('quena.test.outlet')::uuid;h uuid:=current_setting('quena.test.hpp_batch')::uuid;
  msg text;failed boolean;request_id uuid:='f4300000-0000-4000-8000-000000000101';request_two uuid;response jsonb;result jsonb;
BEGIN
  failed:=false;
  BEGIN PERFORM public.inventory_cost_bootstrap_outlet(o,h,gen_random_uuid(),'COSTING-BOOTSTRAP:'||o||':'||h||':'||gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR msg<>'GO_LIVE_OWNER_REQUIRED' THEN RAISE EXCEPTION 'KASIR bootstrap permission failed: %',msg; END IF;
  failed:=false;
  BEGIN PERFORM public.inventory_cost_hpp_invalidate_prepared(h,gen_random_uuid(),'Kasir cannot invalidate');
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR msg<>'GO_LIVE_OWNER_REQUIRED' THEN RAISE EXCEPTION 'KASIR was allowed to invalidate HPP: %',msg; END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',false);failed:=false;
  BEGIN PERFORM public.inventory_cost_activate_wac(o,gen_random_uuid(),'ACTIVATE-WAC:'||o||':'||gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR msg<>'GO_LIVE_OWNER_REQUIRED' THEN RAISE EXCEPTION 'GUDANG WAC permission failed: %',msg; END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false);
  response:=public.inventory_cost_activate_wac(o,request_id,'ACTIVATE-WAC:'||o||':'||request_id);
  IF response->>'code'<>'WAC_ACTIVE' THEN RAISE EXCEPTION 'activation replay did not return stored result'; END IF;
  failed:=false;
  BEGIN UPDATE public.inventory_costing_outlet_authority SET status='REFERENCE_ONLY' WHERE outlet_id=o;
  EXCEPTION WHEN insufficient_privilege THEN failed:=true;END;
  IF NOT failed THEN RAISE EXCEPTION 'Authenticated direct costing authority update was allowed'; END IF;
  failed:=false;request_two:=gen_random_uuid();
  BEGIN PERFORM public.inventory_cost_activate_wac(o,request_two,'ACTIVATE-WAC:'||o||':'||request_two);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR msg<>'GO_LIVE_BOOTSTRAP_READY_REQUIRED' THEN RAISE EXCEPTION 'Second activation was not rejected: %',msg; END IF;
END $role_and_replay_checks$;
RESET ROLE;
-- Cashier completes one small actual staging sale against approved WAC state.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',false);
-- Mirror the normalized inventory row created by the final iPos import. The
-- source identity comes from the valid final normalization row in this fixture.
INSERT INTO public.product_inventory(product_id,outlet_id,quantity,source_import_row_id,created_by,updated_by)
SELECT p.id,sp.outlet_id,1.250,sp.source_import_row_id,'a0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001'
FROM public.products p JOIN public.product_selling_prices sp ON sp.product_id=p.id
WHERE p.sku='CUTOVER-DECIMAL'
ON CONFLICT(product_id,outlet_id) DO UPDATE SET quantity=EXCLUDED.quantity,
  source_import_row_id=EXCLUDED.source_import_row_id,updated_by=EXCLUDED.updated_by;
SET ROLE authenticated;
DO $pos_end_to_end$
DECLARE cart_result jsonb;item_result jsonb;checkout_result jsonb;receipt jsonb;history jsonb;dashboard jsonb;
  cart uuid;product uuid;revision bigint;sale uuid;before_stock numeric;before_value numeric;before_wac numeric;
  req uuid:='f4300000-0000-4000-8000-000000000010';today_business date:=timezone('Asia/Jakarta',now())::date;
BEGIN
  SELECT id INTO product FROM public.products WHERE sku='CUTOVER-DECIMAL';
  SELECT effective_quantity INTO before_stock FROM public.stock_balance_projection WHERE outlet_id=current_setting('quena.test.outlet')::uuid AND product_id=product;
  SELECT inventory_value,current_wac INTO before_value,before_wac FROM public.inventory_cost_projections WHERE outlet_id=current_setting('quena.test.outlet')::uuid AND product_id=product;
  cart_result:=public.pos_cart_create(gen_random_uuid());cart:=(cart_result->>'cart_id')::uuid;
  item_result:=public.pos_cart_add_item(cart,product,0.250,(cart_result->>'revision')::bigint,gen_random_uuid());
  revision:=(item_result->>'revision')::bigint;
  checkout_result:=public.pos_checkout_complete(req,cart,revision,'CASH',125,NULL);
  sale:=(checkout_result->>'sale_id')::uuid;
  IF checkout_result->>'cashier_label'<>'Stage Kasir' OR (checkout_result->>'grand_total')::numeric<>125
    OR (checkout_result->>'cash_received_amount')::numeric<>125 OR (checkout_result->>'change_amount')::numeric<>0
    OR checkout_result ?| ARRAY['resolved_cogs_amount','wac','current_wac','inventory_value','cogs','source_layers','margin','profit'] THEN
    RAISE EXCEPTION 'Checkout receipt response wrong or cost leaked: %',checkout_result; END IF;
  receipt:=public.pos_sale_receipt_read(sale);
  history:=public.pos_sales_history_read(today_business,today_business,NULL,NULL,1);
  IF receipt IS NULL OR receipt->>'sale_number' IS DISTINCT FROM checkout_result->>'sale_number'
    OR receipt ?| ARRAY['hpp','wac','cogs','margin','profit','source_layers','inventory_value']
    OR (history->>'totalCount')::integer<1 THEN RAISE EXCEPTION 'Bounded receipt/history failed: % %',receipt,history; END IF;
  IF (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=current_setting('quena.test.outlet')::uuid AND product_id=product)<>before_stock-0.250
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=current_setting('quena.test.outlet')::uuid AND product_id=product)<>before_value-25
    OR (SELECT current_wac FROM public.inventory_cost_projections WHERE outlet_id=current_setting('quena.test.outlet')::uuid AND product_id=product)<>before_wac
    THEN
    RAISE EXCEPTION 'Sale stock/WAC/COGS evidence incorrect'; END IF;
  PERFORM set_config('quena.test.sale_id',sale::text,false);
  PERFORM set_config('quena.test.sale_number',checkout_result->>'sale_number',false);
END $pos_end_to_end$;
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false);
SET ROLE authenticated;
DO $dashboard_assertion$
DECLARE result jsonb:=public.owner_dashboard_read(7);today_business date:=timezone('Asia/Jakarta',now())::date;
BEGIN
  IF (result->'sales'->>'today_count')::integer<1 OR (result->'sales'->>'today_total')::numeric<125
    OR result->'profit'->>'status'<>'RESOLVED' OR result->'profit'->>'gross_profit' IS NULL
    OR (SELECT count(*) FROM public.go_live_wac_activation_confirmation WHERE outlet_id=current_setting('quena.test.outlet')::uuid)<>1 THEN
    RAISE EXCEPTION 'Post-activation dashboard did not read actual sale/known COGS: %',result; END IF;
END $dashboard_assertion$;
DO $consumed_hpp_invalidation_denial$
DECLARE batch_id uuid:=(SELECT id FROM public.inventory_cost_hpp_acceptance_batches
  WHERE outlet_id=(SELECT id FROM public.outlets WHERE code='QUENA-MART-1') AND status='CONSUMED');
  message text;failed boolean:=false;
BEGIN
  BEGIN PERFORM public.inventory_cost_hpp_invalidate_prepared(batch_id,gen_random_uuid(),'Must remain immutable after bootstrap');
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS message=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR message<>'GO_LIVE_HPP_BATCH_NOT_INVALIDATABLE'
    OR (SELECT status FROM public.inventory_cost_hpp_acceptance_batches WHERE id=batch_id)<>'CONSUMED' THEN
    RAISE EXCEPTION 'Consumed HPP batch was invalidated: %',message; END IF;
END $consumed_hpp_invalidation_denial$;
RESET ROLE;
SELECT 'WAC_ACTIVE_POS_RECEIPT_HISTORY_DASHBOARD_E2E_PASS' AS result;
