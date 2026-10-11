-- P1D-B: atomic native POS checkout capability. WAC activation remains a
-- separate approved go-live operation; this migration never activates it.
BEGIN;

ALTER TABLE public.inventory_cost_operation_requests
  DROP CONSTRAINT inventory_cost_operation_requests_operation_key_check,
  ADD CONSTRAINT inventory_cost_operation_requests_operation_key_check
    CHECK (operation_key IN ('BOOTSTRAP_OUTLET','PURCHASE_RECEIPT','OPNAME_ADJUSTMENT',
      'REVERSAL','STOCK_CORRECTION','SUPPLIER_RETURN','POS_SALE'));

ALTER TABLE public.stock_movement_batches
  ADD COLUMN pos_sale_id uuid,
  ADD COLUMN pos_checkout_request_id uuid,
  ADD CONSTRAINT stock_movement_batch_pos_shape CHECK (
    (source_system='QUENA_POS' AND pos_sale_id IS NOT NULL AND pos_checkout_request_id IS NOT NULL)
    OR (source_system<>'QUENA_POS' AND pos_sale_id IS NULL AND pos_checkout_request_id IS NULL));
ALTER TABLE public.stock_movements
  ADD COLUMN pos_sale_id uuid,
  ADD COLUMN pos_sale_item_id uuid,
  ADD COLUMN pos_checkout_request_id uuid,
  ADD CONSTRAINT stock_movement_pos_shape CHECK (
    (movement_type='SALE' AND source_system='QUENA_POS' AND pos_sale_id IS NOT NULL
      AND pos_sale_item_id IS NOT NULL AND pos_checkout_request_id IS NOT NULL)
    OR ((movement_type<>'SALE' OR source_system<>'QUENA_POS') AND pos_sale_id IS NULL
      AND pos_sale_item_id IS NULL AND pos_checkout_request_id IS NULL));
ALTER TABLE public.pos_checkout_requests ADD CONSTRAINT pos_checkout_request_id_outlet_identity UNIQUE(request_id,outlet_id);
ALTER TABLE public.sale_items ADD CONSTRAINT sale_item_id_sale_outlet_product_identity UNIQUE(id,sale_id,outlet_id,product_id);
ALTER TABLE public.pos_checkout_requests ADD CONSTRAINT pos_checkout_request_id_outlet_cart_identity UNIQUE(request_id,outlet_id,cart_id);
ALTER TABLE public.stock_movement_batches
  ADD CONSTRAINT stock_movement_batch_pos_sale_fk FOREIGN KEY(pos_sale_id,outlet_id)
    REFERENCES public.sales(id,outlet_id) ON DELETE RESTRICT,
  ADD CONSTRAINT stock_movement_batch_pos_request_fk FOREIGN KEY(pos_checkout_request_id,outlet_id)
    REFERENCES public.pos_checkout_requests(request_id,outlet_id) ON DELETE RESTRICT,
  ADD CONSTRAINT stock_movement_batch_sale_request_fk FOREIGN KEY(pos_sale_id,outlet_id,pos_checkout_request_id)
    REFERENCES public.sales(id,outlet_id,checkout_request_id) ON DELETE RESTRICT,
  ADD CONSTRAINT stock_movement_batch_pos_identity UNIQUE(id,outlet_id,pos_sale_id,pos_checkout_request_id);
ALTER TABLE public.stock_movements
  ADD CONSTRAINT stock_movement_batch_pos_identity_fk FOREIGN KEY(batch_id,outlet_id,pos_sale_id,pos_checkout_request_id)
    REFERENCES public.stock_movement_batches(id,outlet_id,pos_sale_id,pos_checkout_request_id) ON DELETE RESTRICT,
  ADD CONSTRAINT stock_movement_pos_sale_fk FOREIGN KEY(pos_sale_id,outlet_id,pos_checkout_request_id)
    REFERENCES public.sales(id,outlet_id,checkout_request_id) ON DELETE RESTRICT,
  ADD CONSTRAINT stock_movement_pos_item_fk FOREIGN KEY(pos_sale_item_id,pos_sale_id,outlet_id,product_id)
    REFERENCES public.sale_items(id,sale_id,outlet_id,product_id) ON DELETE RESTRICT,
  ADD CONSTRAINT stock_movement_pos_request_fk FOREIGN KEY(pos_checkout_request_id,outlet_id)
    REFERENCES public.pos_checkout_requests(request_id,outlet_id) ON DELETE RESTRICT;
CREATE UNIQUE INDEX stock_movement_pos_sale_item_once ON public.stock_movements(pos_sale_item_id)
  WHERE pos_sale_item_id IS NOT NULL;
CREATE UNIQUE INDEX stock_movement_batch_pos_sale_once ON public.stock_movement_batches(pos_sale_id)
  WHERE pos_sale_id IS NOT NULL;
CREATE INDEX stock_movement_pos_sale_idx ON public.stock_movements(pos_sale_id,pos_sale_item_id)
  WHERE pos_sale_id IS NOT NULL;

