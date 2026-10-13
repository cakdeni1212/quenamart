-- Rollback-only C2 chronology matrix on disposable PostgreSQL 15 WAC_ACTIVE staging.
-- The source timestamps below model the real iPos event time; uploaded/commit time is later.
\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database()<>'quena_stock_staging' OR inet_server_port()<>55441
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR current_setting('server_version_num')::integer/10000<>15
    OR NOT EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE status='WAC_ACTIVE') THEN
    RAISE EXCEPTION 'Refusing C2 runtime outside disposable local PostgreSQL 15 WAC_ACTIVE staging';
  END IF;
END; $guard$;

BEGIN;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);

CREATE FUNCTION pg_temp.c2_post_receipt(p_product uuid,p_quantity numeric,p_cost numeric) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE o uuid;supplier uuid;receipt uuid;item uuid;revision integer;request_id uuid;result jsonb;
BEGIN
  SELECT id INTO STRICT o FROM public.outlets WHERE code='QUENA-MART-1';
  supplier:=public.purchase_supplier_upsert(NULL,'C2 opname staging supplier',NULL,NULL,NULL,true);
  receipt:=public.purchase_receipt_create_draft(o,supplier,now(),'Disposable C2 opening fixture');
  result:=public.purchase_receipt_save_draft(receipt,1,now(),NULL,jsonb_build_array(jsonb_build_object(
    'product_id',p_product,'accepted_quantity',p_quantity,'bonus_quantity',0,'rejected_quantity',0)));
  IF result->>'ok'<>'true' THEN RAISE EXCEPTION 'C2 receipt draft failed: %',result; END IF;
  SELECT id INTO STRICT item FROM public.purchase_receipt_items WHERE receipt_id=receipt AND product_id=p_product;
  SELECT draft_revision INTO STRICT revision FROM public.purchase_receipts WHERE id=receipt;
  result:=public.purchase_receipt_acquisition_estimate_save(receipt,item,revision,0,'MANAGER_ESTIMATE',p_cost,'C2 fixture',NULL);
  IF result->>'ok'<>'true' THEN RAISE EXCEPTION 'C2 acquisition estimate failed: %',result; END IF;
  request_id:=public.issue_purchase_receipt_post_intent(receipt);
  result:=public.apply_purchase_receipt_post_intent(request_id);
  IF result->>'code'<>'POSTED' THEN RAISE EXCEPTION 'C2 receipt did not post: %',result; END IF;
END $$;

