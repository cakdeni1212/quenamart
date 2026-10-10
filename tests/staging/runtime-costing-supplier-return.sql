-- Rollback-only C3D workflow/accounting regression against a disposable clone.
\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database() NOT LIKE 'quena_c3d_staging_%' OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR inet_server_port()<>55432 OR current_setting('server_version_num')::integer/10000<>15
    OR NOT EXISTS(SELECT 1 FROM quena_staging.applied_migrations WHERE version='20260929320000') THEN
    RAISE EXCEPTION 'Refusing C3D runtime outside disposable local PostgreSQL 15 staging through 320000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_event_batches)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections)
    OR EXISTS(SELECT 1 FROM public.supplier_returns) THEN
    RAISE EXCEPTION 'C3D runtime requires a rollback-clean fixture';
  END IF;
END; $guard$;

CREATE FUNCTION pg_temp.c3d_post_receipt(p_outlet uuid,p_supplier uuid,p_product uuid,p_qty numeric,p_bonus numeric,p_rejected numeric,p_price numeric)
RETURNS TABLE(receipt_id uuid,item_id uuid) LANGUAGE plpgsql AS $$
DECLARE rid uuid; iid uuid; req uuid; res jsonb;
BEGIN
  rid:=public.purchase_receipt_create_draft(p_outlet,p_supplier,now(),'C3D staging receipt');
  PERFORM public.purchase_receipt_save_draft(rid,1,now(),NULL,jsonb_build_array(jsonb_build_object(
    'product_id',p_product,'accepted_quantity',p_qty,'bonus_quantity',p_bonus,'rejected_quantity',p_rejected)));
  SELECT id INTO STRICT iid FROM public.purchase_receipt_items WHERE purchase_receipt_items.receipt_id=rid AND product_id=p_product;
  PERFORM public.purchase_receipt_acquisition_estimate_save(rid,iid,2,0,'MANAGER_ESTIMATE',p_price,NULL,'C3D staging estimate');
  req:=public.issue_purchase_receipt_post_intent(rid); res:=public.apply_purchase_receipt_post_intent(req);
  IF res->>'code'<>'POSTED' THEN RAISE EXCEPTION 'C3D fixture receipt did not post: %',res; END IF;
  RETURN QUERY SELECT rid,iid;
END $$;

BEGIN;
SET LOCAL statement_timeout='120s';
SET LOCAL lock_timeout='10s';
DO $matrix$
<<matrix>>
DECLARE owner_id uuid:='a0000000-0000-4000-8000-000000000001';
  admin_id uuid:='a0000000-0000-4000-8000-000000000002';
  gudang_id uuid:='a0000000-0000-4000-8000-000000000003';
  kasir_id uuid:='a0000000-0000-4000-8000-000000000004';
  outlet uuid; product uuid; p2 uuid; supplier uuid; baseline numeric; result jsonb; replay jsonb;
  receipt uuid; receipt_item uuid; return_id uuid; request_id uuid; denial text; mcount integer;
  before_stock numeric; event public.inventory_cost_events%rowtype; wac numeric; value_before numeric;
  movement uuid; reverse_req uuid; new_receipt uuid; new_item uuid; corrected_qty numeric;
