-- One-time post-WAC stock enrollment for products introduced after cutover.
-- Normal first supplier receipts may establish only a zero-before-receipt
-- baseline; products already physically present require explicit OWNER attest.
BEGIN;

ALTER TABLE public.inventory_cost_operation_requests
  DROP CONSTRAINT inventory_cost_operation_requests_operation_key_check,
  ADD CONSTRAINT inventory_cost_operation_requests_operation_key_check
    CHECK (operation_key IN ('BOOTSTRAP_OUTLET','PURCHASE_RECEIPT','OPNAME_ADJUSTMENT',
      'REVERSAL','STOCK_CORRECTION','SUPPLIER_RETURN','POS_SALE','IPOS_SALES_IMPORT',
      'TRANSITION_PRODUCT_ENROLLMENT'));

CREATE TABLE public.post_wac_product_enrollments (
  request_id uuid PRIMARY KEY,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  enrollment_kind text NOT NULL CHECK (enrollment_kind IN ('OWNER_TRANSITION','FIRST_RECEIPT_ZERO')),
  effective_at timestamptz NOT NULL,
  accepted_quantity numeric(32,3) NOT NULL CHECK (accepted_quantity>=0 AND accepted_quantity=trunc(accepted_quantity,3)),
  valuation_decision text NOT NULL CHECK (valuation_decision IN ('VALUED','UNVALUED')),
  accepted_unit_cost numeric(20,8),
  reason text NOT NULL CHECK (length(btrim(reason)) BETWEEN 3 AND 1000),
  receipt_id uuid REFERENCES public.purchase_receipts(id) ON DELETE RESTRICT,
  receipt_item_id uuid REFERENCES public.purchase_receipt_items(id) ON DELETE RESTRICT,
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{32}$'),
  result jsonb NOT NULL CHECK (jsonb_typeof(result)='object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT post_wac_enrollment_value_shape CHECK (
    (valuation_decision='VALUED' AND accepted_unit_cost IS NOT NULL AND accepted_unit_cost>=0)
    OR (valuation_decision='UNVALUED' AND accepted_unit_cost IS NULL)
  ),
  CONSTRAINT post_wac_enrollment_kind_shape CHECK (
    (enrollment_kind='OWNER_TRANSITION' AND receipt_id IS NULL AND receipt_item_id IS NULL)
    OR (enrollment_kind='FIRST_RECEIPT_ZERO' AND accepted_quantity=0 AND receipt_id IS NOT NULL AND receipt_item_id IS NOT NULL)
  ),
  CONSTRAINT post_wac_enrollment_product_once UNIQUE(outlet_id,product_id),
  CONSTRAINT post_wac_enrollment_id_outlet_product UNIQUE(request_id,outlet_id,product_id),
  CONSTRAINT post_wac_enrollment_receipt_item_once UNIQUE(receipt_item_id)
);
ALTER TABLE public.post_wac_product_enrollments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_wac_product_enrollments FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.post_wac_product_enrollments FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.post_wac_product_enrollments TO authenticated;
CREATE POLICY post_wac_product_enrollment_manager_read ON public.post_wac_product_enrollments
  FOR SELECT TO authenticated USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));

CREATE FUNCTION public.reject_post_wac_enrollment_mutation()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Post-WAC enrollment evidence is immutable'; END; $$;
ALTER FUNCTION public.reject_post_wac_enrollment_mutation() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reject_post_wac_enrollment_mutation() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER post_wac_enrollment_immutable BEFORE UPDATE OR DELETE ON public.post_wac_product_enrollments
  FOR EACH ROW EXECUTE FUNCTION public.reject_post_wac_enrollment_mutation();

ALTER TABLE public.stock_balance_projection ADD COLUMN post_wac_enrollment_request_id uuid;
ALTER TABLE public.stock_balance_projection
  DROP CONSTRAINT stock_balance_baseline_identity_consistent,
  ADD CONSTRAINT stock_balance_post_wac_enrollment_fk
    FOREIGN KEY(post_wac_enrollment_request_id,outlet_id,product_id)
    REFERENCES public.post_wac_product_enrollments(request_id,outlet_id,product_id) ON DELETE RESTRICT,
  ADD CONSTRAINT stock_balance_baseline_identity_consistent CHECK (
    (baseline_quantity IS NULL AND baseline_source_import_row_id IS NULL AND baseline_batch_id IS NULL
      AND baseline_commit_id IS NULL AND native_zero_baseline_request_id IS NULL AND post_wac_enrollment_request_id IS NULL)
    OR (baseline_quantity IS NOT NULL AND baseline_source_import_row_id IS NOT NULL AND baseline_batch_id IS NOT NULL
      AND baseline_commit_id IS NOT NULL AND native_zero_baseline_request_id IS NULL AND post_wac_enrollment_request_id IS NULL)
    OR (baseline_quantity=0 AND baseline_source_import_row_id IS NULL AND baseline_batch_id IS NULL
      AND baseline_commit_id IS NULL AND native_zero_baseline_request_id IS NOT NULL AND post_wac_enrollment_request_id IS NULL)
    OR (baseline_quantity IS NOT NULL AND baseline_source_import_row_id IS NULL AND baseline_batch_id IS NULL
      AND baseline_commit_id IS NULL AND native_zero_baseline_request_id IS NULL AND post_wac_enrollment_request_id IS NOT NULL)
  );

