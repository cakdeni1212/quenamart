\set ON_ERROR_STOP on
SELECT id outlet_id FROM public.outlets WHERE code='QUENA-MART-1' \gset
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false);
INSERT INTO auth.users(id) VALUES('a0000000-0000-4000-8000-000000000002') ON CONFLICT DO NOTHING;
INSERT INTO public.profiles(id,full_name,role,is_active) VALUES('a0000000-0000-4000-8000-000000000002','Stage Admin','ADMIN',true)
ON CONFLICT(id) DO UPDATE SET role='ADMIN',is_active=true;
SELECT gen_random_uuid()::text activation_request \gset
SELECT set_config('quena.test.activation_request', :'activation_request',false);
SELECT set_config('quena.test.outlet', :'outlet_id',false);
DO $activation_guards$
DECLARE o uuid:=current_setting('quena.test.outlet')::uuid;r uuid:=current_setting('quena.test.activation_request')::uuid;
  h uuid:=(SELECT id FROM public.inventory_cost_hpp_acceptance_batches WHERE outlet_id=current_setting('quena.test.outlet')::uuid AND status='APPROVED');
  msg text;failed boolean;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',false);failed:=false;
  BEGIN PERFORM public.inventory_cost_activate_wac(o,gen_random_uuid(),'ACTIVATE-WAC:'||o||':'||gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR msg<>'GO_LIVE_OWNER_REQUIRED' THEN RAISE EXCEPTION 'ADMIN was allowed to activate WAC: %',msg; END IF;
  failed:=false;
  BEGIN PERFORM public.inventory_cost_bootstrap_outlet(o,h,gen_random_uuid(),'COSTING-BOOTSTRAP:'||o||':'||h||':'||gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR msg<>'GO_LIVE_OWNER_REQUIRED' THEN RAISE EXCEPTION 'ADMIN was allowed to bootstrap: %',msg; END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false);failed:=false;
  BEGIN PERFORM public.inventory_cost_activate_wac(o,r,'WRONG');
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR msg<>'GO_LIVE_WAC_CONFIRMATION_REQUIRED' OR EXISTS(SELECT 1 FROM public.go_live_wac_activation_confirmation WHERE request_id=r) THEN
    RAISE EXCEPTION 'Wrong WAC confirmation was not rejected without evidence'; END IF;
END $activation_guards$;
-- Force a staging-only projection inconsistency in a subtransaction and prove activation rejects it.
DO $reconciliation_guard$
DECLARE o uuid:=current_setting('quena.test.outlet')::uuid;r uuid:=current_setting('quena.test.activation_request')::uuid;
  product uuid;msg text;failed boolean:=false;
BEGIN
  SELECT p.product_id INTO product FROM public.inventory_cost_projections p JOIN public.products pr ON pr.id=p.product_id
    WHERE p.outlet_id=o AND pr.sku='CUTOVER-DECIMAL';
  BEGIN
    UPDATE public.inventory_cost_projections SET inventory_value=inventory_value+1, current_wac=round((inventory_value+1)/valued_quantity,8) WHERE outlet_id=o AND product_id=product;
    PERFORM public.inventory_cost_activate_wac(o,r,'ACTIVATE-WAC:'||o||':'||r);
    RAISE EXCEPTION 'WAC accepted a mismatched value';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR msg<>'GO_LIVE_COSTING_RECONCILIATION_FAILED'
    OR EXISTS(SELECT 1 FROM public.go_live_wac_activation_confirmation WHERE request_id=r)
    OR (SELECT status FROM public.inventory_costing_outlet_authority WHERE outlet_id=o)<>'BOOTSTRAP_READY' THEN
    RAISE EXCEPTION 'Reconciliation failure did not block/rollback activation: %',msg; END IF;
END $reconciliation_guard$;
-- A forced failure after the immutable activation request insert must roll
-- the evidence and authority transition back as one statement.
CREATE FUNCTION public.quena_go_live_fail_wac_activation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status='WAC_ACTIVE' AND OLD.status='BOOTSTRAP_READY' THEN
    RAISE EXCEPTION USING MESSAGE='GO_LIVE_TEST_INJECTED_WAC_ACTIVATION_FAILURE';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER quena_go_live_fail_wac_activation BEFORE UPDATE OF status ON public.inventory_costing_outlet_authority
  FOR EACH ROW EXECUTE FUNCTION public.quena_go_live_fail_wac_activation();
DO $activation_failure_rollback$
DECLARE o uuid:=current_setting('quena.test.outlet')::uuid;r uuid:=gen_random_uuid();
  msg text;failed boolean:=false;
BEGIN
  BEGIN PERFORM public.inventory_cost_activate_wac(o,r,'ACTIVATE-WAC:'||o||':'||r);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR msg<>'GO_LIVE_TEST_INJECTED_WAC_ACTIVATION_FAILURE'
    OR EXISTS(SELECT 1 FROM public.go_live_wac_activation_confirmation WHERE request_id=r)
    OR (SELECT status FROM public.inventory_costing_outlet_authority WHERE outlet_id=o)<>'BOOTSTRAP_READY' THEN
    RAISE EXCEPTION 'Injected activation failure left partial state: %',msg; END IF;
END $activation_failure_rollback$;
DROP TRIGGER quena_go_live_fail_wac_activation ON public.inventory_costing_outlet_authority;
DROP FUNCTION public.quena_go_live_fail_wac_activation();
DO $anonymous_grants$
BEGIN
  IF has_function_privilege('anon','public.inventory_cost_bootstrap_outlet(uuid,uuid,uuid,text)','EXECUTE')
    OR has_function_privilege('anon','public.inventory_cost_activate_wac(uuid,uuid,text)','EXECUTE')
    OR has_function_privilege('anon','public.inventory_cost_hpp_invalidate_prepared(uuid,uuid,text)','EXECUTE')
    OR has_function_privilege('anon','public.go_live_reset_preparation(uuid,uuid,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'Anonymous execution is granted for an operator go-live contract';
  END IF;
END $anonymous_grants$;
SELECT 'OWNER_ROLE_CONFIRMATION_AND_RECONCILIATION_GATES_PASS' AS result;
