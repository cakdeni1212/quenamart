-- Go-live controls: approved HPP bootstrap, audited WAC activation, and
-- OWNER-only rehearsal preparation. Capability only; no production operation.
BEGIN;

ALTER TYPE public.inventory_cost_hpp_acceptance_operation ADD VALUE IF NOT EXISTS 'INVALIDATE';
ALTER TYPE public.inventory_cost_hpp_acceptance_operation ADD VALUE IF NOT EXISTS 'BOOTSTRAP_CONSUME';

ALTER TABLE public.inventory_cost_hpp_acceptance_items
  ADD CONSTRAINT inventory_cost_hpp_acceptance_item_full_identity UNIQUE(batch_id,product_id,outlet_id);
ALTER TABLE public.inventory_cost_event_batches
  ADD COLUMN hpp_acceptance_batch_id uuid,
  ADD CONSTRAINT inventory_cost_event_batch_hpp_identity_fk
    FOREIGN KEY(hpp_acceptance_batch_id,outlet_id)
    REFERENCES public.inventory_cost_hpp_acceptance_batches(id,outlet_id) ON DELETE RESTRICT;
ALTER TABLE public.inventory_cost_events
  ADD COLUMN opening_hpp_acceptance_batch_id uuid,
  ADD COLUMN opening_hpp_disposition public.inventory_cost_hpp_acceptance_disposition,
  ADD CONSTRAINT inventory_cost_event_opening_hpp_item_fk
    FOREIGN KEY(opening_hpp_acceptance_batch_id,product_id,outlet_id)
    REFERENCES public.inventory_cost_hpp_acceptance_items(batch_id,product_id,outlet_id) ON DELETE RESTRICT,
  ADD CONSTRAINT inventory_cost_event_opening_hpp_shape CHECK (
    (event_type='OPENING' AND source_entity_type='STOCK_AUTHORITY_CUTOVER'
      AND ((physical_quantity_after=0 AND opening_hpp_acceptance_batch_id IS NULL AND opening_hpp_disposition IS NULL)
        OR (physical_quantity_after>0 AND opening_hpp_acceptance_batch_id IS NOT NULL AND opening_hpp_disposition IS NOT NULL)))
    OR (event_type<>'OPENING' AND opening_hpp_acceptance_batch_id IS NULL AND opening_hpp_disposition IS NULL)
  );

CREATE TABLE public.inventory_cost_hpp_bootstrap_consumptions (
  acceptance_batch_id uuid PRIMARY KEY,
  outlet_id uuid NOT NULL,
  cost_event_batch_id uuid NOT NULL UNIQUE,
  bootstrap_request_id uuid NOT NULL UNIQUE REFERENCES public.inventory_cost_operation_requests(request_id) ON DELETE RESTRICT,
  hpp_request_id uuid NOT NULL UNIQUE REFERENCES public.inventory_cost_hpp_acceptance_requests(request_id) ON DELETE RESTRICT,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  consumed_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_cost_hpp_consumption_batch_fk FOREIGN KEY(acceptance_batch_id,outlet_id)
    REFERENCES public.inventory_cost_hpp_acceptance_batches(id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_hpp_consumption_cost_batch_fk FOREIGN KEY(cost_event_batch_id,outlet_id)
    REFERENCES public.inventory_cost_event_batches(id,outlet_id) ON DELETE RESTRICT
);
ALTER TABLE public.inventory_cost_hpp_bootstrap_consumptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_cost_hpp_bootstrap_consumptions FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.inventory_cost_hpp_bootstrap_consumptions TO authenticated;
CREATE POLICY inventory_cost_hpp_bootstrap_consumptions_manager_read
  ON public.inventory_cost_hpp_bootstrap_consumptions FOR SELECT TO authenticated
  USING(public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));

CREATE TABLE public.go_live_bootstrap_evidence (
  request_id uuid PRIMARY KEY REFERENCES public.inventory_cost_operation_requests(request_id) ON DELETE RESTRICT,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  acceptance_batch_id uuid NOT NULL,
  cutover_request_id uuid NOT NULL REFERENCES public.stock_opening_cutover_requests(request_id) ON DELETE RESTRICT,
  confirmation text NOT NULL,
  payload_hash text NOT NULL CHECK(payload_hash ~ '^[0-9a-f]{32}$'),
  result jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  CONSTRAINT go_live_bootstrap_evidence_acceptance_fk FOREIGN KEY(acceptance_batch_id,outlet_id)
    REFERENCES public.inventory_cost_hpp_acceptance_batches(id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT go_live_bootstrap_evidence_one_per_outlet UNIQUE(outlet_id),
  CONSTRAINT go_live_bootstrap_evidence_request_outlet UNIQUE(request_id,outlet_id),
  CONSTRAINT go_live_bootstrap_evidence_terminal CHECK((result IS NULL)=(completed_at IS NULL))
);
ALTER TABLE public.go_live_bootstrap_evidence ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.go_live_bootstrap_evidence FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.go_live_bootstrap_evidence TO authenticated;
CREATE POLICY go_live_bootstrap_evidence_manager_read ON public.go_live_bootstrap_evidence
  FOR SELECT TO authenticated USING(public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));

CREATE TABLE public.go_live_reset_preparation_requests (
  request_id uuid PRIMARY KEY,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  reason text NOT NULL CHECK(length(btrim(reason)) BETWEEN 3 AND 500),
  confirmation text NOT NULL,
  payload_hash text NOT NULL CHECK(payload_hash ~ '^[0-9a-f]{32}$'),
  result jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  CONSTRAINT go_live_reset_preparation_terminal CHECK((result IS NULL)=(completed_at IS NULL))
);
ALTER TABLE public.go_live_reset_preparation_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.go_live_reset_preparation_requests FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.go_live_reset_preparation_requests TO authenticated;
CREATE POLICY go_live_reset_preparation_manager_read ON public.go_live_reset_preparation_requests
  FOR SELECT TO authenticated USING(public.current_active_user_role()='OWNER'::public.user_role);

CREATE FUNCTION public.go_live_request_evidence_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Go-live request evidence is immutable'; END IF;
  IF (to_jsonb(OLD)-'result'-'completed_at') IS DISTINCT FROM (to_jsonb(NEW)-'result'-'completed_at') THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Go-live request identity is immutable';
  END IF;
  IF OLD.result IS NOT NULL OR NEW.result IS NULL OR NEW.completed_at IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Go-live request result is terminal';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.go_live_request_evidence_guard() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.go_live_request_evidence_guard() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER go_live_bootstrap_evidence_guard BEFORE UPDATE OR DELETE ON public.go_live_bootstrap_evidence
  FOR EACH ROW EXECUTE FUNCTION public.go_live_request_evidence_guard();
CREATE TRIGGER go_live_reset_preparation_evidence_guard BEFORE UPDATE OR DELETE ON public.go_live_reset_preparation_requests
  FOR EACH ROW EXECUTE FUNCTION public.go_live_request_evidence_guard();
CREATE FUNCTION public.inventory_cost_hpp_consumption_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='HPP bootstrap consumption evidence is immutable'; END;
$$;
ALTER FUNCTION public.inventory_cost_hpp_consumption_guard() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_hpp_consumption_guard() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER inventory_cost_hpp_consumptions_immutable BEFORE UPDATE OR DELETE
  ON public.inventory_cost_hpp_bootstrap_consumptions FOR EACH ROW EXECUTE FUNCTION public.inventory_cost_hpp_consumption_guard();