ALTER TABLE public.stock_balance_projection_events
  ADD COLUMN post_wac_enrollment_request_id uuid,
  DROP CONSTRAINT stock_balance_projection_events_event_type_check,
  ADD CONSTRAINT stock_balance_projection_events_event_type_check CHECK(event_type IN (
    'MOVEMENT_POSTED','MOVEMENT_RECONCILED','AUTHORITY_BASELINE_ACCEPTED','NATIVE_ZERO_BASELINE_ACCEPTED',
    'NATIVE_BASELINE_PERIOD_ADVANCED','POST_WAC_PRODUCT_ENROLLED')),
  ADD CONSTRAINT stock_balance_projection_event_post_wac_fk FOREIGN KEY(post_wac_enrollment_request_id,outlet_id,product_id)
    REFERENCES public.post_wac_product_enrollments(request_id,outlet_id,product_id) ON DELETE RESTRICT,
  DROP CONSTRAINT stock_balance_projection_event_request_shape,
  ADD CONSTRAINT stock_balance_projection_event_request_shape CHECK (
    (event_type='AUTHORITY_BASELINE_ACCEPTED' AND request_id IS NULL AND opening_cutover_request_id IS NOT NULL
      AND native_zero_baseline_request_id IS NULL AND post_wac_enrollment_request_id IS NULL)
    OR (event_type='NATIVE_ZERO_BASELINE_ACCEPTED' AND request_id IS NULL AND opening_cutover_request_id IS NULL
      AND native_zero_baseline_request_id IS NOT NULL AND post_wac_enrollment_request_id IS NULL)
    OR (event_type='NATIVE_BASELINE_PERIOD_ADVANCED' AND request_id IS NULL AND opening_cutover_request_id IS NOT NULL
      AND native_zero_baseline_request_id IS NOT NULL AND post_wac_enrollment_request_id IS NULL)
    OR (event_type='POST_WAC_PRODUCT_ENROLLED' AND request_id IS NULL AND opening_cutover_request_id IS NULL
      AND native_zero_baseline_request_id IS NULL AND post_wac_enrollment_request_id IS NOT NULL)
    OR (event_type NOT IN ('AUTHORITY_BASELINE_ACCEPTED','NATIVE_ZERO_BASELINE_ACCEPTED','NATIVE_BASELINE_PERIOD_ADVANCED',
      'POST_WAC_PRODUCT_ENROLLED') AND opening_cutover_request_id IS NULL
      AND native_zero_baseline_request_id IS NULL AND post_wac_enrollment_request_id IS NULL)
  );

ALTER TYPE public.inventory_cost_acquisition_basis ADD VALUE IF NOT EXISTS 'POST_WAC_ENROLLMENT';

-- Keep per-line evidence for sales already represented by a transition count.
CREATE TABLE public.ipos_sales_import_stock_dispositions (
  import_line_id uuid PRIMARY KEY REFERENCES public.ipos_sales_import_lines(id) ON DELETE RESTRICT,
  enrollment_request_id uuid NOT NULL REFERENCES public.post_wac_product_enrollments(request_id) ON DELETE RESTRICT,
  disposition text NOT NULL CHECK(disposition IN ('INCLUDED_IN_CONFIRMED_BASELINE','DEPLETED_AFTER_BASELINE')),
  source_occurred_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT
);
ALTER TABLE public.ipos_sales_import_stock_dispositions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ipos_sales_import_stock_dispositions FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.ipos_sales_import_stock_dispositions FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.ipos_sales_import_stock_dispositions TO authenticated;
CREATE POLICY ipos_import_stock_disposition_manager_read ON public.ipos_sales_import_stock_dispositions
  FOR SELECT TO authenticated USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE TRIGGER ipos_import_stock_disposition_immutable BEFORE UPDATE OR DELETE ON public.ipos_sales_import_stock_dispositions
  FOR EACH ROW EXECUTE FUNCTION public.reject_post_wac_enrollment_mutation();

