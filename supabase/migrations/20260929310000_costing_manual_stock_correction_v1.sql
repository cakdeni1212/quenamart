-- C3C: controlled manual stock correction with optional atomic WAC costing.
-- Capability only: no stock operation, bootstrap, or authority transition runs here.
BEGIN;

ALTER TYPE public.inventory_cost_event_type ADD VALUE 'STOCK_CORRECTION';

CREATE TYPE public.manual_stock_correction_reason AS ENUM
  ('DAMAGED','LOST','FOUND','INPUT_ERROR','EXPIRED','OTHER');
CREATE TYPE public.manual_stock_correction_status AS ENUM ('DRAFT','POSTED','CANCELLED');

CREATE TABLE public.manual_stock_corrections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  correction_no text NOT NULL UNIQUE,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  status public.manual_stock_correction_status NOT NULL DEFAULT 'DRAFT',
  correction_at timestamptz NOT NULL DEFAULT now(),
  reason_category public.manual_stock_correction_reason NOT NULL,
  reason text NOT NULL CHECK (length(btrim(reason)) >= 3 AND length(reason) <= 1000),
  revision integer NOT NULL DEFAULT 1 CHECK (revision > 0),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  updated_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  posted_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  posted_at timestamptz,
  post_request_id uuid UNIQUE REFERENCES public.stock_operation_requests(request_id) ON DELETE RESTRICT,
  cancelled_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  cancelled_at timestamptz,
  cancellation_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT manual_stock_correction_state_valid CHECK (
    (status='DRAFT' AND posted_by IS NULL AND posted_at IS NULL AND post_request_id IS NULL
      AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_reason IS NULL)
    OR (status='POSTED' AND posted_by IS NOT NULL AND posted_at IS NOT NULL AND post_request_id IS NOT NULL
      AND cancelled_by IS NULL AND cancelled_at IS NULL)
    OR (status='CANCELLED' AND posted_by IS NULL AND posted_at IS NULL AND post_request_id IS NULL
      AND cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL AND cancellation_reason IS NOT NULL
      AND btrim(cancellation_reason)<>'')
  ),
  CONSTRAINT manual_stock_correction_id_outlet_unique UNIQUE(id,outlet_id)
);
CREATE INDEX manual_stock_corrections_outlet_status_time_idx
  ON public.manual_stock_corrections(outlet_id,status,correction_at DESC,id DESC);

CREATE TABLE public.manual_stock_correction_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  correction_id uuid NOT NULL REFERENCES public.manual_stock_corrections(id) ON DELETE RESTRICT,
  outlet_id uuid NOT NULL,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  quantity_delta numeric NOT NULL CHECK (quantity_delta<>0 AND quantity_delta=trunc(quantity_delta,3)
    AND quantity_delta > -100000000000 AND quantity_delta < 100000000000),
  note text CHECK (note IS NULL OR (btrim(note)<>'' AND length(note)<=500)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT manual_stock_correction_item_product_unique UNIQUE(correction_id,product_id),
  CONSTRAINT manual_stock_correction_item_identity_unique UNIQUE(id,correction_id,outlet_id,product_id),
  CONSTRAINT manual_stock_correction_item_outlet_fk FOREIGN KEY(correction_id,outlet_id)
    REFERENCES public.manual_stock_corrections(id,outlet_id) ON DELETE RESTRICT
);
CREATE INDEX manual_stock_correction_items_order_idx ON public.manual_stock_correction_items(correction_id,product_id);