CREATE FUNCTION pg_temp.c2_stock_op(p_op text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE request_id uuid;result jsonb;
BEGIN
  request_id:=public.issue_stock_operation_intent(p_op,p_payload);
  result:=public.apply_stock_operation_intent(request_id);
  RETURN result;
END $$;

CREATE FUNCTION pg_temp.c2_open_count(p_outlet uuid,p_product uuid,p_quantity numeric) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE result jsonb;v_session uuid;revision integer;item_id uuid;
BEGIN
  result:=pg_temp.c2_stock_op('CREATE_SESSION',jsonb_build_object('outlet_id',p_outlet,
    'scope_type','PARTIAL','product_ids',jsonb_build_array(p_product)));
  v_session:=(result->>'sessionId')::uuid;
  IF v_session IS NULL THEN RAISE EXCEPTION 'C2 session create failed: %',result; END IF;
  SELECT id,revision_no INTO STRICT item_id,revision FROM public.stock_opname_items
    WHERE stock_opname_items.session_id=v_session AND product_id=p_product;
  result:=pg_temp.c2_stock_op('RECORD_COUNT',jsonb_build_object('session_id',v_session,'product_id',p_product,
    'physical_quantity',p_quantity,'expected_revision',revision));
  IF result->>'ok'<>'true' THEN RAISE EXCEPTION 'C2 count failed: %',result; END IF;
  RETURN v_session;
END $$;

CREATE FUNCTION pg_temp.c2_submit(p_session uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE result jsonb;
BEGIN
  result:=pg_temp.c2_stock_op('SUBMIT_REVIEW',jsonb_build_object('session_id',p_session));
  IF result->>'ok'<>'true' THEN RAISE EXCEPTION 'C2 submit failed: %',result; END IF;
END $$;

CREATE FUNCTION pg_temp.c2_post(p_session uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE result jsonb;
BEGIN
  result:=pg_temp.c2_stock_op('POST_SESSION',jsonb_build_object('session_id',p_session));
  IF result->>'ok'<>'true' THEN RAISE EXCEPTION 'C2 post failed: %',result; END IF;
END $$;

CREATE FUNCTION pg_temp.c2_recount_post(p_session uuid,p_product uuid,p_physical numeric) RETURNS void LANGUAGE plpgsql AS $$
DECLARE result jsonb;revision integer;
BEGIN
  SELECT revision_no INTO STRICT revision FROM public.stock_opname_items WHERE session_id=p_session AND product_id=p_product;
  result:=pg_temp.c2_stock_op('REBASE_ITEM',jsonb_build_object('session_id',p_session,'product_id',p_product,
    'expected_revision',revision));
  IF result->>'ok'<>'true' THEN RAISE EXCEPTION 'C2 rebase failed: %',result; END IF;
  SELECT revision_no INTO STRICT revision FROM public.stock_opname_items WHERE session_id=p_session AND product_id=p_product;
  result:=pg_temp.c2_stock_op('RECORD_COUNT',jsonb_build_object('session_id',p_session,'product_id',p_product,
    'physical_quantity',p_physical,'expected_revision',revision));
  IF result->>'ok'<>'true' THEN RAISE EXCEPTION 'C2 recount failed: %',result; END IF;
  PERFORM pg_temp.c2_submit(p_session); PERFORM pg_temp.c2_post(p_session);
END $$;

CREATE FUNCTION pg_temp.c2_batch(p_items jsonb) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE o uuid;batch_id uuid;item jsonb;product_id uuid;transaction_id uuid;v_sku text;qty numeric;source_time timestamptz;
  n integer:=0;total_qty numeric:=0;total_amount numeric:=0;
BEGIN
  SELECT id INTO STRICT o FROM public.outlets WHERE code='QUENA-MART-1';
  FOR item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    n:=n+1;qty:=(item->>'quantity')::numeric;total_qty:=total_qty+qty;total_amount:=total_amount+qty*100;
  END LOOP;
  INSERT INTO public.ipos_sales_import_batches(outlet_id,upload_request_id,original_filename,file_sha256,
    report_from,report_to,transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,
    reconciliation,status,revision,uploaded_by)
  VALUES(o,gen_random_uuid(),'c2-opname-timing.xls',md5(gen_random_uuid()::text)||md5(gen_random_uuid()::text),
    timezone('Asia/Jakarta',now())::date,timezone('Asia/Jakarta',now())::date,n,n,total_qty,total_amount,
    jsonb_build_object('quantity',total_qty,'grandTotal',total_amount),
    '{"isReconciled":true,"differences":[]}','UPLOADED',1,auth.uid()) RETURNING id INTO batch_id;
  n:=0;
  FOR item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    n:=n+1;qty:=(item->>'quantity')::numeric;source_time:=(item->>'occurredAt')::timestamptz;
    product_id:=(item->>'productId')::uuid;
    SELECT p.sku INTO STRICT v_sku FROM public.products p WHERE p.id=product_id;
    INSERT INTO public.ipos_sales_import_transactions(batch_id,source_row_number,source_transaction_number,
      source_occurred_at,raw_transaction_total,raw_data)
    VALUES(batch_id,n,lpad((100000+n)::text,6,'0')||'/KSR/UTM/1026',source_time,qty*100,'{}') RETURNING id INTO transaction_id;
    INSERT INTO public.ipos_sales_import_lines(batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,
      raw_quantity,raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data,resolution)
    SELECT batch_id,transaction_id,n*10,p.sku,p.name,qty,p.unit_label,100,0,qty*100,'{}','PENDING'
      FROM public.products p WHERE p.sku=v_sku;
  END LOOP;
  RETURN batch_id;
END $$;

CREATE FUNCTION pg_temp.c2_recheck(p_batch uuid) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE result jsonb;
BEGIN
  result:=public.ipos_sales_import_recheck(p_batch,gen_random_uuid());
  RETURN result;
END $$;

CREATE FUNCTION pg_temp.c2_import(p_batch uuid) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE result jsonb;revision integer;
BEGIN
  result:=pg_temp.c2_recheck(p_batch);
  IF result->>'status'<>'READY' THEN RAISE EXCEPTION 'C2 batch not ready: %',result; END IF;
  SELECT b.revision INTO STRICT revision FROM public.ipos_sales_import_batches b WHERE b.id=p_batch;
  RETURN public.ipos_sales_import_commit(p_batch,revision,gen_random_uuid());
END $$;

SAVEPOINT scenario1;
DO $scenario1$ DECLARE o uuid;p uuid;batch uuid;session uuid;result jsonb;stock numeric;cost_events bigint;
BEGIN
  SELECT id INTO o FROM public.outlets WHERE code='QUENA-MART-1';
  SELECT id INTO p FROM public.products WHERE sku='CUTOVER-MULTI';
  PERFORM pg_temp.c2_post_receipt(p,40,120);
  batch:=pg_temp.c2_batch(jsonb_build_array(jsonb_build_object('productId',p,'quantity',2,'occurredAt',now()-interval '1 minute')));
  session:=pg_temp.c2_open_count(o,p,42.125); -- The 2-unit pre-count sale is already included in this physical count.
  result:=pg_temp.c2_import(batch);
  IF result->>'status'<>'COMMITTED' OR (SELECT requires_recount FROM public.stock_opname_items WHERE session_id=session AND product_id=p) IS NOT TRUE THEN
    RAISE EXCEPTION 'Scenario 1 did not import once and require a recount: %',result;
  END IF;
  PERFORM pg_temp.c2_recount_post(session,p,42.125);
  SELECT effective_quantity INTO stock FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p;
  SELECT count(*) INTO cost_events FROM public.inventory_cost_events WHERE source_entity_type='IPOS_IMPORT_INVENTORY_DEPLETION'
    AND source_entity_id IN (SELECT id FROM public.ipos_sales_import_lines WHERE batch_id=batch);
  IF stock<>42.125 OR cost_events<>1 OR (SELECT count(*) FROM public.stock_movements WHERE ipos_sales_import_line_id IN
      (SELECT id FROM public.ipos_sales_import_lines WHERE batch_id=batch))<>1 THEN
    RAISE EXCEPTION 'Scenario 1 double-subtracted or missed the sale: stock %, movements %, costing %',stock,
      (SELECT count(*) FROM public.stock_movements WHERE ipos_sales_import_line_id IN (SELECT id FROM public.ipos_sales_import_lines WHERE batch_id=batch)),cost_events;
  END IF;
  RAISE NOTICE 'C2 SCENARIO 1 PASS: pre-count sale was included in recount; final stock 42.125, one movement/depletion';
END $scenario1$;
ROLLBACK TO SAVEPOINT scenario1;

SAVEPOINT scenario2;
DO $scenario2$ DECLARE o uuid;p uuid;session uuid;batch uuid;result jsonb;stock numeric;counted_at timestamptz;
BEGIN
  SELECT id INTO o FROM public.outlets WHERE code='QUENA-MART-1'; SELECT id INTO p FROM public.products WHERE sku='CUTOVER-MULTI';
  PERFORM pg_temp.c2_post_receipt(p,40,120);
  session:=pg_temp.c2_open_count(o,p,20);
  SELECT last_counted_at INTO STRICT counted_at FROM public.stock_opname_items WHERE session_id=session AND product_id=p;
  batch:=pg_temp.c2_batch(jsonb_build_array(jsonb_build_object('productId',p,'quantity',3,'occurredAt',counted_at+interval '1 hour')));
  result:=pg_temp.c2_import(batch);
  IF result->>'status'<>'COMMITTED' OR (SELECT requires_recount FROM public.stock_opname_items WHERE session_id=session AND product_id=p) IS NOT TRUE THEN
    RAISE EXCEPTION 'Scenario 2 did not stale the post-count sale line'; END IF;
  PERFORM pg_temp.c2_recount_post(session,p,17);
  SELECT effective_quantity INTO stock FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p;
  IF stock<>17 THEN RAISE EXCEPTION 'Scenario 2 lost post-count sale: expected 17, got %',stock; END IF;
  RAISE NOTICE 'C2 SCENARIO 2 PASS: post-count sale required recount; final stock 17';
END $scenario2$;
ROLLBACK TO SAVEPOINT scenario2;

SAVEPOINT scenario3;
DO $scenario3$ DECLARE o uuid;p uuid;session uuid;batch uuid;result jsonb;stock numeric;
BEGIN
  SELECT id INTO o FROM public.outlets WHERE code='QUENA-MART-1'; SELECT id INTO p FROM public.products WHERE sku='CUTOVER-MULTI';
  PERFORM pg_temp.c2_post_receipt(p,40,120);
  batch:=pg_temp.c2_batch(jsonb_build_array(jsonb_build_object('productId',p,'quantity',1,'occurredAt',now()-interval '30 minutes')));
  session:=pg_temp.c2_open_count(o,p,43.125); PERFORM pg_temp.c2_submit(session);
  result:=pg_temp.c2_import(batch);
  IF result->>'status'<>'COMMITTED' OR (SELECT status FROM public.stock_opname_sessions WHERE id=session)<>'COUNTING'
    OR (SELECT requires_recount FROM public.stock_opname_items WHERE session_id=session AND product_id=p) IS NOT TRUE THEN
    RAISE EXCEPTION 'Scenario 3 did not return reviewed session to recount: %',result; END IF;
  PERFORM pg_temp.c2_recount_post(session,p,43.125);
  SELECT effective_quantity INTO stock FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p;
  IF stock<>43.125 THEN RAISE EXCEPTION 'Scenario 3 pre-count sale was subtracted twice: %',stock; END IF;
  RAISE NOTICE 'C2 SCENARIO 3 PASS: import after review returned to recount; pre-count sale was not double-subtracted';
END $scenario3$;
ROLLBACK TO SAVEPOINT scenario3;

SAVEPOINT scenario4;
DO $scenario4$ DECLARE o uuid;p uuid;session uuid;batch uuid;result jsonb;stock numeric;counted_at timestamptz;
BEGIN
  SELECT id INTO o FROM public.outlets WHERE code='QUENA-MART-1'; SELECT id INTO p FROM public.products WHERE sku='CUTOVER-MULTI';
  PERFORM pg_temp.c2_post_receipt(p,40,120);
  session:=pg_temp.c2_open_count(o,p,20); PERFORM pg_temp.c2_submit(session);
  SELECT last_counted_at INTO STRICT counted_at FROM public.stock_opname_items WHERE session_id=session AND product_id=p;
  batch:=pg_temp.c2_batch(jsonb_build_array(jsonb_build_object('productId',p,'quantity',3,'occurredAt',counted_at+interval '1 hour')));
  result:=pg_temp.c2_import(batch);
  IF result->>'status'<>'COMMITTED' OR (SELECT status FROM public.stock_opname_sessions WHERE id=session)<>'COUNTING' THEN
    RAISE EXCEPTION 'Scenario 4 did not require renewed count after review'; END IF;
  PERFORM pg_temp.c2_recount_post(session,p,17);
  SELECT effective_quantity INTO stock FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p;
  IF stock<>17 THEN RAISE EXCEPTION 'Scenario 4 lost post-count movement: %',stock; END IF;
  RAISE NOTICE 'C2 SCENARIO 4 PASS: post-count import after review required recount; final stock 17';
END $scenario4$;
ROLLBACK TO SAVEPOINT scenario4;

SAVEPOINT scenario5;
DO $scenario5$ DECLARE o uuid;p uuid;session uuid;batch uuid;result jsonb;revision integer;error_message text;
  before_stock numeric;before_value numeric;before_layers numeric;
BEGIN
  SELECT id INTO o FROM public.outlets WHERE code='QUENA-MART-1'; SELECT id INTO p FROM public.products WHERE sku='CUTOVER-MULTI';
  PERFORM pg_temp.c2_post_receipt(p,40,120);
  batch:=pg_temp.c2_batch(jsonb_build_array(jsonb_build_object('productId',p,'quantity',1,'occurredAt',now()-interval '1 minute')));
  session:=pg_temp.c2_open_count(o,p,43.125); PERFORM pg_temp.c2_submit(session); PERFORM pg_temp.c2_post(session);
  SELECT effective_quantity INTO before_stock FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p;
  SELECT inventory_value INTO before_value FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=p;
  SELECT sum(remaining_valued_quantity+remaining_unvalued_quantity) INTO before_layers
    FROM public.inventory_cost_source_layer_balances WHERE outlet_id=o AND product_id=p;
  result:=pg_temp.c2_recheck(batch);
  IF result->>'status'<>'PREFLIGHT_BLOCKED' OR result->>'postedOpnameConflictCount'<>'1' THEN
    RAISE EXCEPTION 'Scenario 5 conflict was not deterministic: %',result; END IF;
  SELECT b.revision INTO STRICT revision FROM public.ipos_sales_import_batches b WHERE b.id=batch;
  error_message:=NULL;
  BEGIN PERFORM public.ipos_sales_import_commit(batch,revision,gen_random_uuid()); EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS error_message=MESSAGE_TEXT; END;
  IF error_message<>'IPOS_SALES_IMPORT_POSTED_OPNAME_CONFLICT' THEN RAISE EXCEPTION 'Scenario 5 wrong commit refusal: %',error_message; END IF;
  result:=pg_temp.c2_recheck(batch);
  SELECT b.revision INTO STRICT revision FROM public.ipos_sales_import_batches b WHERE b.id=batch;
  error_message:=NULL;
  BEGIN PERFORM public.ipos_sales_import_commit(batch,revision,gen_random_uuid()); EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS error_message=MESSAGE_TEXT; END;
  IF error_message<>'IPOS_SALES_IMPORT_POSTED_OPNAME_CONFLICT'
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p) IS DISTINCT FROM before_stock
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=p) IS DISTINCT FROM before_value
    OR (SELECT sum(remaining_valued_quantity+remaining_unvalued_quantity) FROM public.inventory_cost_source_layer_balances
      WHERE outlet_id=o AND product_id=p) IS DISTINCT FROM before_layers
    OR EXISTS(SELECT 1 FROM public.sales WHERE source_import_batch_id=batch)
    OR EXISTS(SELECT 1 FROM public.stock_movements WHERE ipos_sales_import_line_id IN
      (SELECT id FROM public.ipos_sales_import_lines WHERE batch_id=batch))
    OR EXISTS(SELECT 1 FROM public.inventory_cost_events WHERE source_entity_type='IPOS_IMPORT_INVENTORY_DEPLETION'
      AND source_entity_id IN (SELECT id FROM public.ipos_sales_import_lines WHERE batch_id=batch)) THEN
    RAISE EXCEPTION 'Scenario 5 retry mutated a posted physical count or returned another result'; END IF;
  RAISE NOTICE 'C2 SCENARIO 5 PASS: pre-count late import stays blocked on retry; no sale/stock/WAC mutation';
END $scenario5$;
ROLLBACK TO SAVEPOINT scenario5;

SAVEPOINT scenario6;
DO $scenario6$ DECLARE o uuid;p uuid;session uuid;batch uuid;result jsonb;replay jsonb;stock numeric;counted_at timestamptz;
  commit_revision integer;commit_request uuid;
BEGIN
  SELECT id INTO o FROM public.outlets WHERE code='QUENA-MART-1'; SELECT id INTO p FROM public.products WHERE sku='CUTOVER-MULTI';
  PERFORM pg_temp.c2_post_receipt(p,40,120);
  session:=pg_temp.c2_open_count(o,p,20); PERFORM pg_temp.c2_submit(session); PERFORM pg_temp.c2_post(session);
  SELECT last_counted_at INTO STRICT counted_at FROM public.stock_opname_items WHERE session_id=session AND product_id=p;
  batch:=pg_temp.c2_batch(jsonb_build_array(jsonb_build_object('productId',p,'quantity',3,'occurredAt',counted_at+interval '1 hour')));
  result:=pg_temp.c2_import(batch);
  SELECT effective_quantity INTO stock FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p;
  IF result->>'status'<>'COMMITTED' OR stock<>17
    OR (SELECT count(*) FROM public.stock_movements WHERE ipos_sales_import_line_id IN
      (SELECT id FROM public.ipos_sales_import_lines WHERE batch_id=batch))<>1
    OR (SELECT count(*) FROM public.inventory_cost_events WHERE source_entity_type='IPOS_IMPORT_INVENTORY_DEPLETION'
      AND source_entity_id IN (SELECT id FROM public.ipos_sales_import_lines WHERE batch_id=batch))<>1
    OR EXISTS(SELECT 1 FROM public.sale_item_cost_evidence e JOIN public.sales s ON s.id=e.sale_id WHERE s.source_import_batch_id=batch) THEN
    RAISE EXCEPTION 'Scenario 6 safe post-boundary sale did not post exactly once at stock 17'; END IF;
  SELECT r.expected_revision,r.request_id INTO STRICT commit_revision,commit_request
    FROM public.ipos_sales_import_commit_requests r JOIN public.ipos_sales_import_batches b ON b.commit_request_id=r.request_id
    WHERE b.id=batch;
  replay:=public.ipos_sales_import_commit(batch,commit_revision,commit_request);
  IF replay IS DISTINCT FROM result OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p)<>17
    OR (SELECT count(*) FROM public.stock_movements WHERE ipos_sales_import_line_id IN
      (SELECT id FROM public.ipos_sales_import_lines WHERE batch_id=batch))<>1 THEN
    RAISE EXCEPTION 'Scenario 6 same-request replay duplicated safe post-count sale'; END IF;
  RAISE NOTICE 'C2 SCENARIO 6 PASS: post-count/post-posting sale allowed; posted quantity 20 - 3 = 17, WAC depleted once, no sale COGS';