-- Preserve the original projection checks, but make the event-linkage cases
-- explicit: receipts keep their complete receipt/movement/request identity,
-- native POS SALE_COGS uses normalized POS movement/request identity, and all
-- other event types remain unlinked through these receipt-specific columns.
ALTER TABLE public.inventory_cost_events
  DROP CONSTRAINT inventory_cost_event_projection_state_valid,
  ADD CONSTRAINT inventory_cost_event_projection_state_valid CHECK (
    (physical_quantity_delta IS NULL OR physical_quantity_delta=trunc(physical_quantity_delta,3))
    AND (physical_quantity_before IS NULL OR (physical_quantity_before>=0 AND physical_quantity_before=trunc(physical_quantity_before,3)))
    AND (physical_quantity_after IS NULL OR (physical_quantity_after>=0 AND physical_quantity_after=trunc(physical_quantity_after,3)))
    AND (valued_quantity_delta IS NULL OR valued_quantity_delta=trunc(valued_quantity_delta,3))
    AND (provisional_quantity_delta IS NULL OR provisional_quantity_delta=trunc(provisional_quantity_delta,3))
    AND (provisional_quantity_before IS NULL OR (provisional_quantity_before>=0 AND provisional_quantity_before=trunc(provisional_quantity_before,3)))
    AND (provisional_quantity_after IS NULL OR (provisional_quantity_after>=0 AND provisional_quantity_after=trunc(provisional_quantity_after,3)))
    AND (unvalued_quantity_delta IS NULL OR unvalued_quantity_delta=trunc(unvalued_quantity_delta,3))
    AND (unvalued_quantity_before IS NULL OR (unvalued_quantity_before>=0 AND unvalued_quantity_before=trunc(unvalued_quantity_before,3)))
    AND (unvalued_quantity_after IS NULL OR (unvalued_quantity_after>=0 AND unvalued_quantity_after=trunc(unvalued_quantity_after,3)))
    AND (frozen_unit_cost IS NULL OR (frozen_unit_cost>=0 AND frozen_unit_cost<1000000000000))
    AND ((valuation_basis='CURRENT_WAC' AND basis_cost_event_id IS NOT NULL)
      OR (valuation_basis IS DISTINCT FROM 'CURRENT_WAC' AND basis_cost_event_id IS NULL))
    AND (acquisition_evidence_revision IS NULL OR acquisition_evidence_revision>0)
    AND (
      (event_type='PURCHASE_RECEIPT' AND source_entity_type='PURCHASE_RECEIPT'
        AND receipt_id IS NOT NULL AND receipt_item_id IS NOT NULL
        AND stock_movement_id IS NOT NULL AND stock_request_id IS NOT NULL)
      OR (event_type='SALE_COGS' AND source_entity_type='POS_SALE_ITEM'
        AND receipt_id IS NULL AND receipt_item_id IS NULL
        AND source_receipt_id IS NULL AND source_receipt_item_id IS NULL
        AND supplier_return_id IS NULL AND supplier_return_item_id IS NULL AND supplier_id IS NULL
        AND opname_session_id IS NULL AND opname_item_id IS NULL
        AND reverses_cost_event_id IS NULL AND reverses_stock_movement_id IS NULL
        AND stock_movement_id IS NOT NULL AND source_stock_movement_id=stock_movement_id
        AND stock_request_id IS NOT NULL)
      OR (event_type NOT IN ('PURCHASE_RECEIPT','SALE_COGS')
        AND receipt_id IS NULL AND receipt_item_id IS NULL
        AND stock_movement_id IS NULL AND stock_request_id IS NULL)
    )
  );

