\set ON_ERROR_STOP on
BEGIN;
DO $$ BEGIN
  IF current_setting('server_version_num')::integer/10000<>15 OR current_database()<>'quena_member_loyalty_runtime' THEN
    RAISE EXCEPTION 'Loyalty policy runtime requires disposable PostgreSQL 15';
  END IF;
END $$;
INSERT INTO auth.users(id) VALUES ('10000000-0000-4000-8000-000000000005') ON CONFLICT DO NOTHING;
INSERT INTO public.outlets(id,name) VALUES('20000000-0000-4000-8000-000000000002','Loyalty Runtime Outlet');
INSERT INTO public.stock_authority_periods(outlet_id,started_at) VALUES('20000000-0000-4000-8000-000000000002',now());
SELECT set_config('quena.test.actor','10000000-0000-4000-8000-000000000005',true);
SELECT set_config('quena.test.role','OWNER',true);
DO $$ DECLARE result jsonb; policy jsonb; BEGIN
  policy:=public.member_loyalty_settings_read();
  IF (policy->>'program_enabled')::boolean OR (policy->>'redeem_enabled')::boolean
    OR policy->>'rupiah_per_point' IS NOT NULL THEN RAISE EXCEPTION 'Fresh loyalty settings must be OFF and unconfigured'; END IF;
  result:=public.member_loyalty_settings_update('{"program_enabled":true,"rupiah_per_point":"10000","redeem_enabled":true,"rupiah_per_redeem_point":"100","minimum_redeem_points":"100"}'::jsonb);
  IF result->>'updated'<>'true' OR jsonb_array_length(result->'changed_fields')<>5 THEN RAISE EXCEPTION 'Settings update/audit fields missing'; END IF;
  PERFORM public.member_loyalty_settings_update('{"program_enabled":true,"rupiah_per_point":"10000","redeem_enabled":true,"rupiah_per_redeem_point":"100","minimum_redeem_points":"100"}'::jsonb);
  IF (SELECT count(*) FROM public.outlet_settings_events WHERE event_type='LOYALTY_SETTINGS_UPDATED')<>1 THEN RAISE EXCEPTION 'No-op setting save created an audit event'; END IF;