END $scenario6$;
ROLLBACK TO SAVEPOINT scenario6;

SAVEPOINT normal_opname_reversal;
DO $opname_reversal$ DECLARE o uuid;p uuid;session uuid;movement uuid;before_stock numeric;after_stock numeric;result jsonb;
BEGIN
  SELECT id INTO o FROM public.outlets WHERE code='QUENA-MART-1'; SELECT id INTO p FROM public.products WHERE sku='CUTOVER-MULTI';
  PERFORM pg_temp.c2_post_receipt(p,40,120);
  SELECT effective_quantity INTO before_stock FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p;
  session:=pg_temp.c2_open_count(o,p,20); PERFORM pg_temp.c2_submit(session); PERFORM pg_temp.c2_post(session);
  SELECT m.id INTO STRICT movement FROM public.stock_movements m JOIN public.stock_opname_items i ON i.id=m.opname_item_id
    WHERE i.session_id=session AND m.movement_type='OPNAME_ADJUSTMENT';
  result:=pg_temp.c2_stock_op('REVERSE_MOVEMENT',jsonb_build_object('movement_id',movement,'reason','C2 disposable opname reversal'));
  SELECT effective_quantity INTO after_stock FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p;
  IF result->>'ok'<>'true' OR after_stock IS DISTINCT FROM before_stock
    OR (SELECT count(*) FROM public.stock_movements WHERE reverses_movement_id=movement)<>1 THEN
    RAISE EXCEPTION 'Normal posted-opname reversal regression failed: %, stock % -> %',result,before_stock,after_stock; END IF;
  RAISE NOTICE 'C2 NORMAL OPNAME REVERSAL PASS: existing exact inverse remains intact';