CREATE FUNCTION public.guard_pos_sale_cost_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  IF NEW.event_type<>'SALE_COGS'::public.inventory_cost_event_type
     OR NEW.source_entity_type<>'POS_SALE_ITEM' THEN RETURN NEW; END IF;
  IF NEW.receipt_id IS NOT NULL OR NEW.receipt_item_id IS NOT NULL
     OR NEW.source_stock_movement_id IS DISTINCT FROM NEW.stock_movement_id
     OR NEW.stock_movement_id IS NULL OR NEW.stock_request_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='POS SALE_COGS linkage shape is invalid';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.sale_items si
    JOIN public.sales s ON s.id=si.sale_id AND s.outlet_id=si.outlet_id
    JOIN public.stock_movements m ON m.id=NEW.stock_movement_id
      AND m.outlet_id=si.outlet_id AND m.product_id=si.product_id
    JOIN public.stock_movement_batches mb ON mb.id=m.batch_id
      AND mb.outlet_id=m.outlet_id AND mb.pos_sale_id=s.id
      AND mb.pos_checkout_request_id=s.checkout_request_id
    JOIN public.inventory_cost_event_batches cb ON cb.id=NEW.batch_id
      AND cb.outlet_id=s.outlet_id AND cb.batch_type='SALE_COGS'
      AND cb.source_entity_type='POS_SALE' AND cb.source_entity_id=s.id
      AND cb.operation_request_id=NEW.operation_request_id AND cb.created_by=NEW.actor_id
    JOIN public.inventory_cost_operation_requests cor ON cor.request_id=NEW.operation_request_id
      AND cor.actor_id=NEW.actor_id AND cor.operation_key='POS_SALE' AND cor.target_key=s.id::text
    JOIN public.stock_operation_requests sor ON sor.request_id=NEW.stock_request_id
      AND sor.actor_id=NEW.actor_id AND sor.operation_key='POS_CHECKOUT'
      AND sor.target_key=s.pos_cart_id::text
    JOIN public.pos_checkout_requests pcr ON pcr.request_id=NEW.stock_request_id
      AND pcr.actor_id=NEW.actor_id AND pcr.outlet_id=s.outlet_id
      AND pcr.cart_id=s.pos_cart_id
    WHERE si.id=NEW.source_entity_id AND si.sale_id=s.id
      AND s.status='COMPLETED' AND s.checkout_request_id=NEW.operation_request_id
      AND NEW.source_event_id=m.id AND NEW.source_stock_movement_id=m.id
      AND m.movement_type='SALE' AND m.source_system='QUENA_POS'
      AND m.pos_sale_id=s.id AND m.pos_sale_item_id=si.id
      AND m.pos_checkout_request_id=s.checkout_request_id
      AND m.quantity_delta=-si.quantity AND mb.source_system='QUENA_POS'
      AND mb.operation_request_id=NEW.stock_request_id
      AND NEW.outlet_id=s.outlet_id AND NEW.product_id=si.product_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='POS SALE_COGS event does not match completed sale evidence';
  END IF;
  RETURN NEW;
END; $$;
ALTER FUNCTION public.guard_pos_sale_cost_event() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_pos_sale_cost_event() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER inventory_cost_pos_sale_event_guard BEFORE INSERT ON public.inventory_cost_events
  FOR EACH ROW EXECUTE FUNCTION public.guard_pos_sale_cost_event();

CREATE FUNCTION public.guard_no_pos_sale_reversal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_type public.stock_movement_type; v_source public.stock_movement_source;
BEGIN
  IF NEW.movement_type='REVERSAL'::public.stock_movement_type THEN
    SELECT m.movement_type,m.source_system INTO v_type,v_source
      FROM public.stock_movements m WHERE m.id=NEW.reverses_movement_id
        AND m.product_id=NEW.product_id AND m.outlet_id=NEW.outlet_id FOR KEY SHARE;
    IF v_type='SALE'::public.stock_movement_type AND v_source='QUENA_POS'::public.stock_movement_source THEN
      RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POS_COMPLETED_SALE_REVERSAL_FORBIDDEN';
    END IF;
  END IF;
  RETURN NEW;
END; $$;
ALTER FUNCTION public.guard_no_pos_sale_reversal() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_no_pos_sale_reversal() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER stock_movement_no_pos_sale_reversal BEFORE INSERT ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.guard_no_pos_sale_reversal();