CREATE FUNCTION public.inventory_cost_apply_post_wac_enrollment(
  p_request_id uuid,p_outlet_id uuid,p_product_id uuid,p_quantity numeric,p_valuation_decision text,
  p_unit_cost numeric,p_effective_at timestamptz,p_reason text,p_actor uuid,p_kind text,
  p_receipt_id uuid DEFAULT NULL,p_receipt_item_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_period uuid; v_stock public.stock_balance_projection%rowtype; v_cost public.inventory_cost_projections%rowtype;
  v_batch uuid; v_event uuid; v_hash text; v_result jsonb; v_value numeric(32,8); v_valuation public.inventory_cost_projection_status;
  v_cost_req uuid; v_role public.user_role; v_product_created timestamptz; v_active_at timestamptz;
  v_existing public.post_wac_product_enrollments%rowtype;
BEGIN
  IF p_actor IS NULL OR auth.uid() IS DISTINCT FROM p_actor OR p_request_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POST_WAC_ENROLLMENT_UNAUTHORIZED'; END IF;
  v_role:=public.current_active_user_role();
  IF (p_kind='OWNER_TRANSITION' AND v_role<>'OWNER'::public.user_role)
    OR (p_kind='FIRST_RECEIPT_ZERO' AND v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'GUDANG'::public.user_role)) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POST_WAC_ENROLLMENT_UNAUTHORIZED'; END IF;
  IF p_outlet_id IS NULL OR p_product_id IS NULL OR p_quantity IS NULL OR p_quantity<0
    OR p_quantity<>trunc(p_quantity,3) OR p_effective_at IS NULL OR p_effective_at>transaction_timestamp()
    OR p_reason IS NULL OR length(btrim(p_reason))<3 OR length(p_reason)>1000
    OR p_valuation_decision NOT IN ('VALUED','UNVALUED')
    OR (p_valuation_decision='VALUED' AND (p_unit_cost IS NULL OR p_unit_cost<0 OR p_unit_cost<>trunc(p_unit_cost,8)))
    OR (p_valuation_decision='UNVALUED' AND p_unit_cost IS NOT NULL)
    OR (p_kind='OWNER_TRANSITION' AND (p_receipt_id IS NOT NULL OR p_receipt_item_id IS NOT NULL))
    OR (p_kind='FIRST_RECEIPT_ZERO' AND (p_quantity<>0 OR p_receipt_id IS NULL OR p_receipt_item_id IS NULL)) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='POST_WAC_ENROLLMENT_INVALID'; END IF;
  v_hash:=md5(jsonb_build_object('request',p_request_id,'outlet',p_outlet_id,'product',p_product_id,'quantity',p_quantity,
    'decision',p_valuation_decision,'unitCost',p_unit_cost,'effectiveAt',p_effective_at,'reason',btrim(p_reason),
    'kind',p_kind,'receipt',p_receipt_id,'receiptItem',p_receipt_item_id)::text);
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_BOOTSTRAP_OUTLET:'||p_outlet_id::text,73190411));
  SELECT * INTO v_existing FROM public.post_wac_product_enrollments WHERE request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF v_existing.payload_hash<>v_hash THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='POST_WAC_ENROLLMENT_REQUEST_REUSED'; END IF;
    RETURN v_existing.result;
  END IF;
  IF EXISTS(SELECT 1 FROM public.post_wac_product_enrollments WHERE outlet_id=p_outlet_id AND product_id=p_product_id) THEN
    RAISE EXCEPTION USING ERRCODE='23505',MESSAGE='POST_WAC_PRODUCT_ALREADY_ENROLLED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE outlet_id=p_outlet_id AND status='WAC_ACTIVE') THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POST_WAC_ENROLLMENT_REQUIRES_WAC_ACTIVE'; END IF;
  SELECT id INTO v_period FROM public.stock_authority_periods WHERE outlet_id=p_outlet_id AND ended_at IS NULL AND mode='QUENA_MOVEMENT_LEDGER' FOR UPDATE;
  IF v_period IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POST_WAC_ENROLLMENT_STOCK_AUTHORITY_REQUIRED'; END IF;
  SELECT * INTO v_stock FROM public.stock_balance_projection WHERE outlet_id=p_outlet_id AND product_id=p_product_id FOR UPDATE;
  IF NOT FOUND OR v_stock.authority_period_id<>v_period OR v_stock.effective_quantity IS NOT NULL
    OR v_stock.unreconciled_movement_delta<>0 OR v_stock.baseline_quantity IS NOT NULL
    OR v_stock.native_zero_baseline_request_id IS NOT NULL OR v_stock.post_wac_enrollment_request_id IS NOT NULL
    OR EXISTS(SELECT 1 FROM public.stock_movements WHERE outlet_id=p_outlet_id AND product_id=p_product_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections WHERE outlet_id=p_outlet_id AND product_id=p_product_id) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POST_WAC_PRODUCT_NOT_UNENROLLED'; END IF;
  IF EXISTS(SELECT 1 FROM public.stock_opname_items i JOIN public.stock_opname_sessions s ON s.id=i.session_id
    WHERE i.outlet_id=p_outlet_id AND i.product_id=p_product_id AND i.active_scope
      AND s.status IN ('COUNTING'::public.stock_opname_status,'REVIEW'::public.stock_opname_status))
    OR EXISTS(SELECT 1 FROM public.stock_opname_items i JOIN public.stock_opname_sessions s ON s.id=i.session_id
      WHERE i.outlet_id=p_outlet_id AND i.product_id=p_product_id
        AND s.status='POSTED'::public.stock_opname_status
        AND p_effective_at<=coalesce(i.last_counted_at,s.posted_at)) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POST_WAC_ENROLLMENT_OPNAME_CONFLICT'; END IF;
  SELECT p.created_at,a.activated_at INTO v_product_created,v_active_at
  FROM public.products p CROSS JOIN public.inventory_costing_outlet_authority a
  WHERE p.id=p_product_id AND a.outlet_id=p_outlet_id;
  IF v_product_created IS NULL OR v_active_at IS NULL OR v_product_created<=v_active_at THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POST_WAC_ENROLLMENT_PRODUCT_NOT_NEW'; END IF;
  IF p_kind='FIRST_RECEIPT_ZERO' AND NOT EXISTS(SELECT 1 FROM public.purchase_receipt_items i
    JOIN public.purchase_receipts r ON r.id=i.receipt_id WHERE i.id=p_receipt_item_id AND i.receipt_id=p_receipt_id
      AND i.product_id=p_product_id AND r.outlet_id=p_outlet_id AND r.status='DRAFT' AND r.received_at=p_effective_at) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POST_WAC_ENROLLMENT_RECEIPT_CONTEXT_INVALID'; END IF;
  IF EXISTS(SELECT 1 FROM public.ipos_sales_import_lines l JOIN public.ipos_sales_import_transactions t ON t.id=l.transaction_id
    JOIN public.ipos_sales_import_batches b ON b.id=l.batch_id
    JOIN public.products pr ON pr.id=p_product_id
    WHERE b.outlet_id=p_outlet_id AND (l.product_id=p_product_id OR l.raw_sku=pr.sku) AND b.status<>'CANCELLED'
      AND t.source_occurred_at<=p_effective_at AND p_kind='FIRST_RECEIPT_ZERO') THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POST_WAC_ENROLLMENT_PRE_RECEIPT_SALE_CONFLICT'; END IF;

  v_cost_req:=p_request_id;
  INSERT INTO public.inventory_cost_operation_requests(request_id,actor_id,operation_key,target_key,payload_hash)
    VALUES(v_cost_req,p_actor,'TRANSITION_PRODUCT_ENROLLMENT',p_outlet_id::text||':'||p_product_id::text,v_hash);
  v_valuation:=CASE WHEN p_valuation_decision='UNVALUED' THEN 'UNVALUED'::public.inventory_cost_projection_status
    ELSE 'VALUED'::public.inventory_cost_projection_status END;
  v_value:=CASE WHEN p_valuation_decision='UNVALUED' THEN NULL ELSE round(p_quantity*p_unit_cost,8) END;
  INSERT INTO public.inventory_cost_event_batches(outlet_id,batch_type,source_entity_type,source_entity_id,
    operation_request_id,source_amount,allocation_method,created_by)
  VALUES(p_outlet_id,'CORRECTION','TRANSITION_PRODUCT_ENROLLMENT',p_product_id,p_request_id,v_value,
    'OWNER_ATTESTED_PHYSICAL_BASELINE',p_actor) RETURNING id INTO v_batch;
  INSERT INTO public.inventory_cost_events(batch_id,outlet_id,product_id,event_type,source_entity_type,source_entity_id,
    quantity_delta,valued_quantity_before,valued_quantity_after,inventory_value_delta,inventory_value_before,
    inventory_value_after,wac_before,wac_after,valuation_status_before,valuation_status_after,cost_version_before,
    cost_version_after,stock_balance_version,stock_authority_period_id,actor_id,operation_request_id,
    physical_quantity_delta,physical_quantity_before,physical_quantity_after,valued_quantity_delta,
    provisional_quantity_delta,provisional_quantity_before,provisional_quantity_after,unvalued_quantity_delta,
    unvalued_quantity_before,unvalued_quantity_after,valuation_basis,frozen_unit_cost,metadata)
  VALUES(v_batch,p_outlet_id,p_product_id,'CORRECTION','TRANSITION_PRODUCT_ENROLLMENT',p_request_id,p_quantity,
    0,CASE WHEN p_valuation_decision='VALUED' THEN p_quantity ELSE 0 END,v_value,NULL,v_value,NULL,
    CASE WHEN p_quantity>0 AND p_valuation_decision='VALUED' THEN p_unit_cost END,NULL,v_valuation,0,1,
    v_stock.balance_version,v_period,p_actor,p_request_id,p_quantity,0,p_quantity,
    CASE WHEN p_valuation_decision='VALUED' THEN p_quantity ELSE 0 END,0,0,0,
    CASE WHEN p_valuation_decision='UNVALUED' THEN p_quantity ELSE 0 END,0,
    CASE WHEN p_valuation_decision='UNVALUED' THEN p_quantity ELSE 0 END,
    'POST_WAC_ENROLLMENT'::public.inventory_cost_acquisition_basis,p_unit_cost,
    jsonb_build_object('effectiveAt',p_effective_at,'reason',btrim(p_reason),'enrollmentKind',p_kind,
      'historicalSaleCogsEvidence',false,'source','POST_WAC_PRODUCT_ENROLLMENT')) RETURNING id INTO v_event;
  PERFORM public.inventory_cost_open_source_layer(v_event);
  INSERT INTO public.inventory_cost_projections(outlet_id,product_id,physical_quantity,valued_quantity,
    provisional_quantity,unvalued_quantity,inventory_value,current_wac,valuation_status,cost_version,
    stock_balance_version,stock_authority_period_id,last_cost_event_id)
  VALUES(p_outlet_id,p_product_id,p_quantity,
    CASE WHEN p_valuation_decision='VALUED' THEN p_quantity ELSE 0 END,0,
    CASE WHEN p_valuation_decision='UNVALUED' THEN p_quantity ELSE 0 END,v_value,
    CASE WHEN p_quantity>0 AND p_valuation_decision='VALUED' THEN p_unit_cost END,v_valuation,1,
    v_stock.balance_version,v_period,v_event);
  v_result:=jsonb_build_object('ok',true,'requestId',p_request_id,'productId',p_product_id,'outletId',p_outlet_id,
    'effectiveAt',p_effective_at,'effectiveQuantity',p_quantity,'valuationDecision',p_valuation_decision,
    'inventoryValue',v_value,'wac',CASE WHEN p_quantity>0 AND p_valuation_decision='VALUED' THEN p_unit_cost END,
    'costEventId',v_event,'costVersion',1);
  INSERT INTO public.post_wac_product_enrollments(request_id,outlet_id,product_id,actor_id,enrollment_kind,effective_at,
    accepted_quantity,valuation_decision,accepted_unit_cost,reason,receipt_id,receipt_item_id,payload_hash,result)
  VALUES(p_request_id,p_outlet_id,p_product_id,p_actor,p_kind,p_effective_at,p_quantity,p_valuation_decision,
    p_unit_cost,btrim(p_reason),p_receipt_id,p_receipt_item_id,v_hash,v_result);
  UPDATE public.stock_balance_projection SET baseline_quantity=p_quantity,post_wac_enrollment_request_id=p_request_id,
    balance_version=balance_version+1,last_observation_status='BOOTSTRAPPED',updated_at=now()
  WHERE outlet_id=p_outlet_id AND product_id=p_product_id RETURNING * INTO v_stock;
  INSERT INTO public.stock_balance_projection_events(product_id,outlet_id,authority_period_id,event_type,request_id,
    quantity_delta,balance_before,balance_after,balance_version,actor_id,post_wac_enrollment_request_id)
  VALUES(p_product_id,p_outlet_id,v_period,'POST_WAC_PRODUCT_ENROLLED',NULL,0,p_quantity,p_quantity,
    v_stock.balance_version,p_actor,p_request_id);
  UPDATE public.inventory_cost_operation_requests SET result=v_result,completed_at=now() WHERE request_id=p_request_id;
  RETURN v_result;
