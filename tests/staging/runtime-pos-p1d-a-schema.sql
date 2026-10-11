\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database() NOT LIKE 'quena_p1d_a_staging_%'
     OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
     OR inet_server_port()<>55432
     OR current_setting('server_version_num')::integer/10000<>15
     OR (SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal DESC LIMIT 1)<>'20260929340000'
     OR to_regclass('public.sales') IS NULL THEN
    RAISE EXCEPTION 'Refusing P1D-A runtime outside disposable local PostgreSQL 15 through 340000';
  END IF;
END; $guard$;

BEGIN;
SET LOCAL statement_timeout='60s';
SET LOCAL lock_timeout='10s';
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
SELECT id AS product_id FROM public.products WHERE sku='STG-FULL-A' \gset
SET LOCAL ROLE authenticated;
SELECT (public.pos_cart_create('f4000000-0000-4000-8000-000000000001'::uuid)->>'cart_id') AS terminal_cart \gset
SELECT (public.pos_cart_create('f4000000-0000-4000-8000-000000000002'::uuid)->>'cart_id') AS sale_cart \gset
SELECT public.pos_cart_add_item(:'sale_cart'::uuid,:'product_id'::uuid,1.125,1,'f4000000-0000-4000-8000-000000000003'::uuid);
RESET ROLE;
SELECT id AS sale_cart_item FROM public.pos_cart_items WHERE cart_id=:'sale_cart'::uuid AND product_id=:'product_id'::uuid \gset
SELECT set_config('quena.p1d.terminal_cart',:'terminal_cart',true);
SELECT set_config('quena.p1d.sale_cart',:'sale_cart',true);
SELECT set_config('quena.p1d.sale_cart_item',:'sale_cart_item',true);

UPDATE public.pos_carts SET status='COMPLETED' WHERE id=current_setting('quena.p1d.terminal_cart')::uuid;
SET LOCAL ROLE authenticated;
DO $terminal_cart$
DECLARE cid uuid:=current_setting('quena.p1d.terminal_cart')::uuid; product uuid;
BEGIN
  SELECT id INTO STRICT product FROM public.products WHERE sku='STG-FULL-A';
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
  BEGIN PERFORM public.pos_cart_add_item(cid,product,1,1,'f4000000-0000-4000-8000-000000000011');
    RAISE EXCEPTION 'completed cart accepted add-item'; EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
  BEGIN PERFORM public.pos_cart_set_item_quantity(cid,'f4000000-0000-4000-8000-000000000099',1,1,'f4000000-0000-4000-8000-000000000012');
    RAISE EXCEPTION 'completed cart accepted quantity change'; EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
  BEGIN PERFORM public.pos_cart_acknowledge_price(cid,'f4000000-0000-4000-8000-000000000099',1,1,'f4000000-0000-4000-8000-000000000013');
    RAISE EXCEPTION 'completed cart accepted price acknowledgement'; EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
  BEGIN PERFORM public.pos_cart_park(cid,1,'f4000000-0000-4000-8000-000000000014');
    RAISE EXCEPTION 'completed cart accepted park'; EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
  BEGIN PERFORM public.pos_cart_resume(cid,1,'f4000000-0000-4000-8000-000000000015');
    RAISE EXCEPTION 'completed cart accepted resume'; EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
  BEGIN PERFORM public.pos_cart_cancel(cid,1,'f4000000-0000-4000-8000-000000000016');
    RAISE EXCEPTION 'completed cart accepted cancel'; EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
END; $terminal_cart$;
RESET ROLE;

DO $sale_evidence$
DECLARE cid uuid:=current_setting('quena.p1d.sale_cart')::uuid; cart_item uuid:=current_setting('quena.p1d.sale_cart_item')::uuid; outlet uuid; other_outlet uuid:='f4000000-0000-4000-8000-000000000030'; request uuid:='f4000000-0000-4000-8000-000000000020'; sale uuid:='f4000000-0000-4000-8000-000000000021'; item uuid:='f4000000-0000-4000-8000-000000000022'; product uuid;
  sale_no text:='QPOS-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'||lpad(nextval('public.pos_sale_number_seq')::text,8,'0');