CREATE FUNCTION public.inventory_cost_apply_pos_sale(p_request uuid,p_sale uuid,p_outlet uuid,p_period uuid,p_actor uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_auth public.inventory_cost_authority_status; v_batch uuid; v_line record; v_cost public.inventory_cost_projections%ROWTYPE;
  v_m public.stock_movements%ROWTYPE; v_uv numeric; v_val numeric; v_prov numeric; v_plan_u jsonb; v_plan_v jsonb;
  v_delta numeric(32,8); v_after numeric(32,8); v_wac numeric(20,8); v_status public.inventory_cost_projection_status;
  v_event uuid; v_resolved numeric(32,8); v_provisional numeric(32,8); v_final_qty numeric; v_prov_qty numeric;
  v_event_count integer:=0; v_version bigint; v_alloc record;
BEGIN
  SELECT a.status INTO v_auth FROM public.inventory_costing_outlet_authority a
    WHERE a.outlet_id=p_outlet FOR SHARE;
  IF v_auth IS DISTINCT FROM 'WAC_ACTIVE'::public.inventory_cost_authority_status THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_COSTING_NOT_ACTIVE'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.sales s WHERE s.id=p_sale AND s.outlet_id=p_outlet
      AND s.checkout_request_id=p_request AND s.status='COMPLETED') THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POS sale costing context mismatch'; END IF;
  INSERT INTO public.inventory_cost_operation_requests(request_id,actor_id,operation_key,target_key,payload_hash)
  SELECT p_request,p_actor,'POS_SALE',p_sale::text,md5(jsonb_build_object('sale',p_sale,'request',p_request,'outlet',p_outlet)::text);
  INSERT INTO public.inventory_cost_event_batches(outlet_id,batch_type,source_entity_type,source_entity_id,
    operation_request_id,allocation_method,created_by)
  VALUES(p_outlet,'SALE_COGS','POS_SALE',p_sale,p_request,'UNVALUED_FIRST_THEN_PROPORTIONAL_SOURCE_QUANTITY',p_actor)
  RETURNING id INTO v_batch;

  FOR v_line IN SELECT si.*,sm.id AS movement_id,sm.balance_before,sm.balance_after
    FROM public.sale_items si JOIN public.stock_movements sm ON sm.pos_sale_item_id=si.id
    WHERE si.sale_id=p_sale ORDER BY si.product_id LOOP
    SELECT * INTO STRICT v_cost FROM public.inventory_cost_projections cp
      WHERE cp.outlet_id=p_outlet AND cp.product_id=v_line.product_id;
    SELECT * INTO STRICT v_m FROM public.stock_movements WHERE id=v_line.movement_id;
    IF v_cost.physical_quantity IS DISTINCT FROM v_m.balance_before
      OR v_cost.stock_authority_period_id IS DISTINCT FROM p_period THEN
      RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='POS_COST_PROJECTION_STALE'; END IF;
    v_uv:=least(v_line.quantity,v_cost.unvalued_quantity); v_val:=v_line.quantity-v_uv;
    IF v_val>v_cost.valued_quantity THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POS cost layer quantity insufficient'; END IF;
    v_plan_u:='[]'; v_plan_v:='[]'; v_prov:=0;
    IF v_uv>0 THEN v_plan_u:=public.inventory_cost_build_layer_outflow_plan(p_outlet,v_line.product_id,v_uv,'UNVALUED'); END IF;
    IF v_val>0 THEN
      v_plan_v:=public.inventory_cost_build_layer_outflow_plan(p_outlet,v_line.product_id,v_val,'VALUED');
      SELECT coalesce(sum((x->>'provisional')::numeric),0),coalesce(sum((x->>'valued')::numeric),0)
        INTO v_prov,v_val FROM jsonb_array_elements(v_plan_v) x;
    END IF;
    v_final_qty:=v_val-v_prov; v_prov_qty:=v_prov;
    v_delta:=CASE WHEN v_val=0 THEN CASE WHEN v_cost.valued_quantity>0 THEN 0 ELSE NULL END
      WHEN v_val=v_cost.valued_quantity THEN -coalesce(v_cost.inventory_value,0)
      ELSE -round(v_val*v_cost.current_wac,8) END;
    v_after:=CASE WHEN v_cost.valued_quantity-v_val=0
      THEN CASE WHEN v_m.balance_after=0 THEN 0 ELSE NULL END
      ELSE coalesce(v_cost.inventory_value,0)+coalesce(v_delta,0) END;
    v_wac:=CASE WHEN v_cost.valued_quantity-v_val>0
      THEN round(v_after/(v_cost.valued_quantity-v_val),8)::numeric(20,8) ELSE NULL END;
    v_status:=CASE WHEN v_m.balance_after=0 THEN 'VALUED'::public.inventory_cost_projection_status
      WHEN v_cost.valued_quantity-v_val=0 THEN 'UNVALUED'::public.inventory_cost_projection_status
      WHEN v_cost.unvalued_quantity-v_uv>0 THEN 'PARTIALLY_UNVALUED'::public.inventory_cost_projection_status
      WHEN v_cost.provisional_quantity-v_prov>0 THEN 'PROVISIONAL'::public.inventory_cost_projection_status
      ELSE 'VALUED'::public.inventory_cost_projection_status END;
    v_event:=gen_random_uuid(); v_version:=v_cost.cost_version+1;
    INSERT INTO public.inventory_cost_events(id,batch_id,outlet_id,product_id,event_type,source_entity_type,source_entity_id,
      source_event_id,quantity_delta,valued_quantity_before,valued_quantity_delta,valued_quantity_after,
      inventory_value_delta,inventory_value_before,inventory_value_after,wac_before,wac_after,valuation_status_before,
      valuation_status_after,cost_version_before,cost_version_after,stock_balance_version,stock_authority_period_id,
      actor_id,operation_request_id,physical_quantity_delta,physical_quantity_before,physical_quantity_after,
      provisional_quantity_delta,provisional_quantity_before,provisional_quantity_after,unvalued_quantity_delta,
      unvalued_quantity_before,unvalued_quantity_after,source_stock_movement_id,stock_movement_id,stock_request_id,
      valuation_basis,frozen_unit_cost,basis_cost_event_id,metadata)
    VALUES(v_event,v_batch,p_outlet,v_line.product_id,'SALE_COGS','POS_SALE_ITEM',v_line.id,v_m.id,-v_line.quantity,
      v_cost.valued_quantity,-v_val,v_cost.valued_quantity-v_val,v_delta,v_cost.inventory_value,v_after,v_cost.current_wac,
      v_wac,v_cost.valuation_status,v_status,v_cost.cost_version,v_version,
      (SELECT balance_version FROM public.stock_balance_projection WHERE outlet_id=p_outlet AND product_id=v_line.product_id),
      p_period,p_actor,p_request,-v_line.quantity,v_m.balance_before,v_m.balance_after,-v_prov,
      v_cost.provisional_quantity,v_cost.provisional_quantity-v_prov,-v_uv,v_cost.unvalued_quantity,v_cost.unvalued_quantity-v_uv,
      v_m.id,v_m.id,p_request,CASE WHEN v_val>0 THEN 'CURRENT_WAC'::public.inventory_cost_acquisition_basis
        ELSE 'UNVALUED'::public.inventory_cost_acquisition_basis END,
      CASE WHEN v_val>0 THEN v_cost.current_wac ELSE NULL END,
      CASE WHEN v_val>0 THEN v_cost.last_cost_event_id ELSE NULL END,
      jsonb_build_object('allocationMethod','UNVALUED_FIRST_THEN_PROPORTIONAL','wacDepletion',abs(coalesce(v_delta,0))))
    RETURNING id INTO v_event;
    IF v_plan_u<>'[]' THEN PERFORM * FROM public.inventory_cost_apply_layer_plan(v_event,v_m.id,p_request,p_actor,v_version,'OUTFLOW_UNVALUED',v_plan_u); END IF;
    IF v_plan_v<>'[]' THEN PERFORM * FROM public.inventory_cost_apply_layer_plan(v_event,v_m.id,p_request,p_actor,v_version,'OUTFLOW_VALUED',v_plan_v); END IF;
    SELECT coalesce(sum(-a.physical_quantity_delta),0) INTO v_uv FROM public.inventory_cost_layer_allocations a
      WHERE a.cost_event_id=v_event AND a.allocation_kind='OUTFLOW_UNVALUED';
    -- The normalized link rows mirror, rather than estimate, the source ledger.
    INSERT INTO public.sale_item_cost_evidence(sale_item_id,sale_id,outlet_id,product_id,checkout_request_id,
      stock_movement_id,cost_event_id,quantity,valued_quantity,provisional_quantity,unvalued_quantity,
      resolved_cogs_amount,provisional_cogs_amount,status)
    VALUES(v_line.id,p_sale,p_outlet,v_line.product_id,p_request,v_m.id,v_event,v_line.quantity,v_val,v_prov,v_uv,
      CASE WHEN v_final_qty>0 THEN CASE WHEN v_prov_qty>0 THEN round(v_final_qty*v_cost.current_wac,8)
        ELSE abs(coalesce(v_delta,0)) END END,
      CASE WHEN v_prov_qty>0 THEN abs(coalesce(v_delta,0))-CASE WHEN v_final_qty>0
        THEN round(v_final_qty*v_cost.current_wac,8) ELSE 0 END END,
      CASE WHEN v_uv>0 AND v_val>0 THEN 'PARTIALLY_UNRESOLVED'::public.pos_sale_item_cogs_status
        WHEN v_uv>0 THEN 'UNRESOLVED'::public.pos_sale_item_cogs_status
        WHEN v_prov>0 THEN 'PROVISIONAL'::public.pos_sale_item_cogs_status
        ELSE 'RESOLVED'::public.pos_sale_item_cogs_status END);
    FOR v_alloc IN SELECT a.*,(CASE WHEN a.allocation_kind='OUTFLOW_UNVALUED' THEN 'UNVALUED' ELSE 'VALUED' END)::public.pos_sale_cost_allocation_bucket AS bucket
      FROM public.inventory_cost_layer_allocations a WHERE a.cost_event_id=v_event ORDER BY a.source_layer_id,a.id LOOP
      INSERT INTO public.sale_item_cost_allocations(sale_item_id,sale_id,outlet_id,product_id,cost_event_id,stock_movement_id,
        source_layer_allocation_id,source_layer_id,bucket,physical_quantity,valued_quantity,provisional_quantity,unvalued_quantity)
      VALUES(v_line.id,p_sale,p_outlet,v_line.product_id,v_event,v_m.id,v_alloc.id,v_alloc.source_layer_id,v_alloc.bucket,
        -v_alloc.physical_quantity_delta,-v_alloc.valued_quantity_delta,-v_alloc.provisional_quantity_delta,-v_alloc.unvalued_quantity_delta);
    END LOOP;
    UPDATE public.inventory_cost_projections SET physical_quantity=v_m.balance_after,
      valued_quantity=v_cost.valued_quantity-v_val,provisional_quantity=v_cost.provisional_quantity-v_prov,
      unvalued_quantity=v_cost.unvalued_quantity-(SELECT coalesce(sum(-a.unvalued_quantity_delta),0)
        FROM public.inventory_cost_layer_allocations a WHERE a.cost_event_id=v_event),inventory_value=v_after,
      current_wac=v_wac,valuation_status=v_status,cost_version=v_version,
      stock_balance_version=(SELECT balance_version FROM public.stock_balance_projection WHERE outlet_id=p_outlet AND product_id=v_line.product_id),
      stock_authority_period_id=p_period,last_cost_event_id=v_event,updated_at=now()
    WHERE outlet_id=p_outlet AND product_id=v_line.product_id;
    v_event_count:=v_event_count+1;
  END LOOP;
  UPDATE public.inventory_cost_operation_requests SET result=jsonb_build_object('ok',true,'eventCount',v_event_count,'saleId',p_sale),completed_at=now()
    WHERE request_id=p_request;
  RETURN v_event_count;
