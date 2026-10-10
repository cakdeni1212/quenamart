-- C3D: supplier return workflow with stock and optional aggregate-WAC costing.
-- Capability only: this migration does not create operational data or change authority.
BEGIN;

CREATE TYPE public.supplier_return_reason AS ENUM
  ('DAMAGED','WRONG_ITEM','EXCESS','DEFECTIVE','EXPIRED','SUPPLIER_REQUEST','OTHER');
CREATE TYPE public.supplier_return_status AS ENUM ('DRAFT','POSTED','CANCELLED');

-- Composite source identity allows a return line to refer to a real posted
-- receipt item for the same product, without requiring legacy returns to link.
ALTER TABLE public.purchase_receipt_items
  ADD CONSTRAINT purchase_receipt_item_return_identity UNIQUE(id,receipt_id,product_id);

CREATE TABLE public.supplier_returns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  return_no text NOT NULL UNIQUE,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  supplier_id uuid NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  status public.supplier_return_status NOT NULL DEFAULT 'DRAFT',
  return_at timestamptz NOT NULL DEFAULT now(),
  reason_category public.supplier_return_reason NOT NULL,
  reason text NOT NULL CHECK(length(btrim(reason))>=3 AND length(reason)<=1000),
  note text CHECK(note IS NULL OR (btrim(note)<>'' AND length(note)<=1000)),
  revision integer NOT NULL DEFAULT 1 CHECK(revision>0),
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
  CONSTRAINT supplier_return_state_valid CHECK (
    (status='DRAFT' AND posted_by IS NULL AND posted_at IS NULL AND post_request_id IS NULL
      AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_reason IS NULL)
    OR (status='POSTED' AND posted_by IS NOT NULL AND posted_at IS NOT NULL AND post_request_id IS NOT NULL
      AND cancelled_by IS NULL AND cancelled_at IS NULL)
    OR (status='CANCELLED' AND posted_by IS NULL AND posted_at IS NULL AND post_request_id IS NULL
      AND cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL AND cancellation_reason IS NOT NULL
      AND btrim(cancellation_reason)<>'')
  ),
  CONSTRAINT supplier_return_identity UNIQUE(id,outlet_id,supplier_id)
);
CREATE INDEX supplier_returns_outlet_status_time_idx
  ON public.supplier_returns(outlet_id,status,created_at DESC,id DESC);
CREATE INDEX supplier_returns_supplier_time_idx
  ON public.supplier_returns(supplier_id,created_at DESC,id DESC);

CREATE TABLE public.supplier_return_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  return_id uuid NOT NULL,
  outlet_id uuid NOT NULL,
  supplier_id uuid NOT NULL,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  quantity numeric NOT NULL CHECK(quantity>0 AND quantity=trunc(quantity,3)
    AND quantity<100000000000),
  source_receipt_id uuid,
  source_receipt_item_id uuid,
  note text CHECK(note IS NULL OR (btrim(note)<>'' AND length(note)<=500)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT supplier_return_item_source_shape CHECK(
    (source_receipt_id IS NULL AND source_receipt_item_id IS NULL)
    OR (source_receipt_id IS NOT NULL AND source_receipt_item_id IS NOT NULL)),
  CONSTRAINT supplier_return_item_parent_fk FOREIGN KEY(return_id,outlet_id,supplier_id)
    REFERENCES public.supplier_returns(id,outlet_id,supplier_id) ON DELETE RESTRICT,
  CONSTRAINT supplier_return_item_source_fk FOREIGN KEY(source_receipt_item_id,source_receipt_id,product_id)
    REFERENCES public.purchase_receipt_items(id,receipt_id,product_id) ON DELETE RESTRICT,
  CONSTRAINT supplier_return_item_identity UNIQUE(id,return_id,outlet_id,product_id,supplier_id),
  CONSTRAINT supplier_return_item_movement_identity UNIQUE(id,return_id,outlet_id,product_id),
  CONSTRAINT supplier_return_item_product_unique UNIQUE(return_id,product_id)
);
CREATE INDEX supplier_return_items_source_idx
  ON public.supplier_return_items(source_receipt_item_id,return_id)
  WHERE source_receipt_item_id IS NOT NULL;
CREATE INDEX supplier_return_items_order_idx ON public.supplier_return_items(return_id,product_id,id);

