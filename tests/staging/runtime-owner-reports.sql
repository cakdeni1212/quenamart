\set ON_ERROR_STOP on
SELECT id AS outlet_id FROM public.outlets WHERE code='QUENA-MART-1' \gset
SELECT id AS product_id,sku,name FROM public.products WHERE sku='CUTOVER-DECIMAL' \gset
SELECT set_config('quena.test.report_outlet',:'outlet_id',false);
SELECT set_config('quena.test.report_product',:'product_id',false);
SELECT set_config('quena.test.report_sku',:'sku',false);
SELECT set_config('quena.test.report_name',:'name',false);
SELECT set_config('quena.test.report_today',(timezone('Asia/Jakarta',now())::date+2)::text,false);

-- Fixture records are disposable immutable evidence and satisfy the existing sale FKs.
DO $seed_report_sales$
DECLARE
  o uuid:=current_setting('quena.test.report_outlet')::uuid;
  product uuid:=current_setting('quena.test.report_product')::uuid;
  owner_id uuid:='a0000000-0000-4000-8000-000000000001';
  today_business date:=current_setting('quena.test.report_today')::date;
  item record;
  cart uuid;line uuid;req uuid;sale uuid;
BEGIN
  FOR item IN SELECT * FROM (VALUES
    ('a4600000-0000-4000-8000-000000000001'::uuid,'2026-10-11'::date,10000000::numeric,7000000::numeric,'QRIS'::text,0::numeric),
    ('a4600000-0000-4000-8000-000000000002'::uuid,today_business,100000::numeric,70000::numeric,'CASH'::text,0::numeric),
    ('a4600000-0000-4000-8000-000000000003'::uuid,today_business,200000::numeric,140000::numeric,'QRIS'::text,0::numeric),
    ('a4600000-0000-4000-8000-000000000004'::uuid,today_business,700000::numeric,490000::numeric,'SPLIT'::text,0::numeric)
  ) AS fixture(request_id,sale_date,amount,cogs,method,unused) LOOP
    -- The large proof row follows local yesterday so it can be queried separately.
    IF item.request_id='a4600000-0000-4000-8000-000000000001' THEN
      item.sale_date:=today_business-1;
    END IF;
    cart:=gen_random_uuid(); line:=gen_random_uuid(); sale:=gen_random_uuid(); req:=item.request_id;
    INSERT INTO public.pos_carts(id,outlet_id,created_by,status,revision)
      VALUES(cart,o,owner_id,'COMPLETED',1);
    INSERT INTO public.pos_cart_items(id,cart_id,outlet_id,product_id,quantity,observed_unit_price,
      observed_price_at,product_sku_snapshot,product_name_snapshot)
      VALUES(line,cart,o,product,1,item.amount,now(),current_setting('quena.test.report_sku'),current_setting('quena.test.report_name'));
    INSERT INTO public.pos_checkout_requests(request_id,actor_id,outlet_id,cart_id,expected_cart_revision,
      payment_payload_hash,state)
      VALUES(req,owner_id,o,cart,1,md5(req::text),'PENDING');
    INSERT INTO public.sales(id,outlet_id,cashier_id,completed_by,pos_cart_id,checkout_request_id,sale_number,
      status,subtotal,discount_total,grand_total,completed_at)
      VALUES(sale,o,owner_id,owner_id,cart,req,'QPOS-'||to_char(item.sale_date,'YYYYMMDD')||'-'||lpad(nextval('public.pos_sale_number_seq')::text,8,'0'),
      'COMPLETED',item.amount,0,item.amount,CASE WHEN item.request_id='a4600000-0000-4000-8000-000000000002'
        THEN (item.sale_date::timestamp+interval '30 minutes') AT TIME ZONE 'Asia/Jakarta'
        ELSE (item.sale_date::timestamp+'12 hours') AT TIME ZONE 'Asia/Jakarta' END);
    UPDATE public.pos_checkout_requests SET state='COMPLETED',sale_id=sale,result=jsonb_build_object('sale_id',sale),completed_at=now()
      WHERE request_id=req;
    INSERT INTO public.sale_items(id,sale_id,pos_cart_id,pos_cart_item_id,outlet_id,product_id,line_number,
      product_name_snapshot,sku_snapshot,quantity,unit_selling_price,price_checked_at)
      VALUES(gen_random_uuid(),sale,cart,line,o,product,1,current_setting('quena.test.report_name'),
        current_setting('quena.test.report_sku'),1,item.amount,now());
    IF item.method='SPLIT' THEN
      INSERT INTO public.sale_payments(sale_id,outlet_id,method,applied_amount,received_amount,change_amount,recorded_by)
        VALUES(sale,o,'CASH',300000,300000,0,owner_id),(sale,o,'CARD',400000,NULL,NULL,owner_id);
    ELSIF item.method='CASH' THEN
      INSERT INTO public.sale_payments(sale_id,outlet_id,method,applied_amount,received_amount,change_amount,recorded_by)
        VALUES(sale,o,'CASH',item.amount,item.amount,0,owner_id);
    ELSE
      INSERT INTO public.sale_payments(sale_id,outlet_id,method,applied_amount,recorded_by)
        VALUES(sale,o,item.method::public.pos_sale_payment_method,item.amount,owner_id);
    END IF;
    INSERT INTO public.sale_item_cost_evidence(sale_item_id,sale_id,outlet_id,product_id,checkout_request_id,
      quantity,valued_quantity,provisional_quantity,unvalued_quantity,resolved_cogs_amount,status)
      SELECT si.id,sale,o,product,req,1,1,0,0,item.cogs,'RESOLVED'
      FROM public.sale_items si WHERE si.sale_id=sale;
  END LOOP;
  -- Separate completed sale with missing COGS evidence: revenue and expense
  -- remain visible, while profit must remain null.
  cart:=gen_random_uuid();line:=gen_random_uuid();sale:=gen_random_uuid();req:='a4600000-0000-4000-8000-000000000005';
  INSERT INTO public.pos_carts(id,outlet_id,created_by,status,revision) VALUES(cart,o,owner_id,'COMPLETED',1);
  INSERT INTO public.pos_cart_items(id,cart_id,outlet_id,product_id,quantity,observed_unit_price,observed_price_at,product_sku_snapshot,product_name_snapshot)
    VALUES(line,cart,o,product,1,500000,now(),current_setting('quena.test.report_sku'),current_setting('quena.test.report_name'));
  INSERT INTO public.pos_checkout_requests(request_id,actor_id,outlet_id,cart_id,expected_cart_revision,payment_payload_hash,state)
    VALUES(req,owner_id,o,cart,1,md5(req::text),'PENDING');
  INSERT INTO public.sales(id,outlet_id,cashier_id,completed_by,pos_cart_id,checkout_request_id,sale_number,status,subtotal,discount_total,grand_total,completed_at)
    VALUES(sale,o,owner_id,owner_id,cart,req,'QPOS-'||to_char(today_business+1,'YYYYMMDD')||'-'||lpad(nextval('public.pos_sale_number_seq')::text,8,'0'),
      'COMPLETED',500000,0,500000,((today_business+1)::timestamp+'12 hours') AT TIME ZONE 'Asia/Jakarta');
  UPDATE public.pos_checkout_requests SET state='COMPLETED',sale_id=sale,result=jsonb_build_object('sale_id',sale),completed_at=now() WHERE request_id=req;
  INSERT INTO public.sale_items(id,sale_id,pos_cart_id,pos_cart_item_id,outlet_id,product_id,line_number,product_name_snapshot,sku_snapshot,quantity,unit_selling_price,price_checked_at)
    VALUES(gen_random_uuid(),sale,cart,line,o,product,1,current_setting('quena.test.report_name'),current_setting('quena.test.report_sku'),1,500000,now());
  INSERT INTO public.sale_payments(sale_id,outlet_id,method,applied_amount,recorded_by) VALUES(sale,o,'E_WALLET',500000,owner_id);
  INSERT INTO public.operational_expenses(id,outlet_id,expense_number,expense_date,category,description,amount,
    payment_method,status,created_by,created_by_name,updated_by,posted_by,posted_by_name,posted_at,
    cancelled_by,cancelled_by_name,cancelled_at,cancellation_reason)
  VALUES(gen_random_uuid(),o,'QEXP-REPORT-POSTED-YESTERDAY',today_business-1,'LISTRIK','Report fixture posted yesterday',1000000,'BANK_TRANSFER','POSTED',owner_id,'Stage Owner',owner_id,owner_id,'Stage Owner',now(),NULL,NULL,NULL,NULL),
    (gen_random_uuid(),o,'QEXP-REPORT-POSTED-TODAY',today_business,'INTERNET','Report fixture posted today',200000,'CASH','POSTED',owner_id,'Stage Owner',owner_id,owner_id,'Stage Owner',now(),NULL,NULL,NULL,NULL),
    (gen_random_uuid(),o,'QEXP-REPORT-DRAFT',today_business,'ATK','Report fixture draft',500000,'CASH','DRAFT',owner_id,'Stage Owner',owner_id,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
    (gen_random_uuid(),o,'QEXP-REPORT-CANCELLED',today_business,'TRANSPORT','Report fixture cancelled',250000,'CASH','CANCELLED',owner_id,'Stage Owner',owner_id,NULL,NULL,NULL,owner_id,'Stage Owner',now(),'Cancelled fixture'),
    (gen_random_uuid(),o,'QEXP-REPORT-POSTED-INCOMPLETE',today_business+1,'MAINTENANCE','Report fixture incomplete sale day',400000,'CASH','POSTED',owner_id,'Stage Owner',owner_id,owner_id,'Stage Owner',now(),NULL,NULL,NULL,NULL),
    (gen_random_uuid(),o,'QEXP-REPORT-NEGATIVE-OPERATING',today_business+3,'BIAYA_ADMIN','Report fixture expense-only period',150000,'OTHER','POSTED',owner_id,'Stage Owner',owner_id,owner_id,'Stage Owner',now(),NULL,NULL,NULL,NULL);
END $seed_report_sales$;

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false);
SET ROLE authenticated;
DO $assert_report_arithmetic$
DECLARE today_business date:=current_setting('quena.test.report_today')::date;business_today date:=timezone('Asia/Jakarta',now())::date;result jsonb;day_result jsonb;week_result jsonb;incomplete_result jsonb;negative_result jsonb;msg text;failed boolean;dashboard jsonb;
BEGIN
  result:=public.owner_reports_read(today_business-1,today_business-1,today_business-2,today_business-2);
  IF (result->'kpis'->>'revenue')::numeric<>10000000
    OR (result->'kpis'->>'transactions')::integer<>1
    OR (result->'kpis'->>'gross_profit')::numeric<>3000000
    OR (result->'kpis'->>'gross_margin')::numeric<>30
    OR (result->'kpis'->>'expenses')::numeric<>1000000
    OR (result->'kpis'->>'operating_profit')::numeric<>2000000 THEN
    RAISE EXCEPTION 'Owner report 10m/7m/1m arithmetic failed: %',result->'kpis';
  END IF;
  day_result:=public.owner_reports_read(today_business,today_business,today_business-1,today_business-1);
  IF (day_result->'kpis'->>'revenue')::numeric<>1000000
    OR (day_result->'kpis'->>'transactions')::integer<>3
    OR (day_result->'kpis'->>'average_basket')::numeric<>333333.33
    OR (day_result->'kpis'->>'expenses')::numeric<>200000
    OR jsonb_array_length(day_result->'top_products')<>1
    OR day_result->'payment_reconciliation'->>'matches'<>'true'
    OR (SELECT sum((x->>'amount')::numeric) FROM jsonb_array_elements(day_result->'payments') x)<>1000000
    OR (SELECT (x->>'amount')::numeric FROM jsonb_array_elements(day_result->'payments') x WHERE x->>'method'='CASH')<>400000
    OR (SELECT (x->>'amount')::numeric FROM jsonb_array_elements(day_result->'payments') x WHERE x->>'method'='QRIS')<>200000
    OR (SELECT (x->>'amount')::numeric FROM jsonb_array_elements(day_result->'payments') x WHERE x->>'method'='CARD')<>400000 THEN
    RAISE EXCEPTION 'Multiple sale, split payment, or expense lifecycle arithmetic failed: %',day_result;
  END IF;
  week_result:=public.owner_reports_read(today_business-89,today_business,today_business-179,today_business-90);
  IF week_result->>'trend_granularity'<>'WEEK' OR jsonb_array_length(week_result->'sales_trend')>14
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(week_result->'sales_trend') x WHERE x->>'revenue'='0.00') THEN
    RAISE EXCEPTION 'Long period trend was not bucketed weekly: %',week_result->>'trend_granularity';
  END IF;
  incomplete_result:=public.owner_reports_read(today_business+1,today_business+1,today_business,today_business);
  IF (incomplete_result->'kpis'->>'revenue')::numeric<>500000
    OR (incomplete_result->'kpis'->>'transactions')::integer<>1
    OR (incomplete_result->'kpis'->>'expenses')::numeric<>400000
    OR incomplete_result->'kpis'->>'gross_profit' IS NOT NULL
    OR incomplete_result->'kpis'->>'gross_margin' IS NOT NULL
    OR incomplete_result->'kpis'->>'operating_profit' IS NOT NULL
    OR incomplete_result->'kpis'->>'profit_status'<>'INCOMPLETE' THEN
    RAISE EXCEPTION 'Incomplete COGS was treated as zero or hid revenue/expense: %',incomplete_result->'kpis';
  END IF;
  negative_result:=public.owner_reports_read(today_business+3,today_business+3,today_business+2,today_business+2);
  IF (negative_result->'kpis'->>'gross_profit')::numeric<>0
    OR (negative_result->'kpis'->>'operating_profit')::numeric<>-150000 THEN
    RAISE EXCEPTION 'Known negative operating profit was flattened: %',negative_result->'kpis';
  END IF;
  IF day_result->'current_inventory'->>'as_of'<>business_today::text
    OR day_result->'current_tempo'->>'as_of'<>business_today::text THEN
    RAISE EXCEPTION 'Current snapshot panels are not labeled by current local date';
  END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',false);
  result:=public.owner_reports_read(today_business,today_business,today_business-1,today_business-1);
  IF result IS NULL OR result->'kpis'->>'revenue'<>'1000000.00' THEN
    RAISE EXCEPTION 'ADMIN report access failed: %',result;
  END IF;
  dashboard:=public.owner_dashboard_read(7);
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false);
  result:=public.owner_reports_read(business_today,business_today,business_today-1,business_today-1);
  IF result->'kpis'->>'revenue'<>dashboard->'sales'->>'today_total'
    OR result->'kpis'->>'transactions'<>dashboard->'sales'->>'today_count'
    OR result->'kpis'->>'expenses'<>dashboard->'expenses'->>'expenses_today'
    OR result->'kpis'->>'gross_profit'<>dashboard->'profit'->>'gross_profit'
    OR result->'kpis'->>'operating_profit'<>dashboard->'expenses'->>'operating_profit' THEN
    RAISE EXCEPTION 'Dashboard/report same-day values do not reconcile: % / %',result->'kpis',dashboard;
  END IF;
  IF day_result->'top_products'->0 ? 'hpp' OR day_result->'top_products'->0 ? 'cogs'
    OR day_result ? 'source_layers' OR day_result ? 'current_wac' THEN
    RAISE EXCEPTION 'Restricted costing details leaked to report response';
  END IF;
  failed:=false;
  BEGIN PERFORM public.owner_reports_read(today_business-366,today_business,today_business-2,today_business-1);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR msg<>'OWNER_REPORTS_PERIOD_INVALID' THEN RAISE EXCEPTION '366-day custom range was not bounded: %',msg; END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',false);
  failed:=false;
  BEGIN PERFORM public.owner_reports_read(today_business,today_business,today_business-1,today_business-1);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR msg<>'OWNER_REPORTS_UNAUTHORIZED' THEN RAISE EXCEPTION 'KASIR report RPC access was allowed: %',msg; END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',false);
  failed:=false;
  BEGIN PERFORM public.owner_reports_read(today_business,today_business,today_business-1,today_business-1);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;failed:=true;END;
  IF NOT failed OR msg<>'OWNER_REPORTS_UNAUTHORIZED' THEN RAISE EXCEPTION 'GUDANG report RPC access was allowed: %',msg; END IF;
END $assert_report_arithmetic$;
RESET ROLE;
SELECT 'OWNER_REPORTS_POSTGRESQL_RUNTIME_PASS' AS result;
