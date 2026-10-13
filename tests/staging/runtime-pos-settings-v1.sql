-- Rollback-only POS Settings verification for disposable local PostgreSQL 15.
BEGIN;
DO $$
DECLARE
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_admin uuid := 'a0000000-0000-4000-8000-000000000002';
  v_gudang uuid := 'a0000000-0000-4000-8000-000000000003';
  v_kasir uuid := 'a0000000-0000-4000-8000-000000000004';
  v_outlet uuid;
  v_payload jsonb;
  v_result jsonb;
  v_events bigint;
  v_cart uuid := gen_random_uuid();
  v_parked uuid := gen_random_uuid();
  v_request uuid := gen_random_uuid();
  v_sale uuid := gen_random_uuid();
  v_error text;
  v_stock_period uuid;
BEGIN
  IF current_database() <> 'quena_stock_staging'
    OR coalesce(host(inet_server_addr()),'') <> '127.0.0.1'
    OR inet_server_port() <> 58439
    OR current_setting('server_version_num')::integer / 10000 <> 15 THEN
    RAISE EXCEPTION 'Refusing POS settings test outside disposable loopback PostgreSQL 15';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_owner AND role='OWNER' AND is_active)
    OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_admin AND role='ADMIN' AND is_active)
    OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_gudang AND role='GUDANG' AND is_active)
    OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_kasir AND role='KASIR' AND is_active) THEN
    RAISE EXCEPTION 'Expected synthetic staging roles were not seeded';
  END IF;
  v_outlet := public.outlet_settings_current_id();
  SELECT count(*) INTO v_events FROM public.outlet_settings_events WHERE outlet_id=v_outlet;

  -- No settings row is seeded: the effective defaults preserve existing POS behavior.
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  v_result := public.pos_settings_read();
  IF v_result->'enabled_payment_methods' <> '["CASH","QRIS","CARD","E_WALLET"]'::jsonb
    OR v_result->>'allow_hold_transactions' <> 'true'
    OR v_result->>'confirm_cart_cancellation' <> 'true'
    OR v_result->>'receipt_show_address' <> 'true'
    OR v_result->>'receipt_show_phone' <> 'true' THEN
    RAISE EXCEPTION 'Backward-compatible effective defaults changed';
  END IF;

  v_payload := jsonb_build_object(
    'receipt_footer_note','Terima kasih telah berbelanja',
    'receipt_show_address',false,
    'receipt_show_phone',true,
    'enabled_payment_methods',jsonb_build_array('CASH','CARD'),
    'allow_hold_transactions',false,
    'confirm_cart_cancellation',false);
  v_result := public.pos_settings_update(v_outlet,v_payload);
  IF v_result->>'updated' <> 'true' OR v_result#>>'{settings,enabled_payment_methods}' <> '["CASH", "CARD"]'
    OR v_result#>>'{settings,receipt_footer_note}' <> 'Terima kasih telah berbelanja'
    OR v_result#>>'{settings,receipt_show_address}' <> 'false' THEN
    RAISE EXCEPTION 'OWNER settings update did not persist effective behavior';
  END IF;
  IF (SELECT updated_by FROM public.outlet_pos_settings WHERE outlet_id=v_outlet) IS DISTINCT FROM v_owner
    OR (SELECT count(*) FROM public.outlet_settings_events WHERE outlet_id=v_outlet) <> v_events+1
    OR NOT EXISTS(SELECT 1 FROM public.outlet_settings_events WHERE outlet_id=v_outlet
      AND actor_id=v_owner AND event_type='POS_SETTINGS_UPDATED'
      AND changed_fields @> ARRAY['enabled_payment_methods','allow_hold_transactions']) THEN
    RAISE EXCEPTION 'Settings actor/time/changed-field audit evidence missing';
  END IF;
  v_result := public.pos_settings_update(v_outlet,v_payload);
  IF v_result->>'updated' <> 'false'
    OR (SELECT count(*) FROM public.outlet_settings_events WHERE outlet_id=v_outlet) <> v_events+1 THEN
    RAISE EXCEPTION 'No-op update created audit evidence';
  END IF;

  -- At least one supported tender must remain enabled.
  v_payload := jsonb_set(v_payload,'{enabled_payment_methods}','[]'::jsonb);
  BEGIN
    PERFORM public.pos_settings_update(v_outlet,v_payload);
    RAISE EXCEPTION 'All payment methods disabled was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
    IF v_error <> 'POS_SETTINGS_INVALID_PAYMENT_METHODS' THEN RAISE; END IF;
  END;

  -- ADMIN may read management settings but cannot update. KASIR can only read effective
  -- configuration; GUDANG and KASIR cannot use management read/update.
  PERFORM set_config('request.jwt.claim.sub',v_admin::text,true);
  IF public.pos_settings_read()->>'outlet_id' <> v_outlet::text THEN RAISE EXCEPTION 'ADMIN read denied'; END IF;
  BEGIN
    PERFORM public.pos_settings_update(v_outlet,v_payload);
    RAISE EXCEPTION 'ADMIN settings update was accepted';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  PERFORM set_config('request.jwt.claim.sub',v_kasir::text,true);
  IF public.pos_effective_settings_read()->>'outlet_id' <> v_outlet::text THEN RAISE EXCEPTION 'KASIR effective read denied'; END IF;
  BEGIN
    PERFORM public.pos_settings_read();
    RAISE EXCEPTION 'KASIR management read was accepted';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  BEGIN
    PERFORM public.pos_settings_update(v_outlet,v_payload);
    RAISE EXCEPTION 'KASIR settings update was accepted';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  PERFORM set_config('request.jwt.claim.sub',v_gudang::text,true);
  BEGIN
    PERFORM public.pos_effective_settings_read();
    RAISE EXCEPTION 'GUDANG effective POS settings read was accepted';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;

  -- Existing parked carts remain available; disabling hold only blocks a new PARKED transition.
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  INSERT INTO public.pos_carts(id,outlet_id,created_by,status) VALUES(v_cart,v_outlet,v_owner,'ACTIVE');
  BEGIN
    UPDATE public.pos_carts SET status='PARKED',revision=revision+1 WHERE id=v_cart;
    RAISE EXCEPTION 'New hold was accepted while disabled';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
    IF v_error <> 'POS_HOLD_DISABLED' THEN RAISE; END IF;
  END;
  UPDATE public.pos_carts SET status='CANCELLED',cancelled_at=now(),cancelled_by=v_owner WHERE id=v_cart;
  v_payload := jsonb_set(v_payload,'{enabled_payment_methods}','["CASH","QRIS"]'::jsonb);
  v_payload := jsonb_set(v_payload,'{allow_hold_transactions}','true'::jsonb);
  PERFORM public.pos_settings_update(v_outlet,v_payload);
  INSERT INTO public.pos_carts(id,outlet_id,created_by,status) VALUES(v_parked,v_outlet,v_owner,'ACTIVE');
  UPDATE public.pos_carts SET status='PARKED',revision=revision+1 WHERE id=v_parked;
  v_payload := jsonb_set(v_payload,'{allow_hold_transactions}','false'::jsonb);
  PERFORM public.pos_settings_update(v_outlet,v_payload);
  UPDATE public.pos_carts SET status='ACTIVE',revision=revision+1 WHERE id=v_parked;
  IF (SELECT status FROM public.pos_carts WHERE id=v_parked) <> 'ACTIVE' THEN
    RAISE EXCEPTION 'Previously held cart could not be resumed after hold was disabled';
  END IF;

  -- Payment enforcement is on new evidence insertion; historical rows are not rewritten.
  SELECT id INTO v_stock_period FROM public.stock_authority_periods WHERE outlet_id=v_outlet AND ended_at IS NULL;
  IF v_stock_period IS NULL THEN
    INSERT INTO public.stock_authority_periods(outlet_id,mode,created_by,created_reason)
      VALUES(v_outlet,'QUENA_MOVEMENT_LEDGER',v_owner,'POS settings runtime fixture') RETURNING id INTO v_stock_period;
  END IF;
  v_payload := jsonb_set(v_payload,'{enabled_payment_methods}','["CASH"]'::jsonb);
  PERFORM public.pos_settings_update(v_outlet,v_payload);
  INSERT INTO public.pos_carts(id,outlet_id,created_by,status) VALUES(gen_random_uuid(),v_outlet,v_owner,'COMPLETED');
  INSERT INTO public.pos_checkout_requests(request_id,actor_id,outlet_id,cart_id,expected_cart_revision,payment_payload_hash,
    state,sale_id,result,completed_at)
  SELECT v_request,v_owner,v_outlet,id,1,md5(v_request::text),'COMPLETED',v_sale,'{}'::jsonb,now()
  FROM public.pos_carts WHERE created_by=v_owner ORDER BY created_at DESC LIMIT 1;
  INSERT INTO public.sales(id,outlet_id,cashier_id,completed_by,pos_cart_id,checkout_request_id,sale_number,
    subtotal,discount_total,grand_total,completed_at)
  SELECT v_sale,v_outlet,v_owner,v_owner,c.id,v_request,'QPOS-20261013-99112233',100,0,100,now()
  FROM public.pos_carts c WHERE c.id=(SELECT cart_id FROM public.pos_checkout_requests WHERE request_id=v_request);
  BEGIN
    INSERT INTO public.sale_payments(sale_id,outlet_id,method,applied_amount,recorded_by)
      VALUES(v_sale,v_outlet,'QRIS',100,v_owner);
    RAISE EXCEPTION 'Disabled QRIS payment was accepted';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
    IF v_error <> 'POS_PAYMENT_METHOD_DISABLED' THEN RAISE; END IF;
  END;
  IF EXISTS(SELECT 1 FROM public.sale_payments WHERE sale_id=v_sale) THEN RAISE EXCEPTION 'Rejected tender left payment evidence'; END IF;
  INSERT INTO public.sale_payments(sale_id,outlet_id,method,applied_amount,received_amount,change_amount,recorded_by)
    VALUES(v_sale,v_outlet,'CASH',100,100,0,v_owner);
  v_payload := jsonb_set(v_payload,'{receipt_show_address}','false'::jsonb);
  v_payload := jsonb_set(v_payload,'{receipt_show_phone}','false'::jsonb);
  PERFORM public.pos_settings_update(v_outlet,v_payload);
  v_result := public.pos_sale_receipt_read(v_sale);
  IF v_result IS NULL OR v_result->>'outlet_address' IS NOT NULL OR v_result->>'outlet_phone' IS NOT NULL
    OR v_result->>'receipt_footer_note' <> 'Terima kasih telah berbelanja'
    OR jsonb_array_length(v_result->'payments') <> 1 THEN
    RAISE EXCEPTION 'Receipt presentation config was not applied without changing payment evidence';
  END IF;
  IF has_table_privilege('authenticated','public.outlet_pos_settings','SELECT')
    OR has_table_privilege('authenticated','public.outlet_pos_settings','UPDATE') THEN
    RAISE EXCEPTION 'Authenticated role can directly access POS settings table';
  END IF;
  RAISE NOTICE 'PASS: defaults; OWNER update/no-op/audit; ADMIN read-only; KASIR effective read; GUDANG denied; hold enforcement/existing cart; payment rejection/new payment; receipt presentation only';
END;
$$;
ROLLBACK;
