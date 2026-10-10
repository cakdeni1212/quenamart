-- P1B: persisted POS carts and POS-safe catalog lookup only.
-- No checkout, payment, revenue, stock movement, or costing writer is added.
BEGIN;

CREATE TYPE public.pos_cart_status AS ENUM ('ACTIVE','PARKED','CANCELLED');
CREATE TYPE public.pos_cart_event_type AS ENUM (
  'CREATED','ITEM_ADDED','ITEM_QUANTITY_CHANGED','ITEM_REMOVED',
  'PRICE_ACKNOWLEDGED','PARKED','RESUMED','CANCELLED'
);

CREATE TABLE public.pos_carts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  status public.pos_cart_status NOT NULL DEFAULT 'ACTIVE',
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  cancelled_at timestamptz,
  cancelled_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  CONSTRAINT pos_cart_id_outlet_unique UNIQUE (id,outlet_id),
  CONSTRAINT pos_cart_cancel_state CHECK (
    (status='CANCELLED' AND cancelled_at IS NOT NULL AND cancelled_by IS NOT NULL)
    OR (status<>'CANCELLED' AND cancelled_at IS NULL AND cancelled_by IS NULL)
  )
);
CREATE INDEX pos_carts_outlet_status_updated_idx
  ON public.pos_carts(outlet_id,status,updated_at DESC,id DESC);
CREATE INDEX pos_carts_owner_recent_idx ON public.pos_carts(created_by,updated_at DESC,id DESC);

CREATE TABLE public.pos_cart_mutation_requests (
  request_id uuid PRIMARY KEY,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  operation_key text NOT NULL CHECK (operation_key IN ('CREATE','ADD_ITEM','SET_QUANTITY','ACK_PRICE','PARK','RESUME','CANCEL')),
  target_key text NOT NULL,
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{32}$'),
  result jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  CONSTRAINT pos_cart_request_terminal CHECK ((result IS NULL)=(completed_at IS NULL))
);
CREATE INDEX pos_cart_request_actor_time_idx
  ON public.pos_cart_mutation_requests(actor_id,created_at DESC);

CREATE TABLE public.pos_cart_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cart_id uuid NOT NULL,
  outlet_id uuid NOT NULL,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  quantity numeric NOT NULL CHECK (quantity>0 AND quantity<100000000000 AND quantity=trunc(quantity,3)),
  observed_unit_price numeric NOT NULL CHECK (observed_unit_price>0 AND observed_unit_price<1000000000000 AND observed_unit_price=trunc(observed_unit_price,2)),
  observed_price_history_id uuid REFERENCES public.product_selling_price_history(id) ON DELETE RESTRICT,
  observed_price_at timestamptz NOT NULL,
  product_sku_snapshot text NOT NULL,
  product_name_snapshot text NOT NULL,
  unit_snapshot text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pos_cart_item_parent_fk FOREIGN KEY(cart_id,outlet_id)
    REFERENCES public.pos_carts(id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT pos_cart_item_product_once UNIQUE(cart_id,product_id),
  CONSTRAINT pos_cart_item_id_cart_outlet_unique UNIQUE(id,cart_id,outlet_id)
);
CREATE INDEX pos_cart_items_cart_order_idx ON public.pos_cart_items(cart_id,created_at,id);
CREATE INDEX pos_cart_items_product_idx ON public.pos_cart_items(outlet_id,product_id);

CREATE TABLE public.pos_cart_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cart_id uuid NOT NULL,
  outlet_id uuid NOT NULL,
  event_type public.pos_cart_event_type NOT NULL,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  request_id uuid NOT NULL UNIQUE REFERENCES public.pos_cart_mutation_requests(request_id) ON DELETE RESTRICT,
  revision bigint NOT NULL CHECK (revision>0),
  event_data jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(event_data)='object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pos_cart_event_parent_fk FOREIGN KEY(cart_id,outlet_id)
    REFERENCES public.pos_carts(id,outlet_id) ON DELETE RESTRICT
);
CREATE INDEX pos_cart_events_cart_time_idx ON public.pos_cart_events(cart_id,created_at,id);

CREATE FUNCTION public.guard_pos_cart_event_immutable()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POS cart events are append-only';
END;
$$;
ALTER FUNCTION public.guard_pos_cart_event_immutable() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_pos_cart_event_immutable() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER pos_cart_events_immutable BEFORE UPDATE OR DELETE ON public.pos_cart_events
  FOR EACH ROW EXECUTE FUNCTION public.guard_pos_cart_event_immutable();