END; $$;
ALTER FUNCTION public.inventory_cost_apply_post_wac_enrollment(uuid,uuid,uuid,numeric,text,numeric,timestamptz,text,uuid,text,uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_apply_post_wac_enrollment(uuid,uuid,uuid,numeric,text,numeric,timestamptz,text,uuid,text,uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.enroll_post_wac_product(p_request_id uuid,p_product_id uuid,p_quantity numeric,
  p_valuation_decision text,p_unit_cost numeric,p_effective_at timestamptz,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=auth.uid();o uuid;n integer;r jsonb;
BEGIN
  IF a IS NULL OR public.current_active_user_role()<>'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POST_WAC_ENROLLMENT_OWNER_ONLY'; END IF;
  SELECT count(*)::integer,(array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1] INTO n,o
  FROM public.stock_authority_periods ap JOIN public.outlets x ON x.id=ap.outlet_id
  WHERE ap.ended_at IS NULL AND x.is_active;
  IF n<>1 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POST_WAC_ENROLLMENT_OUTLET_UNAVAILABLE'; END IF;
  r:=public.inventory_cost_apply_post_wac_enrollment(p_request_id,o,p_product_id,p_quantity,p_valuation_decision,
    p_unit_cost,p_effective_at,p_reason,a,'OWNER_TRANSITION',NULL,NULL);
  RETURN r;
END; $$;
ALTER FUNCTION public.enroll_post_wac_product(uuid,uuid,numeric,text,numeric,timestamptz,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.enroll_post_wac_product(uuid,uuid,numeric,text,numeric,timestamptz,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.enroll_post_wac_product(uuid,uuid,numeric,text,numeric,timestamptz,text) TO authenticated;

CREATE FUNCTION public.inventory_cost_enroll_first_receipt_zero(
  p_product_id uuid,p_outlet_id uuid,p_receipt_id uuid,p_receipt_item_id uuid,p_received_at timestamptz,p_actor uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_request uuid; v_result jsonb;
BEGIN
  v_request:=md5('FIRST_RECEIPT_ZERO:'||p_receipt_item_id::text)::uuid;
  v_result:=public.inventory_cost_apply_post_wac_enrollment(v_request,p_outlet_id,p_product_id,0,'VALUED',0,
    p_received_at,'Zero-before-first-post-WAC supplier receipt; receipt is the authoritative first quantity event',
    p_actor,'FIRST_RECEIPT_ZERO',p_receipt_id,p_receipt_item_id);
  RETURN v_result;
END; $$;
ALTER FUNCTION public.inventory_cost_enroll_first_receipt_zero(uuid,uuid,uuid,uuid,timestamptz,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_enroll_first_receipt_zero(uuid,uuid,uuid,uuid,timestamptz,uuid) FROM PUBLIC,anon,authenticated,service_role;

-- Extend import readiness so quantities covered by an attested as-of physical
-- count are not demanded or subtracted a second time. Later sales still use C1.
DO $patch$
DECLARE d text; old text; new text;
BEGIN
  d:=pg_get_functiondef('public.inventory_cost_assert_event_layer_allocation(uuid)'::regprocedure);
  old:=$old$IF e.event_type::text NOT IN ('OPENING','PURCHASE_RECEIPT','OPNAME_ADJUSTMENT','REVERSAL','SUPPLIER_RETURN') THEN RETURN; END IF;$old$;
  new:=$new$IF e.event_type::text NOT IN ('OPENING','PURCHASE_RECEIPT','OPNAME_ADJUSTMENT','REVERSAL','SUPPLIER_RETURN')
    AND NOT (e.event_type::text='CORRECTION' AND e.source_entity_type='TRANSITION_PRODUCT_ENROLLMENT') THEN RETURN; END IF;$new$;
  IF position(old IN d)=0 THEN RAISE EXCEPTION 'C3A cost layer assertion guard changed'; END IF;
  d:=replace(d,old,new); EXECUTE d;

  d:=pg_get_functiondef('public.inventory_cost_open_source_layer(uuid)'::regprocedure);
  old:=$old$IF v_event.event_type::text NOT IN ('OPENING','PURCHASE_RECEIPT','OPNAME_ADJUSTMENT') THEN$old$;
  new:=$new$IF v_event.event_type::text NOT IN ('OPENING','PURCHASE_RECEIPT','OPNAME_ADJUSTMENT')
    AND NOT (v_event.event_type::text='CORRECTION' AND v_event.source_entity_type='TRANSITION_PRODUCT_ENROLLMENT') THEN$new$;
  IF position(old IN d)=0 THEN RAISE EXCEPTION 'C3A source layer event guard changed'; END IF;
  d:=replace(d,old,new);
  old:=$old$OR (v_physical=0 AND v_event.event_type::text<>'OPENING') THEN$old$;
  new:=$new$OR (v_physical=0 AND v_event.event_type::text<>'OPENING'
      AND v_event.source_entity_type<>'TRANSITION_PRODUCT_ENROLLMENT') THEN$new$;
  IF position(old IN d)=0 THEN RAISE EXCEPTION 'C3A zero source layer guard changed'; END IF;
  d:=replace(d,old,new);
  old:=$old$v_kind:=CASE v_event.event_type::text WHEN 'OPENING' THEN 'OPENING'
    WHEN 'PURCHASE_RECEIPT' THEN 'PURCHASE_RECEIPT' ELSE 'OPNAME_GAIN' END;$old$;
  new:=$new$v_kind:=CASE WHEN v_event.source_entity_type='TRANSITION_PRODUCT_ENROLLMENT' THEN 'OPENING'
    WHEN v_event.event_type::text='OPENING' THEN 'OPENING' WHEN v_event.event_type::text='PURCHASE_RECEIPT' THEN 'PURCHASE_RECEIPT'
    ELSE 'OPNAME_GAIN' END;$new$;
  IF position(old IN d)=0 THEN RAISE EXCEPTION 'C3A source layer allocation kind changed'; END IF;
  d:=replace(d,old,new); EXECUTE d;

  d:=pg_get_functiondef('public.apply_purchase_receipt_post_intent(uuid)'::regprocedure);
  old:=$old$    IF NOT FOUND OR v_projection.effective_quantity IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Stock projection is unavailable for this outlet period'; END IF;$old$;
  new:=$new$    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Stock projection is unavailable for this outlet period'; END IF;
    IF v_projection.effective_quantity IS NULL THEN
      PERFORM public.inventory_cost_enroll_first_receipt_zero(v_item.product_id,v_receipt.outlet_id,v_receipt.id,
        v_item.id,v_receipt.received_at,v_actor);
      SELECT * INTO v_projection FROM public.stock_balance_projection p
        WHERE p.product_id=v_item.product_id AND p.outlet_id=v_receipt.outlet_id FOR UPDATE;
      IF NOT FOUND OR v_projection.effective_quantity IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Post-WAC receipt baseline enrollment failed'; END IF;
    END IF;$new$;
  IF position(old IN d)=0 THEN RAISE EXCEPTION 'C3A receipt stock projection guard changed'; END IF;
  d:=replace(d,old,new); EXECUTE d;

  d:=pg_get_functiondef('public.ipos_sales_import_recheck(uuid,uuid)'::regprocedure);
  old:=$old$v_negative integer;v_posted_conflicts integer;$old$;
  new:=$new$v_negative integer;v_posted_conflicts integer;v_receipt_chronology integer;$new$;
  IF position(old IN d)=0 THEN RAISE EXCEPTION 'C3A recheck declaration changed'; END IF;
  d:=replace(d,old,new);
  old:=$old$FROM (SELECT product_id,sum(raw_quantity) q FROM public.ipos_sales_import_lines
    WHERE batch_id=p_batch_id AND product_id IS NOT NULL GROUP BY product_id) l$old$;
  new:=$new$FROM (SELECT l.product_id,sum(l.raw_quantity) q FROM public.ipos_sales_import_lines l
    JOIN public.ipos_sales_import_transactions t ON t.id=l.transaction_id
    LEFT JOIN public.post_wac_product_enrollments e ON e.outlet_id=v_outlet AND e.product_id=l.product_id
    WHERE l.batch_id=p_batch_id AND l.product_id IS NOT NULL
      AND (e.request_id IS NULL OR t.source_occurred_at>e.effective_at OR e.enrollment_kind='FIRST_RECEIPT_ZERO')
      GROUP BY l.product_id) l$new$;
  IF position(old IN d)=0 THEN RAISE EXCEPTION 'C3A recheck stock-demand expression changed'; END IF;
  d:=replace(d,old,new);
  old:=$old$AND t.source_occurred_at<=coalesce(i.last_counted_at,s.posted_at);$old$;
  new:=$new$AND t.source_occurred_at<=coalesce(i.last_counted_at,s.posted_at);
  SELECT count(DISTINCT l.product_id) INTO v_receipt_chronology
  FROM public.ipos_sales_import_lines l JOIN public.ipos_sales_import_transactions t ON t.id=l.transaction_id
  JOIN public.post_wac_product_enrollments e ON e.outlet_id=v_outlet AND e.product_id=l.product_id
  WHERE l.batch_id=p_batch_id AND e.enrollment_kind='FIRST_RECEIPT_ZERO' AND t.source_occurred_at<=e.effective_at;$new$;
  IF position(old IN d)=0 THEN RAISE EXCEPTION 'C3A recheck receipt chronology insertion changed'; END IF;
  d:=replace(d,old,new);
  old:=$old$AND v_posted_conflicts=0 AND ($old$;
  new:=$new$AND v_posted_conflicts=0 AND v_receipt_chronology=0 AND ($new$;
  IF position(old IN d)=0 THEN RAISE EXCEPTION 'C3A recheck status blocker expression changed'; END IF;
  d:=replace(d,old,new);
  old:=$old$'postedOpnameConflictCount',v_posted_conflicts,$old$;
  new:=$new$'postedOpnameConflictCount',v_posted_conflicts,'receiptChronologyConflictCount',v_receipt_chronology,$new$;
  IF position(old IN d)=0 THEN RAISE EXCEPTION 'C3A recheck result shape changed'; END IF;
  d:=replace(d,old,new); EXECUTE d;

  d:=pg_get_functiondef('public.ipos_sales_import_commit(uuid,integer,uuid)'::regprocedure);
  old:=$old$SELECT product_id,sum(raw_quantity) q FROM public.ipos_sales_import_lines
      WHERE batch_id=p_batch_id GROUP BY product_id) x LEFT JOIN public.stock_balance_projection p$old$;
  new:=$new$SELECT l.product_id,sum(l.raw_quantity) q FROM public.ipos_sales_import_lines l
      JOIN public.ipos_sales_import_transactions t ON t.id=l.transaction_id
      LEFT JOIN public.post_wac_product_enrollments e ON e.outlet_id=v_outlet AND e.product_id=l.product_id
      WHERE l.batch_id=p_batch_id AND (e.request_id IS NULL OR t.source_occurred_at>e.effective_at
        OR e.enrollment_kind='FIRST_RECEIPT_ZERO')
      GROUP BY l.product_id) x LEFT JOIN public.stock_balance_projection p$new$;
  IF position(old IN d)=0 THEN RAISE EXCEPTION 'C3A commit stock-demand expression changed'; END IF;
  d:=replace(d,old,new);
  old:=$old$  IF v_batch.status<>'READY' OR v_batch.revision<>p_expected_revision OR coalesce((v_batch.reconciliation->>'isReconciled')::boolean,false)=false$old$;
  new:=$new$  IF EXISTS(SELECT 1 FROM public.ipos_sales_import_lines l
    JOIN public.ipos_sales_import_transactions t ON t.id=l.transaction_id
    JOIN public.post_wac_product_enrollments e ON e.outlet_id=v_outlet AND e.product_id=l.product_id
    WHERE l.batch_id=p_batch_id AND e.enrollment_kind='FIRST_RECEIPT_ZERO' AND t.source_occurred_at<=e.effective_at)
    THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='IPOS_SALES_IMPORT_RECEIPT_CHRONOLOGY_CONFLICT'; END IF;
  IF v_batch.status<>'READY' OR v_batch.revision<>p_expected_revision OR coalesce((v_batch.reconciliation->>'isReconciled')::boolean,false)=false$new$;
  IF position(old IN d)=0 THEN RAISE EXCEPTION 'C3A commit receipt chronology guard changed'; END IF;
  d:=replace(d,old,new);
  -- Lines at or before the OWNER-attested timestamp are captured by the
  -- accepted physical baseline. Insert sale snapshots but no stock movement.
  old:=$old$      SELECT d.balance_before,d.balance_after,d.new_balance_version INTO v_before,v_after,v_version
        FROM public.stock_apply_balance_delta(v_item.product_id,v_outlet,-v_item.raw_quantity) d;$old$;
  new:=$new$      SELECT * INTO v_item_enrollment FROM public.post_wac_product_enrollments e
        JOIN public.ipos_sales_import_transactions tx ON tx.id=v_item.transaction_id
        WHERE e.outlet_id=v_outlet AND e.product_id=v_item.product_id AND tx.source_occurred_at<=e.effective_at;
      IF FOUND THEN
        INSERT INTO public.ipos_sales_import_stock_dispositions(import_line_id,enrollment_request_id,disposition,
          source_occurred_at,actor_id)
        VALUES(v_item.id,v_item_enrollment.request_id,'INCLUDED_IN_CONFIRMED_BASELINE',v_tx.source_occurred_at,v_actor);
        CONTINUE;
      END IF;
      SELECT d.balance_before,d.balance_after,d.new_balance_version INTO v_before,v_after,v_version
        FROM public.stock_apply_balance_delta(v_item.product_id,v_outlet,-v_item.raw_quantity) d;$new$;
  IF position(old IN d)=0 THEN RAISE EXCEPTION 'C3A commit stock movement loop changed'; END IF;
  d:=replace(d,old,new);
  old:=$old$DECLARE v_actor uuid:=auth.uid();v_role public.user_role;v_batch public.ipos_sales_import_batches%rowtype;$old$;
  new:=$new$DECLARE v_actor uuid:=auth.uid();v_role public.user_role;v_batch public.ipos_sales_import_batches%rowtype;
    v_item_enrollment record;$new$;
  IF position(old IN d)=0 THEN RAISE EXCEPTION 'C3A commit declaration changed'; END IF;
  d:=replace(d,old,new);
  EXECUTE d;
END $patch$;

COMMIT;