END $opname_reversal$;
ROLLBACK TO SAVEPOINT normal_opname_reversal;

SAVEPOINT same_day_sales;
DO $multisale$ DECLARE o uuid;p uuid;session uuid;batch uuid;result jsonb;stock numeric;movement_qty numeric;
BEGIN
  SELECT id INTO o FROM public.outlets WHERE code='QUENA-MART-1'; SELECT id INTO p FROM public.products WHERE sku='CUTOVER-MULTI';
  PERFORM pg_temp.c2_post_receipt(p,40,120);
  session:=pg_temp.c2_open_count(o,p,20);
  batch:=pg_temp.c2_batch(jsonb_build_array(
    jsonb_build_object('productId',p,'quantity',2,'occurredAt',now()-interval '4 hours'),
    jsonb_build_object('productId',p,'quantity',1,'occurredAt',now()-interval '30 minutes'),
    jsonb_build_object('productId',p,'quantity',3,'occurredAt',now()+interval '1 hour'),
    jsonb_build_object('productId',p,'quantity',2,'occurredAt',now()+interval '5 hours')));
  result:=pg_temp.c2_import(batch);
  IF result->>'transactionCount'<>'4' OR (SELECT requires_recount FROM public.stock_opname_items WHERE session_id=session AND product_id=p) IS NOT TRUE THEN
    RAISE EXCEPTION 'Multi-sale batch did not atomically require recount: %',result; END IF;
  PERFORM pg_temp.c2_recount_post(session,p,15);
  SELECT effective_quantity INTO stock FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p;
  SELECT sum(quantity_delta) INTO movement_qty FROM public.stock_movements WHERE ipos_sales_import_line_id IN
    (SELECT id FROM public.ipos_sales_import_lines WHERE batch_id=batch);
  IF stock<>15 OR movement_qty<>-8 OR (SELECT count(*) FROM public.inventory_cost_events WHERE source_entity_type='IPOS_IMPORT_INVENTORY_DEPLETION'
      AND source_entity_id IN (SELECT id FROM public.ipos_sales_import_lines WHERE batch_id=batch))<>4 THEN
    RAISE EXCEPTION 'Same-day 08:00/09:30 sales double-counted or 11:00/15:00 sales lost: stock %, OUT %',stock,movement_qty; END IF;
  RAISE NOTICE 'C2 MULTI-SALE PASS: 08:00+09:30 reflected in count, 11:00+15:00 included after recount; final 15 (not 12 or 20)';