CREATE FUNCTION public.guard_pos_cart_item_price_evidence()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE h public.product_selling_price_history%ROWTYPE;
BEGIN
  IF NEW.observed_price_history_id IS NOT NULL THEN
    SELECT * INTO h FROM public.product_selling_price_history WHERE id=NEW.observed_price_history_id;
    IF NOT FOUND OR h.product_id<>NEW.product_id OR h.outlet_id<>NEW.outlet_id
       OR h.amount IS DISTINCT FROM NEW.observed_unit_price OR h.effective_at IS DISTINCT FROM NEW.observed_price_at THEN
      RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='POS cart price evidence does not match the selected price history';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.guard_pos_cart_item_price_evidence() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_pos_cart_item_price_evidence() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER pos_cart_items_price_evidence BEFORE INSERT OR UPDATE OF observed_unit_price,observed_price_history_id,observed_price_at,product_id,outlet_id
  ON public.pos_cart_items FOR EACH ROW EXECUTE FUNCTION public.guard_pos_cart_item_price_evidence();

ALTER TABLE public.pos_carts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_carts FORCE ROW LEVEL SECURITY;
ALTER TABLE public.pos_cart_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_cart_items FORCE ROW LEVEL SECURITY;
ALTER TABLE public.pos_cart_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_cart_events FORCE ROW LEVEL SECURITY;
ALTER TABLE public.pos_cart_mutation_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_cart_mutation_requests FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.pos_carts,public.pos_cart_items,public.pos_cart_events,public.pos_cart_mutation_requests FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.pos_cart_context()
RETURNS TABLE(actor_id uuid,outlet_id uuid,actor_role public.user_role)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a uuid; r public.user_role; n integer; o uuid;
BEGIN
  a:=auth.uid(); r:=public.current_active_user_role();
  IF a IS NULL OR r IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'KASIR'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_CART_ACCESS_DENIED';
  END IF;
  SELECT count(*)::integer,(array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1]
    INTO n,o FROM public.stock_authority_periods ap JOIN public.outlets x ON x.id=ap.outlet_id
   WHERE ap.ended_at IS NULL AND x.is_active;
  IF n<>1 OR o IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_OUTLET_UNAVAILABLE'; END IF;
  RETURN QUERY SELECT a,o,r;