END; $$;
ALTER FUNCTION public.inventory_cost_apply_pos_sale(uuid,uuid,uuid,uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_apply_pos_sale(uuid,uuid,uuid,uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.pos_checkout_complete(p_request_id uuid,p_cart_id uuid,p_expected_cart_revision bigint,
  p_payment_method public.pos_sale_payment_method,p_cash_received_amount numeric DEFAULT NULL,p_reference_text text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=auth.uid(); r public.user_role; o uuid; c public.pos_carts%ROWTYPE; q public.pos_checkout_requests%ROWTYPE;
  auth_state public.inventory_cost_authority_status; period public.stock_authority_periods%ROWTYPE;
  li record; proj public.stock_balance_projection%ROWTYPE; price record; total numeric(32,2):=0; line_total numeric(32,2);
  received numeric(32,2); change_amt numeric(32,2); ref text; payload jsonb; h text; sale uuid; sale_no text;
  batch uuid; mid uuid; before_qty numeric; after_qty numeric; ver bigint; completed timestamptz:=clock_timestamp();
  response jsonb; cashier text; line_count integer:=0; effective_history uuid; effective_at timestamptz; v_line_number integer:=0;
BEGIN
  r:=public.current_active_user_role();
  IF a IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'KASIR'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_UNAUTHORIZED'; END IF;
  SELECT count(*)::int,(array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1] INTO line_count,o
    FROM public.stock_authority_periods ap JOIN public.outlets x ON x.id=ap.outlet_id
    WHERE ap.ended_at IS NULL AND x.is_active;
  IF line_count<>1 OR o IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_UNAUTHORIZED'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_BOOTSTRAP_OUTLET:'||o::text,73190411));
  IF p_request_id IS NULL OR p_cart_id IS NULL OR p_expected_cart_revision IS NULL OR p_expected_cart_revision<1 THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_PAYMENT_INVALID'; END IF;
  IF p_payment_method IS NULL OR (p_payment_method='CASH' AND (p_cash_received_amount IS NULL OR p_cash_received_amount<0
      OR p_cash_received_amount>=1000000000000000000000000000000 OR p_cash_received_amount<>round(p_cash_received_amount,2)))
    OR (p_payment_method<>'CASH' AND p_cash_received_amount IS NOT NULL)
    OR (p_reference_text IS NOT NULL AND (length(p_reference_text)>160 OR btrim(p_reference_text)='')) THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_PAYMENT_INVALID'; END IF;
  ref:=nullif(btrim(p_reference_text),'');
  payload:=jsonb_build_object('method',p_payment_method::text,'cashReceived',CASE WHEN p_payment_method='CASH' THEN p_cash_received_amount ELSE NULL END,'reference',ref);
  h:=md5(payload::text);
  SELECT * INTO q FROM public.pos_checkout_requests WHERE request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF q.actor_id<>a OR q.outlet_id<>o OR q.cart_id<>p_cart_id OR q.expected_cart_revision<>p_expected_cart_revision OR q.payment_payload_hash<>h THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_CHECKOUT_CONFLICT'; END IF;
    IF q.state='COMPLETED' THEN RETURN q.result; END IF;
    IF q.state<>'PENDING' THEN RETURN q.result; END IF;
  ELSE
    -- Normalize inaccessible and nonexistent carts before the outlet-aware request FK.
    -- This check is only an authorization/error-contract guard; the locked read below remains authoritative.
    PERFORM 1 FROM public.pos_carts pc
      WHERE pc.id=p_cart_id AND pc.outlet_id=o AND (r<>'KASIR' OR pc.created_by=a);
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_UNAUTHORIZED'; END IF;
    INSERT INTO public.pos_checkout_requests(request_id,actor_id,outlet_id,cart_id,expected_cart_revision,payment_payload_hash)
      VALUES(p_request_id,a,o,p_cart_id,p_expected_cart_revision,h) ON CONFLICT(request_id) DO NOTHING;
    SELECT * INTO STRICT q FROM public.pos_checkout_requests WHERE request_id=p_request_id FOR UPDATE;
    IF q.actor_id<>a OR q.outlet_id<>o OR q.cart_id<>p_cart_id OR q.expected_cart_revision<>p_expected_cart_revision OR q.payment_payload_hash<>h THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_CHECKOUT_CONFLICT'; END IF;
    IF q.state='COMPLETED' THEN RETURN q.result; END IF;
    IF q.state<>'PENDING' THEN RETURN q.result; END IF;
  END IF;
  SELECT * INTO c FROM public.pos_carts WHERE id=p_cart_id AND outlet_id=o FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_UNAUTHORIZED'; END IF;
  IF r='KASIR' AND c.created_by<>a THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_UNAUTHORIZED'; END IF;
  IF c.status='COMPLETED' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_ALREADY_COMPLETED'; END IF;
  IF c.status<>'ACTIVE' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_CART_NOT_ACTIVE'; END IF;
  IF c.revision<>p_expected_cart_revision THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_CART_STALE'; END IF;
  PERFORM 1 FROM public.pos_cart_items WHERE cart_id=p_cart_id ORDER BY product_id FOR UPDATE;
  IF NOT EXISTS(SELECT 1 FROM public.pos_cart_items WHERE cart_id=p_cart_id) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_CART_EMPTY'; END IF;
  SELECT ac.status INTO auth_state FROM public.inventory_costing_outlet_authority ac WHERE ac.outlet_id=o FOR SHARE;
  IF auth_state IS DISTINCT FROM 'WAC_ACTIVE'::public.inventory_cost_authority_status THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_COSTING_NOT_ACTIVE'; END IF;
  FOR li IN SELECT * FROM public.pos_cart_items WHERE cart_id=p_cart_id ORDER BY product_id LOOP
    SELECT * INTO proj FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=li.product_id FOR UPDATE;
    IF NOT FOUND OR proj.effective_quantity IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_INSUFFICIENT_STOCK'; END IF;
    IF proj.effective_quantity<li.quantity THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_INSUFFICIENT_STOCK'; END IF;
  END LOOP;
  SELECT * INTO period FROM public.stock_authority_periods WHERE outlet_id=o AND ended_at IS NULL FOR UPDATE;
  IF NOT FOUND OR EXISTS(SELECT 1 FROM public.stock_balance_projection p WHERE p.outlet_id=o
    AND p.product_id IN(SELECT product_id FROM public.pos_cart_items WHERE cart_id=p_cart_id)
    AND p.authority_period_id<>period.id) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_INSUFFICIENT_STOCK'; END IF;
  FOR li IN SELECT * FROM public.pos_cart_items WHERE cart_id=p_cart_id ORDER BY product_id LOOP
    SELECT s.amount INTO price FROM public.product_selling_prices s WHERE s.outlet_id=o AND s.product_id=li.product_id FOR UPDATE;
    IF NOT FOUND OR price.amount IS NULL OR price.amount<=0 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_PRICE_UNAVAILABLE'; END IF;
    SELECT ph.id,ph.effective_at INTO effective_history,effective_at FROM public.product_selling_price_history ph
      WHERE ph.outlet_id=o AND ph.product_id=li.product_id AND ph.amount IS NOT DISTINCT FROM price.amount
      ORDER BY ph.effective_at DESC,ph.id DESC LIMIT 1;
    IF price.amount IS DISTINCT FROM li.observed_unit_price THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_PRICE_CHANGED'; END IF;
    total:=total+round(li.quantity*price.amount,2);
  END LOOP;
  IF total<=0 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_PAYMENT_INVALID'; END IF;
  total:=round(total,2);
  IF p_payment_method='CASH' THEN
    received:=round(p_cash_received_amount,2); IF received<total THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_PAYMENT_INVALID'; END IF;
    change_amt:=received-total;
  END IF;
  FOR li IN SELECT DISTINCT product_id FROM public.pos_cart_items WHERE cart_id=p_cart_id ORDER BY product_id LOOP
    PERFORM 1 FROM public.inventory_cost_projections WHERE outlet_id=o AND product_id=li.product_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_COSTING_NOT_ACTIVE'; END IF;
  END LOOP;
  FOR li IN SELECT b.product_id,b.layer_id FROM public.inventory_cost_source_layer_balances b
    WHERE b.outlet_id=o AND b.product_id IN(SELECT product_id FROM public.pos_cart_items WHERE cart_id=p_cart_id)
    ORDER BY b.product_id,b.layer_id LOOP
    PERFORM 1 FROM public.inventory_cost_source_layer_balances WHERE layer_id=li.layer_id FOR UPDATE;
  END LOOP;
  INSERT INTO public.stock_operation_requests(request_id,actor_id,operation_key,target_key,request_payload,payload_hash)
    VALUES(p_request_id,a,'POS_CHECKOUT',p_cart_id::text,jsonb_build_object('cart_id',p_cart_id,'revision',p_expected_cart_revision,'payload',payload),h);
  sale:=gen_random_uuid();
  sale_no:='QPOS-'||to_char(completed AT TIME ZONE 'Asia/Jakarta','YYYYMMDD')||'-'||lpad(nextval('public.pos_sale_number_seq')::text,8,'0');
  SELECT coalesce(nullif(btrim(p.full_name),''),'Kasir') INTO cashier
    FROM public.profiles p WHERE p.id=a;
  cashier:=coalesce(nullif(btrim(cashier),''),'Kasir');
  INSERT INTO public.sales(id,outlet_id,cashier_id,completed_by,pos_cart_id,checkout_request_id,sale_number,
    subtotal,discount_total,grand_total,completed_at)
  VALUES(sale,o,a,a,p_cart_id,p_request_id,sale_no,total,0,total,completed);
  FOR li IN SELECT ci.*,p.name,p.sku,p.unit_label,s.amount FROM public.pos_cart_items ci
    JOIN public.products p ON p.id=ci.product_id JOIN public.product_selling_prices s ON s.product_id=ci.product_id AND s.outlet_id=o
    WHERE ci.cart_id=p_cart_id ORDER BY ci.product_id LOOP
    v_line_number:=v_line_number+1;
    INSERT INTO public.sale_items(sale_id,pos_cart_id,pos_cart_item_id,outlet_id,product_id,line_number,product_name_snapshot,
      sku_snapshot,unit_snapshot,quantity,unit_selling_price,selling_price_history_id,price_checked_at)
    SELECT sale,p_cart_id,li.id,o,li.product_id,v_line_number,li.name,li.sku,li.unit_label,
      li.quantity,li.amount,ph.id,completed
    FROM (SELECT 1) seed LEFT JOIN LATERAL (SELECT h.id,h.effective_at FROM public.product_selling_price_history h
      WHERE h.product_id=li.product_id AND h.outlet_id=o AND h.amount=li.amount ORDER BY h.effective_at DESC,h.id DESC LIMIT 1) ph ON true;
  END LOOP;
  INSERT INTO public.sale_payments(sale_id,outlet_id,method,applied_amount,received_amount,change_amount,reference_text,recorded_by)
  VALUES(sale,o,p_payment_method,total,received,change_amt,ref,a);
  INSERT INTO public.stock_movement_batches(authority_period_id,outlet_id,source_system,operation_request_id,created_by,pos_sale_id,pos_checkout_request_id)
    VALUES(period.id,o,'QUENA_POS',p_request_id,a,sale,p_request_id) RETURNING id INTO batch;
  FOR li IN SELECT si.*,ci.product_id FROM public.sale_items si JOIN public.pos_cart_items ci ON ci.id=si.pos_cart_item_id
    WHERE si.sale_id=sale ORDER BY si.product_id LOOP
    SELECT b.balance_before,b.balance_after,b.new_balance_version INTO before_qty,after_qty,ver
      FROM public.stock_apply_balance_delta(li.product_id,o,-li.quantity) b;
    INSERT INTO public.stock_movements(batch_id,authority_period_id,outlet_id,product_id,movement_type,source_system,
      quantity_delta,balance_before,balance_after,source_event_key,created_by,pos_sale_id,pos_sale_item_id,pos_checkout_request_id)
    VALUES(batch,period.id,o,li.product_id,'SALE','QUENA_POS',-li.quantity,before_qty,after_qty,
      'POS_SALE:'||sale::text||':'||li.id::text,a,sale,li.id,p_request_id) RETURNING id INTO mid;
    INSERT INTO public.stock_balance_projection_events(product_id,outlet_id,authority_period_id,event_type,request_id,
      quantity_delta,balance_before,balance_after,balance_version,actor_id)
    VALUES(li.product_id,o,period.id,'MOVEMENT_POSTED',p_request_id,-li.quantity,before_qty,after_qty,ver,a);
  END LOOP;
  IF public.inventory_cost_apply_pos_sale(p_request_id,sale,o,period.id,a)<>(SELECT count(*) FROM public.sale_items WHERE sale_id=sale) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POS sale costing incomplete'; END IF;
  UPDATE public.pos_carts SET status='COMPLETED',revision=revision+1,updated_at=now() WHERE id=p_cart_id;
  INSERT INTO public.pos_cart_events(cart_id,outlet_id,event_type,actor_id,checkout_request_id,revision,event_data)
    VALUES(p_cart_id,o,'COMPLETED',a,p_request_id,c.revision+1,jsonb_build_object('sale_number',sale_no));
  response:=jsonb_build_object('sale_id',sale,'sale_number',sale_no,'completed_at',completed,'cashier_label',cashier,
    'items',(SELECT jsonb_agg(jsonb_build_object('name',si.product_name_snapshot,'sku',si.sku_snapshot,'unit',si.unit_snapshot,
      'quantity',si.quantity,'unit_selling_price',si.unit_selling_price,'line_subtotal',si.line_subtotal) ORDER BY si.line_number)
      FROM public.sale_items si WHERE si.sale_id=sale),'subtotal',total,'discount_total',0,'grand_total',total,
    'payment_method',p_payment_method,'cash_received_amount',received,'change_amount',change_amt,'reference_text',ref);
  UPDATE public.pos_checkout_requests SET state='COMPLETED',sale_id=sale,result=response,completed_at=completed WHERE request_id=p_request_id;
  UPDATE public.stock_operation_requests SET state='COMPLETED',result=jsonb_build_object('sale_id',sale,'sale_number',sale_no),completed_at=completed WHERE request_id=p_request_id;
  RETURN response;
END; $$;
ALTER FUNCTION public.pos_checkout_complete(uuid,uuid,bigint,public.pos_sale_payment_method,numeric,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_checkout_complete(uuid,uuid,bigint,public.pos_sale_payment_method,numeric,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_checkout_complete(uuid,uuid,bigint,public.pos_sale_payment_method,numeric,text) TO authenticated;

COMMIT;
