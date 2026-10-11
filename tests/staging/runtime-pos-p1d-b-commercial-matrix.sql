\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database() NOT LIKE 'quena_p1d_b_staging_%'
     OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
     OR inet_server_port()<>55432 OR current_setting('server_version_num')::integer/10000<>15
     OR NOT EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE status='WAC_ACTIVE') THEN
    RAISE EXCEPTION 'Refusing commercial matrix outside WAC_ACTIVE disposable local staging';
  END IF;
END; $guard$;
BEGIN;
DO $commercial_matrix$
DECLARE outlet uuid; valued_product uuid; unvalued_product uuid; stale_product uuid;
  value_price numeric; unvalued_price numeric; stale_price numeric;
  cart jsonb; added jsonb; parked jsonb; result jsonb; sale uuid; cart_id uuid; rev bigint;
  req uuid; failure text; method public.pos_sale_payment_method; tender numeric;
  role_to_test public.user_role;
  methods public.pos_sale_payment_method[]:=ARRAY['CASH','CASH','QRIS','CARD','E_WALLET']::public.pos_sale_payment_method[];
  i integer; applied numeric; received numeric; change_amt numeric; new_outlet uuid;
  before_qty numeric; before_value numeric; before_wac numeric; cost_row record;
BEGIN
  SELECT ap.outlet_id INTO STRICT outlet FROM public.stock_authority_periods ap WHERE ap.ended_at IS NULL;
  SELECT id INTO STRICT valued_product FROM public.products WHERE sku='STG-BASE20';
  SELECT amount INTO STRICT value_price FROM public.product_selling_prices WHERE outlet_id=outlet AND product_id=valued_product;
  SELECT p.id,s.amount INTO STRICT unvalued_product,unvalued_price
    FROM public.products p JOIN public.product_selling_prices s ON s.product_id=p.id AND s.outlet_id=outlet
    JOIN public.inventory_cost_projections cp ON cp.product_id=p.id AND cp.outlet_id=outlet
    JOIN public.stock_balance_projection sb ON sb.product_id=p.id AND sb.outlet_id=outlet
    WHERE p.sku='STG-FULL-B' AND cp.valued_quantity=0 AND sb.effective_quantity>=4;
  SELECT p.id,s.amount INTO STRICT stale_product,stale_price
    FROM public.products p JOIN public.product_selling_prices s ON s.product_id=p.id AND s.outlet_id=outlet
    WHERE p.sku='STG-STALE';
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);

  -- CASH exact/change and all single-method non-cash records.
  FOR i IN 1..array_length(methods,1) LOOP
    method:=methods[i]; cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
    added:=public.pos_cart_add_item(cart_id,valued_product,1,1,gen_random_uuid()); rev:=(added->>'revision')::bigint;
    tender:=CASE WHEN method<>'CASH' THEN NULL WHEN i=1 THEN value_price ELSE value_price+500 END;
    req:=gen_random_uuid();
    result:=public.pos_checkout_complete(req,cart_id,rev,method,tender,NULL);
    sale:=(result->>'sale_id')::uuid;
    SELECT p.applied_amount,p.received_amount,p.change_amount INTO STRICT applied,received,change_amt
      FROM public.sale_payments p WHERE p.sale_id=sale;
    IF applied<>value_price OR (method='CASH' AND
        (received IS DISTINCT FROM tender OR change_amt IS DISTINCT FROM tender-value_price))
      OR (method<>'CASH' AND (received IS NOT NULL OR change_amt IS NOT NULL))
      OR result->>'cashier_label'<>'Stage Kasir' THEN
      RAISE EXCEPTION 'payment/cashier evidence mismatch for % case %',method,i;
    END IF;
  END LOOP;

  -- Underpaid cash must leave the active cart and all business tables alone.
  cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
  added:=public.pos_cart_add_item(cart_id,valued_product,1,1,gen_random_uuid()); rev:=(added->>'revision')::bigint;
  req:=gen_random_uuid(); failure:=NULL;
  BEGIN PERFORM public.pos_checkout_complete(req,cart_id,rev,'CASH',value_price-0.01,NULL);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN failure:=SQLERRM; END;
  IF failure IS DISTINCT FROM 'POS_PAYMENT_INVALID' OR (SELECT status FROM public.pos_carts WHERE id=cart_id)<>'ACTIVE'
    OR EXISTS(SELECT 1 FROM public.pos_checkout_requests WHERE request_id=req) THEN
    RAISE EXCEPTION 'insufficient CASH did not reject atomically: %',failure;
  END IF;

  -- Stale, empty, parked, and cancelled carts are rejected without completion.
  cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
  req:=gen_random_uuid(); failure:=NULL;
  BEGIN PERFORM public.pos_checkout_complete(req,cart_id,1,'CASH',10000,NULL);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN failure:=SQLERRM; END;
  IF failure IS DISTINCT FROM 'POS_CART_EMPTY' THEN RAISE EXCEPTION 'empty cart result: %',failure; END IF;

  cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
  added:=public.pos_cart_add_item(cart_id,valued_product,1,1,gen_random_uuid()); rev:=(added->>'revision')::bigint;
  req:=gen_random_uuid(); failure:=NULL;
  BEGIN PERFORM public.pos_checkout_complete(req,cart_id,rev-1,'CASH',10000,NULL);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN failure:=SQLERRM; END;
  IF failure IS DISTINCT FROM 'POS_CART_STALE' THEN RAISE EXCEPTION 'stale revision result: %',failure; END IF;

  cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
  added:=public.pos_cart_add_item(cart_id,valued_product,1,1,gen_random_uuid()); rev:=(added->>'revision')::bigint;
  parked:=public.pos_cart_park(cart_id,rev,gen_random_uuid()); rev:=(parked->>'revision')::bigint;
  req:=gen_random_uuid(); failure:=NULL;
  BEGIN PERFORM public.pos_checkout_complete(req,cart_id,rev,'CASH',10000,NULL);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN failure:=SQLERRM; END;
  IF failure IS DISTINCT FROM 'POS_CART_NOT_ACTIVE' THEN RAISE EXCEPTION 'parked cart result: %',failure; END IF;

  cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
  added:=public.pos_cart_add_item(cart_id,valued_product,1,1,gen_random_uuid()); rev:=(added->>'revision')::bigint;
  parked:=public.pos_cart_cancel(cart_id,rev,gen_random_uuid()); rev:=(parked->>'revision')::bigint;
  req:=gen_random_uuid(); failure:=NULL;
  BEGIN PERFORM public.pos_checkout_complete(req,cart_id,rev,'CASH',10000,NULL);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN failure:=SQLERRM; END;
  IF failure IS DISTINCT FROM 'POS_CART_NOT_ACTIVE' THEN RAISE EXCEPTION 'cancelled cart result: %',failure; END IF;

  -- Authoritative price changed/unavailable between add and checkout.
  cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
  added:=public.pos_cart_add_item(cart_id,stale_product,1,1,gen_random_uuid()); rev:=(added->>'revision')::bigint;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
  UPDATE public.product_selling_prices SET amount=stale_price+100
    WHERE outlet_id=outlet AND product_id=stale_product;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
  req:=gen_random_uuid(); failure:=NULL;
  BEGIN PERFORM public.pos_checkout_complete(req,cart_id,rev,'CASH',10000,NULL);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN failure:=SQLERRM; END;
  IF failure IS DISTINCT FROM 'POS_PRICE_CHANGED' THEN RAISE EXCEPTION 'changed price result: %',failure; END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
  UPDATE public.product_selling_prices SET amount=stale_price
    WHERE outlet_id=outlet AND product_id=stale_product;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
  cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
  added:=public.pos_cart_add_item(cart_id,stale_product,1,1,gen_random_uuid()); rev:=(added->>'revision')::bigint;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
  UPDATE public.product_selling_prices SET amount=0 WHERE outlet_id=outlet AND product_id=stale_product;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
  req:=gen_random_uuid(); failure:=NULL;
  BEGIN PERFORM public.pos_checkout_complete(req,cart_id,rev,'CASH',10000,NULL);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN failure:=SQLERRM; END;
  IF failure IS DISTINCT FROM 'POS_PRICE_UNAVAILABLE' THEN RAISE EXCEPTION 'unavailable price result: %',failure; END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
  UPDATE public.product_selling_prices SET amount=stale_price
    WHERE outlet_id=outlet AND product_id=stale_product;

  -- Fully UNVALUED sale keeps unknown cost NULL.
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
  SELECT effective_quantity INTO before_qty FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=unvalued_product;
  cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
  added:=public.pos_cart_add_item(cart_id,unvalued_product,2,1,gen_random_uuid()); rev:=(added->>'revision')::bigint;
  result:=public.pos_checkout_complete(gen_random_uuid(),cart_id,rev,'CASH',unvalued_price*2,NULL);
  sale:=(result->>'sale_id')::uuid;
  SELECT * INTO STRICT cost_row FROM public.sale_item_cost_evidence WHERE sale_id=sale;
  IF cost_row.status<>'UNRESOLVED' OR cost_row.valued_quantity<>0 OR cost_row.unvalued_quantity<>2
    OR cost_row.resolved_cogs_amount IS NOT NULL OR cost_row.provisional_cogs_amount IS NOT NULL
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=unvalued_product)<>before_qty-2
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=unvalued_product) IS NOT NULL THEN
    RAISE EXCEPTION 'fully unvalued sale invented/changed COGS or stock incorrectly';
  END IF;

  -- Decimal quantity and a two-product sale retain one evidence chain per line.
  SELECT effective_quantity INTO before_qty FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=valued_product;
  SELECT inventory_value,current_wac INTO before_value,before_wac FROM public.inventory_cost_projections
    WHERE outlet_id=outlet AND product_id=valued_product;
  cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
  added:=public.pos_cart_add_item(cart_id,valued_product,0.125,1,gen_random_uuid()); rev:=(added->>'revision')::bigint;
  result:=public.pos_checkout_complete(gen_random_uuid(),cart_id,rev,'CASH',value_price*0.125,NULL);
  sale:=(result->>'sale_id')::uuid;
  IF (SELECT quantity FROM public.sale_items WHERE sale_id=sale)<>0.125
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=valued_product)<>before_qty-0.125
    OR (SELECT current_wac FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=valued_product)<>before_wac THEN
    RAISE EXCEPTION 'decimal quantity sale failed';
  END IF;
  cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
  added:=public.pos_cart_add_item(cart_id,valued_product,1,1,gen_random_uuid()); rev:=(added->>'revision')::bigint;
  added:=public.pos_cart_add_item(cart_id,unvalued_product,1,rev,gen_random_uuid()); rev:=(added->>'revision')::bigint;
  result:=public.pos_checkout_complete(gen_random_uuid(),cart_id,rev,'QRIS',NULL,NULL); sale:=(result->>'sale_id')::uuid;
  IF (SELECT count(*) FROM public.sale_items WHERE sale_id=sale)<>2
    OR (SELECT count(*) FROM public.stock_movements WHERE pos_sale_id=sale AND movement_type='SALE')<>2
    OR (SELECT count(*) FROM public.sale_item_cost_evidence WHERE sale_id=sale)<>2 THEN
    RAISE EXCEPTION 'multi-item sale evidence did not persist independently per item';
  END IF;

  -- Owner/admin are allowed; warehouse and a cashier who does not own a cart are denied.
  FOREACH role_to_test IN ARRAY ARRAY['OWNER','ADMIN']::public.user_role[] LOOP
    PERFORM set_config('request.jwt.claim.sub',CASE WHEN role_to_test='OWNER' THEN
      'a0000000-0000-4000-8000-000000000001' ELSE 'a0000000-0000-4000-8000-000000000002' END,true);
    cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
    added:=public.pos_cart_add_item(cart_id,valued_product,1,1,gen_random_uuid()); rev:=(added->>'revision')::bigint;
    PERFORM public.pos_checkout_complete(gen_random_uuid(),cart_id,rev,'CARD',NULL,NULL);
  END LOOP;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
  cart:=public.pos_cart_create(gen_random_uuid()); cart_id:=(cart->>'cart_id')::uuid;
  added:=public.pos_cart_add_item(cart_id,valued_product,1,1,gen_random_uuid()); rev:=(added->>'revision')::bigint;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
  req:=gen_random_uuid(); failure:=NULL;
  BEGIN PERFORM public.pos_checkout_complete(req,cart_id,rev,'CASH',10000,NULL);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN failure:=SQLERRM; END;
  IF failure IS DISTINCT FROM 'POS_UNAUTHORIZED' OR EXISTS(SELECT 1 FROM public.pos_checkout_requests WHERE request_id=req)
    OR failure LIKE '%SQLSTATE%' THEN RAISE EXCEPTION 'KASIR ownership mismatch result leaked/persisted: %',failure; END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
  req:=gen_random_uuid(); failure:=NULL;
  BEGIN PERFORM public.pos_checkout_complete(req,cart_id,rev,'CASH',10000,NULL);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN failure:=SQLERRM; END;
  IF failure IS DISTINCT FROM 'POS_UNAUTHORIZED' OR EXISTS(SELECT 1 FROM public.pos_checkout_requests WHERE request_id=req)
    OR failure LIKE '%SQLSTATE%' THEN RAISE EXCEPTION 'GUDANG checkout result leaked/persisted: %',failure; END IF;

  -- Foreign and nonexistent carts normalize to POS_UNAUTHORIZED before request FK insertion.
  INSERT INTO public.outlets(code,name) VALUES('P1D-B-CROSS-OUTLET','P1D-B cross-outlet fixture') RETURNING id INTO new_outlet;
  INSERT INTO public.pos_carts(outlet_id,created_by) VALUES(new_outlet,'a0000000-0000-4000-8000-000000000004') RETURNING id INTO cart_id;
  FOREACH role_to_test IN ARRAY ARRAY['OWNER','ADMIN','KASIR']::public.user_role[] LOOP
    req:=gen_random_uuid();
    PERFORM set_config('request.jwt.claim.sub',CASE role_to_test
      WHEN 'OWNER' THEN 'a0000000-0000-4000-8000-000000000001'
      WHEN 'ADMIN' THEN 'a0000000-0000-4000-8000-000000000002'
      ELSE 'a0000000-0000-4000-8000-000000000004' END,true);
    failure:=NULL;
    BEGIN PERFORM public.pos_checkout_complete(req,cart_id,1,'CASH',10000,NULL);
    EXCEPTION WHEN OTHERS THEN failure:=SQLERRM; END;
    IF failure IS DISTINCT FROM 'POS_UNAUTHORIZED' OR failure LIKE '%pos_checkout_request_cart_fk%'
      OR failure LIKE '%SQLSTATE%' OR EXISTS(SELECT 1 FROM public.pos_checkout_requests WHERE request_id=req) THEN
      RAISE EXCEPTION 'cross-outlet cart exposed a raw error or persisted request for %: %',role_to_test,failure;
    END IF;
  END LOOP;
  req:=gen_random_uuid(); failure:=NULL;
  BEGIN PERFORM public.pos_checkout_complete(req,gen_random_uuid(),1,'CASH',10000,NULL);
  EXCEPTION WHEN OTHERS THEN failure:=SQLERRM; END;
  IF failure IS DISTINCT FROM 'POS_UNAUTHORIZED' OR failure LIKE '%pos_checkout_request_cart_fk%'
    OR EXISTS(SELECT 1 FROM public.pos_checkout_requests WHERE request_id=req) THEN
    RAISE EXCEPTION 'nonexistent cart did not normalize to unauthorized: %',failure;
  END IF;

  RAISE NOTICE 'PASS: tender, price, cart-state, role, cross-outlet/nonexistent-cart, unvalued, decimal, and multi-item matrix';
END; $commercial_matrix$;
COMMIT;
SELECT 'PASS: disposable commercial checkout matrix committed successfully' AS result;
