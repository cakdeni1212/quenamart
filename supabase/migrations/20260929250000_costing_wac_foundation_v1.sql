-- Costing Engine v1 Checkpoint 1: immutable cost events and WAC bootstrap foundation.
-- This migration does not activate WAC or change stock/purchasing posting behavior.
BEGIN;

CREATE TYPE public.inventory_cost_valuation_status AS ENUM (
  'VALUED', 'PROVISIONAL', 'UNVALUED'
);

CREATE TYPE public.inventory_cost_authority_status AS ENUM (
  'REFERENCE_ONLY', 'BOOTSTRAP_READY', 'WAC_ACTIVE'
);

CREATE TYPE public.inventory_cost_event_type AS ENUM (
  'OPENING', 'PURCHASE_RECEIPT', 'INVOICE_ADJUSTMENT', 'LANDED_COST',
  'SALE_COGS', 'SUPPLIER_RETURN', 'CUSTOMER_RETURN', 'STOCK_ADJUSTMENT',
  'REVERSAL', 'CORRECTION'
);

CREATE TABLE public.inventory_cost_operation_requests (
  request_id uuid PRIMARY KEY,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  operation_key text NOT NULL CHECK (operation_key = 'BOOTSTRAP_OUTLET'),
  target_key text NOT NULL,
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{32}$'),
  result jsonb,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_cost_request_terminal CHECK ((result IS NULL) = (completed_at IS NULL))
);

CREATE TABLE public.inventory_cost_event_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  batch_type public.inventory_cost_event_type NOT NULL,
  source_entity_type text NOT NULL,
  source_entity_id uuid NOT NULL,
  operation_request_id uuid NOT NULL UNIQUE
    REFERENCES public.inventory_cost_operation_requests(request_id) ON DELETE RESTRICT,
  source_amount numeric(20,2),
  allocation_method text,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  applied_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_cost_batch_id_outlet_unique UNIQUE(id,outlet_id),
  CONSTRAINT inventory_cost_batch_source_type_nonblank CHECK (btrim(source_entity_type) <> ''),
  CONSTRAINT inventory_cost_batch_amount_valid CHECK (source_amount IS NULL OR source_amount >= 0),
  CONSTRAINT inventory_cost_batch_allocation_nonblank CHECK (
    allocation_method IS NULL OR btrim(allocation_method) <> ''
  )
);
CREATE INDEX inventory_cost_event_batches_outlet_time_idx
  ON public.inventory_cost_event_batches(outlet_id, created_at DESC, id DESC);