CREATE TABLE public.supplier_return_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  return_id uuid NOT NULL REFERENCES public.supplier_returns(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK(event_type IN ('CREATED','UPDATED','POSTED','CANCELLED')),
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  request_id uuid REFERENCES public.stock_operation_requests(request_id) ON DELETE RESTRICT,
  revision integer NOT NULL CHECK(revision>0),
  snapshot jsonb NOT NULL CHECK(jsonb_typeof(snapshot)='object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT supplier_return_event_request_once UNIQUE(request_id)
);
CREATE INDEX supplier_return_events_time_idx ON public.supplier_return_events(return_id,created_at,id);

ALTER TABLE public.stock_movements
  ADD COLUMN supplier_return_id uuid,
  ADD COLUMN supplier_return_item_id uuid,
  ADD CONSTRAINT stock_movement_supplier_return_shape CHECK(
    (supplier_return_id IS NULL AND supplier_return_item_id IS NULL)
    OR (supplier_return_id IS NOT NULL AND supplier_return_item_id IS NOT NULL
      AND movement_type='SUPPLIER_RETURN' AND source_system='PURCHASING')),
  ADD CONSTRAINT stock_movement_supplier_return_item_fk FOREIGN KEY
    (supplier_return_item_id,supplier_return_id,outlet_id,product_id)
    REFERENCES public.supplier_return_items(id,return_id,outlet_id,product_id) ON DELETE RESTRICT;
CREATE UNIQUE INDEX stock_movement_supplier_return_item_once
  ON public.stock_movements(supplier_return_item_id) WHERE supplier_return_item_id IS NOT NULL;

ALTER TABLE public.inventory_cost_events
  ADD COLUMN supplier_return_id uuid,
  ADD COLUMN supplier_return_item_id uuid,
  ADD COLUMN supplier_id uuid REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  ADD COLUMN source_receipt_id uuid,
  ADD COLUMN source_receipt_item_id uuid,
  ADD CONSTRAINT inventory_cost_event_supplier_return_shape CHECK(
    (supplier_return_id IS NULL AND supplier_return_item_id IS NULL AND supplier_id IS NULL)
    OR (supplier_return_id IS NOT NULL AND supplier_return_item_id IS NOT NULL AND supplier_id IS NOT NULL
      AND source_stock_movement_id IS NOT NULL)),
  ADD CONSTRAINT inventory_cost_event_supplier_return_fk FOREIGN KEY
    (supplier_return_item_id,supplier_return_id,outlet_id,product_id,supplier_id)
    REFERENCES public.supplier_return_items(id,return_id,outlet_id,product_id,supplier_id) ON DELETE RESTRICT,
  ADD CONSTRAINT inventory_cost_event_supplier_receipt_fk FOREIGN KEY
    (source_receipt_item_id,source_receipt_id,product_id)
    REFERENCES public.purchase_receipt_items(id,receipt_id,product_id) ON DELETE RESTRICT;
CREATE UNIQUE INDEX inventory_cost_event_supplier_return_item_once
  ON public.inventory_cost_events(supplier_return_item_id)
  WHERE supplier_return_item_id IS NOT NULL;

ALTER TABLE public.inventory_cost_layer_allocations
  DROP CONSTRAINT inventory_cost_layer_allocations_allocation_kind_check,
  ADD CONSTRAINT inventory_cost_layer_allocations_allocation_kind_check CHECK(allocation_kind=ANY(ARRAY[
    'OPENING','PURCHASE_RECEIPT','OPNAME_GAIN','MANUAL_CORRECTION','SUPPLIER_RETURN',
    'OUTFLOW_UNVALUED','OUTFLOW_VALUED','VALUATION_RESOLUTION','REVERSAL']));
ALTER TABLE public.inventory_cost_operation_requests
  DROP CONSTRAINT inventory_cost_operation_requests_operation_key_check,
  ADD CONSTRAINT inventory_cost_operation_requests_operation_key_check
    CHECK(operation_key IN ('BOOTSTRAP_OUTLET','PURCHASE_RECEIPT','OPNAME_ADJUSTMENT','REVERSAL',
      'STOCK_CORRECTION','SUPPLIER_RETURN'));

ALTER TABLE public.supplier_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_return_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_return_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.supplier_returns,public.supplier_return_items,public.supplier_return_events
  FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.supplier_returns,public.supplier_return_items,public.supplier_return_events TO authenticated;
CREATE POLICY supplier_returns_operational_read ON public.supplier_returns FOR SELECT TO authenticated
  USING(public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'GUDANG'::public.user_role));
CREATE POLICY supplier_return_items_operational_read ON public.supplier_return_items FOR SELECT TO authenticated
  USING(public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'GUDANG'::public.user_role));
CREATE POLICY supplier_return_events_operational_read ON public.supplier_return_events FOR SELECT TO authenticated
  USING(public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'GUDANG'::public.user_role));
REVOKE ALL ON TYPE public.supplier_return_reason,public.supplier_return_status FROM PUBLIC,anon;
GRANT USAGE ON TYPE public.supplier_return_reason,public.supplier_return_status TO authenticated;

CREATE FUNCTION public.guard_supplier_return_history()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Supplier return history cannot be deleted'; END IF;
  IF OLD.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Posted or cancelled supplier return is immutable'; END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.return_no IS DISTINCT FROM OLD.return_no
    OR NEW.outlet_id IS DISTINCT FROM OLD.outlet_id OR NEW.supplier_id IS DISTINCT FROM OLD.supplier_id
    OR NEW.created_by IS DISTINCT FROM OLD.created_by OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Supplier return identity is immutable';
  END IF;
  RETURN NEW;
END; $$;
ALTER FUNCTION public.guard_supplier_return_history() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_supplier_return_history() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER supplier_return_guard BEFORE UPDATE OR DELETE ON public.supplier_returns
  FOR EACH ROW EXECUTE FUNCTION public.guard_supplier_return_history();
CREATE TRIGGER supplier_return_events_immutable BEFORE UPDATE OR DELETE ON public.supplier_return_events
  FOR EACH ROW EXECUTE FUNCTION public.reject_stock_ledger_mutation();

CREATE FUNCTION public.guard_supplier_return_item()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_status public.supplier_return_status;
BEGIN
  SELECT status INTO v_status FROM public.supplier_returns WHERE id=coalesce(NEW.return_id,OLD.return_id);
  IF v_status IS DISTINCT FROM 'DRAFT'::public.supplier_return_status THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Only draft supplier return lines can change';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END; $$;
ALTER FUNCTION public.guard_supplier_return_item() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_supplier_return_item() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER supplier_return_item_guard BEFORE INSERT OR UPDATE OR DELETE ON public.supplier_return_items
  FOR EACH ROW EXECUTE FUNCTION public.guard_supplier_return_item();

CREATE FUNCTION public.supplier_return_assert_editor()
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Authentication required'; END IF;
  v_role:=public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'GUDANG'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Supplier return access denied';
  END IF;
  RETURN v_actor;
END; $$;
ALTER FUNCTION public.supplier_return_assert_editor() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.supplier_return_assert_editor() FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.supplier_return_assert_manager()
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Authentication required'; END IF;
  v_role:=public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Posting supplier return requires OWNER or ADMIN';
  END IF;
  RETURN v_actor;
