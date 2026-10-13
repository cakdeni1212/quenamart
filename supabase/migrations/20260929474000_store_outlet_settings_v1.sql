BEGIN;

ALTER TABLE public.outlets
  ADD COLUMN customer_display_name text,
  ADD COLUMN address text,
  ADD COLUMN city text,
  ADD COLUMN province text,
  ADD COLUMN postal_code text,
  ADD COLUMN phone text,
  ADD COLUMN whatsapp text,
  ADD COLUMN email text,
  ADD COLUMN updated_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT;

ALTER TABLE public.outlets
  ADD CONSTRAINT outlets_customer_display_name_valid CHECK (customer_display_name IS NULL OR (btrim(customer_display_name)<>'' AND length(customer_display_name)<=160)),
  ADD CONSTRAINT outlets_address_valid CHECK (address IS NULL OR (btrim(address)<>'' AND length(address)<=300)),
  ADD CONSTRAINT outlets_city_valid CHECK (city IS NULL OR (btrim(city)<>'' AND length(city)<=100)),
  ADD CONSTRAINT outlets_province_valid CHECK (province IS NULL OR (btrim(province)<>'' AND length(province)<=100)),
  ADD CONSTRAINT outlets_postal_code_valid CHECK (postal_code IS NULL OR (btrim(postal_code)<>'' AND length(postal_code)<=20)),
  ADD CONSTRAINT outlets_phone_valid CHECK (phone IS NULL OR (btrim(phone)<>'' AND length(phone)<=40)),
  ADD CONSTRAINT outlets_whatsapp_valid CHECK (whatsapp IS NULL OR (btrim(whatsapp)<>'' AND length(whatsapp)<=40)),
  ADD CONSTRAINT outlets_email_valid CHECK (email IS NULL OR (btrim(email)<>'' AND length(email)<=254 AND email ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'));

CREATE TABLE public.outlet_settings_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type='OUTLET_SETTINGS_UPDATED'),
  changed_fields text[] NOT NULL CHECK (cardinality(changed_fields)>0),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX outlet_settings_events_outlet_idx ON public.outlet_settings_events(outlet_id,id DESC);
ALTER TABLE public.outlet_settings_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.outlet_settings_events FROM PUBLIC,anon,authenticated,service_role;
REVOKE INSERT,UPDATE,DELETE ON public.outlets FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.outlet_settings_guard_identity()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='OUTLET_DELETE_NOT_ALLOWED';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.code IS DISTINCT FROM OLD.code OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='OUTLET_IDENTITY_IMMUTABLE';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.outlet_settings_guard_identity() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.outlet_settings_guard_identity() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER outlets_settings_identity_guard
BEFORE UPDATE OR DELETE ON public.outlets
FOR EACH ROW EXECUTE FUNCTION public.outlet_settings_guard_identity();

CREATE FUNCTION public.outlet_settings_current_id()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_period_count integer; v_outlet uuid; v_active_count integer;
BEGIN
  SELECT count(*)::integer,(array_agg(p.outlet_id ORDER BY p.started_at DESC))[1]
  INTO v_period_count,v_outlet
  FROM public.stock_authority_periods p JOIN public.outlets o ON o.id=p.outlet_id
  WHERE p.ended_at IS NULL AND o.is_active;
  IF v_period_count=1 THEN RETURN v_outlet; END IF;
  IF v_period_count>1 THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='OUTLET_CONTEXT_AMBIGUOUS'; END IF;

  SELECT count(*)::integer,(array_agg(o.id ORDER BY o.created_at,o.id))[1]
  INTO v_active_count,v_outlet FROM public.outlets o WHERE o.is_active;
  IF v_active_count<>1 OR v_outlet IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='OUTLET_CONTEXT_UNAVAILABLE';
  END IF;
  RETURN v_outlet;
END;
$$;
ALTER FUNCTION public.outlet_settings_current_id() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.outlet_settings_current_id() FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.outlet_settings_read()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role:=public.current_active_user_role(); v_outlet uuid; v_result jsonb;
BEGIN
  IF v_actor IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='OUTLET_SETTINGS_READ_DENIED';
  END IF;
  v_outlet:=public.outlet_settings_current_id();
  SELECT jsonb_build_object(
    'id',o.id,'name',o.name,'customer_display_name',o.customer_display_name,'code',o.code,
    'address',o.address,'city',o.city,'province',o.province,'postal_code',o.postal_code,
    'phone',o.phone,'whatsapp',o.whatsapp,'email',o.email,'is_active',o.is_active,
    'updated_at',o.updated_at,'updated_by',o.updated_by,
    'can_deactivate',(SELECT count(*)>1 FROM public.outlets active WHERE active.is_active)
      AND NOT EXISTS(SELECT 1 FROM public.stock_authority_periods p WHERE p.outlet_id=o.id AND p.ended_at IS NULL)
  ) INTO v_result FROM public.outlets o WHERE o.id=v_outlet;
  RETURN v_result;
END;
$$;
ALTER FUNCTION public.outlet_settings_read() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.outlet_settings_read() FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.outlet_settings_read() TO authenticated;

CREATE FUNCTION public.outlet_settings_update(p_outlet_id uuid,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE
  v_actor uuid:=auth.uid(); v_role public.user_role:=public.current_active_user_role(); v_outlet public.outlets%ROWTYPE;
  v_name text; v_display_name text; v_address text; v_city text; v_province text; v_postal_code text;
  v_phone text; v_whatsapp text; v_email text; v_is_active boolean; v_changed text[];
BEGIN
  IF v_actor IS NULL OR v_role IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='OUTLET_SETTINGS_UPDATE_DENIED';
  END IF;
  IF p_outlet_id IS NULL OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
    OR p_payload-ARRAY['name','customer_display_name','address','city','province','postal_code','phone','whatsapp','email','is_active']<>'{}'::jsonb THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='OUTLET_SETTINGS_INVALID_PAYLOAD';
  END IF;
  IF p_outlet_id IS DISTINCT FROM public.outlet_settings_current_id() THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='OUTLET_SETTINGS_SCOPE_DENIED';
  END IF;
  IF jsonb_typeof(p_payload->'name') IS DISTINCT FROM 'string'
    OR jsonb_typeof(p_payload->'is_active') IS DISTINCT FROM 'boolean' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='OUTLET_SETTINGS_INVALID_PAYLOAD';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_each(p_payload) e WHERE e.key<>'is_active' AND e.value<>'null'::jsonb AND jsonb_typeof(e.value)<>'string') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='OUTLET_SETTINGS_INVALID_PAYLOAD';
  END IF;

  v_name:=btrim(p_payload->>'name');
  v_display_name:=nullif(btrim(p_payload->>'customer_display_name'),'');
  v_address:=nullif(btrim(p_payload->>'address'),''); v_city:=nullif(btrim(p_payload->>'city'),'');
  v_province:=nullif(btrim(p_payload->>'province'),''); v_postal_code:=nullif(btrim(p_payload->>'postal_code'),'');
  v_phone:=nullif(btrim(p_payload->>'phone'),''); v_whatsapp:=nullif(btrim(p_payload->>'whatsapp'),'');
  v_email:=nullif(btrim(p_payload->>'email'),''); v_is_active:=(p_payload->>'is_active')::boolean;
  IF v_name IS NULL OR v_name='' OR length(v_name)>120 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='OUTLET_SETTINGS_INVALID_NAME'; END IF;
  IF v_display_name IS NOT NULL AND length(v_display_name)>160 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='OUTLET_SETTINGS_INVALID_DISPLAY_NAME'; END IF;
  IF v_address IS NOT NULL AND length(v_address)>300 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='OUTLET_SETTINGS_INVALID_ADDRESS'; END IF;
  IF v_city IS NOT NULL AND length(v_city)>100 OR v_province IS NOT NULL AND length(v_province)>100 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='OUTLET_SETTINGS_INVALID_LOCATION'; END IF;
  IF v_postal_code IS NOT NULL AND length(v_postal_code)>20 OR v_phone IS NOT NULL AND length(v_phone)>40 OR v_whatsapp IS NOT NULL AND length(v_whatsapp)>40 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='OUTLET_SETTINGS_INVALID_CONTACT';
  END IF;
  IF v_email IS NOT NULL AND (length(v_email)>254 OR v_email !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='OUTLET_SETTINGS_INVALID_EMAIL';
  END IF;

  SELECT * INTO v_outlet FROM public.outlets WHERE id=p_outlet_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='OUTLET_SETTINGS_NOT_FOUND'; END IF;
  IF v_outlet.is_active AND NOT v_is_active THEN
    IF EXISTS(SELECT 1 FROM public.stock_authority_periods p WHERE p.outlet_id=v_outlet.id AND p.ended_at IS NULL)
      OR (SELECT count(*) FROM public.outlets o WHERE o.is_active)<=1 THEN
      RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='OUTLET_SETTINGS_DEACTIVATION_BLOCKED';
    END IF;
  END IF;
  v_changed:=array_remove(ARRAY[
    CASE WHEN v_outlet.name IS DISTINCT FROM v_name THEN 'name' END,
    CASE WHEN v_outlet.customer_display_name IS DISTINCT FROM v_display_name THEN 'customer_display_name' END,
    CASE WHEN v_outlet.address IS DISTINCT FROM v_address THEN 'address' END,
    CASE WHEN v_outlet.city IS DISTINCT FROM v_city THEN 'city' END,
    CASE WHEN v_outlet.province IS DISTINCT FROM v_province THEN 'province' END,
    CASE WHEN v_outlet.postal_code IS DISTINCT FROM v_postal_code THEN 'postal_code' END,
    CASE WHEN v_outlet.phone IS DISTINCT FROM v_phone THEN 'phone' END,
    CASE WHEN v_outlet.whatsapp IS DISTINCT FROM v_whatsapp THEN 'whatsapp' END,
    CASE WHEN v_outlet.email IS DISTINCT FROM v_email THEN 'email' END,
    CASE WHEN v_outlet.is_active IS DISTINCT FROM v_is_active THEN 'is_active' END
  ],NULL);
  IF cardinality(v_changed)=0 THEN RETURN jsonb_build_object('updated',false,'changed_fields','[]'::jsonb); END IF;

  UPDATE public.outlets SET name=v_name,customer_display_name=v_display_name,address=v_address,city=v_city,
    province=v_province,postal_code=v_postal_code,phone=v_phone,whatsapp=v_whatsapp,email=v_email,
    is_active=v_is_active,updated_by=v_actor,updated_at=now() WHERE id=v_outlet.id;
  INSERT INTO public.outlet_settings_events(outlet_id,actor_id,event_type,changed_fields)
  VALUES(v_outlet.id,v_actor,'OUTLET_SETTINGS_UPDATED',v_changed);
  RETURN jsonb_build_object('updated',true,'changed_fields',to_jsonb(v_changed),'updated_at',now());
END;
$$;
ALTER FUNCTION public.outlet_settings_update(uuid,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.outlet_settings_update(uuid,jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.outlet_settings_update(uuid,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.pos_sale_receipt_read(p_sale_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_outlet uuid; v_outlet_count integer; v_result jsonb;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'KASIR'::public.user_role) OR p_sale_id IS NULL THEN RETURN NULL; END IF;
  SELECT count(*)::integer,(array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1] INTO v_outlet_count,v_outlet
  FROM public.stock_authority_periods ap JOIN public.outlets active_outlet ON active_outlet.id=ap.outlet_id
  WHERE ap.ended_at IS NULL AND active_outlet.is_active;
  IF v_outlet_count<>1 OR v_outlet IS NULL THEN RETURN NULL; END IF;

  SELECT jsonb_build_object(
    'sale_id',s.id,'sale_number',s.sale_number,'completed_at',s.completed_at,
    'cashier_label',coalesce(nullif(btrim(cr.result->>'cashier_label'),''),'Kasir'),
    'outlet_display_name',coalesce(nullif(btrim(o.customer_display_name),''),o.name),
    'outlet_address',nullif(concat_ws(', ',nullif(btrim(o.address),''),nullif(btrim(o.city),''),nullif(btrim(o.province),''),nullif(btrim(o.postal_code),'')),''),
    'outlet_phone',o.phone,'outlet_whatsapp',o.whatsapp,
    'items',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',si.product_name_snapshot,'sku',si.sku_snapshot,'unit',si.unit_snapshot,
      'quantity',si.quantity,'unit_selling_price',si.unit_selling_price,'line_subtotal',si.line_subtotal) ORDER BY si.line_number),'[]'::jsonb)
      FROM public.sale_items si WHERE si.sale_id=s.id AND si.outlet_id=s.outlet_id),
    'subtotal',s.subtotal,'discount_total',s.discount_total,'grand_total',s.grand_total,
    'payments',(SELECT coalesce(jsonb_agg(jsonb_build_object('method',sp.method,'applied_amount',sp.applied_amount,
      'received_amount',sp.received_amount,'change_amount',sp.change_amount,'reference_text',sp.reference_text) ORDER BY sp.recorded_at,sp.id),'[]'::jsonb)
      FROM public.sale_payments sp WHERE sp.sale_id=s.id AND sp.outlet_id=s.outlet_id)
  ) INTO v_result
  FROM public.sales s JOIN public.pos_checkout_requests cr ON cr.request_id=s.checkout_request_id AND cr.outlet_id=s.outlet_id
  JOIN public.outlets o ON o.id=s.outlet_id
  WHERE s.id=p_sale_id AND s.outlet_id=v_outlet AND s.source_system='QUENA_POS'::public.pos_sale_source
    AND s.status='COMPLETED'::public.pos_sale_status
    AND (v_role IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) OR s.cashier_id=v_actor);
  RETURN v_result;
END;
$$;
ALTER FUNCTION public.pos_sale_receipt_read(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_sale_receipt_read(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_sale_receipt_read(uuid) TO authenticated;

COMMIT;