CREATE TABLE public.inventory_cost_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.inventory_cost_event_batches(id) ON DELETE RESTRICT,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  event_type public.inventory_cost_event_type NOT NULL,
  source_entity_type text NOT NULL,
  source_entity_id uuid NOT NULL,
  source_event_id uuid,
  quantity_delta numeric,
  valued_quantity_before numeric,
  valued_quantity_after numeric,
  inventory_value_delta numeric(32,8),
  inventory_value_before numeric(32,8),
  inventory_value_after numeric(32,8),
  wac_before numeric(20,8),
  wac_after numeric(20,8),
  valuation_status_before public.inventory_cost_valuation_status,
  valuation_status_after public.inventory_cost_valuation_status NOT NULL,
  cost_version_before bigint NOT NULL,
  cost_version_after bigint NOT NULL,
  stock_balance_version bigint NOT NULL CHECK (stock_balance_version > 0),
  stock_authority_period_id uuid NOT NULL,
  source_hpp_value numeric(20,8),
  source_hpp_import_row_id uuid,
  source_hpp_verification_review_id uuid REFERENCES public.product_field_audit_reviews(id) ON DELETE RESTRICT,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  operation_request_id uuid NOT NULL
    REFERENCES public.inventory_cost_operation_requests(request_id) ON DELETE RESTRICT,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_cost_event_source_type_nonblank CHECK (btrim(source_entity_type) <> ''),
  CONSTRAINT inventory_cost_event_versions_valid CHECK (
    cost_version_before >= 0 AND cost_version_after = cost_version_before + 1
  ),
  CONSTRAINT inventory_cost_event_quantity_valid CHECK (
    (quantity_delta IS NULL OR (quantity_delta > -100000000000 AND quantity_delta < 100000000000
      AND quantity_delta = trunc(quantity_delta,3)))
    AND (valued_quantity_before IS NULL OR (valued_quantity_before >= 0
      AND valued_quantity_before < 100000000000 AND valued_quantity_before = trunc(valued_quantity_before,3)))
    AND (valued_quantity_after IS NULL OR (valued_quantity_after >= 0
      AND valued_quantity_after < 100000000000 AND valued_quantity_after = trunc(valued_quantity_after,3)))
  ),
  CONSTRAINT inventory_cost_event_value_valid CHECK (
    (inventory_value_delta IS NULL OR inventory_value_delta > -100000000000000000000000)
    AND (inventory_value_before IS NULL OR inventory_value_before >= 0)
    AND (inventory_value_after IS NULL OR inventory_value_after >= 0)
    AND (wac_before IS NULL OR wac_before >= 0)
    AND (wac_after IS NULL OR wac_after >= 0)
    AND (source_hpp_value IS NULL OR (source_hpp_value >= 0 AND source_hpp_value < 1000000000000
      AND source_hpp_value = trunc(source_hpp_value,2)))
  ),
  CONSTRAINT inventory_cost_event_source_hpp_fk FOREIGN KEY
    (source_hpp_import_row_id, product_id, outlet_id)
    REFERENCES public.ipos_import_rows(id, product_id, outlet_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_event_stock_period_fk FOREIGN KEY
    (stock_authority_period_id, outlet_id)
    REFERENCES public.stock_authority_periods(id, outlet_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_event_batch_outlet_fk FOREIGN KEY (batch_id, outlet_id)
    REFERENCES public.inventory_cost_event_batches(id, outlet_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_event_batch_product_unique UNIQUE(batch_id, product_id)
);
CREATE INDEX inventory_cost_events_product_time_idx
  ON public.inventory_cost_events(outlet_id, product_id, created_at DESC, id DESC);
CREATE INDEX inventory_cost_events_source_idx
  ON public.inventory_cost_events(source_entity_type, source_entity_id, event_type);

CREATE TABLE public.inventory_cost_projections (
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  valued_quantity numeric,
  inventory_value numeric(32,8),
  current_wac numeric(20,8),
  valuation_status public.inventory_cost_valuation_status NOT NULL,
  cost_version bigint NOT NULL CHECK (cost_version > 0),
  stock_balance_version bigint NOT NULL CHECK (stock_balance_version > 0),
  stock_authority_period_id uuid NOT NULL,
  last_cost_event_id uuid NOT NULL REFERENCES public.inventory_cost_events(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(outlet_id, product_id),
  CONSTRAINT inventory_cost_projection_stock_period_fk FOREIGN KEY
    (stock_authority_period_id, outlet_id)
    REFERENCES public.stock_authority_periods(id, outlet_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_projection_quantity_valid CHECK (
    valued_quantity IS NULL OR (valued_quantity >= 0 AND valued_quantity < 100000000000
      AND valued_quantity = trunc(valued_quantity,3))
  ),
  CONSTRAINT inventory_cost_projection_value_valid CHECK (
    inventory_value IS NULL OR inventory_value >= 0
  ),
  CONSTRAINT inventory_cost_projection_wac_valid CHECK (
    current_wac IS NULL OR (current_wac >= 0 AND current_wac < 1000000000000)
  ),
  CONSTRAINT inventory_cost_projection_valuation_consistent CHECK (
    (valuation_status = 'UNVALUED' AND inventory_value IS NULL AND current_wac IS NULL)
    OR (valuation_status IN ('VALUED','PROVISIONAL') AND valued_quantity IS NOT NULL
      AND ((valued_quantity = 0 AND inventory_value = 0 AND current_wac IS NULL)
        OR (valued_quantity > 0 AND inventory_value IS NOT NULL AND current_wac IS NOT NULL)))
  )
);
CREATE INDEX inventory_cost_projections_outlet_status_idx
  ON public.inventory_cost_projections(outlet_id, valuation_status, product_id);

CREATE TABLE public.inventory_costing_outlet_authority (
  outlet_id uuid PRIMARY KEY REFERENCES public.outlets(id) ON DELETE RESTRICT,
  status public.inventory_cost_authority_status NOT NULL DEFAULT 'REFERENCE_ONLY',
  bootstrap_batch_id uuid REFERENCES public.inventory_cost_event_batches(id) ON DELETE RESTRICT,
  bootstrapped_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  bootstrapped_at timestamptz,
  activated_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  activated_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_cost_authority_state_valid CHECK (
    (status = 'REFERENCE_ONLY' AND bootstrap_batch_id IS NULL AND bootstrapped_by IS NULL
      AND bootstrapped_at IS NULL AND activated_by IS NULL AND activated_at IS NULL)
    OR (status = 'BOOTSTRAP_READY' AND bootstrap_batch_id IS NOT NULL AND bootstrapped_by IS NOT NULL
      AND bootstrapped_at IS NOT NULL AND activated_by IS NULL AND activated_at IS NULL)
    OR (status = 'WAC_ACTIVE' AND bootstrap_batch_id IS NOT NULL AND bootstrapped_by IS NOT NULL
      AND bootstrapped_at IS NOT NULL AND activated_by IS NOT NULL AND activated_at IS NOT NULL)
  )
);

CREATE FUNCTION public.guard_inventory_cost_ledger_immutable()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='Applied inventory cost ledger rows are immutable';
END;
$$;
ALTER FUNCTION public.guard_inventory_cost_ledger_immutable() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_inventory_cost_ledger_immutable() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER inventory_cost_batches_immutable
  BEFORE UPDATE OR DELETE ON public.inventory_cost_event_batches
  FOR EACH ROW EXECUTE FUNCTION public.guard_inventory_cost_ledger_immutable();
CREATE TRIGGER inventory_cost_events_immutable
  BEFORE UPDATE OR DELETE ON public.inventory_cost_events
  FOR EACH ROW EXECUTE FUNCTION public.guard_inventory_cost_ledger_immutable();

CREATE FUNCTION public.guard_inventory_cost_authority_transition()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF TG_OP='DELETE' OR OLD.outlet_id IS DISTINCT FROM NEW.outlet_id
    OR OLD.bootstrap_batch_id IS DISTINCT FROM NEW.bootstrap_batch_id
    OR OLD.bootstrapped_by IS DISTINCT FROM NEW.bootstrapped_by
    OR OLD.bootstrapped_at IS DISTINCT FROM NEW.bootstrapped_at
    OR OLD.created_at IS DISTINCT FROM NEW.created_at THEN
    RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='Costing cutover provenance is immutable';
  END IF;
  IF OLD.status <> 'BOOTSTRAP_READY' OR NEW.status <> 'WAC_ACTIVE'
    OR NEW.activated_by IS NULL OR NEW.activated_by IS DISTINCT FROM auth.uid()
    OR NEW.activated_at IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='Invalid costing authority transition';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.guard_inventory_cost_authority_transition() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_inventory_cost_authority_transition() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER inventory_cost_authority_transition_guard
  BEFORE UPDATE OR DELETE ON public.inventory_costing_outlet_authority
  FOR EACH ROW EXECUTE FUNCTION public.guard_inventory_cost_authority_transition();

CREATE FUNCTION public.inventory_cost_bootstrap_outlet(p_outlet_id uuid, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_role public.user_role;
  v_hash text;
  v_request public.inventory_cost_operation_requests%rowtype;
  v_period uuid;
  v_batch uuid;
  v_stock record;
  v_hpp numeric;
  v_hpp_source uuid;
  v_review uuid;
  v_status public.inventory_cost_valuation_status;
  v_value numeric(32,8);
  v_wac numeric(20,8);
  v_event uuid;
  v_count integer := 0;
  v_valued integer := 0;
  v_unvalued integer := 0;
  v_result jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Authentication required'; END IF;
  v_role := public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Costing access denied';
  END IF;
  IF p_outlet_id IS NULL OR p_request_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Outlet and request identity are required';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.outlets o WHERE o.id=p_outlet_id AND o.is_active) THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Active outlet is unavailable';
  END IF;
  v_hash := md5(p_outlet_id::text);
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_BOOTSTRAP_REQUEST:'||p_request_id::text,73190411));
  SELECT * INTO v_request FROM public.inventory_cost_operation_requests r WHERE r.request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF v_request.actor_id<>v_actor OR v_request.operation_key<>'BOOTSTRAP_OUTLET'
      OR v_request.target_key<>p_outlet_id::text OR v_request.payload_hash<>v_hash THEN
      RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Costing request identity mismatch';
    END IF;
    IF v_request.result IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='Costing request is incomplete'; END IF;
    RETURN v_request.result;
  END IF;
  INSERT INTO public.inventory_cost_operation_requests(request_id,actor_id,operation_key,target_key,payload_hash)
    VALUES(p_request_id,v_actor,'BOOTSTRAP_OUTLET',p_outlet_id::text,v_hash);

  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_BOOTSTRAP_OUTLET:'||p_outlet_id::text,73190411));
  IF EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority a WHERE a.outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections p WHERE p.outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_event_batches b WHERE b.outlet_id=p_outlet_id) THEN
    v_result := jsonb_build_object('ok',false,'code','ALREADY_BOOTSTRAPPED','outletId',p_outlet_id);
    UPDATE public.inventory_cost_operation_requests SET result=v_result,completed_at=now() WHERE request_id=p_request_id;
    RETURN v_result;
  END IF;

  -- Follow the stock writer's product-projection-before-authority-period lock order.
  FOR v_stock IN SELECT p.product_id,p.outlet_id,p.effective_quantity,p.balance_version,p.authority_period_id
    FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id ORDER BY p.product_id FOR UPDATE
  LOOP
    NULL;
  END LOOP;
  SELECT ap.id INTO v_period FROM public.stock_authority_periods ap
    WHERE ap.outlet_id=p_outlet_id AND ap.ended_at IS NULL FOR UPDATE;
  IF v_period IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Open stock authority period is unavailable'; END IF;
  IF EXISTS(SELECT 1 FROM public.stock_balance_projection p
    WHERE p.outlet_id=p_outlet_id AND p.authority_period_id<>v_period) THEN
    RAISE EXCEPTION USING ERRCODE='40001', MESSAGE='Stock projection period is inconsistent; costing bootstrap stopped';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id) THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='No stock projection rows are available for costing bootstrap';
  END IF;

  INSERT INTO public.inventory_cost_event_batches(outlet_id,batch_type,source_entity_type,source_entity_id,
    operation_request_id,allocation_method,created_by)
  VALUES(p_outlet_id,'OPENING','STOCK_AUTHORITY_CUTOVER',p_outlet_id,p_request_id,'VERIFIED_HPP_AT_CUTOVER',v_actor)
  RETURNING id INTO v_batch;

  FOR v_stock IN SELECT p.product_id,p.outlet_id,p.effective_quantity,p.balance_version,p.authority_period_id
    FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id ORDER BY p.product_id
  LOOP
    v_hpp := NULL; v_hpp_source := NULL; v_review := NULL; v_wac := NULL; v_value := NULL;
    SELECT c.hpp,c.source_import_row_id,r.id INTO v_hpp,v_hpp_source,v_review
    FROM public.product_costs c
    JOIN public.ipos_import_rows ir ON ir.id=c.source_import_row_id
      AND ir.product_id=c.product_id AND ir.outlet_id=c.outlet_id AND ir.status='VALID'
    JOIN LATERAL (
      SELECT fr.id,fr.status FROM public.product_field_audit_reviews fr
      WHERE fr.product_id=c.product_id AND fr.outlet_id=c.outlet_id AND fr.field_key='hpp'
      ORDER BY fr.reviewed_at DESC,fr.id DESC LIMIT 1
    ) r ON r.status='SUDAH_DIVERIFIKASI'::public.product_field_audit_status
    WHERE c.product_id=v_stock.product_id AND c.outlet_id=p_outlet_id
      AND c.hpp IS NOT NULL AND c.hpp>=0 AND c.hpp<1000000000000 AND c.hpp=trunc(c.hpp,2)
      AND EXISTS(SELECT 1 FROM public.product_field_audit_reviews fr
        WHERE fr.id=r.id AND fr.source_import_row_id=c.source_import_row_id);

    IF v_stock.effective_quantity IS NULL THEN
      v_status := 'UNVALUED';
    ELSIF v_stock.effective_quantity=0 THEN
      v_status := 'VALUED'; v_value := 0; v_wac := NULL;
    ELSIF v_hpp IS NOT NULL THEN
      v_status := 'VALUED'; v_wac := v_hpp::numeric(20,8);
      v_value := round(v_stock.effective_quantity*v_hpp,8)::numeric(32,8);
    ELSE
      v_status := 'UNVALUED';
    END IF;

    INSERT INTO public.inventory_cost_events(batch_id,outlet_id,product_id,event_type,source_entity_type,
      source_entity_id,valued_quantity_after,inventory_value_delta,inventory_value_after,wac_after,
      valuation_status_after,cost_version_before,cost_version_after,stock_balance_version,
      stock_authority_period_id,source_hpp_value,source_hpp_import_row_id,source_hpp_verification_review_id,
      actor_id,operation_request_id,metadata)
    VALUES(v_batch,p_outlet_id,v_stock.product_id,'OPENING','STOCK_AUTHORITY_CUTOVER',p_outlet_id,
      v_stock.effective_quantity,v_value,v_value,v_wac,v_status,0,1,v_stock.balance_version,
      v_stock.authority_period_id,v_hpp,v_hpp_source,v_review,v_actor,p_request_id,
      jsonb_build_object('costAuthority','REFERENCE_ONLY','quantitySource','stock_balance_projection',
        'hppSource','product_costs.hpp','hppVerification','latest matching SUDAH_DIVERIFIKASI review'))
    RETURNING id INTO v_event;

    INSERT INTO public.inventory_cost_projections(outlet_id,product_id,valued_quantity,inventory_value,
      current_wac,valuation_status,cost_version,stock_balance_version,stock_authority_period_id,last_cost_event_id)
    VALUES(p_outlet_id,v_stock.product_id,v_stock.effective_quantity,v_value,v_wac,v_status,1,
      v_stock.balance_version,v_stock.authority_period_id,v_event);
    v_count := v_count+1;
    IF v_status='UNVALUED' THEN v_unvalued := v_unvalued+1; ELSE v_valued := v_valued+1; END IF;
  END LOOP;

  INSERT INTO public.inventory_costing_outlet_authority(outlet_id,status,bootstrap_batch_id,bootstrapped_by,bootstrapped_at)
  VALUES(p_outlet_id,'BOOTSTRAP_READY',v_batch,v_actor,now());
  v_result := jsonb_build_object('ok',true,'code','BOOTSTRAP_READY','outletId',p_outlet_id,
    'batchId',v_batch,'productCount',v_count,'valuedCount',v_valued,'unvaluedCount',v_unvalued,
    'authorityStatus','BOOTSTRAP_READY');
  UPDATE public.inventory_cost_operation_requests SET result=v_result,completed_at=now() WHERE request_id=p_request_id;
  RETURN v_result;
END;
$$;
ALTER FUNCTION public.inventory_cost_bootstrap_outlet(uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_bootstrap_outlet(uuid,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.inventory_cost_bootstrap_outlet(uuid,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.inventory_cost_projection_page(p_outlet_id uuid,p_search text DEFAULT NULL,
  p_page integer DEFAULT 1,p_page_size integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = pg_catalog AS $$
DECLARE
  v_role public.user_role;
  v_term text := nullif(btrim(coalesce(p_search,'')),'');
  v_page integer := greatest(coalesce(p_page,1),1);
  v_size integer := least(greatest(coalesce(p_page_size,50),1),100);
  v_total integer;
  v_rows jsonb;
BEGIN
  v_role := public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RETURN jsonb_build_object('ok',false,'code','FORBIDDEN');
  END IF;
  IF p_outlet_id IS NULL THEN RETURN jsonb_build_object('ok',false,'code','INVALID_OUTLET'); END IF;
  SELECT count(*)::integer INTO v_total FROM public.inventory_cost_projections cp
    JOIN public.products p ON p.id=cp.product_id
    WHERE cp.outlet_id=p_outlet_id AND (v_term IS NULL OR p.name ILIKE '%'||v_term||'%' OR p.sku ILIKE '%'||v_term||'%');
  SELECT coalesce(jsonb_agg(jsonb_build_object('productId',x.product_id,'name',x.name,'sku',x.sku,
      'valuedQuantity',x.valued_quantity,'inventoryValue',x.inventory_value,'currentWac',x.current_wac,
      'valuationStatus',x.valuation_status,'costVersion',x.cost_version,
      'stockBalanceVersion',x.stock_balance_version,'stockAuthorityPeriodId',x.stock_authority_period_id,
      'lastCostEventId',x.last_cost_event_id,'bootstrapHpp',x.source_hpp_value,
      'bootstrapHppImportRowId',x.source_hpp_import_row_id,'bootstrapHppReviewId',x.source_hpp_verification_review_id)
      ORDER BY x.name,x.sku,x.product_id),'[]'::jsonb) INTO v_rows
  FROM (
    SELECT cp.*,p.name,p.sku,opening.source_hpp_value,opening.source_hpp_import_row_id,
      opening.source_hpp_verification_review_id
    FROM public.inventory_cost_projections cp
    JOIN public.products p ON p.id=cp.product_id
    LEFT JOIN LATERAL (SELECT e.source_hpp_value,e.source_hpp_import_row_id,e.source_hpp_verification_review_id
      FROM public.inventory_cost_events e WHERE e.outlet_id=cp.outlet_id AND e.product_id=cp.product_id
        AND e.event_type='OPENING' ORDER BY e.created_at,e.id LIMIT 1) opening ON true
    WHERE cp.outlet_id=p_outlet_id AND (v_term IS NULL OR p.name ILIKE '%'||v_term||'%' OR p.sku ILIKE '%'||v_term||'%')
    ORDER BY p.name,p.sku,cp.product_id OFFSET ((v_page::bigint)-1)*v_size LIMIT v_size
  ) x;
  RETURN jsonb_build_object('ok',true,'page',v_page,'pageSize',v_size,'total',v_total,'rows',v_rows,
    'authorityStatus',coalesce((SELECT a.status::text FROM public.inventory_costing_outlet_authority a
      WHERE a.outlet_id=p_outlet_id),'REFERENCE_ONLY'));
END;
$$;
ALTER FUNCTION public.inventory_cost_projection_page(uuid,text,integer,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_projection_page(uuid,text,integer,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.inventory_cost_projection_page(uuid,text,integer,integer) TO authenticated;

ALTER TABLE public.inventory_cost_operation_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_cost_event_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_cost_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_cost_projections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_costing_outlet_authority ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.inventory_cost_operation_requests,public.inventory_cost_event_batches,
  public.inventory_cost_events,public.inventory_cost_projections,public.inventory_costing_outlet_authority
  FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.inventory_cost_event_batches,public.inventory_cost_events,
  public.inventory_cost_projections,public.inventory_costing_outlet_authority TO authenticated;
CREATE POLICY inventory_cost_batches_read_managers ON public.inventory_cost_event_batches
  FOR SELECT TO authenticated USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY inventory_cost_events_read_managers ON public.inventory_cost_events
  FOR SELECT TO authenticated USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY inventory_cost_projection_read_managers ON public.inventory_cost_projections
  FOR SELECT TO authenticated USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY inventory_cost_authority_read_managers ON public.inventory_costing_outlet_authority
  FOR SELECT TO authenticated USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));

GRANT USAGE ON TYPE public.inventory_cost_valuation_status,public.inventory_cost_authority_status,
  public.inventory_cost_event_type TO authenticated;
REVOKE ALL ON TYPE public.inventory_cost_valuation_status,public.inventory_cost_authority_status,
  public.inventory_cost_event_type FROM PUBLIC,anon;

COMMIT;