END; $$;
ALTER FUNCTION public.supplier_return_assert_manager() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.supplier_return_assert_manager() FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.supplier_return_validate_reason(p_category text,p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  IF p_category NOT IN ('DAMAGED','WRONG_ITEM','EXCESS','DEFECTIVE','EXPIRED','SUPPLIER_REQUEST','OTHER')
    OR p_reason IS NULL OR length(btrim(p_reason))<3 OR length(p_reason)>1000
    OR (p_category='OTHER' AND length(btrim(p_reason))<10) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Supplier return reason is required and must be meaningful';
  END IF;
END; $$;
ALTER FUNCTION public.supplier_return_validate_reason(text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.supplier_return_validate_reason(text,text) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.create_supplier_return(
  p_outlet_id uuid,p_supplier_id uuid,p_reason_category text,p_reason text,p_note text,p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=public.supplier_return_assert_editor(); rid uuid; rno text; x record; n integer:=0;
BEGIN
  PERFORM public.supplier_return_validate_reason(p_reason_category,p_reason);
  IF NOT EXISTS(SELECT 1 FROM public.outlets WHERE id=p_outlet_id AND is_active)
    OR NOT EXISTS(SELECT 1 FROM public.suppliers WHERE id=p_supplier_id AND is_active) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Outlet or supplier is unavailable';
  END IF;
  IF p_note IS NOT NULL AND (btrim(p_note)='' OR length(p_note)>1000) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid return note'; END IF;
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Supplier return requires 1 to 100 product lines';
  END IF;
  rid:=gen_random_uuid(); rno:='RT-'||to_char(clock_timestamp(),'YYMMDD')||'-'||upper(substr(replace(rid::text,'-',''),1,8));
  INSERT INTO public.supplier_returns(id,return_no,outlet_id,supplier_id,reason_category,reason,note,created_by,updated_by)
    VALUES(rid,rno,p_outlet_id,p_supplier_id,p_reason_category::public.supplier_return_reason,btrim(p_reason),nullif(btrim(p_note),''),a,a);
  FOR x IN SELECT * FROM jsonb_to_recordset(p_lines) AS z(product_id uuid,quantity numeric,source_receipt_id uuid,source_receipt_item_id uuid,note text) ORDER BY product_id LOOP
    IF x.product_id IS NULL OR x.quantity IS NULL OR x.quantity<=0 OR x.quantity<>trunc(x.quantity,3)
      OR x.quantity>=100000000000 OR (x.note IS NOT NULL AND (btrim(x.note)='' OR length(x.note)>500)) THEN
      RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid supplier return line';
    END IF;
    PERFORM public.supplier_return_validate_source(p_outlet_id,p_supplier_id,x.product_id,x.source_receipt_id,x.source_receipt_item_id);
    INSERT INTO public.supplier_return_items(return_id,outlet_id,supplier_id,product_id,quantity,source_receipt_id,source_receipt_item_id,note)
    VALUES(rid,p_outlet_id,p_supplier_id,x.product_id,x.quantity,x.source_receipt_id,x.source_receipt_item_id,nullif(btrim(x.note),''));
    n:=n+1;
  END LOOP;
  INSERT INTO public.supplier_return_events(return_id,event_type,actor_id,revision,snapshot)
  VALUES(rid,'CREATED',a,1,public.supplier_return_snapshot(rid));
  RETURN jsonb_build_object('ok',true,'id',rid,'returnNo',rno,'status','DRAFT','revision',1);
END; $$;

CREATE FUNCTION public.supplier_return_snapshot(p_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT jsonb_build_object('reasonCategory',r.reason_category,'reason',r.reason,'note',r.note,
    'lines',coalesce((SELECT jsonb_agg(jsonb_build_object('id',i.id,'productId',i.product_id,'quantity',i.quantity,
      'sourceReceiptId',i.source_receipt_id,'sourceReceiptItemId',i.source_receipt_item_id,'note',i.note) ORDER BY i.product_id)
      FROM public.supplier_return_items i WHERE i.return_id=r.id),'[]'::jsonb))
  FROM public.supplier_returns r WHERE r.id=p_id
$$;
ALTER FUNCTION public.supplier_return_snapshot(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.supplier_return_snapshot(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.supplier_return_validate_source(p_outlet uuid,p_supplier uuid,p_product uuid,p_receipt uuid,p_item uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r public.purchase_receipts%rowtype; i public.purchase_receipt_items%rowtype;
BEGIN
  IF p_receipt IS NULL AND p_item IS NULL THEN RETURN; END IF;
  IF p_receipt IS NULL OR p_item IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Receipt and receipt item must be linked together'; END IF;
  SELECT * INTO STRICT r FROM public.purchase_receipts WHERE id=p_receipt;
  SELECT * INTO STRICT i FROM public.purchase_receipt_items WHERE id=p_item AND receipt_id=p_receipt AND product_id=p_product;
  IF r.outlet_id<>p_outlet OR r.supplier_id<>p_supplier OR r.status<>'POSTED'
    OR i.accepted_quantity+i.bonus_quantity<=0 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Linked source must be a posted receipt for this supplier, outlet, and product';
  END IF;
END; $$;
ALTER FUNCTION public.supplier_return_validate_source(uuid,uuid,uuid,uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.supplier_return_validate_source(uuid,uuid,uuid,uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;

ALTER FUNCTION public.create_supplier_return(uuid,uuid,text,text,text,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.create_supplier_return(uuid,uuid,text,text,text,jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.create_supplier_return(uuid,uuid,text,text,text,jsonb) TO authenticated;

CREATE FUNCTION public.update_supplier_return(p_id uuid,p_expected_revision integer,p_reason_category text,p_reason text,p_note text,p_lines jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=public.supplier_return_assert_editor(); d public.supplier_returns%rowtype; x record;
BEGIN
  SELECT * INTO d FROM public.supplier_returns WHERE id=p_id FOR UPDATE;
  IF NOT FOUND OR d.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Only draft supplier returns can be edited'; END IF;
  IF d.revision<>p_expected_revision THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='Supplier return changed; reload before editing'; END IF;
  PERFORM public.supplier_return_validate_reason(p_reason_category,p_reason);
  IF p_note IS NOT NULL AND (btrim(p_note)='' OR length(p_note)>1000) OR jsonb_typeof(p_lines) IS DISTINCT FROM 'array'
    OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid supplier return details'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_to_recordset(p_lines) AS z(product_id uuid) GROUP BY product_id HAVING count(*)>1) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Product appears more than once in supplier return';
  END IF;
  UPDATE public.supplier_returns SET reason_category=p_reason_category::public.supplier_return_reason,reason=btrim(p_reason),
    note=nullif(btrim(p_note),''),revision=revision+1,updated_by=a,updated_at=now() WHERE id=p_id;
  DELETE FROM public.supplier_return_items i WHERE i.return_id=p_id
    AND NOT EXISTS(SELECT 1 FROM jsonb_to_recordset(p_lines) AS z(product_id uuid) WHERE z.product_id=i.product_id);
  FOR x IN SELECT * FROM jsonb_to_recordset(p_lines) AS z(product_id uuid,quantity numeric,source_receipt_id uuid,source_receipt_item_id uuid,note text) ORDER BY product_id LOOP
    IF x.product_id IS NULL OR x.quantity IS NULL OR x.quantity<=0 OR x.quantity<>trunc(x.quantity,3)
      OR x.quantity>=100000000000 OR (x.note IS NOT NULL AND (btrim(x.note)='' OR length(x.note)>500)) THEN
      RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid supplier return line';
    END IF;
    PERFORM public.supplier_return_validate_source(d.outlet_id,d.supplier_id,x.product_id,x.source_receipt_id,x.source_receipt_item_id);
    INSERT INTO public.supplier_return_items(return_id,outlet_id,supplier_id,product_id,quantity,source_receipt_id,source_receipt_item_id,note)
    VALUES(p_id,d.outlet_id,d.supplier_id,x.product_id,x.quantity,x.source_receipt_id,x.source_receipt_item_id,nullif(btrim(x.note),''))
    ON CONFLICT(return_id,product_id) DO UPDATE SET quantity=excluded.quantity,source_receipt_id=excluded.source_receipt_id,
      source_receipt_item_id=excluded.source_receipt_item_id,note=excluded.note,updated_at=now();
  END LOOP;
  INSERT INTO public.supplier_return_events(return_id,event_type,actor_id,revision,snapshot)
  VALUES(p_id,'UPDATED',a,d.revision+1,public.supplier_return_snapshot(p_id));
  RETURN jsonb_build_object('ok',true,'id',p_id,'status','DRAFT','revision',d.revision+1);
END; $$;
ALTER FUNCTION public.update_supplier_return(uuid,integer,text,text,text,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.update_supplier_return(uuid,integer,text,text,text,jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.update_supplier_return(uuid,integer,text,text,text,jsonb) TO authenticated;

CREATE FUNCTION public.cancel_supplier_return(p_id uuid,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=public.supplier_return_assert_editor(); d public.supplier_returns%rowtype;
BEGIN
  SELECT * INTO d FROM public.supplier_returns WHERE id=p_id FOR UPDATE;
  IF NOT FOUND OR d.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Only draft supplier returns can be cancelled'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason))<3 OR length(p_reason)>500 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Cancellation reason is required'; END IF;
  UPDATE public.supplier_returns SET status='CANCELLED',cancelled_by=a,cancelled_at=now(),cancellation_reason=btrim(p_reason),
    updated_by=a,updated_at=now(),revision=revision+1 WHERE id=p_id;
  INSERT INTO public.supplier_return_events(return_id,event_type,actor_id,revision,snapshot)
  VALUES(p_id,'CANCELLED',a,d.revision+1,jsonb_build_object('reason',btrim(p_reason)));
  RETURN jsonb_build_object('ok',true,'id',p_id,'status','CANCELLED');
END; $$;
ALTER FUNCTION public.cancel_supplier_return(uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.cancel_supplier_return(uuid,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.cancel_supplier_return(uuid,text) TO authenticated;

CREATE FUNCTION public.supplier_return_receipt_candidates(p_supplier uuid,p_product uuid,p_q text DEFAULT NULL,p_limit integer DEFAULT 20)
RETURNS TABLE(receipt_id uuid,receipt_reference text,received_at timestamptz,receipt_item_id uuid,received_quantity numeric,returned_quantity numeric,available_quantity numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=auth.uid(); role public.user_role; v_outlet uuid;
BEGIN
  role:=public.current_active_user_role();
  IF a IS NULL OR role IS NULL OR role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'GUDANG'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Supplier return access denied';
  END IF;
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid receipt lookup limit'; END IF;
  SELECT outlet_id INTO v_outlet FROM public.stock_authority_periods WHERE ended_at IS NULL;
  IF v_outlet IS NULL THEN RETURN; END IF;
  RETURN QUERY SELECT r.id,r.receipt_reference,r.received_at,i.id,i.accepted_quantity+i.bonus_quantity,
    coalesce((SELECT sum(ri.quantity) FROM public.supplier_return_items ri JOIN public.supplier_returns rr ON rr.id=ri.return_id
      WHERE ri.source_receipt_item_id=i.id AND rr.status='POSTED'),0),
    greatest(0,i.accepted_quantity+i.bonus_quantity-coalesce((SELECT sum(ri.quantity) FROM public.supplier_return_items ri
      JOIN public.supplier_returns rr ON rr.id=ri.return_id WHERE ri.source_receipt_item_id=i.id AND rr.status='POSTED'),0))
  FROM public.purchase_receipts r JOIN public.purchase_receipt_items i ON i.receipt_id=r.id
  WHERE r.outlet_id=v_outlet AND r.supplier_id=p_supplier AND r.status='POSTED' AND i.product_id=p_product
    AND (p_q IS NULL OR r.receipt_reference ILIKE '%'||left(p_q,80)||'%')
  ORDER BY r.received_at DESC,r.id DESC LIMIT p_limit;
END; $$;
ALTER FUNCTION public.supplier_return_receipt_candidates(uuid,uuid,text,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.supplier_return_receipt_candidates(uuid,uuid,text,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.supplier_return_receipt_candidates(uuid,uuid,text,integer) TO authenticated;

CREATE FUNCTION public.supplier_return_resolve_barcode(p_barcode text)
RETURNS TABLE(product_id uuid,name text,sku text,barcode text,effective_quantity numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=auth.uid(); role public.user_role; v_outlet uuid; v_match record;
BEGIN
  role:=public.current_active_user_role();
  IF a IS NULL OR role IS NULL OR role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'GUDANG'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Supplier return access denied';
  END IF;
  SELECT outlet_id INTO v_outlet FROM public.stock_authority_periods WHERE ended_at IS NULL;
  IF v_outlet IS NULL THEN RETURN; END IF;
  SELECT * INTO v_match FROM public.resolve_stock_barcode(v_outlet,p_barcode);
  IF v_match.resolution IS DISTINCT FROM 'BARCODE_MATCH' THEN RETURN; END IF;
  RETURN QUERY SELECT p.id,p.name,p.sku,b.barcode,s.effective_quantity
    FROM public.products p JOIN public.stock_balance_projection s ON s.product_id=p.id AND s.outlet_id=v_outlet
    LEFT JOIN LATERAL (SELECT x.barcode FROM public.product_barcodes x WHERE x.product_id=p.id AND x.is_active ORDER BY x.created_at,x.id LIMIT 1) b ON true
    WHERE p.id=v_match.product_id AND s.effective_quantity IS NOT NULL;
END; $$;
ALTER FUNCTION public.supplier_return_resolve_barcode(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.supplier_return_resolve_barcode(text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.supplier_return_resolve_barcode(text) TO authenticated;

CREATE FUNCTION public.guard_supplier_return_movement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE i public.supplier_return_items%rowtype; d public.supplier_returns%rowtype;
BEGIN
  IF NEW.supplier_return_item_id IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO STRICT i FROM public.supplier_return_items WHERE id=NEW.supplier_return_item_id;
  SELECT * INTO STRICT d FROM public.supplier_returns WHERE id=NEW.supplier_return_id;
  IF d.status<>'DRAFT' OR i.return_id<>d.id OR i.outlet_id<>NEW.outlet_id OR i.product_id<>NEW.product_id
    OR i.quantity<>abs(NEW.quantity_delta) OR NEW.quantity_delta>=0 OR NEW.movement_type<>'SUPPLIER_RETURN'
    OR NEW.source_system<>'PURCHASING' OR NEW.source_event_key<>i.id::text THEN
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Supplier return movement does not match draft evidence';
  END IF;
  RETURN NEW;
END; $$;
ALTER FUNCTION public.guard_supplier_return_movement() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_supplier_return_movement() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER supplier_return_movement_guard BEFORE INSERT ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.guard_supplier_return_movement();

CREATE FUNCTION public.guard_supplier_return_cost_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE i public.supplier_return_items%rowtype; d public.supplier_returns%rowtype; m public.stock_movements%rowtype;
  b public.stock_movement_batches%rowtype;
BEGIN
  IF NEW.event_type<>'SUPPLIER_RETURN' THEN RETURN NEW; END IF;
  SELECT * INTO STRICT i FROM public.supplier_return_items WHERE id=NEW.supplier_return_item_id;
  SELECT * INTO STRICT d FROM public.supplier_returns WHERE id=NEW.supplier_return_id;
  SELECT * INTO STRICT m FROM public.stock_movements WHERE id=NEW.source_stock_movement_id;
  SELECT * INTO STRICT b FROM public.stock_movement_batches WHERE id=m.batch_id;
  IF d.status<>'DRAFT' OR d.id<>i.return_id OR d.supplier_id<>NEW.supplier_id OR i.outlet_id<>NEW.outlet_id
    OR i.product_id<>NEW.product_id OR i.quantity<>abs(NEW.physical_quantity_delta)
    OR m.supplier_return_id<>d.id OR m.supplier_return_item_id<>i.id OR m.quantity_delta<>NEW.physical_quantity_delta
    OR m.created_by<>NEW.actor_id OR b.operation_request_id<>NEW.operation_request_id
    OR (i.source_receipt_id IS DISTINCT FROM NEW.source_receipt_id)
    OR (i.source_receipt_item_id IS DISTINCT FROM NEW.source_receipt_item_id) THEN
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Supplier return cost event does not match stock evidence';
  END IF;
  RETURN NEW;
END; $$;
ALTER FUNCTION public.guard_supplier_return_cost_event() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_supplier_return_cost_event() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER supplier_return_cost_event_guard BEFORE INSERT ON public.inventory_cost_events
  FOR EACH ROW EXECUTE FUNCTION public.guard_supplier_return_cost_event();

CREATE OR REPLACE FUNCTION public.inventory_cost_assert_event_layer_allocation(p_cost_event_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE e public.inventory_cost_events%rowtype; n bigint; ph numeric; va numeric; pr numeric; uv numeric;
BEGIN
  SELECT * INTO STRICT e FROM public.inventory_cost_events WHERE id=p_cost_event_id;
  IF e.event_type::text NOT IN ('OPENING','PURCHASE_RECEIPT','OPNAME_ADJUSTMENT','REVERSAL','SUPPLIER_RETURN') THEN RETURN; END IF;
  SELECT count(*),coalesce(sum(a.physical_quantity_delta),0),coalesce(sum(a.valued_quantity_delta),0),
    coalesce(sum(a.provisional_quantity_delta),0),coalesce(sum(a.unvalued_quantity_delta),0)
  INTO n,ph,va,pr,uv FROM public.inventory_cost_layer_allocations a WHERE a.cost_event_id=p_cost_event_id;
  IF n=0 OR ph IS DISTINCT FROM coalesce(e.physical_quantity_delta,e.quantity_delta,0)
    OR va IS DISTINCT FROM coalesce(e.valued_quantity_delta,0)
    OR pr IS DISTINCT FROM coalesce(e.provisional_quantity_delta,0)
    OR uv IS DISTINCT FROM coalesce(e.unvalued_quantity_delta,0) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Cost event and source-layer allocations do not reconcile';
  END IF;
END; $$;
ALTER FUNCTION public.inventory_cost_assert_event_layer_allocation(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_assert_event_layer_allocation(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.inventory_cost_apply_supplier_return(p_request_id uuid,p_return_id uuid,p_period_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=auth.uid(); role public.user_role; d public.supplier_returns%rowtype;
  req public.inventory_cost_operation_requests%rowtype; c public.inventory_cost_projections%rowtype;
  x record; m record; cb uuid; ev uuid; v_unvalued numeric; v_valued numeric; v_provisional numeric;
  v_plan_u jsonb; v_plan_v jsonb; v_delta numeric(32,8); v_after numeric(32,8); v_wac numeric(20,8);
  v_status public.inventory_cost_projection_status; h text; n integer:=0;
BEGIN
  IF a IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Costing actor unavailable'; END IF;
  role:=public.current_active_user_role();
  IF role IS NULL OR role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Supplier return costing requires OWNER or ADMIN'; END IF;
  SELECT * INTO STRICT d FROM public.supplier_returns WHERE id=p_return_id;
  IF NOT EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE outlet_id=d.outlet_id AND status='WAC_ACTIVE') THEN RETURN 0; END IF;
  h:=md5(jsonb_build_object('request',p_request_id,'return',p_return_id,'outlet',d.outlet_id,
    'lines',(SELECT jsonb_agg(jsonb_build_object('id',i.id,'product',i.product_id,'qty',i.quantity) ORDER BY i.product_id)
      FROM public.supplier_return_items i WHERE i.return_id=p_return_id))::text);
  SELECT * INTO req FROM public.inventory_cost_operation_requests WHERE request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF req.actor_id<>a OR req.operation_key<>'SUPPLIER_RETURN' OR req.target_key<>p_return_id::text OR req.payload_hash<>h THEN
      RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Supplier return cost request identity mismatch';
    END IF;
    IF req.result IS NOT NULL THEN RETURN coalesce((req.result->>'eventCount')::integer,0); END IF;
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Supplier return cost request is incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_cost_event_batches WHERE operation_request_id=p_request_id) THEN
    RAISE EXCEPTION USING ERRCODE='23505',MESSAGE='Supplier return cost request already has a batch';
  END IF;
  INSERT INTO public.inventory_cost_operation_requests(request_id,actor_id,operation_key,target_key,payload_hash)
    VALUES(p_request_id,a,'SUPPLIER_RETURN',p_return_id::text,h);
  FOR x IN SELECT DISTINCT product_id FROM public.supplier_return_items WHERE return_id=p_return_id ORDER BY product_id LOOP
    PERFORM 1 FROM public.inventory_cost_projections WHERE outlet_id=d.outlet_id AND product_id=x.product_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Active costing projection is missing'; END IF;
  END LOOP;
  FOR x IN SELECT b.product_id,b.layer_id FROM public.inventory_cost_source_layer_balances b
    WHERE b.outlet_id=d.outlet_id AND b.product_id IN(SELECT product_id FROM public.supplier_return_items WHERE return_id=p_return_id)
    ORDER BY b.product_id,b.layer_id LOOP
    PERFORM 1 FROM public.inventory_cost_source_layer_balances WHERE layer_id=x.layer_id FOR UPDATE;
  END LOOP;
  INSERT INTO public.inventory_cost_event_batches(outlet_id,batch_type,source_entity_type,source_entity_id,
    operation_request_id,allocation_method,created_by)
  VALUES(d.outlet_id,'SUPPLIER_RETURN','SUPPLIER_RETURN',d.id,p_request_id,
    'UNVALUED_FIRST_THEN_PROPORTIONAL_SOURCE_QUANTITY',a) RETURNING id INTO cb;
  FOR x IN SELECT i.*,sm.id movement_id,sm.quantity_delta,sm.balance_before,sm.balance_after
    FROM public.supplier_return_items i JOIN public.stock_movements sm ON sm.supplier_return_item_id=i.id
    WHERE i.return_id=p_return_id ORDER BY i.product_id LOOP
    SELECT * INTO STRICT c FROM public.inventory_cost_projections WHERE outlet_id=d.outlet_id AND product_id=x.product_id;
    IF c.physical_quantity IS DISTINCT FROM x.balance_before OR c.stock_authority_period_id IS DISTINCT FROM p_period_id THEN
      RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='Stock and costing projections are out of sync';
    END IF;
    v_unvalued:=least(x.quantity,c.unvalued_quantity); v_valued:=x.quantity-v_unvalued;
    IF v_valued>c.valued_quantity THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Return exceeds valued and unvalued costing quantity'; END IF;
    v_plan_u:='[]';v_plan_v:='[]';v_provisional:=0;
    IF v_unvalued>0 THEN v_plan_u:=public.inventory_cost_build_layer_outflow_plan(d.outlet_id,x.product_id,v_unvalued,'UNVALUED'); END IF;
    IF v_valued>0 THEN
      v_plan_v:=public.inventory_cost_build_layer_outflow_plan(d.outlet_id,x.product_id,v_valued,'VALUED');
      SELECT -coalesce(sum((z->>'provisional')::numeric),0) INTO v_provisional FROM jsonb_array_elements(v_plan_v) z;
    END IF;
    v_delta:=CASE WHEN v_valued=0 THEN CASE WHEN c.valued_quantity>0 THEN 0 ELSE NULL END
      WHEN v_valued=c.valued_quantity THEN -coalesce(c.inventory_value,0) ELSE -round(v_valued*c.current_wac,8) END;
    v_after:=CASE WHEN c.valued_quantity-v_valued=0 THEN CASE WHEN x.balance_after=0 THEN 0 ELSE NULL END
      ELSE coalesce(c.inventory_value,0)+coalesce(v_delta,0) END;
    v_wac:=CASE WHEN c.valued_quantity-v_valued>0 THEN round(v_after/(c.valued_quantity-v_valued),8)::numeric(20,8) ELSE NULL END;
    v_status:=CASE WHEN x.balance_after=0 THEN 'VALUED'::public.inventory_cost_projection_status
      WHEN c.valued_quantity-v_valued=0 THEN 'UNVALUED'::public.inventory_cost_projection_status
      WHEN c.unvalued_quantity-v_unvalued>0 THEN 'PARTIALLY_UNVALUED'::public.inventory_cost_projection_status
      WHEN c.provisional_quantity+v_provisional>0 THEN 'PROVISIONAL'::public.inventory_cost_projection_status
      ELSE 'VALUED'::public.inventory_cost_projection_status END;
    ev:=gen_random_uuid();
    INSERT INTO public.inventory_cost_events(id,batch_id,outlet_id,product_id,event_type,source_entity_type,source_entity_id,
      source_event_id,quantity_delta,valued_quantity_before,valued_quantity_delta,valued_quantity_after,inventory_value_delta,
      inventory_value_before,inventory_value_after,wac_before,wac_after,valuation_status_before,valuation_status_after,
      cost_version_before,cost_version_after,stock_balance_version,stock_authority_period_id,actor_id,operation_request_id,
      physical_quantity_delta,physical_quantity_before,physical_quantity_after,provisional_quantity_delta,
      provisional_quantity_before,provisional_quantity_after,unvalued_quantity_delta,unvalued_quantity_before,
      unvalued_quantity_after,source_stock_movement_id,supplier_return_id,supplier_return_item_id,supplier_id,
      source_receipt_id,source_receipt_item_id,valuation_basis,frozen_unit_cost,basis_cost_event_id,metadata)
    VALUES(ev,cb,d.outlet_id,x.product_id,'SUPPLIER_RETURN','SUPPLIER_RETURN_LINE',x.id,x.movement_id,x.quantity_delta,
      c.valued_quantity,-v_valued,c.valued_quantity-v_valued,v_delta,c.inventory_value,v_after,c.current_wac,v_wac,
      c.valuation_status,v_status,c.cost_version,c.cost_version+1,
      (SELECT balance_version FROM public.stock_balance_projection WHERE outlet_id=d.outlet_id AND product_id=x.product_id),
      p_period_id,a,p_request_id,x.quantity_delta,x.balance_before,x.balance_after,-v_provisional,c.provisional_quantity,
      c.provisional_quantity-v_provisional,-v_unvalued,c.unvalued_quantity,c.unvalued_quantity-v_unvalued,x.movement_id,d.id,x.id,d.supplier_id,
      x.source_receipt_id,x.source_receipt_item_id,CASE WHEN v_valued>0 THEN 'CURRENT_WAC'::public.inventory_cost_acquisition_basis
        ELSE 'UNVALUED'::public.inventory_cost_acquisition_basis END,
      CASE WHEN v_valued>0 THEN c.current_wac ELSE NULL END,CASE WHEN v_valued>0 THEN c.last_cost_event_id ELSE NULL END,
      jsonb_build_object('allocationMethod','UNVALUED_FIRST_THEN_PROPORTIONAL','sourceReceiptIsAttributionOnly',true,
        'financialDepletionBasis','AGGREGATE_WAC'));
    IF v_plan_u<>'[]' THEN PERFORM * FROM public.inventory_cost_apply_layer_plan(ev,x.movement_id,p_request_id,a,c.cost_version+1,'SUPPLIER_RETURN',v_plan_u); END IF;
    IF v_plan_v<>'[]' THEN PERFORM * FROM public.inventory_cost_apply_layer_plan(ev,x.movement_id,p_request_id,a,c.cost_version+1,'SUPPLIER_RETURN',v_plan_v); END IF;
    UPDATE public.inventory_cost_projections SET physical_quantity=x.balance_after,valued_quantity=c.valued_quantity-v_valued,
      provisional_quantity=c.provisional_quantity-v_provisional,unvalued_quantity=c.unvalued_quantity-v_unvalued,
      inventory_value=v_after,current_wac=v_wac,valuation_status=v_status,cost_version=c.cost_version+1,
      stock_balance_version=(SELECT balance_version FROM public.stock_balance_projection WHERE outlet_id=d.outlet_id AND product_id=x.product_id),
      stock_authority_period_id=p_period_id,last_cost_event_id=ev,updated_at=now()
    WHERE outlet_id=d.outlet_id AND product_id=x.product_id;
    n:=n+1;
  END LOOP;
  IF n=0 THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Supplier return has no stock movements'; END IF;
  UPDATE public.inventory_cost_operation_requests SET result=jsonb_build_object('ok',true,'eventCount',n,'returnId',d.id),completed_at=now()
    WHERE request_id=p_request_id;
  RETURN n;
END; $$;
ALTER FUNCTION public.inventory_cost_apply_supplier_return(uuid,uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_apply_supplier_return(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.post_supplier_return(p_id uuid,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=public.supplier_return_assert_manager(); d public.supplier_returns%rowtype;
  req public.stock_operation_requests%rowtype; x record; p public.stock_balance_projection%rowtype;
  period public.stock_authority_periods%rowtype; authority public.inventory_cost_authority_status;
  h text; batch uuid; movement uuid; before_qty numeric; after_qty numeric; ver bigint; n integer:=0; cost_n integer;
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Request identity is required'; END IF;
  SELECT outlet_id INTO d.outlet_id FROM public.supplier_returns WHERE id=p_id;
  IF d.outlet_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Supplier return is unavailable'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_BOOTSTRAP_OUTLET:'||d.outlet_id::text,73190411));
  SELECT * INTO STRICT d FROM public.supplier_returns WHERE id=p_id FOR UPDATE;
  SELECT status INTO authority FROM public.inventory_costing_outlet_authority WHERE outlet_id=d.outlet_id;
  IF authority='BOOTSTRAP_READY' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Perubahan stok ditahan selama persiapan awal costing berlangsung'; END IF;
  SELECT * INTO req FROM public.stock_operation_requests WHERE request_id=p_request_id AND actor_id=a FOR UPDATE;
  IF FOUND AND req.state<>'PENDING' THEN
    IF req.operation_key<>'POST_SUPPLIER_RETURN' OR req.target_key<>p_id::text THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Request identity mismatch'; END IF;
    RETURN req.result;
  END IF;
  IF d.status='POSTED' THEN
    IF d.post_request_id=p_request_id AND FOUND THEN RETURN req.result; END IF;
    RAISE EXCEPTION USING ERRCODE='23505',MESSAGE='Supplier return is already posted';
  END IF;
  IF d.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Only draft supplier returns can be posted'; END IF;
  h:=md5(jsonb_build_object('return',d.id,'revision',d.revision,'supplier',d.supplier_id,
    'lines',(SELECT jsonb_agg(jsonb_build_object('id',i.id,'product',i.product_id,'quantity',i.quantity,
      'receipt',i.source_receipt_id,'receiptItem',i.source_receipt_item_id) ORDER BY i.product_id)
      FROM public.supplier_return_items i WHERE i.return_id=d.id))::text);
  IF FOUND THEN
    IF req.operation_key<>'POST_SUPPLIER_RETURN' OR req.target_key<>p_id::text OR req.payload_hash<>h
      OR req.request_payload->>'return_id'<>p_id::text THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Supplier return request payload changed'; END IF;
  ELSE
    INSERT INTO public.stock_operation_requests(request_id,actor_id,operation_key,target_key,request_payload,payload_hash)
      VALUES(p_request_id,a,'POST_SUPPLIER_RETURN',p_id::text,jsonb_build_object('return_id',p_id,'revision',d.revision),h);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.supplier_return_items WHERE return_id=p_id) THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Supplier return has no lines'; END IF;
  -- Serialize receipt attribution before stock rows, then enforce both the
  -- receipt accepted+bonus ceiling and current effective stock availability.
  FOR x IN SELECT DISTINCT source_receipt_item_id FROM public.supplier_return_items
    WHERE return_id=p_id AND source_receipt_item_id IS NOT NULL ORDER BY source_receipt_item_id LOOP
    PERFORM 1 FROM public.purchase_receipt_items WHERE id=x.source_receipt_item_id FOR UPDATE;
  END LOOP;
  FOR x IN SELECT i.* FROM public.supplier_return_items i WHERE i.return_id=p_id ORDER BY i.product_id LOOP
    IF x.source_receipt_item_id IS NOT NULL THEN
      PERFORM public.supplier_return_validate_source(d.outlet_id,d.supplier_id,x.product_id,x.source_receipt_id,x.source_receipt_item_id);
      IF coalesce((SELECT sum(ri.quantity) FROM public.supplier_return_items ri JOIN public.supplier_returns rr ON rr.id=ri.return_id
          WHERE ri.source_receipt_item_id=x.source_receipt_item_id AND rr.status='POSTED'),0)+x.quantity >
          (SELECT accepted_quantity+bonus_quantity FROM public.purchase_receipt_items WHERE id=x.source_receipt_item_id) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Supplier return exceeds returnable quantity from linked receipt';
      END IF;
    END IF;
  END LOOP;
  FOR x IN SELECT product_id FROM public.supplier_return_items WHERE return_id=p_id ORDER BY product_id LOOP
    SELECT * INTO p FROM public.stock_balance_projection WHERE outlet_id=d.outlet_id AND product_id=x.product_id FOR UPDATE;
    IF NOT FOUND OR p.effective_quantity IS NULL OR p.effective_quantity <
      (SELECT quantity FROM public.supplier_return_items WHERE return_id=p_id AND product_id=x.product_id) THEN
      RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Return exceeds current available stock';
    END IF;
  END LOOP;
  SELECT * INTO period FROM public.stock_authority_periods WHERE outlet_id=d.outlet_id AND ended_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Stock authority period is unavailable'; END IF;
  IF authority='WAC_ACTIVE' THEN
    FOR x IN SELECT product_id FROM public.supplier_return_items WHERE return_id=p_id ORDER BY product_id LOOP
      PERFORM 1 FROM public.inventory_cost_projections WHERE outlet_id=d.outlet_id AND product_id=x.product_id FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Active costing projection is missing'; END IF;
    END LOOP;
    FOR x IN SELECT b.product_id,b.layer_id FROM public.inventory_cost_source_layer_balances b
      WHERE b.outlet_id=d.outlet_id AND b.product_id IN(SELECT product_id FROM public.supplier_return_items WHERE return_id=p_id)
      ORDER BY b.product_id,b.layer_id LOOP
      PERFORM 1 FROM public.inventory_cost_source_layer_balances WHERE layer_id=x.layer_id FOR UPDATE;
    END LOOP;
  END IF;
  INSERT INTO public.stock_movement_batches(authority_period_id,outlet_id,source_system,operation_request_id,created_by)
    VALUES(period.id,d.outlet_id,'PURCHASING',p_request_id,a) RETURNING id INTO batch;
  FOR x IN SELECT i.* FROM public.supplier_return_items i WHERE i.return_id=p_id ORDER BY i.product_id LOOP
    SELECT bal.balance_before,bal.balance_after,bal.new_balance_version INTO before_qty,after_qty,ver
      FROM public.stock_apply_balance_delta(x.product_id,d.outlet_id,-x.quantity) bal;
    INSERT INTO public.stock_movements(batch_id,authority_period_id,outlet_id,product_id,movement_type,source_system,
      quantity_delta,balance_before,balance_after,source_reference,source_event_key,supplier_return_id,supplier_return_item_id,created_by)
    VALUES(batch,period.id,d.outlet_id,x.product_id,'SUPPLIER_RETURN','PURCHASING',-x.quantity,before_qty,after_qty,
      d.return_no||': '||d.reason,x.id::text,d.id,x.id,a) RETURNING id INTO movement;
    INSERT INTO public.stock_balance_projection_events(product_id,outlet_id,authority_period_id,event_type,request_id,
      quantity_delta,balance_before,balance_after,balance_version,actor_id)
    VALUES(x.product_id,d.outlet_id,period.id,'MOVEMENT_POSTED',p_request_id,-x.quantity,before_qty,after_qty,ver,a);
    n:=n+1;
  END LOOP;
  IF authority='WAC_ACTIVE' THEN cost_n:=public.inventory_cost_apply_supplier_return(p_request_id,p_id,period.id);
    IF cost_n<>n THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Supplier return costing was incomplete'; END IF;
  END IF;
  UPDATE public.supplier_returns SET status='POSTED',posted_by=a,posted_at=now(),post_request_id=p_request_id,updated_by=a,updated_at=now()
    WHERE id=p_id;
  UPDATE public.stock_operation_requests SET state='COMPLETED',result=jsonb_build_object('ok',true,'returnId',d.id,
    'returnNo',d.return_no,'status','POSTED','movementBatchId',batch,'lineCount',n),completed_at=now() WHERE request_id=p_request_id;
  INSERT INTO public.supplier_return_events(return_id,event_type,actor_id,request_id,revision,snapshot)
    VALUES(d.id,'POSTED',a,p_request_id,d.revision,jsonb_build_object('movementBatchId',batch,'lineCount',n));
  RETURN (SELECT result FROM public.stock_operation_requests WHERE request_id=p_request_id);
END; $$;
ALTER FUNCTION public.post_supplier_return(uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.post_supplier_return(uuid,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.post_supplier_return(uuid,uuid) TO authenticated;

COMMIT;