BEGIN
  SELECT outlet_id INTO STRICT outlet FROM public.pos_carts WHERE id=cid;
  SELECT id INTO STRICT product FROM public.products WHERE sku='STG-FULL-A';
  INSERT INTO public.outlets(id,code,name,is_active) VALUES(other_outlet,'P1D-A-ISOLATION','P1D-A isolation fixture',false);
  BEGIN
    INSERT INTO public.pos_checkout_requests(request_id,actor_id,outlet_id,cart_id,expected_cart_revision,payment_payload_hash)
      VALUES('f4000000-0000-4000-8000-000000000031','a0000000-0000-4000-8000-000000000004',other_outlet,cid,2,md5('cross-outlet'));
    RAISE EXCEPTION 'checkout request crossed outlet/cart boundary';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;
  INSERT INTO public.pos_checkout_requests(request_id,actor_id,outlet_id,cart_id,expected_cart_revision,payment_payload_hash)
    VALUES(request,'a0000000-0000-4000-8000-000000000004',outlet,cid,2,md5('cash-and-qris'));
  INSERT INTO public.sales(id,outlet_id,cashier_id,completed_by,pos_cart_id,checkout_request_id,sale_number,
    subtotal,discount_total,grand_total,completed_at)
    VALUES(sale,outlet,'a0000000-0000-4000-8000-000000000004','a0000000-0000-4000-8000-000000000004',cid,request,
      sale_no,4.99,0,4.99,now());
  UPDATE public.pos_checkout_requests SET state='COMPLETED',sale_id=sale,
    result=jsonb_build_object('sale_id',sale),completed_at=now() WHERE request_id=request;
  INSERT INTO public.sale_items(id,sale_id,pos_cart_id,pos_cart_item_id,outlet_id,product_id,line_number,product_name_snapshot,sku_snapshot,
    quantity,unit_selling_price,price_checked_at)
    VALUES(item,sale,cid,cart_item,outlet,product,1,'Snapshot Product','STG-FULL-A',1.125,2.22,now());
  IF (SELECT line_subtotal FROM public.sale_items WHERE id=item)<>2.50 THEN
    RAISE EXCEPTION 'sale item generated subtotal does not follow the money rounding contract'; END IF;
  INSERT INTO public.sale_payments(sale_id,outlet_id,method,applied_amount,received_amount,change_amount,recorded_by)
    VALUES(sale,outlet,'CASH',2.00,3.00,1.00,'a0000000-0000-4000-8000-000000000004');
  INSERT INTO public.sale_payments(sale_id,outlet_id,method,applied_amount,recorded_by)
    VALUES(sale,outlet,'QRIS',2.99,'a0000000-0000-4000-8000-000000000004');
  INSERT INTO public.sale_item_cost_evidence(sale_item_id,sale_id,outlet_id,product_id,checkout_request_id,
    quantity,valued_quantity,provisional_quantity,unvalued_quantity,status)
    VALUES(item,sale,outlet,product,request,1.125,0,0,1.125,'UNRESOLVED');
  BEGIN
    INSERT INTO public.sale_payments(sale_id,outlet_id,method,applied_amount,received_amount,change_amount,recorded_by)
      VALUES(sale,outlet,'CASH',2.00,1.00,0,'a0000000-0000-4000-8000-000000000004');
    RAISE EXCEPTION 'cash received below applied amount was accepted';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO public.sale_payments(sale_id,outlet_id,method,applied_amount,received_amount,change_amount,recorded_by)
      VALUES(sale,outlet,'CARD',1.00,2.00,1.00,'a0000000-0000-4000-8000-000000000004');
    RAISE EXCEPTION 'noncash payment accepted cash-only fields';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    UPDATE public.sales SET grand_total=5 WHERE id=sale;
    RAISE EXCEPTION 'sale update was accepted';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
  BEGIN
    DELETE FROM public.sale_items WHERE id=item;
    RAISE EXCEPTION 'sale item delete was accepted';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
  BEGIN
    UPDATE public.sale_payments SET reference_text='changed' WHERE sale_id=sale;
    RAISE EXCEPTION 'payment update was accepted';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
  BEGIN
    UPDATE public.sale_item_cost_evidence SET resolved_cogs_amount=0 WHERE sale_item_id=item;
    RAISE EXCEPTION 'cost evidence update was accepted';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
  BEGIN
    INSERT INTO public.sales(outlet_id,cashier_id,completed_by,pos_cart_id,checkout_request_id,sale_number,
      subtotal,discount_total,grand_total,completed_at)
      VALUES(outlet,'a0000000-0000-4000-8000-000000000004','a0000000-0000-4000-8000-000000000004',cid,request,
        sale_no,4.99,0,4.99,now());
    RAISE EXCEPTION 'duplicate sale/cart/request/number was accepted';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  PERFORM set_config('quena.p1d.sale_id',sale::text,true);
END; $sale_evidence$;

SET LOCAL ROLE authenticated;
DO $security$
DECLARE sale uuid:=current_setting('quena.p1d.sale_id')::uuid; kasir_count integer; owner_count integer; gudang_count integer;
BEGIN
  IF has_table_privilege('authenticated','public.sales','SELECT')
    OR has_table_privilege('authenticated','public.sales','INSERT')
    OR has_table_privilege('authenticated','public.sale_payments','INSERT')
    OR has_table_privilege('authenticated','public.pos_checkout_requests','INSERT')
    OR has_table_privilege('authenticated','public.pos_carts','UPDATE') THEN
    RAISE EXCEPTION 'commercial evidence unexpectedly has direct client access'; END IF;
  IF NOT has_table_privilege('authenticated','public.sale_item_cost_evidence','SELECT') THEN
    RAISE EXCEPTION 'cost evidence manager-read grant is missing'; END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
  SELECT count(*) INTO owner_count FROM public.sale_item_cost_evidence WHERE sale_id=sale;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
  SELECT count(*) INTO kasir_count FROM public.sale_item_cost_evidence WHERE sale_id=sale;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
  SELECT count(*) INTO gudang_count FROM public.sale_item_cost_evidence WHERE sale_id=sale;
  IF owner_count<>1 OR kasir_count<>0 OR gudang_count<>0 THEN
    RAISE EXCEPTION 'cost visibility mismatch owner %, kasir %, gudang %',owner_count,kasir_count,gudang_count; END IF;
  IF to_regprocedure('public.pos_checkout_complete(uuid,uuid,bigint,jsonb)') IS NOT NULL
    OR to_regprocedure('public.pos_checkout_create(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'P1D-A unexpectedly installed checkout writer'; END IF;
END; $security$;
RESET ROLE;
ROLLBACK;