CREATE FUNCTION public.inventory_cost_hpp_invalidate_prepared(p_batch_id uuid,p_request_id uuid,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=auth.uid(); b public.inventory_cost_hpp_acceptance_batches%rowtype; r public.inventory_cost_hpp_acceptance_requests%rowtype;
  why text:=nullif(btrim(p_reason),''); payload jsonb; out jsonb;
BEGIN
  IF a IS NULL OR public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='GO_LIVE_OWNER_REQUIRED';
  END IF;
  IF p_batch_id IS NULL OR p_request_id IS NULL OR why IS NULL OR length(why)>500 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='GO_LIVE_INVALIDATION_INPUT_REQUIRED';
  END IF;
  payload:=jsonb_build_object('operation','INVALIDATE','batchId',p_batch_id,'reason',why);
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_HPP_ACCEPTANCE_REQUEST:'||p_request_id::text,73190411));
  SELECT * INTO r FROM public.inventory_cost_hpp_acceptance_requests WHERE request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF r.actor_id<>a OR r.operation<>'INVALIDATE' OR r.payload<>payload THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='GO_LIVE_REQUEST_CONFLICT'; END IF;
    IF r.result IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_REQUEST_INCOMPLETE'; END IF;
    RETURN r.result;
  END IF;
  SELECT * INTO b FROM public.inventory_cost_hpp_acceptance_batches WHERE id=p_batch_id FOR UPDATE;
  IF NOT FOUND OR b.status<>'PREPARED' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_HPP_BATCH_NOT_INVALIDATABLE'; END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_cost_hpp_bootstrap_consumptions c WHERE c.acceptance_batch_id=p_batch_id)
    OR EXISTS(SELECT 1 FROM public.go_live_bootstrap_evidence e WHERE e.acceptance_batch_id=p_batch_id) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_HPP_BATCH_ALREADY_CONSUMED';
  END IF;
  INSERT INTO public.inventory_cost_hpp_acceptance_requests(request_id,actor_id,operation,payload)
    VALUES(p_request_id,a,'INVALIDATE',payload);
  UPDATE public.inventory_cost_hpp_acceptance_batches SET status='INVALIDATED',updated_at=clock_timestamp() WHERE id=p_batch_id;
  out:=jsonb_build_object('ok',true,'code','INVALIDATED','batchId',p_batch_id);
  INSERT INTO public.inventory_cost_hpp_acceptance_events(batch_id,event_type,actor_id,request_id,reason,details)
    VALUES(p_batch_id,'INVALIDATED',a,p_request_id,why,out);
  UPDATE public.inventory_cost_hpp_acceptance_requests SET result=out,completed_at=clock_timestamp() WHERE request_id=p_request_id;
  RETURN out;
END;
$$;
ALTER FUNCTION public.inventory_cost_hpp_invalidate_prepared(uuid,uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_hpp_invalidate_prepared(uuid,uuid,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.inventory_cost_hpp_invalidate_prepared(uuid,uuid,text) TO authenticated;

CREATE FUNCTION public.inventory_cost_bootstrap_outlet(p_outlet_id uuid,p_acceptance_batch_id uuid,p_request_id uuid,p_confirmation text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=auth.uid(); role public.user_role; h public.inventory_cost_hpp_acceptance_batches%rowtype;
  cut public.stock_opening_cutover_requests%rowtype; period_id uuid; existing public.go_live_bootstrap_evidence%rowtype;
  payload_hash text; cost_batch uuid; event_id uuid; consumption_request uuid:=gen_random_uuid(); stock_projection_row record; hpp_item public.inventory_cost_hpp_acceptance_items%rowtype;
  q numeric; unit_cost numeric(20,8); value_after numeric(32,8); wac numeric(20,8); vq numeric; uq numeric;
  v_count integer:=0; valued_count integer:=0; unvalued_count integer:=0; total_value numeric(32,8):=0; total_valued numeric:=0; total_unvalued numeric:=0;
  res jsonb; cost_req public.inventory_cost_operation_requests%rowtype;
BEGIN
  role:=public.current_active_user_role();
  IF a IS NULL OR role IS DISTINCT FROM 'OWNER'::public.user_role THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='GO_LIVE_OWNER_REQUIRED'; END IF;
  IF p_outlet_id IS NULL OR p_acceptance_batch_id IS NULL OR p_request_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='GO_LIVE_BOOTSTRAP_INPUT_REQUIRED'; END IF;
  IF p_confirmation IS DISTINCT FROM ('COSTING-BOOTSTRAP:'||p_outlet_id::text||':'||p_acceptance_batch_id::text||':'||p_request_id::text) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='GO_LIVE_BOOTSTRAP_CONFIRMATION_REQUIRED';
  END IF;
  payload_hash:=md5(p_outlet_id::text||':'||p_acceptance_batch_id::text||':'||p_confirmation);
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_BOOTSTRAP_OUTLET:'||p_outlet_id::text,73190411));
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_BOOTSTRAP_REQUEST:'||p_request_id::text,73190411));
  SELECT * INTO existing FROM public.go_live_bootstrap_evidence WHERE request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF existing.actor_id<>a OR existing.outlet_id<>p_outlet_id OR existing.acceptance_batch_id<>p_acceptance_batch_id
      OR existing.confirmation<>p_confirmation OR existing.payload_hash<>payload_hash THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='GO_LIVE_REQUEST_CONFLICT'; END IF;
    IF existing.result IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_REQUEST_INCOMPLETE'; END IF;
    RETURN existing.result;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.outlets WHERE id=p_outlet_id AND is_active) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='GO_LIVE_OUTLET_UNAVAILABLE'; END IF;
  SELECT * INTO h FROM public.inventory_cost_hpp_acceptance_batches WHERE id=p_acceptance_batch_id AND outlet_id=p_outlet_id FOR UPDATE;
  IF NOT FOUND OR h.status<>'APPROVED' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_APPROVED_HPP_REQUIRED'; END IF;
  SELECT * INTO cut FROM public.stock_opening_cutover_requests WHERE outlet_id=p_outlet_id AND completed_at IS NOT NULL;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_STOCK_CUTOVER_REQUIRED'; END IF;
  SELECT ap.id INTO period_id FROM public.stock_authority_periods ap
    WHERE ap.outlet_id=p_outlet_id AND ap.ended_at IS NULL AND ap.mode='QUENA_MOVEMENT_LEDGER' FOR UPDATE;
  IF period_id IS NULL OR period_id IS DISTINCT FROM cut.new_authority_period_id THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_STOCK_PERIOD_MISMATCH'; END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections WHERE outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_event_batches WHERE outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_hpp_bootstrap_consumptions WHERE outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_operation_requests WHERE operation_key='BOOTSTRAP_OUTLET' AND target_key=p_outlet_id::text AND result IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_BOOTSTRAP_ALREADY_STARTED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_carts c WHERE c.outlet_id=p_outlet_id AND c.status IN ('ACTIVE','PARKED'))
    OR EXISTS(SELECT 1 FROM public.stock_opname_sessions s WHERE s.outlet_id=p_outlet_id AND s.status IN ('COUNTING','REVIEW'))
    OR EXISTS(SELECT 1 FROM public.purchase_receipts r WHERE r.outlet_id=p_outlet_id AND r.status='DRAFT')
    OR EXISTS(SELECT 1 FROM public.purchase_invoices i WHERE i.outlet_id=p_outlet_id AND i.status='DRAFT')
    OR EXISTS(SELECT 1 FROM public.manual_stock_corrections m WHERE m.outlet_id=p_outlet_id AND m.status='DRAFT')
    OR EXISTS(SELECT 1 FROM public.supplier_returns r WHERE r.outlet_id=p_outlet_id AND r.status='DRAFT')
    OR EXISTS(SELECT 1 FROM public.pos_checkout_requests r WHERE r.outlet_id=p_outlet_id AND r.completed_at IS NULL)
    OR EXISTS(SELECT 1 FROM public.stock_operation_requests r WHERE r.state='PENDING'
      AND ((r.request_payload->>'outlet_id')=p_outlet_id::text OR EXISTS(SELECT 1 FROM public.stock_opname_sessions ss
        WHERE ss.id::text=r.request_payload->>'session_id' AND ss.outlet_id=p_outlet_id)
        OR EXISTS(SELECT 1 FROM public.stock_movements sm WHERE sm.id::text=r.request_payload->>'movement_id' AND sm.outlet_id=p_outlet_id)
        OR EXISTS(SELECT 1 FROM public.purchase_receipts pr WHERE pr.id::text=r.request_payload->>'receipt_id' AND pr.outlet_id=p_outlet_id)
        OR EXISTS(SELECT 1 FROM public.manual_stock_corrections mc WHERE mc.id::text=r.request_payload->>'correction_id' AND mc.outlet_id=p_outlet_id)
        OR EXISTS(SELECT 1 FROM public.supplier_returns sr WHERE sr.id::text=r.request_payload->>'return_id' AND sr.outlet_id=p_outlet_id))) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_OPERATIONAL_WORK_OPEN';
  END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_cost_hpp_acceptance_batches b WHERE b.outlet_id=p_outlet_id
      AND b.id<>p_acceptance_batch_id AND b.status IN ('APPROVED','CONSUMED')) THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_OTHER_HPP_BATCH_EXISTS'; END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_cost_hpp_acceptance_items i WHERE i.batch_id=p_acceptance_batch_id
      AND (i.approved_by IS NULL OR i.approved_at IS NULL OR i.quantity_at_approval IS NULL
        OR i.quantity_at_approval<>(SELECT p.effective_quantity FROM public.stock_balance_projection p WHERE p.outlet_id=i.outlet_id AND p.product_id=i.product_id)
        OR i.balance_version_at_approval<>(SELECT p.balance_version FROM public.stock_balance_projection p WHERE p.outlet_id=i.outlet_id AND p.product_id=i.product_id)
        OR i.normalization_commit_id IS DISTINCT FROM cut.normalization_commit_id)) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_HPP_STOCK_EVIDENCE_MISMATCH';
  END IF;
  IF EXISTS(SELECT 1 FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id AND p.effective_quantity>0
      AND NOT EXISTS(SELECT 1 FROM public.inventory_cost_hpp_acceptance_items i WHERE i.batch_id=p_acceptance_batch_id
        AND i.outlet_id=p_outlet_id AND i.product_id=p.product_id)) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_HPP_ITEM_MISSING';
  END IF;
  FOR stock_projection_row IN SELECT p.product_id,p.effective_quantity,p.balance_version,p.authority_period_id
    FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id ORDER BY p.product_id FOR UPDATE LOOP NULL; END LOOP;
  IF EXISTS(SELECT 1 FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id AND p.authority_period_id<>period_id)
    OR NOT EXISTS(SELECT 1 FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id) THEN
    RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='GO_LIVE_STOCK_PROJECTION_MISMATCH';
  END IF;
  INSERT INTO public.inventory_cost_operation_requests(request_id,actor_id,operation_key,target_key,payload_hash)
    VALUES(p_request_id,a,'BOOTSTRAP_OUTLET',p_outlet_id::text,payload_hash);
  INSERT INTO public.go_live_bootstrap_evidence(request_id,outlet_id,actor_id,acceptance_batch_id,cutover_request_id,confirmation,payload_hash)
    VALUES(p_request_id,p_outlet_id,a,p_acceptance_batch_id,cut.request_id,p_confirmation,payload_hash);
  INSERT INTO public.inventory_cost_event_batches(outlet_id,batch_type,source_entity_type,source_entity_id,
    operation_request_id,allocation_method,created_by,hpp_acceptance_batch_id)
    VALUES(p_outlet_id,'OPENING','STOCK_AUTHORITY_CUTOVER',p_outlet_id,p_request_id,'APPROVED_HPP_ACCEPTANCE',a,p_acceptance_batch_id)
    RETURNING id INTO cost_batch;
  FOR stock_projection_row IN SELECT p.product_id,p.effective_quantity,p.balance_version,p.authority_period_id
    FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id ORDER BY p.product_id LOOP
    q:=stock_projection_row.effective_quantity; unit_cost:=NULL; value_after:=NULL; wac:=NULL; vq:=0; uq:=0; hpp_item:=NULL;
    IF q IS NULL OR q<0 OR q<>trunc(q,3) THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_INVALID_OPENING_QUANTITY'; END IF;
    IF q>0 THEN
      SELECT * INTO hpp_item FROM public.inventory_cost_hpp_acceptance_items WHERE batch_id=p_acceptance_batch_id AND product_id=stock_projection_row.product_id AND outlet_id=p_outlet_id;
      IF NOT FOUND OR hpp_item.quantity_at_approval<>q OR hpp_item.approved_by IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_HPP_QUANTITY_MISMATCH'; END IF;
      IF NOT EXISTS(SELECT 1 FROM public.stock_opening_cutover_items ci WHERE ci.request_id=cut.request_id AND ci.product_id=stock_projection_row.product_id
          AND ci.opening_quantity=q AND ci.normalization_commit_id=cut.normalization_commit_id) THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_CUTOVER_ITEM_MISMATCH';
      END IF;
      IF hpp_item.disposition='LEAVE_UNVALUED' THEN uq:=q;
      ELSIF hpp_item.disposition IN ('ACCEPT_CURRENT_HPP','OPENING_HPP_OVERRIDE','AUTHORITATIVE_ZERO') AND hpp_item.accepted_opening_hpp IS NOT NULL THEN
        unit_cost:=hpp_item.accepted_opening_hpp::numeric(20,8); vq:=q; value_after:=round(q*unit_cost,8)::numeric(32,8); wac:=unit_cost;
      ELSE RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_HPP_DISPOSITION_INVALID'; END IF;
    ELSE
      value_after:=0;
    END IF;
    INSERT INTO public.inventory_cost_events(batch_id,outlet_id,product_id,event_type,source_entity_type,source_entity_id,
      valued_quantity_before,valued_quantity_delta,valued_quantity_after,inventory_value_before,inventory_value_delta,inventory_value_after,
      wac_after,valuation_status_after,cost_version_before,cost_version_after,stock_balance_version,stock_authority_period_id,
      source_hpp_value,source_hpp_import_row_id,source_hpp_verification_review_id,actor_id,operation_request_id,
      physical_quantity_delta,physical_quantity_before,physical_quantity_after,provisional_quantity_delta,
      provisional_quantity_before,provisional_quantity_after,unvalued_quantity_delta,unvalued_quantity_before,unvalued_quantity_after,
      valuation_basis,frozen_unit_cost,metadata,opening_hpp_acceptance_batch_id,opening_hpp_disposition)
    VALUES(cost_batch,p_outlet_id,stock_projection_row.product_id,'OPENING','STOCK_AUTHORITY_CUTOVER',p_outlet_id,0,vq,vq,0,value_after,value_after,wac,
      CASE WHEN uq>0 THEN 'UNVALUED'::public.inventory_cost_projection_status ELSE 'VALUED'::public.inventory_cost_projection_status END,
      0,1,stock_projection_row.balance_version,period_id,unit_cost,CASE WHEN q>0 THEN hpp_item.source_import_row_id END,
      CASE WHEN q>0 THEN hpp_item.latest_review_id END,a,p_request_id,q,0,q,0,0,0,uq,0,uq,
      CASE WHEN uq>0 THEN 'UNVALUED'::public.inventory_cost_acquisition_basis
        WHEN q=0 THEN NULL::public.inventory_cost_acquisition_basis
        WHEN hpp_item.disposition='AUTHORITATIVE_ZERO' THEN 'AUTHORITATIVE_ZERO'::public.inventory_cost_acquisition_basis
        WHEN hpp_item.disposition='OPENING_HPP_OVERRIDE' THEN 'MANAGER_ESTIMATE'::public.inventory_cost_acquisition_basis
        ELSE 'VERIFIED_IPOS_HPP'::public.inventory_cost_acquisition_basis END,
      unit_cost,jsonb_build_object('hppAcceptanceBatchId',p_acceptance_batch_id,'disposition',CASE WHEN q>0 THEN hpp_item.disposition::text END,
        'quantitySource','stock_opening_cutover_items','costSource','approved_initial_hpp_acceptance'),
      CASE WHEN q>0 THEN p_acceptance_batch_id END,CASE WHEN q>0 THEN hpp_item.disposition END)
    RETURNING id INTO event_id;
    INSERT INTO public.inventory_cost_projections(outlet_id,product_id,valued_quantity,inventory_value,current_wac,valuation_status,
      cost_version,stock_balance_version,stock_authority_period_id,last_cost_event_id,physical_quantity,provisional_quantity,unvalued_quantity)
    VALUES(p_outlet_id,stock_projection_row.product_id,vq,value_after,wac,
      CASE WHEN uq>0 THEN 'UNVALUED'::public.inventory_cost_projection_status ELSE 'VALUED'::public.inventory_cost_projection_status END,
      1,stock_projection_row.balance_version,period_id,event_id,q,0,uq);
    PERFORM public.inventory_cost_open_source_layer(event_id);
    v_count:=v_count+1; total_valued:=total_valued+vq; total_unvalued:=total_unvalued+uq;
    IF uq>0 THEN unvalued_count:=unvalued_count+1; ELSE valued_count:=valued_count+1; END IF;
    IF value_after IS NOT NULL THEN total_value:=total_value+value_after; END IF;
  END LOOP;
  IF EXISTS(SELECT 1 FROM public.inventory_cost_hpp_acceptance_requests WHERE request_id=consumption_request) THEN
    RAISE EXCEPTION USING ERRCODE='23505',MESSAGE='GO_LIVE_HPP_CONSUMPTION_REQUEST_COLLISION';
  END IF;
  INSERT INTO public.inventory_cost_hpp_acceptance_requests(request_id,actor_id,operation,payload)
    VALUES(consumption_request,a,'BOOTSTRAP_CONSUME',jsonb_build_object('operation','BOOTSTRAP_CONSUME','batchId',p_acceptance_batch_id,'bootstrapRequestId',p_request_id));
  INSERT INTO public.inventory_cost_hpp_bootstrap_consumptions(acceptance_batch_id,outlet_id,cost_event_batch_id,bootstrap_request_id,hpp_request_id,actor_id)
    VALUES(p_acceptance_batch_id,p_outlet_id,cost_batch,p_request_id,consumption_request,a);
  UPDATE public.inventory_cost_hpp_acceptance_batches SET status='CONSUMED',updated_at=clock_timestamp() WHERE id=p_acceptance_batch_id;
  res:=jsonb_build_object('ok',true,'code','BOOTSTRAP_READY','outletId',p_outlet_id,'batchId',cost_batch,
    'acceptanceBatchId',p_acceptance_batch_id,'cutoverRequestId',cut.request_id,'productCount',v_count,
    'valuedCount',valued_count,'unvaluedCount',unvalued_count,'valuedQuantity',total_valued,
    'unvaluedQuantity',total_unvalued,'provisionalQuantity',0,
    'inventoryValue',CASE WHEN total_unvalued>0 THEN NULL ELSE total_value END,
    'knownValuedInventoryValue',total_value,'authorityStatus','BOOTSTRAP_READY');
  UPDATE public.inventory_cost_hpp_acceptance_requests SET result=res,completed_at=clock_timestamp() WHERE request_id=consumption_request;
  INSERT INTO public.inventory_costing_outlet_authority(outlet_id,status,bootstrap_batch_id,bootstrapped_by,bootstrapped_at)
    VALUES(p_outlet_id,'BOOTSTRAP_READY',cost_batch,a,clock_timestamp());
  UPDATE public.inventory_cost_operation_requests SET result=res,completed_at=clock_timestamp() WHERE request_id=p_request_id;
  UPDATE public.go_live_bootstrap_evidence SET result=res,completed_at=clock_timestamp() WHERE request_id=p_request_id;
  RETURN res;
END;
$$;
ALTER FUNCTION public.inventory_cost_bootstrap_outlet(uuid,uuid,uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_bootstrap_outlet(uuid,uuid,uuid,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.inventory_cost_bootstrap_outlet(uuid,uuid,uuid,text) TO authenticated;

-- The old signature had no approval-batch or confirmation argument. Keep it
-- only as a fail-closed compatibility stub so no stale client can bootstrap.
CREATE OR REPLACE FUNCTION public.inventory_cost_bootstrap_outlet(p_outlet_id uuid,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='GO_LIVE_APPROVED_HPP_AND_CONFIRMATION_REQUIRED';
END;
$$;
ALTER FUNCTION public.inventory_cost_bootstrap_outlet(uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_bootstrap_outlet(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE TABLE public.go_live_wac_activation_confirmation (
  request_id uuid PRIMARY KEY,
  outlet_id uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  acceptance_batch_id uuid NOT NULL,
  bootstrap_batch_id uuid NOT NULL REFERENCES public.inventory_cost_event_batches(id) ON DELETE RESTRICT,
  bootstrap_request_id uuid NOT NULL REFERENCES public.inventory_cost_operation_requests(request_id) ON DELETE RESTRICT,
  stock_authority_period_id uuid NOT NULL REFERENCES public.stock_authority_periods(id) ON DELETE RESTRICT,
  confirmation text NOT NULL,
  payload_hash text NOT NULL CHECK(payload_hash ~ '^[0-9a-f]{32}$'),
  result jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  FOREIGN KEY(acceptance_batch_id,outlet_id) REFERENCES public.inventory_cost_hpp_acceptance_batches(id,outlet_id) ON DELETE RESTRICT,
  FOREIGN KEY(bootstrap_request_id,outlet_id) REFERENCES public.go_live_bootstrap_evidence(request_id,outlet_id) ON DELETE RESTRICT,
  CHECK((result IS NULL)=(completed_at IS NULL)),
  UNIQUE(outlet_id)
);
-- Add full authority activation evidence only after the bootstrap tables exist.
ALTER TABLE public.go_live_wac_activation_confirmation ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.go_live_wac_activation_confirmation FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.go_live_wac_activation_confirmation TO authenticated;
CREATE POLICY go_live_wac_activation_confirmation_manager_read ON public.go_live_wac_activation_confirmation
  FOR SELECT TO authenticated USING(public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE TRIGGER go_live_wac_activation_evidence_guard BEFORE UPDATE OR DELETE ON public.go_live_wac_activation_confirmation
  FOR EACH ROW EXECUTE FUNCTION public.go_live_request_evidence_guard();

CREATE FUNCTION public.inventory_cost_activate_wac(p_outlet_id uuid,p_request_id uuid,p_confirmation text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=auth.uid(); role public.user_role; auth public.inventory_costing_outlet_authority%rowtype;
  boot public.go_live_bootstrap_evidence%rowtype; consumed public.inventory_cost_hpp_bootstrap_consumptions%rowtype;
  period_id uuid; existing public.go_live_wac_activation_confirmation%rowtype; payload_hash text; v_result jsonb;
  qty_valued numeric:=0; qty_provisional numeric:=0; qty_unvalued numeric:=0; total_value numeric(32,8):=0;
  product_count integer:=0; valued_count integer:=0; unvalued_count integer:=0;
BEGIN
  role:=public.current_active_user_role();
  IF a IS NULL OR role IS DISTINCT FROM 'OWNER'::public.user_role THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='GO_LIVE_OWNER_REQUIRED'; END IF;
  IF p_outlet_id IS NULL OR p_request_id IS NULL OR p_confirmation IS DISTINCT FROM ('ACTIVATE-WAC:'||p_outlet_id::text||':'||p_request_id::text) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='GO_LIVE_WAC_CONFIRMATION_REQUIRED';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_BOOTSTRAP_OUTLET:'||p_outlet_id::text,73190411));
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('GO_LIVE_WAC_REQUEST:'||p_request_id::text,73190411));
  payload_hash:=md5(p_outlet_id::text||':'||p_confirmation);
  SELECT * INTO existing FROM public.go_live_wac_activation_confirmation WHERE request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF existing.actor_id<>a OR existing.outlet_id<>p_outlet_id OR existing.confirmation<>p_confirmation OR existing.payload_hash<>payload_hash THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='GO_LIVE_REQUEST_CONFLICT';
    END IF;
    IF existing.result IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_REQUEST_INCOMPLETE'; END IF;
    RETURN existing.result;
  END IF;
  SELECT * INTO auth FROM public.inventory_costing_outlet_authority WHERE outlet_id=p_outlet_id FOR UPDATE;
  IF NOT FOUND OR auth.status<>'BOOTSTRAP_READY' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_BOOTSTRAP_READY_REQUIRED'; END IF;
  SELECT * INTO boot FROM public.go_live_bootstrap_evidence WHERE outlet_id=p_outlet_id AND result IS NOT NULL;
  IF NOT FOUND OR boot.request_id IS NULL OR boot.result->>'batchId' IS DISTINCT FROM auth.bootstrap_batch_id::text THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_BOOTSTRAP_EVIDENCE_REQUIRED';
  END IF;
  SELECT * INTO consumed FROM public.inventory_cost_hpp_bootstrap_consumptions WHERE outlet_id=p_outlet_id
    AND cost_event_batch_id=auth.bootstrap_batch_id;
  IF NOT FOUND OR consumed.acceptance_batch_id IS DISTINCT FROM boot.acceptance_batch_id THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_HPP_CONSUMPTION_REQUIRED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.inventory_cost_hpp_acceptance_batches WHERE id=consumed.acceptance_batch_id AND outlet_id=p_outlet_id AND status='CONSUMED') THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_HPP_NOT_CONSUMED';
  END IF;
  SELECT ap.id INTO period_id FROM public.stock_authority_periods ap WHERE ap.outlet_id=p_outlet_id AND ap.ended_at IS NULL AND ap.mode='QUENA_MOVEMENT_LEDGER' FOR UPDATE;
  IF period_id IS NULL OR EXISTS(SELECT 1 FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id AND p.authority_period_id<>period_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections p WHERE p.outlet_id=p_outlet_id AND p.stock_authority_period_id<>period_id) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_AUTHORITY_PERIOD_MISMATCH';
  END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_cost_operation_requests r WHERE r.operation_key='BOOTSTRAP_OUTLET'
      AND r.target_key=p_outlet_id::text AND r.result IS NULL)
    OR EXISTS(SELECT 1 FROM public.pos_carts c WHERE c.outlet_id=p_outlet_id AND c.status IN ('ACTIVE','PARKED'))
    OR EXISTS(SELECT 1 FROM public.stock_opname_sessions s WHERE s.outlet_id=p_outlet_id AND s.status IN ('COUNTING','REVIEW'))
    OR EXISTS(SELECT 1 FROM public.purchase_receipts r WHERE r.outlet_id=p_outlet_id AND r.status='DRAFT')
    OR EXISTS(SELECT 1 FROM public.purchase_invoices i WHERE i.outlet_id=p_outlet_id AND i.status='DRAFT')
    OR EXISTS(SELECT 1 FROM public.manual_stock_corrections m WHERE m.outlet_id=p_outlet_id AND m.status='DRAFT')
    OR EXISTS(SELECT 1 FROM public.supplier_returns r WHERE r.outlet_id=p_outlet_id AND r.status='DRAFT')
    OR EXISTS(SELECT 1 FROM public.pos_checkout_requests r WHERE r.outlet_id=p_outlet_id AND r.completed_at IS NULL)
    OR EXISTS(SELECT 1 FROM public.stock_operation_requests r WHERE r.state='PENDING'
      AND ((r.request_payload->>'outlet_id')=p_outlet_id::text OR EXISTS(SELECT 1 FROM public.stock_opname_sessions ss
        WHERE ss.id::text=r.request_payload->>'session_id' AND ss.outlet_id=p_outlet_id)
        OR EXISTS(SELECT 1 FROM public.stock_movements sm WHERE sm.id::text=r.request_payload->>'movement_id' AND sm.outlet_id=p_outlet_id)
        OR EXISTS(SELECT 1 FROM public.purchase_receipts pr WHERE pr.id::text=r.request_payload->>'receipt_id' AND pr.outlet_id=p_outlet_id)
        OR EXISTS(SELECT 1 FROM public.manual_stock_corrections mc WHERE mc.id::text=r.request_payload->>'correction_id' AND mc.outlet_id=p_outlet_id)
        OR EXISTS(SELECT 1 FROM public.supplier_returns sr WHERE sr.id::text=r.request_payload->>'return_id' AND sr.outlet_id=p_outlet_id))) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_OPERATIONAL_WORK_OPEN';
  END IF;
  SELECT count(*)::integer,coalesce(sum(cp.valued_quantity),0),coalesce(sum(cp.provisional_quantity),0),
    coalesce(sum(cp.unvalued_quantity),0),coalesce(sum(cp.inventory_value) FILTER(WHERE cp.inventory_value IS NOT NULL),0)::numeric(32,8),
    count(*) FILTER(WHERE cp.valued_quantity>0)::integer,count(*) FILTER(WHERE cp.unvalued_quantity>0)::integer
  INTO product_count,qty_valued,qty_provisional,qty_unvalued,total_value,valued_count,unvalued_count
  FROM public.inventory_cost_projections cp WHERE cp.outlet_id=p_outlet_id;
  IF product_count<>(SELECT count(*) FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.stock_balance_projection sp LEFT JOIN public.inventory_cost_projections cp
        ON cp.outlet_id=sp.outlet_id AND cp.product_id=sp.product_id
      WHERE sp.outlet_id=p_outlet_id AND (cp.product_id IS NULL OR cp.physical_quantity IS DISTINCT FROM sp.effective_quantity
        OR cp.valued_quantity+cp.unvalued_quantity IS DISTINCT FROM sp.effective_quantity
        OR cp.provisional_quantity<0 OR cp.provisional_quantity>cp.valued_quantity
        OR cp.stock_balance_version<>sp.balance_version OR cp.stock_authority_period_id<>sp.authority_period_id))
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections cp WHERE cp.outlet_id=p_outlet_id AND NOT EXISTS(
      SELECT 1 FROM public.inventory_cost_source_layer_balances lb WHERE lb.outlet_id=cp.outlet_id AND lb.product_id=cp.product_id
      GROUP BY lb.outlet_id,lb.product_id HAVING sum(lb.remaining_valued_quantity)=cp.valued_quantity
        AND sum(lb.remaining_provisional_quantity)=cp.provisional_quantity AND sum(lb.remaining_unvalued_quantity)=cp.unvalued_quantity))
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections cp WHERE cp.outlet_id=p_outlet_id
      AND NOT EXISTS(SELECT 1 FROM public.stock_balance_projection sp
        WHERE sp.outlet_id=cp.outlet_id AND sp.product_id=cp.product_id))
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections cp JOIN public.inventory_cost_events e
        ON e.id=cp.last_cost_event_id AND e.outlet_id=cp.outlet_id AND e.product_id=cp.product_id
      WHERE cp.outlet_id=p_outlet_id AND (cp.inventory_value IS DISTINCT FROM e.inventory_value_after
        OR cp.physical_quantity IS DISTINCT FROM e.physical_quantity_after
        OR cp.valued_quantity IS DISTINCT FROM e.valued_quantity_after
        OR cp.provisional_quantity IS DISTINCT FROM e.provisional_quantity_after
        OR cp.unvalued_quantity IS DISTINCT FROM e.unvalued_quantity_after)) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_COSTING_RECONCILIATION_FAILED';
  END IF;
  INSERT INTO public.go_live_wac_activation_confirmation(request_id,outlet_id,actor_id,acceptance_batch_id,
    bootstrap_batch_id,bootstrap_request_id,stock_authority_period_id,confirmation,payload_hash)
  VALUES(p_request_id,p_outlet_id,a,consumed.acceptance_batch_id,auth.bootstrap_batch_id,consumed.bootstrap_request_id,
    period_id,p_confirmation,payload_hash);
  UPDATE public.inventory_costing_outlet_authority SET status='WAC_ACTIVE',activated_by=a,activated_at=clock_timestamp(),updated_at=clock_timestamp()
    WHERE outlet_id=p_outlet_id AND status='BOOTSTRAP_READY';
  v_result:=jsonb_build_object('ok',true,'code','WAC_ACTIVE','outletId',p_outlet_id,'acceptanceBatchId',consumed.acceptance_batch_id,
    'bootstrapBatchId',auth.bootstrap_batch_id,'stockAuthorityPeriodId',period_id,'productCount',product_count,
    'valuedProductCount',valued_count,'unvaluedProductCount',unvalued_count,'valuedQuantity',qty_valued,
    'provisionalQuantity',qty_provisional,'unvaluedQuantity',qty_unvalued,
    'inventoryValue',CASE WHEN qty_unvalued>0 THEN NULL ELSE total_value END,'knownValuedInventoryValue',total_value,'activatedBy',a);
  UPDATE public.go_live_wac_activation_confirmation SET result=v_result,completed_at=clock_timestamp() WHERE request_id=p_request_id;
  RETURN v_result;
END;
$$;
ALTER FUNCTION public.inventory_cost_activate_wac(uuid,uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_activate_wac(uuid,uuid,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.inventory_cost_activate_wac(uuid,uuid,text) TO authenticated;

CREATE FUNCTION public.go_live_readiness(p_outlet_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE role public.user_role; period public.stock_authority_periods%rowtype; cut public.stock_opening_cutover_requests%rowtype;
  auth public.inventory_costing_outlet_authority%rowtype; consumed public.inventory_cost_hpp_bootstrap_consumptions%rowtype;
  latest_commit uuid; prepared_count integer; approved_count integer; hpp_mismatch integer; costing_mismatch integer;
  open_carts integer; open_opname integer; draft_receipts integer; draft_invoices integer; draft_corrections integer;
  draft_returns integer; pending_stock integer; incomplete_checkout integer; active_quantity_overrides integer;
  sales_count integer; cost_rows integer; cost_batches integer; hpp_state text; post_review jsonb; out jsonb;
BEGIN
  role:=public.current_active_user_role();
  IF auth.uid() IS NULL OR role NOT IN ('OWNER','ADMIN') THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='GO_LIVE_READINESS_FORBIDDEN'; END IF;
  IF p_outlet_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.outlets o WHERE o.id=p_outlet_id AND o.is_active) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='GO_LIVE_OUTLET_INVALID'; END IF;
  SELECT * INTO period FROM public.stock_authority_periods WHERE outlet_id=p_outlet_id AND ended_at IS NULL;
  SELECT * INTO cut FROM public.stock_opening_cutover_requests WHERE outlet_id=p_outlet_id AND completed_at IS NOT NULL;
  SELECT * INTO auth FROM public.inventory_costing_outlet_authority WHERE outlet_id=p_outlet_id;
  SELECT * INTO consumed FROM public.inventory_cost_hpp_bootstrap_consumptions WHERE outlet_id=p_outlet_id;
  SELECT c.id INTO latest_commit FROM public.ipos_normalization_commits c WHERE c.outlet_id=p_outlet_id AND c.status='COMPLETED'
    ORDER BY c.completed_at DESC,c.id DESC LIMIT 1;
  SELECT count(*) FILTER(WHERE status='PREPARED'),count(*) FILTER(WHERE status='APPROVED')
    INTO prepared_count,approved_count FROM public.inventory_cost_hpp_acceptance_batches WHERE outlet_id=p_outlet_id;
  SELECT count(*) INTO open_carts FROM public.pos_carts WHERE outlet_id=p_outlet_id AND status IN ('ACTIVE','PARKED');
  SELECT count(*) INTO open_opname FROM public.stock_opname_sessions WHERE outlet_id=p_outlet_id AND status IN ('COUNTING','REVIEW');
  SELECT count(*) INTO draft_receipts FROM public.purchase_receipts WHERE outlet_id=p_outlet_id AND status='DRAFT';
  SELECT count(*) INTO draft_invoices FROM public.purchase_invoices WHERE outlet_id=p_outlet_id AND status='DRAFT';
  SELECT count(*) INTO draft_corrections FROM public.manual_stock_corrections WHERE outlet_id=p_outlet_id AND status='DRAFT';
  SELECT count(*) INTO draft_returns FROM public.supplier_returns WHERE outlet_id=p_outlet_id AND status='DRAFT';
  SELECT count(*) INTO incomplete_checkout FROM public.pos_checkout_requests WHERE outlet_id=p_outlet_id AND completed_at IS NULL;
  SELECT count(*) INTO active_quantity_overrides FROM public.product_field_overrides WHERE outlet_id=p_outlet_id AND field_key='quantity' AND is_active;
  SELECT count(*) INTO pending_stock FROM public.stock_operation_requests r WHERE r.state='PENDING'
    AND ((r.request_payload->>'outlet_id')=p_outlet_id::text
      OR EXISTS(SELECT 1 FROM public.stock_opname_sessions s WHERE s.id::text=r.request_payload->>'session_id' AND s.outlet_id=p_outlet_id)
      OR EXISTS(SELECT 1 FROM public.stock_movements m WHERE m.id::text=r.request_payload->>'movement_id' AND m.outlet_id=p_outlet_id)
      OR EXISTS(SELECT 1 FROM public.purchase_receipts pr WHERE pr.id::text=r.request_payload->>'receipt_id' AND pr.outlet_id=p_outlet_id)
      OR EXISTS(SELECT 1 FROM public.manual_stock_corrections mc WHERE mc.id::text=r.request_payload->>'correction_id' AND mc.outlet_id=p_outlet_id)
      OR EXISTS(SELECT 1 FROM public.supplier_returns sr WHERE sr.id::text=r.request_payload->>'return_id' AND sr.outlet_id=p_outlet_id));
  SELECT count(*) INTO sales_count FROM public.sales WHERE outlet_id=p_outlet_id;
  SELECT count(*) INTO cost_rows FROM public.inventory_cost_projections WHERE outlet_id=p_outlet_id;
  SELECT count(*) INTO cost_batches FROM public.inventory_cost_event_batches WHERE outlet_id=p_outlet_id;
  SELECT count(*) INTO hpp_mismatch FROM public.stock_balance_projection sp
    LEFT JOIN public.inventory_cost_hpp_acceptance_batches hb ON hb.outlet_id=sp.outlet_id AND hb.status='APPROVED'
    LEFT JOIN public.inventory_cost_hpp_acceptance_items hi ON hi.batch_id=hb.id AND hi.outlet_id=sp.outlet_id AND hi.product_id=sp.product_id
    LEFT JOIN public.stock_opening_cutover_items ci ON ci.request_id=cut.request_id AND ci.product_id=sp.product_id
    WHERE sp.outlet_id=p_outlet_id AND sp.effective_quantity>0 AND
      (hb.id IS NULL OR hi.product_id IS NULL OR hi.approved_by IS NULL OR hi.quantity_at_approval IS DISTINCT FROM sp.effective_quantity
        OR hi.balance_version_at_approval IS DISTINCT FROM sp.balance_version
        OR hi.normalization_commit_id IS DISTINCT FROM cut.normalization_commit_id
        OR ci.product_id IS NULL OR ci.opening_quantity IS DISTINCT FROM sp.effective_quantity);
  SELECT count(*) INTO costing_mismatch FROM (
    SELECT sp.product_id FROM public.stock_balance_projection sp
      LEFT JOIN public.inventory_cost_projections cp ON cp.outlet_id=sp.outlet_id AND cp.product_id=sp.product_id
      LEFT JOIN public.inventory_cost_events e ON e.id=cp.last_cost_event_id AND e.outlet_id=cp.outlet_id AND e.product_id=cp.product_id
      WHERE sp.outlet_id=p_outlet_id AND (cp.product_id IS NULL OR e.id IS NULL
        OR cp.physical_quantity IS DISTINCT FROM sp.effective_quantity OR cp.stock_balance_version IS DISTINCT FROM sp.balance_version
        OR cp.stock_authority_period_id IS DISTINCT FROM sp.authority_period_id
        OR cp.valued_quantity+cp.unvalued_quantity IS DISTINCT FROM sp.effective_quantity
        OR cp.inventory_value IS DISTINCT FROM e.inventory_value_after
        OR cp.valued_quantity IS DISTINCT FROM e.valued_quantity_after
        OR cp.provisional_quantity IS DISTINCT FROM e.provisional_quantity_after
        OR cp.unvalued_quantity IS DISTINCT FROM e.unvalued_quantity_after
        OR NOT EXISTS(SELECT 1 FROM public.inventory_cost_source_layer_balances lb WHERE lb.outlet_id=cp.outlet_id AND lb.product_id=cp.product_id
          GROUP BY lb.outlet_id,lb.product_id HAVING sum(lb.remaining_valued_quantity)=cp.valued_quantity
            AND sum(lb.remaining_provisional_quantity)=cp.provisional_quantity AND sum(lb.remaining_unvalued_quantity)=cp.unvalued_quantity))
    UNION ALL SELECT cp.product_id FROM public.inventory_cost_projections cp
      WHERE cp.outlet_id=p_outlet_id AND NOT EXISTS(SELECT 1 FROM public.stock_balance_projection sp WHERE sp.outlet_id=cp.outlet_id AND sp.product_id=cp.product_id)
  ) mismatch;
  SELECT coalesce(jsonb_agg(jsonb_build_object('kind',kind,'count',cnt) ORDER BY kind),'[]'::jsonb) INTO post_review FROM (
    SELECT 'posted_purchase_receipts' kind,count(*) cnt FROM public.purchase_receipts WHERE outlet_id=p_outlet_id AND status='POSTED' HAVING count(*)>0
    UNION ALL SELECT 'finalized_purchase_invoices',count(*) FROM public.purchase_invoices WHERE outlet_id=p_outlet_id AND status='FINALIZED' HAVING count(*)>0
    UNION ALL SELECT 'posted_supplier_returns',count(*) FROM public.supplier_returns WHERE outlet_id=p_outlet_id AND status='POSTED' HAVING count(*)>0
    UNION ALL SELECT 'posted_manual_corrections',count(*) FROM public.manual_stock_corrections WHERE outlet_id=p_outlet_id AND status='POSTED' HAVING count(*)>0
    UNION ALL SELECT 'sales',count(*) FROM public.sales WHERE outlet_id=p_outlet_id HAVING count(*)>0
  ) x;
  hpp_state:=CASE WHEN consumed.acceptance_batch_id IS NOT NULL THEN 'CONSUMED' ELSE
    coalesce((SELECT b.status::text FROM public.inventory_cost_hpp_acceptance_batches b WHERE b.outlet_id=p_outlet_id
      AND b.status IN ('PREPARED','APPROVED','CONSUMED') ORDER BY b.prepared_at DESC LIMIT 1),'NONE') END;
  out:=jsonb_build_object('outletId',p_outlet_id,'stockAuthority',CASE WHEN period.id IS NULL THEN NULL ELSE period.mode::text END,
    'stockAuthorityPeriodId',period.id,'latestNormalizationCommitId',latest_commit,'stockCutoverCompleted',cut.request_id IS NOT NULL,
    'hppAcceptanceStatus',hpp_state,'preparedHppBatchCount',prepared_count,'approvedHppBatchCount',approved_count,
    'bootstrapStatus',coalesce(auth.status::text,'NONE'),'wacActive',coalesce(auth.status='WAC_ACTIVE',false),
    'stockProjectionCount',(SELECT count(*) FROM public.stock_balance_projection WHERE outlet_id=p_outlet_id),
    'costProjectionCount',cost_rows,'costEventBatchCount',cost_batches,'activeCarts',open_carts,'openOpname',open_opname,
    'draftReceipts',draft_receipts,'draftInvoices',draft_invoices,'draftCorrections',draft_corrections,'draftReturns',draft_returns,
    'pendingStockOperations',pending_stock,'incompleteCheckoutRequests',incomplete_checkout,
    'activeQuantityOverrides',active_quantity_overrides,'nativeSales',sales_count,'manualReview',post_review,
    'readyForFinalImport',cut.request_id IS NULL AND period.mode='IPOS_SNAPSHOT_PLUS_QUENA_MOVEMENTS'
      AND open_carts=0 AND open_opname=0 AND draft_receipts=0 AND draft_invoices=0 AND draft_corrections=0
      AND draft_returns=0 AND incomplete_checkout=0 AND pending_stock=0 AND active_quantity_overrides=0
      AND hpp_state='NONE' AND auth.outlet_id IS NULL AND sales_count=0 AND cost_rows=0 AND cost_batches=0
      AND jsonb_array_length(post_review)=0,
    'readyForStockCutover',latest_commit IS NOT NULL AND cut.request_id IS NULL AND period.id IS NOT NULL
      AND period.mode='IPOS_SNAPSHOT_PLUS_QUENA_MOVEMENTS' AND open_carts=0 AND open_opname=0 AND draft_receipts=0
      AND draft_invoices=0 AND draft_corrections=0 AND draft_returns=0 AND incomplete_checkout=0 AND pending_stock=0
      AND active_quantity_overrides=0 AND sales_count=0 AND cost_rows=0 AND cost_batches=0 AND prepared_count=0 AND approved_count=0
      AND jsonb_array_length(post_review)=0,
    'readyForHppPrepare',cut.request_id IS NOT NULL AND cut.normalization_commit_id=latest_commit
      AND period.mode='QUENA_MOVEMENT_LEDGER' AND auth.outlet_id IS NULL
      AND prepared_count=0 AND approved_count=0 AND sales_count=0 AND jsonb_array_length(post_review)=0,
    'readyForBootstrap',cut.request_id IS NOT NULL AND cut.normalization_commit_id=latest_commit
      AND period.mode='QUENA_MOVEMENT_LEDGER' AND approved_count=1 AND hpp_mismatch=0
      AND auth.outlet_id IS NULL AND cost_rows=0 AND cost_batches=0 AND draft_receipts=0 AND draft_invoices=0
      AND open_carts=0 AND open_opname=0 AND draft_corrections=0 AND draft_returns=0 AND incomplete_checkout=0
      AND pending_stock=0 AND active_quantity_overrides=0 AND sales_count=0 AND jsonb_array_length(post_review)=0,
    'hppEvidenceMismatchCount',hpp_mismatch,'costingReconciliationMismatchCount',costing_mismatch,
    'readyForWacActivation',auth.status='BOOTSTRAP_READY' AND consumed.acceptance_batch_id IS NOT NULL
      AND hpp_state='CONSUMED' AND period.mode='QUENA_MOVEMENT_LEDGER' AND pending_stock=0
      AND open_carts=0 AND open_opname=0 AND draft_receipts=0 AND draft_invoices=0 AND draft_corrections=0
      AND draft_returns=0 AND incomplete_checkout=0 AND active_quantity_overrides=0 AND costing_mismatch=0
      AND jsonb_array_length(post_review)=0,
    'readyForPos',auth.status='WAC_ACTIVE');
  RETURN out;
END;
$$;
ALTER FUNCTION public.go_live_readiness(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.go_live_readiness(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.go_live_readiness(uuid) TO authenticated;

-- This operation cancels only reversible drafts via their audited lifecycle.
-- Posted/financial evidence is preserved and reported for manual review.
CREATE FUNCTION public.go_live_reset_preparation(p_outlet_id uuid,p_request_id uuid,p_confirmation text,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
  DECLARE a uuid:=auth.uid(); role public.user_role; old public.go_live_reset_preparation_requests%rowtype;
  payload_hash text; c record; s record; req uuid; n_cart integer:=0; n_opname integer:=0; n_receipt integer:=0;
  n_invoice integer:=0; n_correction integer:=0; n_return integer:=0; n_hpp integer:=0;
  child_request uuid; op_result jsonb; manual jsonb; blockers jsonb; ready boolean; out jsonb; why text:=nullif(btrim(p_reason),'');
BEGIN
  role:=public.current_active_user_role();
  IF a IS NULL OR role IS DISTINCT FROM 'OWNER'::public.user_role THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='GO_LIVE_OWNER_REQUIRED'; END IF;
  IF p_outlet_id IS NULL OR p_request_id IS NULL OR why IS NULL OR length(why)<3 OR length(why)>500
    OR p_confirmation IS DISTINCT FROM ('PREPARE-GO-LIVE:'||p_outlet_id::text||':'||p_request_id::text) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='GO_LIVE_PREPARATION_CONFIRMATION_REQUIRED';
  END IF;
  payload_hash:=md5(p_outlet_id::text||':'||why||':'||p_confirmation);
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_BOOTSTRAP_OUTLET:'||p_outlet_id::text,73190411));
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('GO_LIVE_PREPARE_REQUEST:'||p_request_id::text,73190411));
  SELECT * INTO old FROM public.go_live_reset_preparation_requests WHERE request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF old.actor_id<>a OR old.outlet_id<>p_outlet_id OR old.reason<>why OR old.confirmation<>p_confirmation OR old.payload_hash<>payload_hash THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='GO_LIVE_REQUEST_CONFLICT';
    END IF;
    IF old.result IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_REQUEST_INCOMPLETE'; END IF;
    RETURN old.result;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.outlets WHERE id=p_outlet_id AND is_active) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='GO_LIVE_OUTLET_UNAVAILABLE'; END IF;
  IF EXISTS(SELECT 1 FROM public.stock_opening_cutover_requests WHERE outlet_id=p_outlet_id AND completed_at IS NOT NULL) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_FINAL_IMPORT_PREPARATION_CLOSED_AFTER_CUTOVER';
  END IF;
  INSERT INTO public.go_live_reset_preparation_requests(request_id,outlet_id,actor_id,reason,confirmation,payload_hash)
    VALUES(p_request_id,p_outlet_id,a,why,p_confirmation,payload_hash);
  -- Prevent new draft/import/cost rows racing the assessment. The operation
  -- shares the same outlet lock as stock/cost writers.
  LOCK TABLE public.pos_carts,public.stock_opname_sessions,public.purchase_receipts,public.purchase_invoices,
    public.manual_stock_corrections,public.supplier_returns,public.inventory_cost_hpp_acceptance_batches,
    public.inventory_costing_outlet_authority,public.inventory_cost_projections,public.inventory_cost_event_batches,
    public.stock_operation_requests IN SHARE ROW EXCLUSIVE MODE;
  SELECT count(*) INTO n_invoice FROM public.purchase_invoices WHERE outlet_id=p_outlet_id AND status='DRAFT';
  IF EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority a WHERE a.outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections p WHERE p.outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_event_batches b WHERE b.outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.sales sale_row WHERE sale_row.outlet_id=p_outlet_id) THEN
    manual:=jsonb_build_array(
      jsonb_build_object('kind','cost_authority','count',(SELECT count(*) FROM public.inventory_costing_outlet_authority WHERE outlet_id=p_outlet_id)),
      jsonb_build_object('kind','cost_projections','count',(SELECT count(*) FROM public.inventory_cost_projections WHERE outlet_id=p_outlet_id)),
      jsonb_build_object('kind','cost_event_batches','count',(SELECT count(*) FROM public.inventory_cost_event_batches WHERE outlet_id=p_outlet_id)),
      jsonb_build_object('kind','sales','count',(SELECT count(*) FROM public.sales WHERE outlet_id=p_outlet_id)));
    out:=jsonb_build_object('ok',true,'code','MANUAL_REVIEW_REQUIRED','outletId',p_outlet_id,'requestId',p_request_id,
      'cancelledDrafts',jsonb_build_object('carts',0,'opname',0,'receipts',0,'invoices',0,'manualCorrections',0,'supplierReturns',0,'hppBatches',0),
      'remainingBlockers',jsonb_build_array('COSTING_OR_SALES_STATE_EXISTS'),'manualReviewItems',manual,
      'ready_for_final_import',false,'preservedAuthProfilesOutletsSuppliersAndPostedEvidence',true);
    UPDATE public.go_live_reset_preparation_requests SET result=out,completed_at=clock_timestamp() WHERE request_id=p_request_id;
    RETURN out;
  END IF;
  FOR c IN SELECT id,revision FROM public.pos_carts WHERE outlet_id=p_outlet_id AND status IN ('ACTIVE','PARKED') ORDER BY id LOOP
    PERFORM public.pos_cart_cancel(c.id,c.revision,gen_random_uuid()); n_cart:=n_cart+1;
  END LOOP;
  FOR s IN SELECT id FROM public.stock_opname_sessions WHERE outlet_id=p_outlet_id AND status IN ('COUNTING','REVIEW') ORDER BY id LOOP
    req:=public.issue_stock_operation_intent('CANCEL_SESSION',jsonb_build_object('session_id',s.id));
    op_result:=public.apply_stock_operation_intent(req);
    IF coalesce((op_result->>'ok')::boolean,false) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='GO_LIVE_OPNAME_CANCEL_FAILED'; END IF;
    n_opname:=n_opname+1;
  END LOOP;
  FOR c IN SELECT id FROM public.purchase_receipts WHERE outlet_id=p_outlet_id AND status='DRAFT' ORDER BY id LOOP
    PERFORM public.purchase_receipt_cancel_draft(c.id); n_receipt:=n_receipt+1;
  END LOOP;
  -- Receipt cancellation owns linked draft-invoice lifecycle. Cancel receipts
  -- first so that the existing audited writer can cancel linked invoices and
  -- preserve receipt/invoice event semantics; this loop then handles only
  -- standalone drafts that remain.
  FOR c IN SELECT id FROM public.purchase_invoices WHERE outlet_id=p_outlet_id AND status='DRAFT' ORDER BY id FOR UPDATE LOOP
    UPDATE public.purchase_invoices SET status='CANCELLED',cancelled_by=a,cancelled_at=clock_timestamp(),updated_by=a,updated_at=clock_timestamp()
      WHERE id=c.id AND status='DRAFT';
    INSERT INTO public.purchase_invoice_events(invoice_id,event_type,actor_id,note)
      VALUES(c.id,'CANCELLED',a,'Draf dibatalkan untuk persiapan final iPos: '||why);
  END LOOP;
  FOR c IN SELECT id FROM public.manual_stock_corrections WHERE outlet_id=p_outlet_id AND status='DRAFT' ORDER BY id LOOP
    PERFORM public.cancel_manual_stock_correction(c.id,why); n_correction:=n_correction+1;
  END LOOP;
  FOR c IN SELECT id FROM public.supplier_returns WHERE outlet_id=p_outlet_id AND status='DRAFT' ORDER BY id LOOP
    PERFORM public.cancel_supplier_return(c.id,why); n_return:=n_return+1;
  END LOOP;
  FOR c IN SELECT id FROM public.inventory_cost_hpp_acceptance_batches WHERE outlet_id=p_outlet_id AND status='PREPARED' ORDER BY id LOOP
    PERFORM public.inventory_cost_hpp_invalidate_prepared(c.id,gen_random_uuid(),left('Superseded during go-live preparation: '||why,500)); n_hpp:=n_hpp+1;
  END LOOP;
  SELECT coalesce(jsonb_agg(jsonb_build_object('kind',kind,'count',cnt) ORDER BY kind),'[]'::jsonb) INTO manual FROM (
    SELECT 'posted_receipts' kind,count(*) cnt FROM public.purchase_receipts WHERE outlet_id=p_outlet_id AND status='POSTED' HAVING count(*)>0
    UNION ALL SELECT 'finalized_invoices',count(*) FROM public.purchase_invoices WHERE outlet_id=p_outlet_id AND status='FINALIZED' HAVING count(*)>0
    UNION ALL SELECT 'posted_returns',count(*) FROM public.supplier_returns WHERE outlet_id=p_outlet_id AND status='POSTED' HAVING count(*)>0
    UNION ALL SELECT 'posted_corrections',count(*) FROM public.manual_stock_corrections WHERE outlet_id=p_outlet_id AND status='POSTED' HAVING count(*)>0
    UNION ALL SELECT 'posted_opname_sessions',count(*) FROM public.stock_opname_sessions WHERE outlet_id=p_outlet_id AND status='POSTED' HAVING count(*)>0
    UNION ALL SELECT 'sales',count(*) FROM public.sales WHERE outlet_id=p_outlet_id HAVING count(*)>0
    UNION ALL SELECT 'cost_authority',count(*) FROM public.inventory_costing_outlet_authority WHERE outlet_id=p_outlet_id HAVING count(*)>0
    UNION ALL SELECT 'cost_projections',count(*) FROM public.inventory_cost_projections WHERE outlet_id=p_outlet_id HAVING count(*)>0
    UNION ALL SELECT 'cost_batches',count(*) FROM public.inventory_cost_event_batches WHERE outlet_id=p_outlet_id HAVING count(*)>0
    UNION ALL SELECT 'active_quantity_overrides',count(*) FROM public.product_field_overrides WHERE outlet_id=p_outlet_id AND field_key='quantity' AND is_active HAVING count(*)>0
    UNION ALL SELECT 'pending_stock_operations',count(*) FROM public.stock_operation_requests r WHERE r.state='PENDING'
      AND ((r.request_payload->>'outlet_id')=p_outlet_id::text OR EXISTS(SELECT 1 FROM public.stock_opname_sessions session_row
        WHERE session_row.id::text=r.request_payload->>'session_id' AND session_row.outlet_id=p_outlet_id)) HAVING count(*)>0
  ) m;
  SELECT coalesce(jsonb_agg(blocker ORDER BY blocker),'[]'::jsonb) INTO blockers FROM (
    SELECT 'OPEN_POS_CARTS'::text blocker WHERE EXISTS(SELECT 1 FROM public.pos_carts WHERE outlet_id=p_outlet_id AND status IN ('ACTIVE','PARKED'))
    UNION ALL SELECT 'OPEN_OPNAME' WHERE EXISTS(SELECT 1 FROM public.stock_opname_sessions WHERE outlet_id=p_outlet_id AND status IN ('COUNTING','REVIEW'))
    UNION ALL SELECT 'DRAFT_PURCHASING_OR_CORRECTIONS' WHERE EXISTS(SELECT 1 FROM public.purchase_receipts WHERE outlet_id=p_outlet_id AND status='DRAFT')
      OR EXISTS(SELECT 1 FROM public.purchase_invoices WHERE outlet_id=p_outlet_id AND status='DRAFT')
      OR EXISTS(SELECT 1 FROM public.manual_stock_corrections WHERE outlet_id=p_outlet_id AND status='DRAFT')
      OR EXISTS(SELECT 1 FROM public.supplier_returns WHERE outlet_id=p_outlet_id AND status='DRAFT')
    UNION ALL SELECT 'ACTIVE_HPP_BATCH' WHERE EXISTS(SELECT 1 FROM public.inventory_cost_hpp_acceptance_batches WHERE outlet_id=p_outlet_id AND status IN ('PREPARED','APPROVED','CONSUMED'))
    UNION ALL SELECT 'INCOMPLETE_CHECKOUT' WHERE EXISTS(SELECT 1 FROM public.pos_checkout_requests WHERE outlet_id=p_outlet_id AND completed_at IS NULL)
    UNION ALL SELECT 'ACTIVE_QUANTITY_OVERRIDE' WHERE EXISTS(SELECT 1 FROM public.product_field_overrides WHERE outlet_id=p_outlet_id AND field_key='quantity' AND is_active)
    UNION ALL SELECT 'COSTING_ALREADY_STARTED' WHERE EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE outlet_id=p_outlet_id)
      OR EXISTS(SELECT 1 FROM public.inventory_cost_projections WHERE outlet_id=p_outlet_id)
      OR EXISTS(SELECT 1 FROM public.inventory_cost_event_batches WHERE outlet_id=p_outlet_id)
    UNION ALL SELECT 'PENDING_STOCK_OPERATION' WHERE EXISTS(SELECT 1 FROM public.stock_operation_requests r WHERE r.state='PENDING'
      AND ((r.request_payload->>'outlet_id')=p_outlet_id::text OR EXISTS(SELECT 1 FROM public.stock_opname_sessions session_row
        WHERE session_row.id::text=r.request_payload->>'session_id' AND session_row.outlet_id=p_outlet_id)
        OR EXISTS(SELECT 1 FROM public.stock_movements sm WHERE sm.id::text=r.request_payload->>'movement_id' AND sm.outlet_id=p_outlet_id)
        OR EXISTS(SELECT 1 FROM public.purchase_receipts pr WHERE pr.id::text=r.request_payload->>'receipt_id' AND pr.outlet_id=p_outlet_id)
        OR EXISTS(SELECT 1 FROM public.manual_stock_corrections mc WHERE mc.id::text=r.request_payload->>'correction_id' AND mc.outlet_id=p_outlet_id)
        OR EXISTS(SELECT 1 FROM public.supplier_returns sr WHERE sr.id::text=r.request_payload->>'return_id' AND sr.outlet_id=p_outlet_id)))
  ) b;
  ready:=jsonb_array_length(blockers)=0 AND jsonb_array_length(manual)=0;
  out:=jsonb_build_object('ok',true,'code',CASE WHEN ready THEN 'READY_FOR_FINAL_IMPORT' ELSE 'MANUAL_REVIEW_REQUIRED' END,
    'outletId',p_outlet_id,'requestId',p_request_id,'cancelledDrafts',jsonb_build_object('carts',n_cart,'opname',n_opname,
      'receipts',n_receipt,'invoices',n_invoice,'manualCorrections',n_correction,'supplierReturns',n_return,'hppBatches',n_hpp),
    'remainingBlockers',blockers,'manualReviewItems',manual,'ready_for_final_import',ready,
    'preservedAuthProfilesOutletsSuppliersAndPostedEvidence',true);
  UPDATE public.go_live_reset_preparation_requests SET result=out,completed_at=clock_timestamp() WHERE request_id=p_request_id;
  RETURN out;
END;
$$;
ALTER FUNCTION public.go_live_reset_preparation(uuid,uuid,text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.go_live_reset_preparation(uuid,uuid,text,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.go_live_reset_preparation(uuid,uuid,text,text) TO authenticated;

COMMIT;