END $$;
SELECT set_config('quena.test.role','OWNER',true);
DO $$ DECLARE m jsonb; selected jsonb; applied jsonb; replay jsonb; v_member uuid; req uuid:=gen_random_uuid(); BEGIN
  m:=public.member_upsert(NULL,'Member Loyalty','081234567890',NULL,gen_random_uuid());
  v_member:=(m->>'id')::uuid;
  INSERT INTO public.member_point_ledger(member_id,outlet_id,event_type,points_delta,source_type,source_reference,occurred_at,request_id)
    VALUES(v_member,'20000000-0000-4000-8000-000000000002','EARN',500,'RUNTIME','OPENING',now(),gen_random_uuid());
  INSERT INTO public.pos_carts(id,outlet_id,created_by,status,revision)
    VALUES('30000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000005','ACTIVE',1);
  selected:=public.pos_cart_member_set('30000000-0000-4000-8000-000000000002',v_member,1,gen_random_uuid());
  INSERT INTO public.pos_cart_items(cart_id,outlet_id,product_id,quantity,observed_unit_price)
    VALUES('30000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000002',gen_random_uuid(),1,30000);
  BEGIN PERFORM public.pos_cart_redeem_points_set('30000000-0000-4000-8000-000000000002',80,2,gen_random_uuid());
    RAISE EXCEPTION 'Below-minimum redemption was accepted'; EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL; END;
  BEGIN PERFORM public.pos_cart_redeem_points_set('30000000-0000-4000-8000-000000000002',501,2,gen_random_uuid());
    RAISE EXCEPTION 'Insufficient point balance was accepted'; EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL; END;
  BEGIN PERFORM public.pos_cart_redeem_points_set('30000000-0000-4000-8000-000000000002',301,2,gen_random_uuid());
    RAISE EXCEPTION 'Redemption above payable was accepted'; EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL; END;
  applied:=public.pos_cart_redeem_points_set('30000000-0000-4000-8000-000000000002',150,2,req);
  IF (applied->>'discount_amount')::numeric<>15000 OR applied->>'points_requested'<>'150' THEN RAISE EXCEPTION 'Partial redemption preview did not use the effective rate: %',applied; END IF;
  replay:=public.pos_cart_redeem_points_set('30000000-0000-4000-8000-000000000002',150,2,req);
  IF replay IS DISTINCT FROM applied OR (SELECT revision FROM public.pos_carts WHERE id='30000000-0000-4000-8000-000000000002')<>3 THEN
    RAISE EXCEPTION 'Redemption replay changed the cart twice'; END IF;
  IF (SELECT count(*) FROM public.member_point_ledger l WHERE l.member_id=v_member AND l.event_type IN('SALE_EARN','SALE_REDEEM'))<>0 THEN
    RAISE EXCEPTION 'Applying redemption created point ledger evidence before checkout'; END IF;
  BEGIN PERFORM public.pos_cart_redeem_points_set('30000000-0000-4000-8000-000000000002',140,2,req);
    RAISE EXCEPTION 'Conflicting redemption request replay was accepted'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  IF (SELECT redeem_policy_revision FROM public.pos_carts WHERE id='30000000-0000-4000-8000-000000000002')<>(SELECT policy_revision FROM public.outlet_loyalty_settings WHERE outlet_id='20000000-0000-4000-8000-000000000002') THEN
    RAISE EXCEPTION 'Cart did not retain the applied policy revision'; END IF;
  PERFORM public.member_loyalty_settings_update('{"program_enabled":true,"rupiah_per_point":"10000","redeem_enabled":true,"rupiah_per_redeem_point":"125","minimum_redeem_points":"100"}'::jsonb);
  IF (SELECT redeem_policy_revision FROM public.pos_carts WHERE id='30000000-0000-4000-8000-000000000002')=(SELECT policy_revision FROM public.outlet_loyalty_settings WHERE outlet_id='20000000-0000-4000-8000-000000000002') THEN
    RAISE EXCEPTION 'Cart redemption did not become stale after a saved policy change'; END IF;
END $$;
DO $$ BEGIN
  BEGIN PERFORM public.member_loyalty_settings_update('{"program_enabled":true,"rupiah_per_point":"0","redeem_enabled":false,"rupiah_per_redeem_point":null,"minimum_redeem_points":null}'::jsonb);
    RAISE EXCEPTION 'Zero earn threshold accepted'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
END $$;
SELECT set_config('quena.test.role','ADMIN',true);
DO $$ BEGIN
  PERFORM public.member_loyalty_settings_read();
  BEGIN PERFORM public.member_loyalty_settings_update('{"program_enabled":false,"rupiah_per_point":null,"redeem_enabled":false,"rupiah_per_redeem_point":null,"minimum_redeem_points":null}'::jsonb); RAISE EXCEPTION 'ADMIN updated loyalty settings';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT set_config('quena.test.role','KASIR',true);
DO $$ BEGIN
  BEGIN PERFORM public.member_loyalty_settings_read(); RAISE EXCEPTION 'KASIR read management settings';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM public.member_loyalty_settings_update('{"program_enabled":false,"rupiah_per_point":null,"redeem_enabled":false,"rupiah_per_redeem_point":null,"minimum_redeem_points":null}'::jsonb); RAISE EXCEPTION 'KASIR updated settings';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT set_config('quena.test.role','GUDANG',true);
DO $$ BEGIN
  BEGIN PERFORM public.member_loyalty_settings_read(); RAISE EXCEPTION 'GUDANG read loyalty management settings';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
ROLLBACK;