CREATE TABLE public.manual_stock_correction_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  correction_id uuid NOT NULL REFERENCES public.manual_stock_corrections(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK(event_type IN ('CREATED','UPDATED','POSTED','CANCELLED')),
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  request_id uuid REFERENCES public.stock_operation_requests(request_id) ON DELETE RESTRICT,
  revision integer NOT NULL CHECK(revision>0),
  snapshot jsonb NOT NULL CHECK(jsonb_typeof(snapshot)='object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT manual_stock_correction_event_request_once UNIQUE(request_id)
);
CREATE INDEX manual_stock_correction_events_time_idx ON public.manual_stock_correction_events(correction_id,created_at,id);

ALTER TABLE public.stock_movements
  ADD COLUMN manual_stock_correction_id uuid,
  ADD COLUMN manual_stock_correction_item_id uuid,
  ADD CONSTRAINT stock_movement_manual_correction_shape CHECK (
    (manual_stock_correction_id IS NULL AND manual_stock_correction_item_id IS NULL)
    OR (manual_stock_correction_id IS NOT NULL AND manual_stock_correction_item_id IS NOT NULL
      AND movement_type IN ('MANUAL_IN','MANUAL_OUT') AND source_system='MANUAL')
  ),
  ADD CONSTRAINT stock_movement_manual_correction_item_fk FOREIGN KEY
    (manual_stock_correction_item_id,manual_stock_correction_id,outlet_id,product_id)
    REFERENCES public.manual_stock_correction_items(id,correction_id,outlet_id,product_id) ON DELETE RESTRICT;
CREATE UNIQUE INDEX stock_movement_manual_correction_item_once
  ON public.stock_movements(manual_stock_correction_item_id) WHERE manual_stock_correction_item_id IS NOT NULL;

ALTER TABLE public.inventory_cost_events
  ADD COLUMN manual_stock_correction_id uuid,
  ADD COLUMN manual_stock_correction_item_id uuid,
  ADD CONSTRAINT inventory_cost_event_manual_correction_shape CHECK (
    (manual_stock_correction_id IS NULL AND manual_stock_correction_item_id IS NULL)
    OR (manual_stock_correction_id IS NOT NULL AND manual_stock_correction_item_id IS NOT NULL
      AND source_stock_movement_id IS NOT NULL)
  ),
  ADD CONSTRAINT inventory_cost_event_manual_correction_fk FOREIGN KEY
    (manual_stock_correction_item_id,manual_stock_correction_id,outlet_id,product_id)
    REFERENCES public.manual_stock_correction_items(id,correction_id,outlet_id,product_id) ON DELETE RESTRICT;
CREATE UNIQUE INDEX inventory_cost_event_manual_correction_item_once
  ON public.inventory_cost_events(manual_stock_correction_item_id)
  WHERE manual_stock_correction_item_id IS NOT NULL;

ALTER TABLE public.inventory_cost_source_layers
  ADD COLUMN manual_stock_correction_id uuid,
  ADD COLUMN manual_stock_correction_item_id uuid,
  ADD CONSTRAINT inventory_cost_source_layer_manual_correction_shape CHECK (
    (manual_stock_correction_id IS NULL AND manual_stock_correction_item_id IS NULL)
    OR (manual_stock_correction_id IS NOT NULL AND manual_stock_correction_item_id IS NOT NULL
      AND source_stock_movement_id IS NOT NULL)
  ),
  ADD CONSTRAINT inventory_cost_source_layer_manual_correction_fk FOREIGN KEY
    (manual_stock_correction_item_id,manual_stock_correction_id,outlet_id,product_id)
    REFERENCES public.manual_stock_correction_items(id,correction_id,outlet_id,product_id) ON DELETE RESTRICT;

ALTER TABLE public.inventory_cost_layer_allocations
  DROP CONSTRAINT inventory_cost_layer_allocations_allocation_kind_check,
  ADD CONSTRAINT inventory_cost_layer_allocations_allocation_kind_check
    CHECK (allocation_kind = ANY (ARRAY['OPENING','PURCHASE_RECEIPT','OPNAME_GAIN','MANUAL_CORRECTION',
      'OUTFLOW_UNVALUED','OUTFLOW_VALUED','VALUATION_RESOLUTION','REVERSAL']));

ALTER TABLE public.inventory_cost_operation_requests
  DROP CONSTRAINT inventory_cost_operation_requests_operation_key_check,
  ADD CONSTRAINT inventory_cost_operation_requests_operation_key_check
    CHECK (operation_key IN ('BOOTSTRAP_OUTLET','PURCHASE_RECEIPT','OPNAME_ADJUSTMENT','REVERSAL','STOCK_CORRECTION'));

ALTER TABLE public.manual_stock_corrections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manual_stock_correction_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manual_stock_correction_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.manual_stock_corrections,public.manual_stock_correction_items,
  public.manual_stock_correction_events FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.manual_stock_corrections,public.manual_stock_correction_items,
  public.manual_stock_correction_events TO authenticated;
CREATE POLICY manual_stock_corrections_manager_read ON public.manual_stock_corrections
  FOR SELECT TO authenticated USING(public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY manual_stock_correction_items_manager_read ON public.manual_stock_correction_items
  FOR SELECT TO authenticated USING(public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY manual_stock_correction_events_manager_read ON public.manual_stock_correction_events
  FOR SELECT TO authenticated USING(public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
REVOKE ALL ON TYPE public.manual_stock_correction_reason,public.manual_stock_correction_status FROM PUBLIC,anon;
GRANT USAGE ON TYPE public.manual_stock_correction_reason,public.manual_stock_correction_status TO authenticated;

CREATE FUNCTION public.guard_manual_stock_correction_history()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Correction history cannot be deleted'; END IF;
  IF OLD.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Posted or cancelled correction is immutable'; END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.correction_no IS DISTINCT FROM OLD.correction_no
    OR NEW.outlet_id IS DISTINCT FROM OLD.outlet_id OR NEW.created_by IS DISTINCT FROM OLD.created_by
    OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Correction identity is immutable';
  END IF;
  RETURN NEW;
END; $$;
ALTER FUNCTION public.guard_manual_stock_correction_history() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_manual_stock_correction_history() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER manual_stock_correction_guard BEFORE UPDATE OR DELETE ON public.manual_stock_corrections
  FOR EACH ROW EXECUTE FUNCTION public.guard_manual_stock_correction_history();
CREATE TRIGGER manual_stock_correction_events_immutable BEFORE UPDATE OR DELETE ON public.manual_stock_correction_events
  FOR EACH ROW EXECUTE FUNCTION public.reject_stock_ledger_mutation();

CREATE FUNCTION public.guard_manual_stock_correction_item()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_status public.manual_stock_correction_status;
BEGIN
  SELECT status INTO v_status FROM public.manual_stock_corrections WHERE id=coalesce(NEW.correction_id,OLD.correction_id);
  IF v_status IS DISTINCT FROM 'DRAFT'::public.manual_stock_correction_status THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Only draft correction lines can change';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END; $$;
ALTER FUNCTION public.guard_manual_stock_correction_item() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_manual_stock_correction_item() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER manual_stock_correction_item_guard BEFORE INSERT OR UPDATE OR DELETE ON public.manual_stock_correction_items
  FOR EACH ROW EXECUTE FUNCTION public.guard_manual_stock_correction_item();

CREATE FUNCTION public.guard_manual_stock_correction_movement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE i public.manual_stock_correction_items%rowtype; d public.manual_stock_corrections%rowtype;
BEGIN
  IF NEW.manual_stock_correction_item_id IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO STRICT i FROM public.manual_stock_correction_items WHERE id=NEW.manual_stock_correction_item_id;
  SELECT * INTO STRICT d FROM public.manual_stock_corrections WHERE id=NEW.manual_stock_correction_id;
  IF i.correction_id<>d.id OR i.outlet_id<>NEW.outlet_id OR i.product_id<>NEW.product_id
    OR i.quantity_delta<>NEW.quantity_delta OR d.status<>'DRAFT'
    OR NEW.movement_type IS DISTINCT FROM (CASE WHEN i.quantity_delta>0 THEN 'MANUAL_IN'::public.stock_movement_type ELSE 'MANUAL_OUT'::public.stock_movement_type END)
    OR NEW.source_system<>'MANUAL' OR NEW.source_event_key<>i.id::text THEN
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Correction movement does not match its draft source line';
  END IF;
  RETURN NEW;
END; $$;
ALTER FUNCTION public.guard_manual_stock_correction_movement() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_manual_stock_correction_movement() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER manual_stock_correction_movement_guard BEFORE INSERT ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.guard_manual_stock_correction_movement();

CREATE FUNCTION public.guard_manual_stock_correction_cost_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE i public.manual_stock_correction_items%rowtype; d public.manual_stock_corrections%rowtype;
  m public.stock_movements%rowtype; b public.stock_movement_batches%rowtype;
BEGIN
  IF NEW.event_type<>'STOCK_CORRECTION' THEN RETURN NEW; END IF;
  SELECT * INTO STRICT i FROM public.manual_stock_correction_items WHERE id=NEW.manual_stock_correction_item_id;
  SELECT * INTO STRICT d FROM public.manual_stock_corrections WHERE id=NEW.manual_stock_correction_id;
  SELECT * INTO STRICT m FROM public.stock_movements WHERE id=NEW.source_stock_movement_id;
  SELECT * INTO STRICT b FROM public.stock_movement_batches WHERE id=m.batch_id;
  IF d.id<>i.correction_id OR d.status<>'DRAFT' OR i.outlet_id<>NEW.outlet_id OR i.product_id<>NEW.product_id
    OR i.quantity_delta<>NEW.physical_quantity_delta OR m.manual_stock_correction_id<>d.id
    OR m.manual_stock_correction_item_id<>i.id OR m.quantity_delta<>NEW.physical_quantity_delta
    OR m.created_by<>NEW.actor_id OR b.operation_request_id<>NEW.operation_request_id
    OR m.authority_period_id<>NEW.stock_authority_period_id OR m.balance_before<>NEW.physical_quantity_before
    OR m.balance_after<>NEW.physical_quantity_after THEN
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Cost event does not match manual correction stock evidence';
  END IF;
  RETURN NEW;
END; $$;
ALTER FUNCTION public.guard_manual_stock_correction_cost_event() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_manual_stock_correction_cost_event() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER manual_stock_correction_cost_event_guard BEFORE INSERT ON public.inventory_cost_events
  FOR EACH ROW EXECUTE FUNCTION public.guard_manual_stock_correction_cost_event();

CREATE FUNCTION public.inventory_cost_assert_manual_correction_allocation(p_event uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE e public.inventory_cost_events%rowtype; n bigint; ph numeric; va numeric; pr numeric; uv numeric;
BEGIN
  SELECT * INTO STRICT e FROM public.inventory_cost_events WHERE id=p_event;
  IF e.event_type<>'STOCK_CORRECTION' THEN RETURN; END IF;
  SELECT count(*),coalesce(sum(physical_quantity_delta),0),coalesce(sum(valued_quantity_delta),0),
    coalesce(sum(provisional_quantity_delta),0),coalesce(sum(unvalued_quantity_delta),0)
  INTO n,ph,va,pr,uv FROM public.inventory_cost_layer_allocations WHERE cost_event_id=p_event;
  IF n=0 OR ph IS DISTINCT FROM e.physical_quantity_delta OR va IS DISTINCT FROM e.valued_quantity_delta
    OR pr IS DISTINCT FROM e.provisional_quantity_delta OR uv IS DISTINCT FROM e.unvalued_quantity_delta THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Correction event and source-layer allocations do not reconcile';
  END IF;
END; $$;
ALTER FUNCTION public.inventory_cost_assert_manual_correction_allocation(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_assert_manual_correction_allocation(uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.inventory_cost_check_manual_correction_allocation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN PERFORM public.inventory_cost_assert_manual_correction_allocation(NEW.id); RETURN NULL; END; $$;
ALTER FUNCTION public.inventory_cost_check_manual_correction_allocation() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_check_manual_correction_allocation() FROM PUBLIC,anon,authenticated,service_role;
CREATE CONSTRAINT TRIGGER inventory_cost_manual_correction_allocation_consistent
  AFTER INSERT ON public.inventory_cost_events DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.inventory_cost_check_manual_correction_allocation();

CREATE FUNCTION public.manual_stock_correction_assert_manager()
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Authentication required'; END IF;
  v_role:=public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Manual stock correction requires OWNER or ADMIN';
  END IF;
  RETURN v_actor;
END; $$;
ALTER FUNCTION public.manual_stock_correction_assert_manager() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.manual_stock_correction_assert_manager() FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.create_manual_stock_correction(
  p_outlet_id uuid,p_reason_category text,p_reason text,p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=public.manual_stock_correction_assert_manager(); v_id uuid; v_no text; v_line record; v_count integer:=0;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.outlets WHERE id=p_outlet_id AND is_active) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Outlet is unavailable';
  END IF;
  IF p_reason_category NOT IN ('DAMAGED','LOST','FOUND','INPUT_ERROR','EXPIRED','OTHER')
    OR p_reason IS NULL OR length(btrim(p_reason))<3 OR length(p_reason)>1000
    OR (p_reason_category='OTHER' AND length(btrim(p_reason))<10) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='A correction category and meaningful reason are required';
  END IF;
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Correction requires 1 to 100 product lines';
  END IF;
  v_id:=gen_random_uuid(); v_no:='KRS-'||to_char(clock_timestamp(),'YYMMDD')||'-'||upper(substr(replace(v_id::text,'-',''),1,8));
  INSERT INTO public.manual_stock_corrections(id,correction_no,outlet_id,reason_category,reason,created_by,updated_by)
  VALUES(v_id,v_no,p_outlet_id,p_reason_category::public.manual_stock_correction_reason,btrim(p_reason),v_actor,v_actor);
  FOR v_line IN SELECT * FROM jsonb_to_recordset(p_lines) AS x(product_id uuid,quantity_delta numeric,note text)
    ORDER BY product_id LOOP
    IF v_line.product_id IS NULL OR v_line.quantity_delta IS NULL OR v_line.quantity_delta=0
      OR v_line.quantity_delta<>trunc(v_line.quantity_delta,3)
      OR abs(v_line.quantity_delta)>=100000000000
      OR (v_line.note IS NOT NULL AND (btrim(v_line.note)='' OR length(v_line.note)>500)) THEN
      RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid correction line';
    END IF;
    IF EXISTS(SELECT 1 FROM public.manual_stock_correction_items WHERE correction_id=v_id AND product_id=v_line.product_id) THEN
      RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Product appears more than once in correction';
    END IF;
    INSERT INTO public.manual_stock_correction_items(correction_id,outlet_id,product_id,quantity_delta,note)
    VALUES(v_id,p_outlet_id,v_line.product_id,v_line.quantity_delta,nullif(btrim(v_line.note),''));
    v_count:=v_count+1;
  END LOOP;
  IF v_count=0 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Correction has no valid lines'; END IF;
  INSERT INTO public.manual_stock_correction_events(correction_id,event_type,actor_id,revision,snapshot)
  VALUES(v_id,'CREATED',v_actor,1,jsonb_build_object('reasonCategory',p_reason_category,'reason',btrim(p_reason),
    'lines',(SELECT coalesce(jsonb_agg(jsonb_build_object('itemId',i.id,'productId',i.product_id,'quantityDelta',i.quantity_delta,'note',i.note) ORDER BY i.product_id),'[]')
      FROM public.manual_stock_correction_items i WHERE i.correction_id=v_id)));
  RETURN jsonb_build_object('ok',true,'id',v_id,'correctionNo',v_no,'status','DRAFT','revision',1);
END; $$;
ALTER FUNCTION public.create_manual_stock_correction(uuid,text,text,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.create_manual_stock_correction(uuid,text,text,jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.create_manual_stock_correction(uuid,text,text,jsonb) TO authenticated;

CREATE FUNCTION public.update_manual_stock_correction(
  p_id uuid,p_expected_revision integer,p_reason_category text,p_reason text,p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=public.manual_stock_correction_assert_manager(); v_doc public.manual_stock_corrections%rowtype;
  v_line record; v_count integer:=0;
BEGIN
  SELECT * INTO v_doc FROM public.manual_stock_corrections WHERE id=p_id FOR UPDATE;
  IF NOT FOUND OR v_doc.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Only draft corrections can be edited'; END IF;
  IF v_doc.revision<>p_expected_revision THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='Correction changed; reload before editing'; END IF;
  IF p_reason_category NOT IN ('DAMAGED','LOST','FOUND','INPUT_ERROR','EXPIRED','OTHER') OR p_reason IS NULL
    OR length(btrim(p_reason))<3 OR length(p_reason)>1000 OR (p_reason_category='OTHER' AND length(btrim(p_reason))<10)
    OR jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Correction reason or lines are invalid';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_to_recordset(p_lines) AS x(product_id uuid) GROUP BY product_id HAVING count(*)>1) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Product appears more than once in correction';
  END IF;
  UPDATE public.manual_stock_corrections SET reason_category=p_reason_category::public.manual_stock_correction_reason,
    reason=btrim(p_reason),revision=revision+1,updated_by=v_actor,updated_at=now() WHERE id=p_id;
  DELETE FROM public.manual_stock_correction_items i WHERE i.correction_id=p_id
    AND NOT EXISTS(SELECT 1 FROM jsonb_to_recordset(p_lines) AS x(product_id uuid) WHERE x.product_id=i.product_id);
  FOR v_line IN SELECT * FROM jsonb_to_recordset(p_lines) AS x(product_id uuid,quantity_delta numeric,note text) ORDER BY product_id LOOP
    IF v_line.product_id IS NULL OR v_line.quantity_delta IS NULL OR v_line.quantity_delta=0
      OR v_line.quantity_delta<>trunc(v_line.quantity_delta,3) OR abs(v_line.quantity_delta)>=100000000000
      OR (v_line.note IS NOT NULL AND (btrim(v_line.note)='' OR length(v_line.note)>500)) THEN
      RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid correction line';
    END IF;
    INSERT INTO public.manual_stock_correction_items(correction_id,outlet_id,product_id,quantity_delta,note)
    VALUES(p_id,v_doc.outlet_id,v_line.product_id,v_line.quantity_delta,nullif(btrim(v_line.note),''))
    ON CONFLICT(correction_id,product_id) DO UPDATE SET quantity_delta=excluded.quantity_delta,note=excluded.note,updated_at=now();
    v_count:=v_count+1;
  END LOOP;
  IF v_count=0 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Correction has no valid lines'; END IF;
  INSERT INTO public.manual_stock_correction_events(correction_id,event_type,actor_id,revision,snapshot)
  VALUES(p_id,'UPDATED',v_actor,v_doc.revision+1,jsonb_build_object('reasonCategory',p_reason_category,'reason',btrim(p_reason),
    'lines',(SELECT coalesce(jsonb_agg(jsonb_build_object('itemId',i.id,'productId',i.product_id,'quantityDelta',i.quantity_delta,'note',i.note) ORDER BY i.product_id),'[]')
      FROM public.manual_stock_correction_items i WHERE i.correction_id=p_id)));
  RETURN jsonb_build_object('ok',true,'id',p_id,'status','DRAFT','revision',v_doc.revision+1);
END; $$;
ALTER FUNCTION public.update_manual_stock_correction(uuid,integer,text,text,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.update_manual_stock_correction(uuid,integer,text,text,jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.update_manual_stock_correction(uuid,integer,text,text,jsonb) TO authenticated;

CREATE FUNCTION public.cancel_manual_stock_correction(p_id uuid,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=public.manual_stock_correction_assert_manager(); v_doc public.manual_stock_corrections%rowtype;
BEGIN
  SELECT * INTO v_doc FROM public.manual_stock_corrections WHERE id=p_id FOR UPDATE;
  IF NOT FOUND OR v_doc.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Only draft corrections can be cancelled'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason))<3 OR length(p_reason)>500 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Cancellation reason is required';
  END IF;
  UPDATE public.manual_stock_corrections SET status='CANCELLED',cancelled_by=v_actor,cancelled_at=now(),
    cancellation_reason=btrim(p_reason),updated_by=v_actor,updated_at=now(),revision=revision+1 WHERE id=p_id;
  INSERT INTO public.manual_stock_correction_events(correction_id,event_type,actor_id,revision,snapshot)
  VALUES(p_id,'CANCELLED',v_actor,v_doc.revision+1,jsonb_build_object('reason',btrim(p_reason)));
  RETURN jsonb_build_object('ok',true,'id',p_id,'status','CANCELLED');
END; $$;
ALTER FUNCTION public.cancel_manual_stock_correction(uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.cancel_manual_stock_correction(uuid,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.cancel_manual_stock_correction(uuid,text) TO authenticated;

CREATE FUNCTION public.inventory_cost_open_manual_correction_layer(p_event_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE e public.inventory_cost_events%rowtype; l uuid; q numeric;
BEGIN
  SELECT * INTO STRICT e FROM public.inventory_cost_events WHERE id=p_event_id;
  IF e.event_type<>'STOCK_CORRECTION' OR coalesce(e.physical_quantity_delta,e.quantity_delta,0)<=0
    OR e.valued_quantity_delta<>0 OR e.unvalued_quantity_delta<=0 THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Manual correction layer must represent positive unvalued stock';
  END IF;
  q:=e.physical_quantity_delta;
  INSERT INTO public.inventory_cost_source_layers(outlet_id,product_id,opening_cost_event_id,source_event_type,
    source_entity_type,source_entity_id,source_stock_movement_id,original_physical_quantity,original_valued_quantity,
    original_provisional_quantity,original_unvalued_quantity,valuation_basis,created_cost_version,created_by,
    manual_stock_correction_id,manual_stock_correction_item_id)
  VALUES(e.outlet_id,e.product_id,e.id,e.event_type,e.source_entity_type,e.source_entity_id,e.source_stock_movement_id,
    q,0,0,q,'UNVALUED',e.cost_version_after,e.actor_id,e.manual_stock_correction_id,e.manual_stock_correction_item_id)
  RETURNING id INTO l;
  INSERT INTO public.inventory_cost_source_layer_balances(layer_id,outlet_id,product_id,remaining_valued_quantity,
    remaining_provisional_quantity,remaining_unvalued_quantity,state,last_cost_version,last_cost_event_id)
  VALUES(l,e.outlet_id,e.product_id,0,0,q,'ACTIVE',e.cost_version_after,e.id);
  INSERT INTO public.inventory_cost_layer_allocations(cost_event_id,source_layer_id,outlet_id,product_id,
    stock_movement_id,allocation_kind,physical_quantity_delta,valued_quantity_delta,provisional_quantity_delta,
    unvalued_quantity_delta,cost_version,request_id,actor_id)
  VALUES(e.id,l,e.outlet_id,e.product_id,e.source_stock_movement_id,'MANUAL_CORRECTION',q,0,0,q,
    e.cost_version_after,e.operation_request_id,e.actor_id);
  RETURN l;
END; $$;
ALTER FUNCTION public.inventory_cost_open_manual_correction_layer(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_open_manual_correction_layer(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.inventory_cost_apply_manual_correction(p_request_id uuid,p_correction_id uuid,p_batch_id uuid,p_period_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=auth.uid(); role public.user_role; doc public.manual_stock_corrections%rowtype;
  req public.inventory_cost_operation_requests%rowtype; cost public.inventory_cost_projections%rowtype;
  m record; ev uuid; cb uuid; vdel numeric; vqty numeric; pqty numeric; uqty numeric; unvalued numeric; valued numeric;
  pu jsonb; pv jsonb; plan jsonb; val numeric; valafter numeric; wac numeric; stat public.inventory_cost_projection_status;
  batch uuid; n integer:=0; pr numeric; payloadhash text;
BEGIN
  IF a IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Authentication required'; END IF;
  role:=public.current_active_user_role();
  IF role IS NULL OR role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Manual correction costing requires OWNER or ADMIN'; END IF;
  SELECT * INTO STRICT doc FROM public.manual_stock_corrections WHERE id=p_correction_id;
  IF NOT EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE outlet_id=doc.outlet_id AND status='WAC_ACTIVE') THEN RETURN 0; END IF;
  payloadhash:=md5(jsonb_build_object('request',p_request_id,'correction',p_correction_id,'batch',p_batch_id,'period',p_period_id)::text);
  SELECT * INTO req FROM public.inventory_cost_operation_requests WHERE request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF req.actor_id<>a OR req.operation_key<>'STOCK_CORRECTION' OR req.target_key<>p_correction_id::text OR req.payload_hash<>payloadhash THEN
      RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Cost correction request identity mismatch';
    END IF;
    IF req.result IS NOT NULL THEN RETURN coalesce((req.result->>'eventCount')::integer,0); END IF;
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Cost correction request is incomplete';
  END IF;
  INSERT INTO public.inventory_cost_operation_requests(request_id,actor_id,operation_key,target_key,payload_hash)
  VALUES(p_request_id,a,'STOCK_CORRECTION',p_correction_id::text,payloadhash);
  FOR m IN SELECT i.product_id FROM public.manual_stock_correction_items i WHERE i.correction_id=p_correction_id ORDER BY i.product_id LOOP
    SELECT * INTO cost FROM public.inventory_cost_projections WHERE outlet_id=doc.outlet_id AND product_id=m.product_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Active costing projection is missing'; END IF;
  END LOOP;
  FOR m IN SELECT b.product_id,b.layer_id FROM public.inventory_cost_source_layer_balances b
    WHERE b.outlet_id=doc.outlet_id AND b.product_id IN(SELECT product_id FROM public.manual_stock_correction_items WHERE correction_id=p_correction_id)
    ORDER BY b.product_id,b.layer_id LOOP
    PERFORM 1 FROM public.inventory_cost_source_layer_balances WHERE layer_id=m.layer_id FOR UPDATE;
  END LOOP;
  INSERT INTO public.inventory_cost_event_batches(outlet_id,batch_type,source_entity_type,source_entity_id,
    operation_request_id,allocation_method,created_by)
  VALUES(doc.outlet_id,'STOCK_CORRECTION','MANUAL_STOCK_CORRECTION',doc.id,p_request_id,
    'UNVALUED_FIRST_THEN_PROPORTIONAL_SOURCE_QUANTITY',a) RETURNING id INTO cb;
  FOR m IN SELECT i.*,sm.id movement_id,sm.quantity_delta,sm.balance_before,sm.balance_after
    FROM public.manual_stock_correction_items i JOIN public.stock_movements sm ON sm.manual_stock_correction_item_id=i.id
    WHERE i.correction_id=p_correction_id ORDER BY i.product_id LOOP
    SELECT * INTO STRICT cost FROM public.inventory_cost_projections WHERE outlet_id=doc.outlet_id AND product_id=m.product_id;
    IF cost.physical_quantity IS DISTINCT FROM m.balance_before THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='Stock and costing projections are out of sync'; END IF;
    ev:=gen_random_uuid(); pu:='[]';pv:='[]';vdel:=0;vqty:=0;pqty:=0;uqty:=0;val:=CASE WHEN cost.valued_quantity>0 THEN 0 ELSE NULL END;
    IF m.quantity_delta>0 THEN
      uqty:=m.quantity_delta;
    ELSE
      unvalued:=least(abs(m.quantity_delta),cost.unvalued_quantity); valued:=abs(m.quantity_delta)-unvalued;
      IF valued>cost.valued_quantity THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Correction would remove more stock than available valued and unvalued quantity'; END IF;
      IF unvalued>0 THEN pu:=public.inventory_cost_build_layer_outflow_plan(doc.outlet_id,m.product_id,unvalued,'UNVALUED'); uqty:=-unvalued; END IF;
      IF valued>0 THEN
        pv:=public.inventory_cost_build_layer_outflow_plan(doc.outlet_id,m.product_id,valued,'VALUED');
        SELECT -coalesce(sum((x->>'provisional')::numeric),0) INTO pqty FROM jsonb_array_elements(pv) x;
        vqty:=-valued;
        val:=CASE WHEN valued=cost.valued_quantity THEN -coalesce(cost.inventory_value,0) ELSE -round(valued*cost.current_wac,8) END;
      END IF;
    END IF;
    valafter:=CASE WHEN cost.valued_quantity+vqty=0 THEN CASE WHEN m.balance_after=0 THEN 0 ELSE NULL END ELSE coalesce(cost.inventory_value,0)+val END;
    wac:=CASE WHEN cost.valued_quantity+vqty>0 THEN round(valafter/(cost.valued_quantity+vqty),8)::numeric(20,8) ELSE NULL END;
    stat:=CASE WHEN m.balance_after=0 THEN 'VALUED'::public.inventory_cost_projection_status
      WHEN cost.valued_quantity+vqty=0 THEN 'UNVALUED'::public.inventory_cost_projection_status
      WHEN cost.unvalued_quantity+uqty>0 THEN 'PARTIALLY_UNVALUED'::public.inventory_cost_projection_status
      WHEN cost.provisional_quantity+pqty>0 THEN 'PROVISIONAL'::public.inventory_cost_projection_status ELSE 'VALUED'::public.inventory_cost_projection_status END;
    INSERT INTO public.inventory_cost_events(id,batch_id,outlet_id,product_id,event_type,source_entity_type,source_entity_id,
      quantity_delta,valued_quantity_before,valued_quantity_delta,valued_quantity_after,inventory_value_delta,inventory_value_before,
      inventory_value_after,wac_before,wac_after,valuation_status_before,valuation_status_after,cost_version_before,cost_version_after,
      stock_balance_version,stock_authority_period_id,actor_id,operation_request_id,physical_quantity_delta,physical_quantity_before,
      physical_quantity_after,provisional_quantity_delta,provisional_quantity_before,provisional_quantity_after,unvalued_quantity_delta,
      unvalued_quantity_before,unvalued_quantity_after,source_stock_movement_id,manual_stock_correction_id,
      manual_stock_correction_item_id,valuation_basis,frozen_unit_cost,basis_cost_event_id,metadata)
    VALUES(ev,cb,doc.outlet_id,m.product_id,'STOCK_CORRECTION','MANUAL_STOCK_CORRECTION_LINE',m.id,m.quantity_delta,
      cost.valued_quantity,vqty,cost.valued_quantity+vqty,val,cost.inventory_value,valafter,cost.current_wac,wac,
      cost.valuation_status,stat,cost.cost_version,cost.cost_version+1,
      (SELECT balance_version FROM public.stock_balance_projection WHERE outlet_id=doc.outlet_id AND product_id=m.product_id),
      p_period_id,a,p_request_id,m.quantity_delta,m.balance_before,m.balance_after,pqty,cost.provisional_quantity,
      cost.provisional_quantity+pqty,uqty,cost.unvalued_quantity,cost.unvalued_quantity+uqty,m.movement_id,
      doc.id,m.id,CASE WHEN vqty<0 THEN 'CURRENT_WAC'::public.inventory_cost_acquisition_basis ELSE 'UNVALUED'::public.inventory_cost_acquisition_basis END,
      CASE WHEN vqty<0 THEN cost.current_wac ELSE NULL END,CASE WHEN vqty<0 THEN cost.last_cost_event_id ELSE NULL END,
      jsonb_build_object('allocationMethod','UNVALUED_FIRST_THEN_PROPORTIONAL','sourceValuesAreNotCarryingValues',true));
    IF m.quantity_delta>0 THEN PERFORM public.inventory_cost_open_manual_correction_layer(ev);
    ELSE
      IF pu<>'[]' THEN PERFORM * FROM public.inventory_cost_apply_layer_plan(ev,m.movement_id,p_request_id,a,cost.cost_version+1,'OUTFLOW_UNVALUED',pu); END IF;
      IF pv<>'[]' THEN PERFORM * FROM public.inventory_cost_apply_layer_plan(ev,m.movement_id,p_request_id,a,cost.cost_version+1,'OUTFLOW_VALUED',pv); END IF;
    END IF;
    UPDATE public.inventory_cost_projections SET physical_quantity=m.balance_after,valued_quantity=cost.valued_quantity+vqty,
      provisional_quantity=cost.provisional_quantity+pqty,unvalued_quantity=cost.unvalued_quantity+uqty,
      inventory_value=valafter,current_wac=wac,valuation_status=stat,cost_version=cost.cost_version+1,
      stock_balance_version=(SELECT balance_version FROM public.stock_balance_projection WHERE outlet_id=doc.outlet_id AND product_id=m.product_id),
      stock_authority_period_id=p_period_id,last_cost_event_id=ev,updated_at=now()
    WHERE outlet_id=doc.outlet_id AND product_id=m.product_id;
    n:=n+1;
  END LOOP;
  IF n=0 THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Correction has no posted movements'; END IF;
  UPDATE public.inventory_cost_operation_requests SET result=jsonb_build_object('ok',true,'eventCount',n,'correctionId',doc.id),completed_at=now()
    WHERE request_id=p_request_id;
  RETURN n;
END; $$;
ALTER FUNCTION public.inventory_cost_apply_manual_correction(uuid,uuid,uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_apply_manual_correction(uuid,uuid,uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.post_manual_stock_correction(p_id uuid,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=public.manual_stock_correction_assert_manager(); doc public.manual_stock_corrections%rowtype;
  req public.stock_operation_requests%rowtype; line record; proj public.stock_balance_projection%rowtype;
  period public.stock_authority_periods%rowtype; authority public.inventory_cost_authority_status; hash text;
  batch uuid; movement uuid; before_qty numeric; after_qty numeric; new_version bigint; v_result jsonb; count_lines integer:=0;
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Request identity is required'; END IF;
  SELECT outlet_id INTO doc.outlet_id FROM public.manual_stock_corrections WHERE id=p_id;
  IF doc.outlet_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Correction is unavailable'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_BOOTSTRAP_OUTLET:'||doc.outlet_id::text,73190411));
  SELECT * INTO STRICT doc FROM public.manual_stock_corrections WHERE id=p_id FOR UPDATE;
  authority:=NULL;
  SELECT status INTO authority FROM public.inventory_costing_outlet_authority WHERE outlet_id=doc.outlet_id;
  IF authority='BOOTSTRAP_READY' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Perubahan stok ditahan selama persiapan awal costing berlangsung'; END IF;
  SELECT * INTO req FROM public.stock_operation_requests WHERE request_id=p_request_id AND actor_id=a FOR UPDATE;
  IF FOUND AND req.state<>'PENDING' THEN
    IF req.operation_key<>'POST_CORRECTION' OR req.target_key<>p_id::text THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Request identity mismatch'; END IF;
    RETURN req.result;
  END IF;
  IF doc.status='POSTED' THEN
    IF doc.post_request_id=p_request_id AND FOUND THEN RETURN req.result; END IF;
    RAISE EXCEPTION USING ERRCODE='23505',MESSAGE='Correction is already posted';
  END IF;
  IF doc.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Only draft corrections can be posted'; END IF;
  hash:=md5(jsonb_build_object('correction',p_id,'revision',doc.revision,
    'lines',(SELECT jsonb_agg(jsonb_build_object('id',i.id,'product',i.product_id,'delta',i.quantity_delta) ORDER BY i.product_id)
      FROM public.manual_stock_correction_items i WHERE i.correction_id=p_id))::text);
  IF FOUND THEN
    IF req.operation_key<>'POST_CORRECTION' OR req.target_key<>p_id::text OR req.payload_hash<>hash OR req.request_payload->>'correction_id'<>p_id::text
      THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Correction request payload changed'; END IF;
  ELSE
    INSERT INTO public.stock_operation_requests(request_id,actor_id,operation_key,target_key,request_payload,payload_hash)
    VALUES(p_request_id,a,'POST_CORRECTION',p_id::text,jsonb_build_object('correction_id',p_id,'revision',doc.revision),hash);
  END IF;
  FOR line IN SELECT product_id FROM public.manual_stock_correction_items WHERE correction_id=p_id ORDER BY product_id LOOP
    SELECT * INTO proj FROM public.stock_balance_projection WHERE outlet_id=doc.outlet_id AND product_id=line.product_id FOR UPDATE;
    IF NOT FOUND OR proj.effective_quantity IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Stok produk belum tersedia'; END IF;
    IF EXISTS(SELECT 1 FROM public.manual_stock_correction_items i WHERE i.correction_id=p_id AND i.product_id=line.product_id
      AND proj.effective_quantity+i.quantity_delta<0) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Koreksi tidak dapat membuat stok menjadi negatif'; END IF;
  END LOOP;
  SELECT * INTO period FROM public.stock_authority_periods WHERE outlet_id=doc.outlet_id AND ended_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Periode otoritas stok tidak tersedia'; END IF;
  IF authority='WAC_ACTIVE' THEN
    FOR line IN SELECT product_id FROM public.manual_stock_correction_items WHERE correction_id=p_id ORDER BY product_id LOOP
      PERFORM 1 FROM public.inventory_cost_projections WHERE outlet_id=doc.outlet_id AND product_id=line.product_id FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Proyeksi costing aktif tidak tersedia'; END IF;
    END LOOP;
    FOR line IN SELECT b.layer_id FROM public.inventory_cost_source_layer_balances b WHERE b.outlet_id=doc.outlet_id
      AND b.product_id IN(SELECT product_id FROM public.manual_stock_correction_items WHERE correction_id=p_id) ORDER BY b.product_id,b.layer_id LOOP
      PERFORM 1 FROM public.inventory_cost_source_layer_balances WHERE layer_id=line.layer_id FOR UPDATE;
    END LOOP;
  END IF;
  INSERT INTO public.stock_movement_batches(authority_period_id,outlet_id,source_system,operation_request_id,created_by)
  VALUES(period.id,doc.outlet_id,'MANUAL',p_request_id,a) RETURNING id INTO batch;
  FOR line IN SELECT i.* FROM public.manual_stock_correction_items i WHERE i.correction_id=p_id ORDER BY i.product_id LOOP
    SELECT d.balance_before,d.balance_after,d.new_balance_version INTO before_qty,after_qty,new_version
      FROM public.stock_apply_balance_delta(line.product_id,doc.outlet_id,line.quantity_delta) d;
    INSERT INTO public.stock_movements(batch_id,authority_period_id,outlet_id,product_id,movement_type,source_system,
      quantity_delta,balance_before,balance_after,source_reference,source_event_key,manual_stock_correction_id,
      manual_stock_correction_item_id,created_by)
    VALUES(batch,period.id,doc.outlet_id,line.product_id,CASE WHEN line.quantity_delta>0 THEN 'MANUAL_IN'::public.stock_movement_type
      ELSE 'MANUAL_OUT'::public.stock_movement_type END,'MANUAL',line.quantity_delta,before_qty,after_qty,
      doc.reason_category::text||': '||doc.reason,line.id::text,doc.id,line.id,a) RETURNING id INTO movement;
    INSERT INTO public.stock_balance_projection_events(product_id,outlet_id,authority_period_id,event_type,request_id,
      quantity_delta,balance_before,balance_after,balance_version,actor_id)
    VALUES(line.product_id,doc.outlet_id,period.id,'MOVEMENT_POSTED',p_request_id,line.quantity_delta,before_qty,after_qty,new_version,a);
    count_lines:=count_lines+1;
  END LOOP;
  IF authority='WAC_ACTIVE' THEN PERFORM public.inventory_cost_apply_manual_correction(p_request_id,p_id,batch,period.id); END IF;
  UPDATE public.manual_stock_corrections SET status='POSTED',posted_by=a,posted_at=now(),post_request_id=p_request_id,
    updated_by=a,updated_at=now() WHERE id=p_id;
  v_result:=jsonb_build_object('ok',true,'correctionId',p_id,'correctionNo',doc.correction_no,'status','POSTED','movementBatchId',batch,'lineCount',count_lines);
  UPDATE public.stock_operation_requests SET state='COMPLETED',result=v_result,completed_at=now() WHERE request_id=p_request_id;
  INSERT INTO public.manual_stock_correction_events(correction_id,event_type,actor_id,request_id,revision,snapshot)
  VALUES(p_id,'POSTED',a,p_request_id,doc.revision,jsonb_build_object('movementBatchId',batch,'lineCount',count_lines));
  RETURN v_result;
END; $$;
ALTER FUNCTION public.post_manual_stock_correction(uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.post_manual_stock_correction(uuid,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.post_manual_stock_correction(uuid,uuid) TO authenticated;

COMMIT;