END $multisale$;
ROLLBACK TO SAVEPOINT same_day_sales;

SAVEPOINT recount_boundary;
DO $recount$ DECLARE o uuid;p uuid;session uuid;batch uuid;result jsonb;first_count timestamptz;latest_count timestamptz;stock numeric;
BEGIN
  SELECT id INTO o FROM public.outlets WHERE code='QUENA-MART-1'; SELECT id INTO p FROM public.products WHERE sku='CUTOVER-MULTI';
  PERFORM pg_temp.c2_post_receipt(p,40,120);
  session:=pg_temp.c2_open_count(o,p,20);
  SELECT last_counted_at INTO STRICT first_count FROM public.stock_opname_items WHERE session_id=session AND product_id=p;
  -- Disposable fixture clock shift models 10:00 -> 12:00 sale -> 14:00 recount; writer reads this persisted count field.
  UPDATE public.stock_opname_items SET last_counted_at=now()-interval '4 hours' WHERE session_id=session AND product_id=p;
  -- Only the mutable current item projection is time-shifted in this disposable fixture;
  -- immutable count-event evidence remains untouched.
  SELECT last_counted_at INTO STRICT first_count FROM public.stock_opname_items WHERE session_id=session AND product_id=p;
  result:=pg_temp.c2_stock_op('RECORD_COUNT',jsonb_build_object('session_id',session,'product_id',p,
    'physical_quantity',18,'expected_revision',(SELECT revision_no FROM public.stock_opname_items WHERE session_id=session AND product_id=p)));
  IF result->>'ok'<>'true' THEN RAISE EXCEPTION 'Recount event failed: %',result; END IF;
  SELECT last_counted_at INTO STRICT latest_count FROM public.stock_opname_items WHERE session_id=session AND product_id=p;
  IF latest_count<=first_count THEN RAISE EXCEPTION 'Recount timestamp did not advance'; END IF;
  batch:=pg_temp.c2_batch(jsonb_build_array(
    jsonb_build_object('productId',p,'quantity',2,'occurredAt',now()-interval '3 hours'),
    jsonb_build_object('productId',p,'quantity',1,'occurredAt',now()+interval '1 hour')));
  result:=pg_temp.c2_import(batch);
  PERFORM pg_temp.c2_recount_post(session,p,17);
  SELECT effective_quantity INTO stock FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p;
  IF result->>'status'<>'COMMITTED' OR stock<>17 THEN RAISE EXCEPTION 'Latest recount boundary did not yield 17: %, %',result,stock; END IF;
  RAISE NOTICE 'C2 RECOUNT PASS: 12:00 sale is reflected by 14:00 recount; 16:00 sale is included after it; final 17';
