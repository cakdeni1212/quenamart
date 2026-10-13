-- Rollback-only verification for the Settings outlet RPCs on disposable local PostgreSQL 15.
BEGIN;
DO $$
DECLARE
  v_owner uuid:='a0000000-0000-4000-8000-000000000001';
  v_admin uuid:='a0000000-0000-4000-8000-000000000002';
  v_gudang uuid:='a0000000-0000-4000-8000-000000000003';
  v_kasir uuid:='a0000000-0000-4000-8000-000000000004';
  v_outlet uuid;
  v_name text;
  v_payload jsonb;
  v_result jsonb;
  v_event_count bigint;
  v_sales_count bigint;
  v_error text;
  v_cart uuid:=gen_random_uuid();
  v_request uuid:=gen_random_uuid();
  v_sale uuid:=gen_random_uuid();
  v_receipt jsonb;
BEGIN
  IF current_database()<>'quena_stock_staging' OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR inet_server_port()<>5432 OR current_setting('server_version_num')::integer/10000<>15 THEN
    RAISE EXCEPTION 'Refusing Settings runtime test outside disposable loopback PostgreSQL 15 staging';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_owner AND role='OWNER' AND is_active)
    OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_admin AND role='ADMIN' AND is_active)
    OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_gudang AND role='GUDANG' AND is_active)
    OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_kasir AND role='KASIR' AND is_active) THEN
    RAISE EXCEPTION 'Expected synthetic staging roles were not seeded';
  END IF;
  v_outlet:=public.outlet_settings_current_id();
  SELECT name INTO v_name FROM public.outlets WHERE id=v_outlet;
  SELECT count(*) INTO v_event_count FROM public.outlet_settings_events WHERE outlet_id=v_outlet;
  SELECT count(*) INTO v_sales_count FROM public.sales WHERE outlet_id=v_outlet;

  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  v_result:=public.outlet_settings_read();
  IF v_result->>'id'<>v_outlet::text OR v_result->>'code'<>'QUENA-MART-1' THEN
    RAISE EXCEPTION 'Owner outlet read returned wrong identity';
  END IF;
  v_payload:=jsonb_build_object('name',v_name,'customer_display_name','Quena Mart Runtime','address',NULL,
    'city','Uji Runtime','province',NULL,'postal_code',NULL,'phone','081234567890','whatsapp',NULL,
    'email','runtime@example.test','is_active',true);
  v_result:=public.outlet_settings_update(v_outlet,v_payload);
  IF v_result->>'updated'<>'true' OR NOT ('phone'=ANY(ARRAY(SELECT jsonb_array_elements_text(v_result->'changed_fields')))) THEN
    RAISE EXCEPTION 'Owner update did not report the expected change';
  END IF;
  IF (SELECT phone FROM public.outlets WHERE id=v_outlet)<>'081234567890'
    OR (SELECT updated_by FROM public.outlets WHERE id=v_outlet) IS DISTINCT FROM v_owner THEN
    RAISE EXCEPTION 'Phone leading zero or update actor was not preserved';
  END IF;
  v_result:=public.outlet_settings_update(v_outlet,v_payload);
  IF v_result->>'updated'<>'false' OR (SELECT count(*) FROM public.outlet_settings_events WHERE outlet_id=v_outlet)<>v_event_count+1 THEN
    RAISE EXCEPTION 'Exact duplicate update was not a no-op';
  END IF;

  INSERT INTO public.pos_carts(id,outlet_id,created_by,status) VALUES(v_cart,v_outlet,v_owner,'COMPLETED');
  INSERT INTO public.pos_checkout_requests(request_id,actor_id,outlet_id,cart_id,expected_cart_revision,payment_payload_hash,
    state,sale_id,result,completed_at)
  VALUES(v_request,v_owner,v_outlet,v_cart,1,md5(v_request::text),'COMPLETED',v_sale,'{"cashier_label":"Stage Owner"}'::jsonb,now());
  INSERT INTO public.sales(id,outlet_id,cashier_id,completed_by,pos_cart_id,checkout_request_id,sale_number,
    subtotal,discount_total,grand_total,completed_at)
  VALUES(v_sale,v_outlet,v_owner,v_owner,v_cart,v_request,'QPOS-20261013-00000001',0,0,0,now());
  v_receipt:=public.pos_sale_receipt_read(v_sale);
  IF v_receipt->>'outlet_display_name'<>'Quena Mart Runtime' OR v_receipt->>'outlet_address'<>'Uji Runtime'
    OR v_receipt->>'outlet_phone'<>'081234567890' THEN
    RAISE EXCEPTION 'Native receipt did not read current canonical outlet identity';
  END IF;

  BEGIN
    v_payload:=jsonb_set(v_payload,'{email}','"not-an-email"'::jsonb);
    PERFORM public.outlet_settings_update(v_outlet,v_payload);
    RAISE EXCEPTION 'Invalid email was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
    IF v_error<>'OUTLET_SETTINGS_INVALID_EMAIL' THEN RAISE; END IF;
  END;

  v_payload:=jsonb_set(v_payload,'{email}','"runtime@example.test"'::jsonb);
  PERFORM set_config('request.jwt.claim.sub',v_admin::text,true);
  IF public.outlet_settings_read()->>'id'<>v_outlet::text THEN RAISE EXCEPTION 'Admin read failed'; END IF;
  BEGIN
    PERFORM public.outlet_settings_update(v_outlet,v_payload);
    RAISE EXCEPTION 'Admin update was accepted';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;

  PERFORM set_config('request.jwt.claim.sub',v_gudang::text,true);
  BEGIN
    PERFORM public.outlet_settings_read();
    RAISE EXCEPTION 'Gudang outlet settings read was accepted';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  BEGIN
    PERFORM public.outlet_settings_update(v_outlet,v_payload);
    RAISE EXCEPTION 'Gudang outlet update was accepted';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;

  PERFORM set_config('request.jwt.claim.sub',v_kasir::text,true);
  BEGIN
    PERFORM public.outlet_settings_read();
    RAISE EXCEPTION 'Kasir outlet settings read was accepted';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  BEGIN
    PERFORM public.outlet_settings_update(v_outlet,v_payload);
    RAISE EXCEPTION 'Kasir outlet update was accepted';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;

  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  BEGIN
    PERFORM public.outlet_settings_update(v_outlet,jsonb_set(v_payload,'{is_active}','false'::jsonb));
    RAISE EXCEPTION 'Active/current outlet deactivation was accepted';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
    IF v_error<>'OUTLET_SETTINGS_DEACTIVATION_BLOCKED' THEN RAISE; END IF;
  END;

  IF has_table_privilege('authenticated','public.outlets','UPDATE') THEN RAISE EXCEPTION 'Authenticated has direct outlet update grant'; END IF;
  IF (SELECT count(*) FROM public.sales WHERE outlet_id=v_outlet)<>v_sales_count+1 THEN RAISE EXCEPTION 'Settings changed historical sales'; END IF;
  RAISE NOTICE 'PASS: OWNER update/audit/no-op; ADMIN read-only; KASIR/GUDANG denied; validation, leading-zero phone, deactivation guard and current receipt identity';
END;
$$;
ROLLBACK;