BEGIN
  SELECT id INTO STRICT outlet FROM public.outlets WHERE code='QUENA-MART-1' AND is_active;
  SELECT id INTO STRICT product FROM public.products WHERE sku='STG-BASE20';
  SELECT id INTO STRICT p2 FROM public.products WHERE sku='STG-FULL-B';
  SELECT effective_quantity INTO STRICT baseline FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product;
  PERFORM set_config('request.jwt.claim.sub',owner_id::text,true); PERFORM set_config('role','authenticated',true);
  supplier:=public.purchase_supplier_upsert(NULL,'C3D supplier-return staging fixture',NULL,NULL,NULL,true);

  -- REFERENCE_ONLY, linked source accepted+bonus, stock reduction/replay, and source-attribution ceiling.
  SELECT r.receipt_id,r.item_id INTO receipt,receipt_item FROM pg_temp.c3d_post_receipt(outlet,supplier,product,2,1,6,8000) r;
  IF (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product)<>baseline+3 THEN
    RAISE EXCEPTION 'receipt fixture physical stock mismatch';
  END IF;
  result:=public.create_supplier_return(outlet,supplier,'DAMAGED','Bottle leaked after receipt',NULL,
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity',1,'source_receipt_id',receipt,'source_receipt_item_id',receipt_item)));
  return_id:=(result->>'id')::uuid; request_id:=gen_random_uuid(); result:=public.post_supplier_return(return_id,request_id);
  replay:=public.post_supplier_return(return_id,request_id);
  IF result IS DISTINCT FROM replay OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product)<>baseline+2
    OR (SELECT count(*) FROM public.stock_movements WHERE supplier_return_id=return_id)<>1
    OR EXISTS(SELECT 1 FROM public.inventory_cost_events) THEN RAISE EXCEPTION 'REFERENCE_ONLY return/replay failed'; END IF;
  denial:=NULL;
  BEGIN PERFORM public.post_supplier_return(return_id,gen_random_uuid()); EXCEPTION WHEN unique_violation THEN denial:=SQLSTATE; END;
  IF denial IS DISTINCT FROM '23505' OR (SELECT count(*) FROM public.stock_movements WHERE supplier_return_id=return_id)<>1
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product)<>baseline+2 THEN
    RAISE EXCEPTION 'different request duplicated posted supplier return'; END IF;
  result:=public.create_supplier_return(outlet,supplier,'DAMAGED','Return accepted and bonus quantity',NULL,
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity',2,'source_receipt_id',receipt,'source_receipt_item_id',receipt_item)));
  return_id:=(result->>'id')::uuid;
  result:=public.post_supplier_return(return_id,gen_random_uuid());
  IF result->>'status'<>'POSTED' OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product)<>baseline THEN
    RAISE EXCEPTION 'accepted+bonus return did not post within attribution cap'; END IF;
  result:=public.create_supplier_return(outlet,supplier,'WRONG_ITEM','Wrong unit returned to supplier',NULL,
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity',0.001,'source_receipt_id',receipt,'source_receipt_item_id',receipt_item)));
  return_id:=(result->>'id')::uuid; denial:=NULL;
  BEGIN PERFORM public.post_supplier_return(return_id,gen_random_uuid()); EXCEPTION WHEN check_violation THEN denial:=SQLSTATE; END;
  IF denial IS DISTINCT FROM '23514' THEN RAISE EXCEPTION 'linked over-return was not rejected'; END IF;
  -- Insufficient current stock and multi-line failure roll back all movement/request changes.
  SELECT effective_quantity INTO before_stock FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product;
  result:=public.create_supplier_return(outlet,supplier,'OTHER','Unlinked legacy damaged stock',NULL,jsonb_build_array(
    jsonb_build_object('product_id',product,'quantity',before_stock+1),jsonb_build_object('product_id',p2,'quantity',99999999999)));
  return_id:=(result->>'id')::uuid; request_id:=gen_random_uuid(); denial:=NULL;
  BEGIN PERFORM public.post_supplier_return(return_id,request_id); EXCEPTION WHEN check_violation OR invalid_parameter_value THEN denial:=SQLSTATE; END;
  PERFORM set_config('role','none',true);
  IF denial IS NULL OR EXISTS(SELECT 1 FROM public.stock_operation_requests sor WHERE sor.request_id=matrix.request_id)
    OR EXISTS(SELECT 1 FROM public.stock_movement_batches smb WHERE smb.operation_request_id=matrix.request_id)
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product)<>before_stock THEN
    RAISE EXCEPTION 'insufficient/multi-line invalid return partially mutated stock'; END IF;
  PERFORM set_config('role','authenticated',true);

  -- Role policy: GUDANG can draft/read but cannot post; KASIR cannot create/read.
  PERFORM set_config('request.jwt.claim.sub',gudang_id::text,true);
  result:=public.create_supplier_return(outlet,supplier,'DEFECTIVE','GUDANG operational return draft',NULL,
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity',0.125)));
  return_id:=(result->>'id')::uuid;
  PERFORM public.update_supplier_return(return_id,1,'DEFECTIVE','GUDANG revised operational draft',NULL,
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity',0.125)));
  denial:=NULL;
  BEGIN PERFORM public.post_supplier_return(return_id,gen_random_uuid()); EXCEPTION WHEN insufficient_privilege THEN denial:=SQLSTATE; END;
  IF denial IS DISTINCT FROM '42501' OR (SELECT count(*) FROM public.supplier_returns WHERE id=return_id)<>1 THEN
    RAISE EXCEPTION 'GUDANG draft/post permissions incorrect'; END IF;
  PERFORM set_config('request.jwt.claim.sub',kasir_id::text,true);
  IF (SELECT count(*) FROM public.supplier_returns)<>0 THEN RAISE EXCEPTION 'KASIR can read supplier returns'; END IF;
  denial:=NULL;
  BEGIN PERFORM public.create_supplier_return(outlet,supplier,'DAMAGED','KASIR forbidden return',NULL,
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity',1))); EXCEPTION WHEN insufficient_privilege THEN denial:=SQLSTATE; END;
  IF denial IS DISTINCT FROM '42501' THEN RAISE EXCEPTION 'KASIR was allowed to create supplier return'; END IF;
  PERFORM set_config('request.jwt.claim.sub',admin_id::text,true);
  result:=public.create_supplier_return(outlet,supplier,'OTHER','ADMIN supplier return manager fixture',NULL,
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity',0.001)));
  IF result->>'status'<>'DRAFT' THEN RAISE EXCEPTION 'ADMIN could not create supplier return'; END IF;
  return_id:=(result->>'id')::uuid;
  result:=public.post_supplier_return(return_id,gen_random_uuid());
  IF result->>'status'<>'POSTED' THEN RAISE EXCEPTION 'ADMIN could not post supplier return'; END IF;
  PERFORM set_config('request.jwt.claim.sub',owner_id::text,true);

  -- Establish local WAC authority; this is isolated staging only.
  PERFORM set_config('role','none',true);
  INSERT INTO public.product_field_audit_reviews(product_id,outlet_id,field_key,status,source_import_row_id,reviewer_id,evidence_notes,request_id)
    SELECT product,outlet,'hpp','SUDAH_DIVERIFIKASI',source_import_row_id,owner_id,'C3D local bootstrap fixture',gen_random_uuid()
    FROM public.product_costs WHERE product_id=product AND outlet_id=outlet;
  result:=public.inventory_cost_bootstrap_outlet(outlet,'d1000000-0000-4000-8000-000000000320');
  IF result->>'code'<>'BOOTSTRAP_READY' THEN RAISE EXCEPTION 'local WAC bootstrap fixture failed: %',result; END IF;
  PERFORM set_config('role','authenticated',true);
  result:=public.create_supplier_return(outlet,supplier,'EXCESS','Cutover blocked return',NULL,
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity',0.001)));
  return_id:=(result->>'id')::uuid; request_id:=gen_random_uuid(); denial:=NULL;
  SELECT effective_quantity INTO before_stock FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product;
  BEGIN PERFORM public.post_supplier_return(return_id,request_id); EXCEPTION WHEN SQLSTATE '55000' THEN denial:=SQLSTATE; END;
  PERFORM set_config('role','none',true);
  IF denial IS DISTINCT FROM '55000' OR EXISTS(SELECT 1 FROM public.stock_operation_requests sor WHERE sor.request_id=matrix.request_id)
    OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=outlet AND product_id=product)<>before_stock THEN
    RAISE EXCEPTION 'BOOTSTRAP_READY changed stock or terminalized request'; END IF;
  UPDATE public.inventory_costing_outlet_authority SET status='WAC_ACTIVE',activated_by=owner_id,activated_at=now() WHERE outlet_id=outlet;
  PERFORM set_config('role','authenticated',true);

  -- Positive legacy quantity remains unvalued; return removes it before valued quantity.
  result:=public.create_manual_stock_correction(outlet,'FOUND','C3D create isolated unvalued quantity',
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity_delta',3)));
  PERFORM public.post_manual_stock_correction((result->>'id')::uuid,gen_random_uuid());
  result:=public.create_supplier_return(outlet,supplier,'DAMAGED','Unvalued quantity returned first',NULL,
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity',2)));
  return_id:=(result->>'id')::uuid; request_id:=gen_random_uuid(); PERFORM public.post_supplier_return(return_id,request_id);
  SELECT * INTO STRICT event FROM public.inventory_cost_events WHERE supplier_return_id=return_id;
  IF event.unvalued_quantity_delta<>-2 OR event.valued_quantity_delta<>0 OR event.inventory_value_delta<>0 THEN
    RAISE EXCEPTION 'supplier return did not consume unvalued source first'; END IF;

  -- Post two source receipts at different prices. A linked return's financial delta still uses pooled aggregate WAC.
  result:=public.create_supplier_return(outlet,supplier,'DAMAGED','Clear final unvalued unit',NULL,
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity',1)));
  PERFORM public.post_supplier_return((result->>'id')::uuid,gen_random_uuid());
  SELECT r.receipt_id,r.item_id INTO receipt,receipt_item FROM pg_temp.c3d_post_receipt(outlet,supplier,product,5,0,0,8000) r;
  PERFORM pg_temp.c3d_post_receipt(outlet,supplier,product,5,0,0,12000);
  SELECT current_wac,inventory_value INTO wac,value_before FROM public.inventory_cost_projections WHERE outlet_id=outlet AND product_id=product;
  result:=public.create_supplier_return(outlet,supplier,'DAMAGED','Linked return uses pooled WAC',NULL,
    jsonb_build_array(jsonb_build_object('product_id',product,'quantity',2,'source_receipt_id',receipt,'source_receipt_item_id',receipt_item)));
  return_id:=(result->>'id')::uuid; request_id:=gen_random_uuid(); PERFORM public.post_supplier_return(return_id,request_id);
  SELECT * INTO STRICT event FROM public.inventory_cost_events WHERE supplier_return_id=return_id;
  IF event.inventory_value_delta IS DISTINCT FROM -round(2*wac,8) OR event.inventory_value_delta IN (-16000,-24000)
    OR event.source_receipt_id IS DISTINCT FROM receipt OR event.valuation_basis<>'CURRENT_WAC' THEN
    RAISE EXCEPTION 'linked return was valued at historical receipt price rather than aggregate WAC'; END IF;
  SELECT m.id INTO STRICT movement FROM public.stock_movement_batches b JOIN public.stock_movements m ON m.batch_id=b.id WHERE b.operation_request_id=request_id;
  -- A later receipt changes WAC but does not consume any source layer touched by the return.
  PERFORM pg_temp.c3d_post_receipt(outlet,supplier,product,1,0,0,17000);
  reverse_req:=public.issue_stock_operation_intent('REVERSE_MOVEMENT',jsonb_build_object('movement_id',movement,'reason','C3D exact inverse test'));
  result:=public.apply_stock_operation_intent(reverse_req);
  IF result->>'ok'<>'true' OR (SELECT e.inventory_value_delta FROM public.inventory_cost_events e WHERE e.reverses_cost_event_id=event.id)
      IS DISTINCT FROM -event.inventory_value_delta THEN RAISE EXCEPTION 'standard reversal did not restore exact original return cost'; END IF;

  -- Source-level unique key rejects a second movement/cost event path for an already-posted line.
  SELECT r.id INTO STRICT return_id FROM public.supplier_returns r WHERE r.status='POSTED'
    AND EXISTS(SELECT 1 FROM public.inventory_cost_events e WHERE e.supplier_return_id=r.id)
    ORDER BY r.created_at DESC LIMIT 1;
  IF (SELECT count(*) FROM public.stock_movements WHERE supplier_return_id=return_id)<>1
    OR (SELECT count(*) FROM public.inventory_cost_events WHERE supplier_return_id=return_id)<>1 THEN
    RAISE EXCEPTION 'posted return lacks exactly one movement/cost event'; END IF;

END; $matrix$;
ROLLBACK;