END $recount$;
ROLLBACK TO SAVEPOINT recount_boundary;

SAVEPOINT batch_atomicity;
DO $atomicity$ DECLARE o uuid;a uuid;b_product uuid;session uuid;batch uuid;result jsonb;revision integer;message text;
  a_before numeric;b_before numeric;av_before numeric;bv_before numeric;al_before numeric;bl_before numeric;
BEGIN
  SELECT id INTO o FROM public.outlets WHERE code='QUENA-MART-1';
  SELECT id INTO a FROM public.products WHERE sku='CUTOVER-MULTI';
  SELECT id INTO b_product FROM public.products WHERE sku='CUTOVER-DECIMAL';
  PERFORM pg_temp.c2_post_receipt(a,40,120); PERFORM pg_temp.c2_post_receipt(b_product,40,100);
  session:=pg_temp.c2_open_count(o,b_product,20); PERFORM pg_temp.c2_submit(session); PERFORM pg_temp.c2_post(session);
  SELECT effective_quantity INTO a_before FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=a;
  SELECT effective_quantity INTO b_before FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=b_product;
  SELECT inventory_value INTO av_before FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=a;
  SELECT inventory_value INTO bv_before FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=b_product;
  SELECT sum(remaining_valued_quantity+remaining_unvalued_quantity) INTO al_before
    FROM public.inventory_cost_source_layer_balances WHERE outlet_id=o AND product_id=a;
  SELECT sum(remaining_valued_quantity+remaining_unvalued_quantity) INTO bl_before
    FROM public.inventory_cost_source_layer_balances WHERE outlet_id=o AND product_id=b_product;
  batch:=pg_temp.c2_batch(jsonb_build_array(
    jsonb_build_object('productId',a,'quantity',1,'occurredAt',now()+interval '2 hours'),
    jsonb_build_object('productId',b_product,'quantity',1,'occurredAt',now()-interval '2 hours')));
  result:=pg_temp.c2_recheck(batch);
  SELECT b.revision INTO STRICT revision FROM public.ipos_sales_import_batches b WHERE b.id=batch;
  message:=NULL;
  BEGIN PERFORM public.ipos_sales_import_commit(batch,revision,gen_random_uuid()); EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS message=MESSAGE_TEXT; END;
  IF result->>'status'<>'PREFLIGHT_BLOCKED' OR result->>'postedOpnameConflictCount'<>'1'
    OR message<>'IPOS_SALES_IMPORT_POSTED_OPNAME_CONFLICT'
    OR EXISTS(SELECT 1 FROM public.sales WHERE source_import_batch_id=batch)
    OR EXISTS(SELECT 1 FROM public.stock_movements WHERE ipos_sales_import_line_id IN
      (SELECT id FROM public.ipos_sales_import_lines WHERE batch_id=batch))
    OR EXISTS(SELECT 1 FROM public.inventory_cost_events WHERE source_entity_type='IPOS_IMPORT_INVENTORY_DEPLETION'
      AND source_entity_id IN (SELECT id FROM public.ipos_sales_import_lines WHERE batch_id=batch))
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=a) IS DISTINCT FROM a_before
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=b_product) IS DISTINCT FROM b_before
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=a) IS DISTINCT FROM av_before
    OR (SELECT inventory_value FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=b_product) IS DISTINCT FROM bv_before
    OR (SELECT sum(remaining_valued_quantity+remaining_unvalued_quantity) FROM public.inventory_cost_source_layer_balances
      WHERE outlet_id=o AND product_id=a) IS DISTINCT FROM al_before
    OR (SELECT sum(remaining_valued_quantity+remaining_unvalued_quantity) FROM public.inventory_cost_source_layer_balances
      WHERE outlet_id=o AND product_id=b_product) IS DISTINCT FROM bl_before THEN
    RAISE EXCEPTION 'Mixed batch conflict partially applied: preflight %, commit %, stock %/%',result,message,a_before,b_before; END IF;
  RAISE NOTICE 'C2 ATOMICITY PASS: one posted-count conflict blocked both products before sale, stock, and WAC mutation';
END $atomicity$;
ROLLBACK TO SAVEPOINT batch_atomicity;

ROLLBACK;