END;
$$;
ALTER FUNCTION public.pos_cart_context() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_cart_context() FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.pos_product_contract(p_outlet uuid,p_product uuid)
RETURNS TABLE(eligibility text,product_id uuid,sku text,product_name text,unit_label text,
  unit_price numeric,price_history_id uuid,price_effective_at timestamptz,effective_stock numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
  SELECT CASE WHEN p.id IS NULL OR i.product_id IS NULL THEN 'PRODUCT_UNAVAILABLE'
              WHEN s.amount IS NULL THEN 'PRICE_UNAVAILABLE'
              WHEN s.amount<=0 THEN 'PRICE_ZERO'
              ELSE 'ELIGIBLE' END,
         p.id,p.sku,p.name,p.unit_label,s.amount,h.id,h.effective_at,b.effective_quantity
    FROM (SELECT 1) seed
    LEFT JOIN public.products p ON p.id=p_product
    LEFT JOIN public.product_inventory i ON i.product_id=p.id AND i.outlet_id=p_outlet
    LEFT JOIN public.product_selling_prices s ON s.product_id=p.id AND s.outlet_id=p_outlet
    LEFT JOIN LATERAL (
      SELECT ph.id,ph.effective_at FROM public.product_selling_price_history ph
       WHERE ph.product_id=p.id AND ph.outlet_id=p_outlet AND ph.amount IS NOT DISTINCT FROM s.amount
       ORDER BY ph.effective_at DESC,ph.id DESC LIMIT 1
    ) h ON true
    LEFT JOIN public.stock_balance_projection b ON b.product_id=p.id AND b.outlet_id=p_outlet
   WHERE EXISTS(SELECT 1 FROM public.outlets o WHERE o.id=p_outlet AND o.is_active)
$$;
ALTER FUNCTION public.pos_product_contract(uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_product_contract(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.pos_cart_request_begin(p_request uuid,p_actor uuid,p_outlet uuid,p_operation text,p_target text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE q public.pos_cart_mutation_requests%ROWTYPE; h text;
BEGIN
  IF p_request IS NULL OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='POS_CART_REQUEST_INVALID';
  END IF;
  h:=md5(p_payload::text);
  INSERT INTO public.pos_cart_mutation_requests(request_id,actor_id,outlet_id,operation_key,target_key,payload_hash)
    VALUES(p_request,p_actor,p_outlet,p_operation,p_target,h) ON CONFLICT(request_id) DO NOTHING;
  SELECT * INTO q FROM public.pos_cart_mutation_requests WHERE request_id=p_request FOR UPDATE;
  IF q.actor_id<>p_actor OR q.outlet_id<>p_outlet OR q.operation_key<>p_operation OR q.target_key<>p_target OR q.payload_hash<>h THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='POS_CART_REQUEST_REUSED';
  END IF;
  IF q.result IS NOT NULL THEN RETURN q.result; END IF;
  RETURN NULL;
END;
$$;
ALTER FUNCTION public.pos_cart_request_begin(uuid,uuid,uuid,text,text,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_cart_request_begin(uuid,uuid,uuid,text,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.pos_cart_set_result(p_request uuid,p_result jsonb)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
  UPDATE public.pos_cart_mutation_requests SET result=p_result,completed_at=now()
   WHERE request_id=p_request AND result IS NULL
$$;
ALTER FUNCTION public.pos_cart_set_result(uuid,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_cart_set_result(uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.pos_cart_create(p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c record; replay jsonb; cart uuid; result jsonb;
BEGIN
  SELECT * INTO STRICT c FROM public.pos_cart_context();
  replay:=public.pos_cart_request_begin(p_request_id,c.actor_id,c.outlet_id,'CREATE','NEW_CART',jsonb_build_object('operation','CREATE','outlet_id',c.outlet_id));
  IF replay IS NOT NULL THEN RETURN replay; END IF;
  INSERT INTO public.pos_carts(outlet_id,created_by) VALUES(c.outlet_id,c.actor_id) RETURNING id INTO cart;
  INSERT INTO public.pos_cart_events(cart_id,outlet_id,event_type,actor_id,request_id,revision)
    VALUES(cart,c.outlet_id,'CREATED',c.actor_id,p_request_id,1);
  result:=jsonb_build_object('ok',true,'cart_id',cart,'status','ACTIVE','revision',1);
  PERFORM public.pos_cart_set_result(p_request_id,result); RETURN result;
END;
$$;
ALTER FUNCTION public.pos_cart_create(uuid) OWNER TO postgres;

CREATE FUNCTION public.pos_cart_add_item(p_cart uuid,p_product uuid,p_quantity_delta numeric,p_expected_revision bigint,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c record; cart public.pos_carts%ROWTYPE; item public.pos_cart_items%ROWTYPE; prod record;
  replay jsonb; payload jsonb; result jsonb; new_revision bigint; new_qty numeric;
BEGIN
  SELECT * INTO STRICT c FROM public.pos_cart_context();
  IF p_quantity_delta IS NULL OR p_quantity_delta<=0 OR p_quantity_delta>=100000000000 OR p_quantity_delta<>trunc(p_quantity_delta,3) OR p_expected_revision IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='POS_CART_QUANTITY_INVALID';
  END IF;
  payload:=jsonb_build_object('cart_id',p_cart,'product_id',p_product,'quantity_delta',p_quantity_delta,'expected_revision',p_expected_revision);
  replay:=public.pos_cart_request_begin(p_request_id,c.actor_id,c.outlet_id,'ADD_ITEM',coalesce(p_cart::text,''),payload);
  IF replay IS NOT NULL THEN RETURN replay; END IF;
  SELECT * INTO cart FROM public.pos_carts WHERE id=p_cart AND outlet_id=c.outlet_id FOR UPDATE;
  IF NOT FOUND OR (c.actor_role='KASIR' AND cart.created_by<>c.actor_id) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_CART_NOT_FOUND'; END IF;
  IF cart.status<>'ACTIVE' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POS_CART_NOT_EDITABLE'; END IF;
  IF cart.revision<>p_expected_revision THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='POS_CART_STALE_REVISION'; END IF;
  SELECT * INTO prod FROM public.pos_product_contract(c.outlet_id,p_product);
  IF NOT FOUND OR prod.eligibility<>'ELIGIBLE' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE=CASE WHEN prod.eligibility='PRICE_ZERO' THEN 'POS_PRICE_ZERO' WHEN prod.eligibility='PRICE_UNAVAILABLE' THEN 'POS_PRICE_UNAVAILABLE' ELSE 'POS_PRODUCT_UNAVAILABLE' END;
  END IF;
  SELECT * INTO item FROM public.pos_cart_items WHERE cart_id=p_cart AND product_id=p_product FOR UPDATE;
  IF FOUND THEN
    IF item.observed_unit_price<>prod.unit_price THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='POS_PRICE_CHANGED_ACK_REQUIRED'; END IF;
    new_qty:=item.quantity+p_quantity_delta;
    IF new_qty>=100000000000 OR new_qty<>trunc(new_qty,3) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='POS_CART_QUANTITY_INVALID'; END IF;
    UPDATE public.pos_cart_items SET quantity=new_qty,updated_at=now() WHERE id=item.id;
    new_revision:=cart.revision+1;
    INSERT INTO public.pos_cart_events(cart_id,outlet_id,event_type,actor_id,request_id,revision,event_data)
      VALUES(p_cart,c.outlet_id,'ITEM_ADDED',c.actor_id,p_request_id,new_revision,jsonb_build_object('item_id',item.id,'product_id',p_product,'quantity_delta',p_quantity_delta,'quantity_after',new_qty));
  ELSE
    IF (SELECT count(*) FROM public.pos_cart_items WHERE cart_id=p_cart)>=200 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='POS_CART_LINE_LIMIT'; END IF;
    INSERT INTO public.pos_cart_items(cart_id,outlet_id,product_id,quantity,observed_unit_price,observed_price_history_id,observed_price_at,
      product_sku_snapshot,product_name_snapshot,unit_snapshot)
    VALUES(p_cart,c.outlet_id,p_product,p_quantity_delta,prod.unit_price,prod.price_history_id,coalesce(prod.price_effective_at,now()),prod.sku,prod.product_name,prod.unit_label)
    RETURNING * INTO item;
    new_qty:=item.quantity; new_revision:=cart.revision+1;
    INSERT INTO public.pos_cart_events(cart_id,outlet_id,event_type,actor_id,request_id,revision,event_data)
      VALUES(p_cart,c.outlet_id,'ITEM_ADDED',c.actor_id,p_request_id,new_revision,jsonb_build_object('item_id',item.id,'product_id',p_product,'quantity_delta',p_quantity_delta,'quantity_after',new_qty));
  END IF;
  UPDATE public.pos_carts SET revision=new_revision,updated_at=now() WHERE id=p_cart;
  result:=jsonb_build_object('ok',true,'cart_id',p_cart,'status','ACTIVE','revision',new_revision);
  PERFORM public.pos_cart_set_result(p_request_id,result); RETURN result;
END;
$$;
ALTER FUNCTION public.pos_cart_add_item(uuid,uuid,numeric,bigint,uuid) OWNER TO postgres;

CREATE FUNCTION public.pos_cart_set_item_quantity(p_cart uuid,p_item uuid,p_quantity numeric,p_expected_revision bigint,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c record; cart public.pos_carts%ROWTYPE; item public.pos_cart_items%ROWTYPE; replay jsonb; payload jsonb; result jsonb; rev bigint;
BEGIN
  SELECT * INTO STRICT c FROM public.pos_cart_context();
  IF p_quantity IS NULL OR p_quantity<0 OR p_quantity>=100000000000 OR p_quantity<>trunc(p_quantity,3) OR p_expected_revision IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='POS_CART_QUANTITY_INVALID';
  END IF;
  payload:=jsonb_build_object('cart_id',p_cart,'item_id',p_item,'quantity',p_quantity,'expected_revision',p_expected_revision);
  replay:=public.pos_cart_request_begin(p_request_id,c.actor_id,c.outlet_id,'SET_QUANTITY',coalesce(p_cart::text,''),payload);
  IF replay IS NOT NULL THEN RETURN replay; END IF;
  SELECT * INTO cart FROM public.pos_carts WHERE id=p_cart AND outlet_id=c.outlet_id FOR UPDATE;
  IF NOT FOUND OR (c.actor_role='KASIR' AND cart.created_by<>c.actor_id) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_CART_NOT_FOUND'; END IF;
  IF cart.status<>'ACTIVE' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POS_CART_NOT_EDITABLE'; END IF;
  IF cart.revision<>p_expected_revision THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='POS_CART_STALE_REVISION'; END IF;
  SELECT * INTO item FROM public.pos_cart_items WHERE id=p_item AND cart_id=p_cart AND outlet_id=c.outlet_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='POS_CART_ITEM_NOT_FOUND'; END IF;
  rev:=cart.revision+1;
  IF p_quantity=0 THEN
    DELETE FROM public.pos_cart_items WHERE id=p_item;
    INSERT INTO public.pos_cart_events(cart_id,outlet_id,event_type,actor_id,request_id,revision,event_data)
      VALUES(p_cart,c.outlet_id,'ITEM_REMOVED',c.actor_id,p_request_id,rev,jsonb_build_object('item_id',p_item,'product_id',item.product_id,'quantity_before',item.quantity));
  ELSE
    UPDATE public.pos_cart_items SET quantity=p_quantity,updated_at=now() WHERE id=p_item;
    INSERT INTO public.pos_cart_events(cart_id,outlet_id,event_type,actor_id,request_id,revision,event_data)
      VALUES(p_cart,c.outlet_id,'ITEM_QUANTITY_CHANGED',c.actor_id,p_request_id,rev,jsonb_build_object('item_id',p_item,'product_id',item.product_id,'quantity_before',item.quantity,'quantity_after',p_quantity));
  END IF;
  UPDATE public.pos_carts SET revision=rev,updated_at=now() WHERE id=p_cart;
  result:=jsonb_build_object('ok',true,'cart_id',p_cart,'status','ACTIVE','revision',rev);
  PERFORM public.pos_cart_set_result(p_request_id,result); RETURN result;
END;
$$;
ALTER FUNCTION public.pos_cart_set_item_quantity(uuid,uuid,numeric,bigint,uuid) OWNER TO postgres;

CREATE FUNCTION public.pos_cart_acknowledge_price(p_cart uuid,p_item uuid,p_confirmed_price numeric,p_expected_revision bigint,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c record; cart public.pos_carts%ROWTYPE; item public.pos_cart_items%ROWTYPE; prod record; replay jsonb; payload jsonb; result jsonb; rev bigint;
BEGIN
  SELECT * INTO STRICT c FROM public.pos_cart_context();
  IF p_confirmed_price IS NULL OR p_confirmed_price<=0 OR p_confirmed_price<>trunc(p_confirmed_price,2) OR p_expected_revision IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='POS_PRICE_CONFIRMATION_INVALID';
  END IF;
  payload:=jsonb_build_object('cart_id',p_cart,'item_id',p_item,'confirmed_price',p_confirmed_price,'expected_revision',p_expected_revision);
  replay:=public.pos_cart_request_begin(p_request_id,c.actor_id,c.outlet_id,'ACK_PRICE',coalesce(p_cart::text,''),payload);
  IF replay IS NOT NULL THEN RETURN replay; END IF;
  SELECT * INTO cart FROM public.pos_carts WHERE id=p_cart AND outlet_id=c.outlet_id FOR UPDATE;
  IF NOT FOUND OR (c.actor_role='KASIR' AND cart.created_by<>c.actor_id) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_CART_NOT_FOUND'; END IF;
  IF cart.status<>'ACTIVE' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POS_CART_NOT_EDITABLE'; END IF;
  IF cart.revision<>p_expected_revision THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='POS_CART_STALE_REVISION'; END IF;
  SELECT * INTO item FROM public.pos_cart_items WHERE id=p_item AND cart_id=p_cart AND outlet_id=c.outlet_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='POS_CART_ITEM_NOT_FOUND'; END IF;
  SELECT * INTO prod FROM public.pos_product_contract(c.outlet_id,item.product_id);
  IF NOT FOUND OR prod.eligibility<>'ELIGIBLE' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='POS_PRICE_UNAVAILABLE'; END IF;
  IF prod.unit_price IS DISTINCT FROM p_confirmed_price THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='POS_PRICE_CHANGED_RETRY'; END IF;
  UPDATE public.pos_cart_items SET observed_unit_price=prod.unit_price,observed_price_history_id=prod.price_history_id,
    observed_price_at=coalesce(prod.price_effective_at,now()),updated_at=now() WHERE id=p_item;
  rev:=cart.revision+1;
  UPDATE public.pos_carts SET revision=rev,updated_at=now() WHERE id=p_cart;
  INSERT INTO public.pos_cart_events(cart_id,outlet_id,event_type,actor_id,request_id,revision,event_data)
    VALUES(p_cart,c.outlet_id,'PRICE_ACKNOWLEDGED',c.actor_id,p_request_id,rev,jsonb_build_object('item_id',p_item,'product_id',item.product_id,'previous_price',item.observed_unit_price,'current_price',prod.unit_price,'price_history_id',prod.price_history_id));
  result:=jsonb_build_object('ok',true,'cart_id',p_cart,'status','ACTIVE','revision',rev);
  PERFORM public.pos_cart_set_result(p_request_id,result); RETURN result;
END;
$$;
ALTER FUNCTION public.pos_cart_acknowledge_price(uuid,uuid,numeric,bigint,uuid) OWNER TO postgres;

CREATE FUNCTION public.pos_cart_transition(p_cart uuid,p_expected_revision bigint,p_request_id uuid,p_operation text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c record; cart public.pos_carts%ROWTYPE; replay jsonb; payload jsonb; result jsonb; target public.pos_cart_status; event_kind public.pos_cart_event_type; rev bigint;
BEGIN
  SELECT * INTO STRICT c FROM public.pos_cart_context();
  IF p_operation NOT IN ('PARK','RESUME','CANCEL') OR p_expected_revision IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='POS_CART_OPERATION_INVALID'; END IF;
  payload:=jsonb_build_object('cart_id',p_cart,'expected_revision',p_expected_revision,'operation',p_operation);
  replay:=public.pos_cart_request_begin(p_request_id,c.actor_id,c.outlet_id,p_operation,coalesce(p_cart::text,''),payload);
  IF replay IS NOT NULL THEN RETURN replay; END IF;
  SELECT * INTO cart FROM public.pos_carts WHERE id=p_cart AND outlet_id=c.outlet_id FOR UPDATE;
  IF NOT FOUND OR (c.actor_role='KASIR' AND cart.created_by<>c.actor_id) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_CART_NOT_FOUND'; END IF;
  IF cart.revision<>p_expected_revision THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='POS_CART_STALE_REVISION'; END IF;
  IF p_operation='PARK' AND cart.status='ACTIVE' THEN target:='PARKED'; event_kind:='PARKED';
  ELSIF p_operation='RESUME' AND cart.status='PARKED' THEN target:='ACTIVE'; event_kind:='RESUMED';
  ELSIF p_operation='CANCEL' AND cart.status IN ('ACTIVE','PARKED') THEN target:='CANCELLED'; event_kind:='CANCELLED';
  ELSE RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POS_CART_TRANSITION_INVALID'; END IF;
  rev:=cart.revision+1;
  UPDATE public.pos_carts SET status=target,revision=rev,updated_at=now(),
    cancelled_at=CASE WHEN target='CANCELLED' THEN now() ELSE NULL END,
    cancelled_by=CASE WHEN target='CANCELLED' THEN c.actor_id ELSE NULL END
   WHERE id=p_cart;
  INSERT INTO public.pos_cart_events(cart_id,outlet_id,event_type,actor_id,request_id,revision)
    VALUES(p_cart,c.outlet_id,event_kind,c.actor_id,p_request_id,rev);
  result:=jsonb_build_object('ok',true,'cart_id',p_cart,'status',target,'revision',rev);
  PERFORM public.pos_cart_set_result(p_request_id,result); RETURN result;
END;
$$;
ALTER FUNCTION public.pos_cart_transition(uuid,bigint,uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_cart_transition(uuid,bigint,uuid,text) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.pos_cart_park(p_cart uuid,p_expected_revision bigint,p_request_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$ SELECT public.pos_cart_transition(p_cart,p_expected_revision,p_request_id,'PARK') $$;
ALTER FUNCTION public.pos_cart_park(uuid,bigint,uuid) OWNER TO postgres;
CREATE FUNCTION public.pos_cart_resume(p_cart uuid,p_expected_revision bigint,p_request_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$ SELECT public.pos_cart_transition(p_cart,p_expected_revision,p_request_id,'RESUME') $$;
ALTER FUNCTION public.pos_cart_resume(uuid,bigint,uuid) OWNER TO postgres;
CREATE FUNCTION public.pos_cart_cancel(p_cart uuid,p_expected_revision bigint,p_request_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$ SELECT public.pos_cart_transition(p_cart,p_expected_revision,p_request_id,'CANCEL') $$;
ALTER FUNCTION public.pos_cart_cancel(uuid,bigint,uuid) OWNER TO postgres;

CREATE FUNCTION public.pos_resolve_barcode(p_barcode text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c record; q text; n integer; pid uuid; prod record; result jsonb;
BEGIN
  SELECT * INTO STRICT c FROM public.pos_cart_context();
  q:=nullif(btrim(p_barcode),'');
  IF q IS NULL OR length(q)>128 OR q ~ '[[:cntrl:]]' THEN RETURN jsonb_build_object('resolution','BARCODE_NOT_FOUND'); END IF;
  SELECT count(DISTINCT b.product_id)::integer,(array_agg(DISTINCT b.product_id ORDER BY b.product_id))[1]
    INTO n,pid FROM public.product_barcodes b JOIN public.products p ON p.id=b.product_id
   WHERE b.is_active AND b.barcode=q COLLATE "C";
  IF n=0 THEN RETURN jsonb_build_object('resolution','BARCODE_NOT_FOUND'); END IF;
  IF n>1 THEN RETURN jsonb_build_object('resolution','BARCODE_AMBIGUOUS'); END IF;
  SELECT * INTO prod FROM public.pos_product_contract(c.outlet_id,pid);
  IF NOT FOUND OR prod.eligibility<>'ELIGIBLE' THEN
    RETURN jsonb_build_object('resolution',CASE WHEN prod.eligibility='PRICE_ZERO' THEN 'PRICE_ZERO' WHEN prod.eligibility='PRICE_UNAVAILABLE' THEN 'PRICE_UNAVAILABLE' ELSE 'PRODUCT_UNAVAILABLE' END);
  END IF;
  result:=jsonb_build_object('resolution','BARCODE_MATCH','product',jsonb_build_object('product_id',prod.product_id,'sku',prod.sku,
    'name',prod.product_name,'unit',prod.unit_label,'unit_price',prod.unit_price,'price_history_id',prod.price_history_id,
    'price_effective_at',prod.price_effective_at,'effective_stock',prod.effective_stock));
  RETURN result;
END;
$$;
ALTER FUNCTION public.pos_resolve_barcode(text) OWNER TO postgres;

CREATE FUNCTION public.pos_search_products(p_query text,p_limit integer DEFAULT 25)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c record; q text; lim integer; rows jsonb;
BEGIN
  SELECT * INTO STRICT c FROM public.pos_cart_context();
  q:=nullif(btrim(p_query),''); lim:=least(greatest(coalesce(p_limit,25),1),25);
  IF q IS NULL OR length(q)<2 OR length(q)>80 OR q ~ '[[:cntrl:]]' THEN RETURN jsonb_build_object('rows','[]'::jsonb,'count',0); END IF;
  SELECT coalesce(jsonb_agg(x.item ORDER BY x.name COLLATE "C",x.sku COLLATE "C",x.product_id),'[]'::jsonb)
    INTO rows FROM (
      SELECT p.id product_id,p.sku,p.name,p.unit_label,s.amount AS unit_price,h.id AS price_history_id,h.effective_at AS price_effective_at,
        b.effective_quantity AS effective_stock,
        jsonb_build_object('product_id',p.id,'sku',p.sku,'name',p.name,'unit',p.unit_label,'unit_price',s.amount,
          'price_history_id',h.id,'price_effective_at',h.effective_at,'effective_stock',b.effective_quantity) AS item
      FROM public.products p
      JOIN public.product_inventory i ON i.product_id=p.id AND i.outlet_id=c.outlet_id
      JOIN public.product_selling_prices s ON s.product_id=p.id AND s.outlet_id=c.outlet_id AND s.amount>0
      LEFT JOIN public.stock_balance_projection b ON b.product_id=p.id AND b.outlet_id=c.outlet_id
      LEFT JOIN LATERAL (SELECT ph.id,ph.effective_at FROM public.product_selling_price_history ph
        WHERE ph.product_id=p.id AND ph.outlet_id=c.outlet_id AND ph.amount IS NOT DISTINCT FROM s.amount
        ORDER BY ph.effective_at DESC,ph.id DESC LIMIT 1) h ON true
      WHERE position(lower(q) in lower(p.name))>0 OR position(lower(q) in lower(p.sku))>0
        OR EXISTS(SELECT 1 FROM public.product_barcodes pb WHERE pb.product_id=p.id AND pb.is_active AND position(lower(q) in lower(pb.barcode))>0)
      ORDER BY p.name COLLATE "C",p.sku COLLATE "C",p.id LIMIT lim
    ) x;
  RETURN jsonb_build_object('rows',rows,'count',jsonb_array_length(rows));
END;
$$;
ALTER FUNCTION public.pos_search_products(text,integer) OWNER TO postgres;

CREATE FUNCTION public.pos_cart_workspace_read(p_cart_id uuid DEFAULT NULL,p_limit integer DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c record; lim integer; result jsonb;
BEGIN
  SELECT * INTO STRICT c FROM public.pos_cart_context(); lim:=least(greatest(coalesce(p_limit,20),1),30);
  IF p_cart_id IS NOT NULL THEN
    IF NOT EXISTS(SELECT 1 FROM public.pos_carts x WHERE x.id=p_cart_id AND x.outlet_id=c.outlet_id
      AND (c.actor_role<>'KASIR' OR x.created_by=c.actor_id)) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_CART_NOT_FOUND'; END IF;
    SELECT jsonb_build_object('carts',coalesce(jsonb_agg(y.cart),'[]'::jsonb)) INTO result FROM (
      SELECT jsonb_build_object('id',x.id,'status',x.status,'revision',x.revision,'created_by',x.created_by,'cashier_name',p.full_name,
        'created_at',x.created_at,'updated_at',x.updated_at,'items',coalesce((
          SELECT jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'sku',i.product_sku_snapshot,'name',i.product_name_snapshot,
            'unit',i.unit_snapshot,'quantity',i.quantity,'observed_unit_price',i.observed_unit_price,'observed_price_history_id',i.observed_price_history_id,
            'observed_price_at',i.observed_price_at,'current_unit_price',s.amount,'current_price_history_id',h.id,'current_price_effective_at',h.effective_at,
            'price_status',CASE WHEN s.amount IS NULL OR s.amount<=0 THEN 'UNAVAILABLE' WHEN s.amount<>i.observed_unit_price THEN 'CHANGED' ELSE 'CURRENT' END,
            'effective_stock',b.effective_quantity,'observed_line_total',round(i.quantity*i.observed_unit_price,2)) ORDER BY i.created_at,i.id)
            FROM public.pos_cart_items i JOIN public.pos_carts parent ON parent.id=i.cart_id
            LEFT JOIN public.product_selling_prices s ON s.product_id=i.product_id AND s.outlet_id=i.outlet_id
            LEFT JOIN LATERAL (SELECT ph.id,ph.effective_at FROM public.product_selling_price_history ph WHERE ph.product_id=i.product_id AND ph.outlet_id=i.outlet_id AND ph.amount IS NOT DISTINCT FROM s.amount ORDER BY ph.effective_at DESC,ph.id DESC LIMIT 1) h ON true
            LEFT JOIN public.stock_balance_projection b ON b.product_id=i.product_id AND b.outlet_id=i.outlet_id
           WHERE i.cart_id=x.id), '[]'::jsonb),
        'observed_total',coalesce((SELECT round(sum(i.quantity*i.observed_unit_price),2) FROM public.pos_cart_items i WHERE i.cart_id=x.id),0)) AS cart
        FROM public.pos_carts x JOIN public.profiles p ON p.id=x.created_by
       WHERE x.id=p_cart_id AND x.outlet_id=c.outlet_id AND (c.actor_role<>'KASIR' OR x.created_by=c.actor_id)
    ) y;
  ELSE
    SELECT jsonb_build_object('carts',coalesce(jsonb_agg(y.cart ORDER BY y.status_rank,y.updated_at DESC,y.id),'[]'::jsonb)) INTO result FROM (
      SELECT x.id,x.updated_at,CASE x.status WHEN 'ACTIVE' THEN 1 WHEN 'PARKED' THEN 2 ELSE 3 END status_rank,
        jsonb_build_object('id',x.id,'status',x.status,'revision',x.revision,'created_by',x.created_by,'cashier_name',p.full_name,
          'created_at',x.created_at,'updated_at',x.updated_at,'items',coalesce((
            SELECT jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'sku',i.product_sku_snapshot,'name',i.product_name_snapshot,
              'unit',i.unit_snapshot,'quantity',i.quantity,'observed_unit_price',i.observed_unit_price,'observed_price_history_id',i.observed_price_history_id,
              'observed_price_at',i.observed_price_at,'current_unit_price',s.amount,'current_price_history_id',h.id,'current_price_effective_at',h.effective_at,
              'price_status',CASE WHEN s.amount IS NULL OR s.amount<=0 THEN 'UNAVAILABLE' WHEN s.amount<>i.observed_unit_price THEN 'CHANGED' ELSE 'CURRENT' END,
              'effective_stock',b.effective_quantity,'observed_line_total',round(i.quantity*i.observed_unit_price,2)) ORDER BY i.created_at,i.id)
              FROM public.pos_cart_items i
              LEFT JOIN public.product_selling_prices s ON s.product_id=i.product_id AND s.outlet_id=i.outlet_id
              LEFT JOIN LATERAL (SELECT ph.id,ph.effective_at FROM public.product_selling_price_history ph WHERE ph.product_id=i.product_id AND ph.outlet_id=i.outlet_id AND ph.amount IS NOT DISTINCT FROM s.amount ORDER BY ph.effective_at DESC,ph.id DESC LIMIT 1) h ON true
              LEFT JOIN public.stock_balance_projection b ON b.product_id=i.product_id AND b.outlet_id=i.outlet_id WHERE i.cart_id=x.id), '[]'::jsonb),
          'observed_total',coalesce((SELECT round(sum(i.quantity*i.observed_unit_price),2) FROM public.pos_cart_items i WHERE i.cart_id=x.id),0)) cart
        FROM public.pos_carts x JOIN public.profiles p ON p.id=x.created_by
       WHERE x.outlet_id=c.outlet_id AND (c.actor_role<>'KASIR' OR x.created_by=c.actor_id)
       ORDER BY status_rank,x.updated_at DESC,x.id LIMIT lim
    ) y;
  END IF;
  RETURN coalesce(result,jsonb_build_object('carts','[]'::jsonb));
END;
$$;
ALTER FUNCTION public.pos_cart_workspace_read(uuid,integer) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.pos_cart_create(uuid),public.pos_cart_add_item(uuid,uuid,numeric,bigint,uuid),
  public.pos_cart_set_item_quantity(uuid,uuid,numeric,bigint,uuid),public.pos_cart_acknowledge_price(uuid,uuid,numeric,bigint,uuid),
  public.pos_cart_park(uuid,bigint,uuid),public.pos_cart_resume(uuid,bigint,uuid),public.pos_cart_cancel(uuid,bigint,uuid),
  public.pos_resolve_barcode(text),public.pos_search_products(text,integer),public.pos_cart_workspace_read(uuid,integer)
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_cart_create(uuid),public.pos_cart_add_item(uuid,uuid,numeric,bigint,uuid),
  public.pos_cart_set_item_quantity(uuid,uuid,numeric,bigint,uuid),public.pos_cart_acknowledge_price(uuid,uuid,numeric,bigint,uuid),
  public.pos_cart_park(uuid,bigint,uuid),public.pos_cart_resume(uuid,bigint,uuid),public.pos_cart_cancel(uuid,bigint,uuid),
  public.pos_resolve_barcode(text),public.pos_search_products(text,integer),public.pos_cart_workspace_read(uuid,integer)
  TO authenticated;

COMMIT;
