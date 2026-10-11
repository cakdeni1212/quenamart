-- One-time, outlet-scoped opening-stock cutover from an explicitly selected
-- completed iPos normalization commit. Historical stock movements are kept
-- under their closed authority period; no costing/bootstrap state is written.
BEGIN;

ALTER TABLE public.ipos_normalization_commits
  ADD CONSTRAINT ipos_normalization_commits_full_identity UNIQUE(id,batch_id,outlet_id);

CREATE TABLE public.stock_opening_cutover_requests (
  request_id uuid PRIMARY KEY,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  normalization_commit_id uuid NOT NULL,
  import_batch_id uuid NOT NULL,
  expected_previous_period_id uuid NOT NULL,
  new_authority_period_id uuid,
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{32}$'),
  result jsonb CHECK (result IS NULL OR jsonb_typeof(result)='object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  CONSTRAINT stock_opening_cutover_request_one_per_outlet UNIQUE(outlet_id),
  CONSTRAINT stock_opening_cutover_request_identity UNIQUE(request_id,outlet_id),
  CONSTRAINT stock_opening_cutover_request_scope_identity
    UNIQUE(request_id,outlet_id,normalization_commit_id,import_batch_id,expected_previous_period_id,actor_id),
  CONSTRAINT stock_opening_cutover_request_new_identity
    UNIQUE(request_id,outlet_id,new_authority_period_id),
  CONSTRAINT stock_opening_cutover_request_snapshot_fk
    FOREIGN KEY(normalization_commit_id,import_batch_id,outlet_id)
    REFERENCES public.ipos_normalization_commits(id,batch_id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT stock_opening_cutover_request_previous_period_fk
    FOREIGN KEY(expected_previous_period_id,outlet_id)
    REFERENCES public.stock_authority_periods(id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT stock_opening_cutover_request_new_period_fk
    FOREIGN KEY(new_authority_period_id,outlet_id)
    REFERENCES public.stock_authority_periods(id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT stock_opening_cutover_request_terminal CHECK (
    (result IS NULL AND completed_at IS NULL AND new_authority_period_id IS NULL)
    OR (result IS NOT NULL AND completed_at IS NOT NULL AND new_authority_period_id IS NOT NULL)
  )
);
CREATE INDEX stock_opening_cutover_requests_outlet_time_idx
  ON public.stock_opening_cutover_requests(outlet_id,created_at DESC);

ALTER TABLE public.stock_balance_projection_events
  ADD COLUMN opening_cutover_request_id uuid,
  ADD CONSTRAINT stock_balance_projection_event_cutover_fk
    FOREIGN KEY(opening_cutover_request_id)
    REFERENCES public.stock_opening_cutover_requests(request_id) ON DELETE RESTRICT,
  ADD CONSTRAINT stock_balance_projection_event_request_shape CHECK (
    (event_type='AUTHORITY_BASELINE_ACCEPTED' AND request_id IS NULL AND opening_cutover_request_id IS NOT NULL)
    OR (event_type<>'AUTHORITY_BASELINE_ACCEPTED' AND opening_cutover_request_id IS NULL)
  ),
  ADD CONSTRAINT stock_balance_projection_event_cutover_identity
    UNIQUE(id,outlet_id,product_id,authority_period_id,opening_cutover_request_id);

CREATE TABLE public.stock_opening_cutover_items (
  request_id uuid NOT NULL,
  outlet_id uuid NOT NULL,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  normalization_commit_id uuid NOT NULL,
  import_batch_id uuid NOT NULL,
  source_import_row_id uuid NOT NULL,
  previous_authority_period_id uuid NOT NULL,
  new_authority_period_id uuid NOT NULL,
  projection_event_id uuid NOT NULL UNIQUE,
  previous_baseline_quantity numeric,
  previous_movement_delta numeric NOT NULL,
  previous_effective_quantity numeric NOT NULL,
  previous_balance_version bigint NOT NULL,
  opening_quantity numeric NOT NULL,
  new_balance_version bigint NOT NULL,
  accepted_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  accepted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(request_id,product_id),
  CONSTRAINT stock_opening_cutover_item_request_fk
    FOREIGN KEY(request_id,outlet_id)
    REFERENCES public.stock_opening_cutover_requests(request_id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT stock_opening_cutover_item_request_scope_fk
    FOREIGN KEY(request_id,outlet_id,normalization_commit_id,import_batch_id,previous_authority_period_id,accepted_by)
    REFERENCES public.stock_opening_cutover_requests(request_id,outlet_id,normalization_commit_id,import_batch_id,expected_previous_period_id,actor_id)
    ON DELETE RESTRICT,
  CONSTRAINT stock_opening_cutover_item_new_period_fk
    FOREIGN KEY(request_id,outlet_id,new_authority_period_id)
    REFERENCES public.stock_opening_cutover_requests(request_id,outlet_id,new_authority_period_id)
    ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT stock_opening_cutover_item_event_fk
    FOREIGN KEY(projection_event_id,outlet_id,product_id,new_authority_period_id,request_id)
    REFERENCES public.stock_balance_projection_events(id,outlet_id,product_id,authority_period_id,opening_cutover_request_id)
    ON DELETE RESTRICT,
  CONSTRAINT stock_opening_cutover_item_source_fk
    FOREIGN KEY(source_import_row_id,import_batch_id,outlet_id,product_id)
    REFERENCES public.ipos_import_rows(id,batch_id,outlet_id,product_id) ON DELETE RESTRICT,
  CONSTRAINT stock_opening_cutover_item_previous_period_fk
    FOREIGN KEY(previous_authority_period_id,outlet_id)
    REFERENCES public.stock_authority_periods(id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT stock_opening_cutover_item_quantity_valid CHECK (
    (previous_baseline_quantity IS NULL OR previous_baseline_quantity>=0)
    AND previous_movement_delta > -100000000000 AND previous_movement_delta < 100000000000
    AND previous_movement_delta=trunc(previous_movement_delta,3)
    AND previous_effective_quantity>=0 AND previous_effective_quantity<100000000000
    AND previous_effective_quantity=trunc(previous_effective_quantity,3)
    AND opening_quantity>=0 AND opening_quantity<100000000000
    AND opening_quantity=trunc(opening_quantity,3)
    AND previous_balance_version>0 AND new_balance_version=previous_balance_version+1
  )
);
CREATE INDEX stock_opening_cutover_items_source_idx
  ON public.stock_opening_cutover_items(normalization_commit_id,import_batch_id,source_import_row_id);

ALTER TABLE public.stock_opening_cutover_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_opening_cutover_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.stock_opening_cutover_requests,public.stock_opening_cutover_items
  FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.stock_opening_cutover_requests,public.stock_opening_cutover_items TO authenticated;
CREATE POLICY stock_opening_cutover_requests_manager_read
  ON public.stock_opening_cutover_requests FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY stock_opening_cutover_items_manager_read
  ON public.stock_opening_cutover_items FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));

CREATE FUNCTION public.guard_stock_opening_cutover_request()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Stock opening cutover evidence is immutable';
  END IF;
  IF OLD.result IS NOT NULL
    OR NEW.request_id IS DISTINCT FROM OLD.request_id
    OR NEW.outlet_id IS DISTINCT FROM OLD.outlet_id
    OR NEW.actor_id IS DISTINCT FROM OLD.actor_id
    OR NEW.normalization_commit_id IS DISTINCT FROM OLD.normalization_commit_id
    OR NEW.import_batch_id IS DISTINCT FROM OLD.import_batch_id
    OR NEW.expected_previous_period_id IS DISTINCT FROM OLD.expected_previous_period_id
    OR NEW.payload_hash IS DISTINCT FROM OLD.payload_hash
    OR NEW.created_at IS DISTINCT FROM OLD.created_at
    OR NEW.result IS NULL OR NEW.completed_at IS NULL OR NEW.new_authority_period_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Invalid stock opening cutover finalization';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.guard_stock_opening_cutover_request() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_stock_opening_cutover_request() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER stock_opening_cutover_request_immutable
  BEFORE UPDATE OR DELETE ON public.stock_opening_cutover_requests
  FOR EACH ROW EXECUTE FUNCTION public.guard_stock_opening_cutover_request();

CREATE FUNCTION public.reject_stock_opening_cutover_item_mutation()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Stock opening cutover item evidence is immutable';
END;
$$;
ALTER FUNCTION public.reject_stock_opening_cutover_item_mutation() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reject_stock_opening_cutover_item_mutation() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER stock_opening_cutover_items_immutable
  BEFORE UPDATE OR DELETE ON public.stock_opening_cutover_items
  FOR EACH ROW EXECUTE FUNCTION public.reject_stock_opening_cutover_item_mutation();

CREATE FUNCTION public.stock_opening_cutover(
  p_outlet_id uuid,
  p_normalization_commit_id uuid,
  p_expected_previous_period_id uuid,
  p_request_id uuid,
  p_confirmation text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE
  v_actor uuid:=auth.uid();
  v_role public.user_role;
  v_payload_hash text;
  v_existing public.stock_opening_cutover_requests%rowtype;
  v_batch_id uuid;
  v_latest_commit uuid;
  v_previous_period public.stock_authority_periods%rowtype;
  v_new_period uuid;
  v_authority public.inventory_cost_authority_status;
  v_now timestamptz:=clock_timestamp();
  v_product record;
  v_before numeric;
  v_after numeric;
  v_new_version bigint;
  v_event_id uuid;
  v_count integer:=0;
  v_result jsonb;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='STOCK_CUTOVER_UNAUTHORIZED';
  END IF;
  IF p_outlet_id IS NULL OR p_normalization_commit_id IS NULL
    OR p_expected_previous_period_id IS NULL OR p_request_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='STOCK_CUTOVER_INVALID_REQUEST';
  END IF;
  IF p_confirmation IS DISTINCT FROM
      ('OPENING-STOCK-CUTOVER:'||p_outlet_id::text||':'||p_normalization_commit_id::text) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='STOCK_CUTOVER_CONFIRMATION_REQUIRED';
  END IF;
  v_payload_hash:=md5(p_outlet_id::text||':'||p_normalization_commit_id::text||':'||p_expected_previous_period_id::text);

  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('STOCK_OPENING_CUTOVER_REQUEST:'||p_request_id::text,73190411));
  SELECT * INTO v_existing FROM public.stock_opening_cutover_requests r
    WHERE r.request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.outlet_id IS DISTINCT FROM p_outlet_id
      OR v_existing.normalization_commit_id IS DISTINCT FROM p_normalization_commit_id
      OR v_existing.expected_previous_period_id IS DISTINCT FROM p_expected_previous_period_id
      OR v_existing.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STOCK_CUTOVER_REQUEST_CONFLICT';
    END IF;
    IF v_existing.result IS NULL THEN
      RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='STOCK_CUTOVER_REQUEST_INCOMPLETE';
    END IF;
    RETURN v_existing.result;
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_BOOTSTRAP_OUTLET:'||p_outlet_id::text,73190411));
  IF NOT EXISTS(SELECT 1 FROM public.outlets o WHERE o.id=p_outlet_id AND o.is_active) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='STOCK_CUTOVER_UNAUTHORIZED';
  END IF;

  -- Draft/import/HPP creation RPCs do not all participate in the stock/cost
  -- advisory lock. Serialize their table writes for this one-time operation,
  -- then evaluate blockers/snapshot under those locks. This prevents a draft
  -- or newer normalization commit appearing between the checks and rebase.
  LOCK TABLE public.inventory_cost_event_batches,
    public.inventory_cost_events,
    public.inventory_cost_hpp_acceptance_batches,
    public.inventory_cost_projections,
    public.inventory_cost_source_layers,
    public.inventory_costing_outlet_authority,
    public.ipos_import_batches,
    public.ipos_import_rows,
    public.ipos_normalization_commit_rows,
    public.ipos_normalization_commits,
    public.manual_stock_corrections,
    public.pos_carts,
    public.pos_checkout_requests,
    public.product_field_overrides,
    public.purchase_invoices,
    public.purchase_receipts,
    public.sales,
    public.stock_movements,
    public.stock_operation_requests,
    public.stock_opname_sessions,
    public.supplier_returns
    IN SHARE ROW EXCLUSIVE MODE;

  SELECT c.batch_id INTO v_batch_id FROM public.ipos_normalization_commits c
    JOIN public.ipos_import_batches b ON b.id=c.batch_id AND b.outlet_id=c.outlet_id AND b.status='COMPLETED'
    WHERE c.id=p_normalization_commit_id AND c.outlet_id=p_outlet_id
      AND c.status='COMPLETED' AND c.completed_at IS NOT NULL;
  IF v_batch_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STOCK_CUTOVER_SNAPSHOT_UNAVAILABLE';
  END IF;
  SELECT c.id INTO v_latest_commit FROM public.ipos_normalization_commits c
    WHERE c.outlet_id=p_outlet_id AND c.status='COMPLETED'
    ORDER BY c.completed_at DESC,c.id DESC LIMIT 1;
  IF v_latest_commit IS DISTINCT FROM p_normalization_commit_id THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STOCK_CUTOVER_SNAPSHOT_NOT_LATEST';
  END IF;

  -- A full opening snapshot must cover every projected product and provide an
  -- explicit, valid 3dp quantity. Missing/invalid products require audit action.
  IF NOT EXISTS(SELECT 1 FROM public.ipos_normalization_commit_rows cr
      JOIN public.ipos_import_rows ir ON ir.id=cr.source_row_id AND ir.batch_id=cr.batch_id
        AND ir.outlet_id=cr.outlet_id AND ir.product_id=cr.product_id AND ir.status='VALID'
      WHERE cr.commit_id=p_normalization_commit_id AND cr.batch_id=v_batch_id
        AND cr.outlet_id=p_outlet_id AND cr.action IN ('CREATE','UPDATE')
        AND cr.product_id IS NOT NULL)
    OR EXISTS(SELECT 1 FROM public.ipos_normalization_commit_rows cr
      JOIN public.ipos_import_rows ir ON ir.id=cr.source_row_id AND ir.batch_id=cr.batch_id
        AND ir.outlet_id=cr.outlet_id AND ir.product_id=cr.product_id AND ir.status='VALID'
      WHERE cr.commit_id=p_normalization_commit_id AND cr.batch_id=v_batch_id
        AND cr.outlet_id=p_outlet_id AND cr.action IN ('CREATE','UPDATE')
        AND cr.product_id IS NOT NULL
        AND (jsonb_typeof(cr.normalized_data->'quantity') IS DISTINCT FROM 'number'
          OR CASE WHEN jsonb_typeof(cr.normalized_data->'quantity')='number' THEN
            (cr.normalized_data->>'quantity')::numeric<0
              OR (cr.normalized_data->>'quantity')::numeric>=100000000000
              OR (cr.normalized_data->>'quantity')::numeric<>trunc((cr.normalized_data->>'quantity')::numeric,3)
            ELSE true END
          OR EXISTS(SELECT 1 FROM pg_catalog.jsonb_array_elements(cr.validation_errors) e(value)
            WHERE e.value->>'code'='INVALID_NUMERIC_VALUE' AND e.value->>'field'='STOK')))
    OR EXISTS(SELECT 1 FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id
      AND NOT EXISTS(SELECT 1 FROM public.ipos_normalization_commit_rows cr
        JOIN public.ipos_import_rows ir ON ir.id=cr.source_row_id AND ir.batch_id=cr.batch_id
          AND ir.outlet_id=cr.outlet_id AND ir.product_id=cr.product_id AND ir.status='VALID'
        WHERE cr.commit_id=p_normalization_commit_id AND cr.batch_id=v_batch_id
          AND cr.outlet_id=p_outlet_id AND cr.product_id=p.product_id
          AND cr.action IN ('CREATE','UPDATE') AND jsonb_typeof(cr.normalized_data->'quantity')='number'))
    OR EXISTS(SELECT 1 FROM public.ipos_normalization_commit_rows cr
      WHERE cr.commit_id=p_normalization_commit_id AND cr.outlet_id=p_outlet_id
        AND cr.action IN ('CREATE','UPDATE') AND cr.product_id IS NOT NULL
        AND NOT EXISTS(SELECT 1 FROM public.stock_balance_projection p
          WHERE p.product_id=cr.product_id AND p.outlet_id=p_outlet_id)) THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STOCK_CUTOVER_SNAPSHOT_INCOMPLETE';
  END IF;
  IF EXISTS(SELECT 1 FROM public.product_field_overrides o
    WHERE o.outlet_id=p_outlet_id AND o.field_key='quantity' AND o.is_active) THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STOCK_CUTOVER_QUANTITY_OVERRIDE_ACTIVE';
  END IF;

  IF EXISTS(SELECT 1 FROM public.pos_carts c WHERE c.outlet_id=p_outlet_id AND c.status IN ('ACTIVE','PARKED'))
    OR EXISTS(SELECT 1 FROM public.stock_opname_sessions s WHERE s.outlet_id=p_outlet_id AND s.status IN ('COUNTING','REVIEW'))
    OR EXISTS(SELECT 1 FROM public.purchase_receipts r WHERE r.outlet_id=p_outlet_id AND r.status='DRAFT')
    OR EXISTS(SELECT 1 FROM public.purchase_invoices i WHERE i.outlet_id=p_outlet_id AND i.status='DRAFT')
    OR EXISTS(SELECT 1 FROM public.manual_stock_corrections m WHERE m.outlet_id=p_outlet_id AND m.status='DRAFT')
    OR EXISTS(SELECT 1 FROM public.supplier_returns r WHERE r.outlet_id=p_outlet_id AND r.status='DRAFT')
    OR EXISTS(SELECT 1 FROM public.pos_checkout_requests r WHERE r.outlet_id=p_outlet_id AND r.completed_at IS NULL)
    OR EXISTS(SELECT 1 FROM public.stock_operation_requests r WHERE r.state='PENDING'
      AND ((r.request_payload->>'outlet_id')=p_outlet_id::text
        OR EXISTS(SELECT 1 FROM public.stock_opname_sessions s
          WHERE s.id::text=r.request_payload->>'session_id' AND s.outlet_id=p_outlet_id)
        OR EXISTS(SELECT 1 FROM public.stock_movements m
          WHERE m.id::text=r.request_payload->>'movement_id' AND m.outlet_id=p_outlet_id)
        OR EXISTS(SELECT 1 FROM public.purchase_receipts pr
          WHERE pr.id::text=r.request_payload->>'receipt_id' AND pr.outlet_id=p_outlet_id)
        OR EXISTS(SELECT 1 FROM public.manual_stock_corrections mc
          WHERE mc.id::text=r.request_payload->>'correction_id' AND mc.outlet_id=p_outlet_id)
        OR EXISTS(SELECT 1 FROM public.supplier_returns sr
          WHERE sr.id::text=r.request_payload->>'return_id' AND sr.outlet_id=p_outlet_id)))
    OR EXISTS(SELECT 1 FROM public.inventory_cost_hpp_acceptance_batches h
      WHERE h.outlet_id=p_outlet_id AND h.status IN ('PREPARED','APPROVED','CONSUMED')) THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STOCK_CUTOVER_OPERATIONAL_DRAFTS_OPEN';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales s WHERE s.outlet_id=p_outlet_id) THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STOCK_CUTOVER_NATIVE_SALES_EXIST';
  END IF;

  SELECT a.status INTO v_authority FROM public.inventory_costing_outlet_authority a
    WHERE a.outlet_id=p_outlet_id FOR UPDATE;
  IF v_authority IN ('WAC_ACTIVE','BOOTSTRAP_READY') THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STOCK_CUTOVER_COSTING_ALREADY_STARTED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_cost_projections p WHERE p.outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_event_batches b WHERE b.outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_events e WHERE e.outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_source_layers l WHERE l.outlet_id=p_outlet_id) THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STOCK_CUTOVER_COSTING_EVIDENCE_EXISTS';
  END IF;
  IF EXISTS(SELECT 1 FROM public.stock_opening_cutover_requests r WHERE r.outlet_id=p_outlet_id) THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STOCK_CUTOVER_ALREADY_COMPLETED';
  END IF;

  INSERT INTO public.stock_opening_cutover_requests(request_id,outlet_id,actor_id,normalization_commit_id,
    import_batch_id,expected_previous_period_id,payload_hash)
  VALUES(p_request_id,p_outlet_id,v_actor,p_normalization_commit_id,v_batch_id,
    p_expected_previous_period_id,v_payload_hash);

  -- Match bootstrap's projection-before-period lock order. Cost-aware stock
  -- writers serialize on COST_BOOTSTRAP_OUTLET before they reach these rows.
  FOR v_product IN SELECT p.product_id FROM public.stock_balance_projection p
    WHERE p.outlet_id=p_outlet_id ORDER BY p.product_id FOR UPDATE
  LOOP
    NULL;
  END LOOP;
  SELECT * INTO v_previous_period FROM public.stock_authority_periods ap
    WHERE ap.outlet_id=p_outlet_id AND ap.ended_at IS NULL FOR UPDATE;
  IF NOT FOUND OR v_previous_period.id IS DISTINCT FROM p_expected_previous_period_id THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STOCK_CUTOVER_PREVIOUS_PERIOD_STALE';
  END IF;

  UPDATE public.stock_authority_periods SET ended_at=v_now WHERE id=v_previous_period.id;
  INSERT INTO public.stock_authority_periods(outlet_id,mode,started_at,created_by,created_reason)
  VALUES(p_outlet_id,'QUENA_MOVEMENT_LEDGER'::public.stock_authority_mode,v_now,v_actor,
    'Accepted iPos opening cutover request '||p_request_id::text)
  RETURNING id INTO v_new_period;

  FOR v_product IN
    SELECT cr.product_id,cr.source_row_id,cr.batch_id,
      (cr.normalized_data->>'quantity')::numeric AS opening_quantity,
      p.baseline_quantity,p.unreconciled_movement_delta,p.effective_quantity,p.balance_version,
      p.authority_period_id
    FROM public.ipos_normalization_commit_rows cr
    JOIN public.ipos_import_rows ir ON ir.id=cr.source_row_id AND ir.batch_id=cr.batch_id
      AND ir.outlet_id=cr.outlet_id AND ir.product_id=cr.product_id AND ir.status='VALID'
    JOIN public.stock_balance_projection p ON p.product_id=cr.product_id AND p.outlet_id=cr.outlet_id
    WHERE cr.commit_id=p_normalization_commit_id AND cr.batch_id=v_batch_id
      AND cr.outlet_id=p_outlet_id AND cr.action IN ('CREATE','UPDATE')
    ORDER BY cr.product_id
  LOOP
    IF v_product.authority_period_id IS DISTINCT FROM v_previous_period.id THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STOCK_CUTOVER_PROJECTION_PERIOD_MISMATCH';
    END IF;
    v_before:=v_product.effective_quantity;
    v_after:=v_product.opening_quantity;
    UPDATE public.stock_balance_projection p SET
      authority_period_id=v_new_period,
      baseline_quantity=v_after,
      baseline_source_import_row_id=v_product.source_row_id,
      baseline_batch_id=v_product.batch_id,
      baseline_commit_id=p_normalization_commit_id,
      unreconciled_movement_delta=0,
      balance_version=p.balance_version+1,
      last_observation_source_import_row_id=v_product.source_row_id,
      last_observation_status='BOOTSTRAPPED',
      updated_at=v_now
    WHERE p.product_id=v_product.product_id AND p.outlet_id=p_outlet_id
    RETURNING p.balance_version INTO v_new_version;
    INSERT INTO public.stock_balance_projection_events(product_id,outlet_id,authority_period_id,
      event_type,quantity_delta,balance_before,balance_after,balance_version,actor_id,opening_cutover_request_id)
    VALUES(v_product.product_id,p_outlet_id,v_new_period,'AUTHORITY_BASELINE_ACCEPTED',
      v_after-v_before,v_before,v_after,v_new_version,v_actor,p_request_id)
    RETURNING id INTO v_event_id;
    INSERT INTO public.stock_opening_cutover_items(request_id,outlet_id,product_id,
      normalization_commit_id,import_batch_id,source_import_row_id,previous_authority_period_id,new_authority_period_id,
      projection_event_id,previous_baseline_quantity,previous_movement_delta,previous_effective_quantity,
      previous_balance_version,opening_quantity,new_balance_version,accepted_by,accepted_at)
    VALUES(p_request_id,p_outlet_id,v_product.product_id,p_normalization_commit_id,v_product.batch_id,
      v_product.source_row_id,v_previous_period.id,v_new_period,v_event_id,v_product.baseline_quantity,
      v_product.unreconciled_movement_delta,v_before,v_product.balance_version,v_after,
      v_new_version,v_actor,v_now);
    v_count:=v_count+1;
  END LOOP;
  IF v_count=0 THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STOCK_CUTOVER_SNAPSHOT_EMPTY';
  END IF;

  v_result:=jsonb_build_object('ok',true,'code','OPENING_STOCK_ACCEPTED',
    'outletId',p_outlet_id,'normalizationCommitId',p_normalization_commit_id,
    'previousAuthorityPeriodId',v_previous_period.id,'newAuthorityPeriodId',v_new_period,
    'productCount',v_count,'acceptedAt',v_now);
  UPDATE public.stock_opening_cutover_requests SET new_authority_period_id=v_new_period,
    result=v_result,completed_at=v_now WHERE request_id=p_request_id;
  RETURN v_result;
END;
$$;
ALTER FUNCTION public.stock_opening_cutover(uuid,uuid,uuid,uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.stock_opening_cutover(uuid,uuid,uuid,uuid,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.stock_opening_cutover(uuid,uuid,uuid,uuid,text) TO authenticated;

COMMIT;
