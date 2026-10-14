-- Configurable outlet loyalty policy, POS redemption, and immutable sale point evidence.
BEGIN;

CREATE TABLE public.outlet_loyalty_settings (
  outlet_id uuid PRIMARY KEY REFERENCES public.outlets(id) ON DELETE RESTRICT,
  program_enabled boolean NOT NULL DEFAULT false,
  rupiah_per_point bigint,
  redeem_enabled boolean NOT NULL DEFAULT false,
  rupiah_per_redeem_point bigint,
  minimum_redeem_points bigint,
  policy_revision bigint NOT NULL DEFAULT 1 CHECK(policy_revision>0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  CONSTRAINT loyalty_earn_rate_bounds CHECK (rupiah_per_point IS NULL OR rupiah_per_point BETWEEN 1 AND 1000000000),
  CONSTRAINT loyalty_redeem_rate_bounds CHECK (rupiah_per_redeem_point IS NULL OR rupiah_per_redeem_point BETWEEN 1 AND 1000000000),
  CONSTRAINT loyalty_minimum_bounds CHECK (minimum_redeem_points IS NULL OR minimum_redeem_points BETWEEN 1 AND 1000000000),
  CONSTRAINT loyalty_enabled_policy_valid CHECK (
    (NOT program_enabled OR rupiah_per_point IS NOT NULL)
    AND (NOT redeem_enabled OR (rupiah_per_redeem_point IS NOT NULL AND minimum_redeem_points IS NOT NULL))
  )
);
ALTER TABLE public.outlet_loyalty_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.outlet_loyalty_settings FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.outlet_loyalty_settings FROM PUBLIC,anon,authenticated,service_role;

ALTER TABLE public.outlet_settings_events DROP CONSTRAINT outlet_settings_events_event_type_check;
ALTER TABLE public.outlet_settings_events ADD CONSTRAINT outlet_settings_events_event_type_check
  CHECK (event_type IN ('OUTLET_SETTINGS_UPDATED','POS_SETTINGS_UPDATED','LOYALTY_SETTINGS_UPDATED'));

CREATE FUNCTION public.member_loyalty_settings_effective(p_outlet uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
  SELECT jsonb_build_object(
    'outlet_id',o.id,
    'program_enabled',coalesce(s.program_enabled,false),
    'rupiah_per_point',s.rupiah_per_point::text,
    'redeem_enabled',coalesce(s.redeem_enabled,false),
    'rupiah_per_redeem_point',s.rupiah_per_redeem_point::text,
    'minimum_redeem_points',s.minimum_redeem_points::text,
    'policy_revision',coalesce(s.policy_revision,0),
    'updated_at',s.updated_at
  )
  FROM public.outlets o LEFT JOIN public.outlet_loyalty_settings s ON s.outlet_id=o.id
  WHERE o.id=p_outlet AND o.is_active
$$;
ALTER FUNCTION public.member_loyalty_settings_effective(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_loyalty_settings_effective(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.member_loyalty_settings_read()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid; result jsonb;
BEGIN
  IF a IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='LOYALTY_SETTINGS_READ_DENIED';
  END IF;
  o:=public.outlet_settings_current_id();
  result:=public.member_loyalty_settings_effective(o);
  IF result IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='LOYALTY_OUTLET_UNAVAILABLE'; END IF;
  RETURN result;
END $$;
ALTER FUNCTION public.member_loyalty_settings_read() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_loyalty_settings_read() FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.member_loyalty_settings_read() TO authenticated;

CREATE FUNCTION public.member_loyalty_settings_update(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid;
  enabled boolean; earn_rate bigint; redeem boolean; redeem_rate bigint; minimum bigint; old jsonb; changed text[];
BEGIN
  IF a IS NULL OR r IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='LOYALTY_SETTINGS_UPDATE_DENIED';
  END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR p_payload-ARRAY['program_enabled','rupiah_per_point','redeem_enabled','rupiah_per_redeem_point','minimum_redeem_points']<>'{}'::jsonb
     OR jsonb_typeof(p_payload->'program_enabled') IS DISTINCT FROM 'boolean'
     OR jsonb_typeof(p_payload->'redeem_enabled') IS DISTINCT FROM 'boolean' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='LOYALTY_SETTINGS_INVALID_PAYLOAD';
  END IF;
  enabled:=(p_payload->>'program_enabled')::boolean;
  redeem:=(p_payload->>'redeem_enabled')::boolean;
  IF jsonb_typeof(p_payload->'rupiah_per_point') NOT IN ('string','null')
     OR jsonb_typeof(p_payload->'rupiah_per_redeem_point') NOT IN ('string','null')
     OR jsonb_typeof(p_payload->'minimum_redeem_points') NOT IN ('string','null') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='LOYALTY_SETTINGS_INVALID_PAYLOAD';
  END IF;
  IF nullif(p_payload->>'rupiah_per_point','') IS NOT NULL AND (p_payload->>'rupiah_per_point') !~ '^[1-9][0-9]{0,8}$' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='LOYALTY_EARN_RATE_INVALID';
  END IF;
  IF nullif(p_payload->>'rupiah_per_redeem_point','') IS NOT NULL AND (p_payload->>'rupiah_per_redeem_point') !~ '^[1-9][0-9]{0,8}$' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='LOYALTY_REDEEM_RATE_INVALID';
  END IF;
  IF nullif(p_payload->>'minimum_redeem_points','') IS NOT NULL AND (p_payload->>'minimum_redeem_points') !~ '^[1-9][0-9]{0,8}$' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='LOYALTY_MINIMUM_INVALID';
  END IF;
  earn_rate:=nullif(p_payload->>'rupiah_per_point','')::bigint;
  redeem_rate:=nullif(p_payload->>'rupiah_per_redeem_point','')::bigint;
  minimum:=nullif(p_payload->>'minimum_redeem_points','')::bigint;
  IF enabled AND earn_rate IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='LOYALTY_EARN_RATE_REQUIRED'; END IF;
  IF redeem AND (redeem_rate IS NULL OR minimum IS NULL) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='LOYALTY_REDEEM_POLICY_REQUIRED'; END IF;

  o:=public.outlet_settings_current_id();
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('LOYALTY_SETTINGS:'||o::text,73190433));
  old:=public.member_loyalty_settings_effective(o);
  changed:=array_remove(ARRAY[
    CASE WHEN (old->>'program_enabled')::boolean IS DISTINCT FROM enabled THEN 'program_enabled' END,
    CASE WHEN old->>'rupiah_per_point' IS DISTINCT FROM earn_rate::text THEN 'rupiah_per_point' END,
    CASE WHEN (old->>'redeem_enabled')::boolean IS DISTINCT FROM redeem THEN 'redeem_enabled' END,
    CASE WHEN old->>'rupiah_per_redeem_point' IS DISTINCT FROM redeem_rate::text THEN 'rupiah_per_redeem_point' END,
    CASE WHEN old->>'minimum_redeem_points' IS DISTINCT FROM minimum::text THEN 'minimum_redeem_points' END
  ],NULL);
  IF cardinality(changed)=0 THEN RETURN jsonb_build_object('updated',false,'settings',old); END IF;
  INSERT INTO public.outlet_loyalty_settings(outlet_id,program_enabled,rupiah_per_point,redeem_enabled,
    rupiah_per_redeem_point,minimum_redeem_points,updated_by,updated_at)
  VALUES(o,enabled,earn_rate,redeem,redeem_rate,minimum,a,now())
  ON CONFLICT(outlet_id) DO UPDATE SET program_enabled=EXCLUDED.program_enabled,
    rupiah_per_point=EXCLUDED.rupiah_per_point,redeem_enabled=EXCLUDED.redeem_enabled,
    rupiah_per_redeem_point=EXCLUDED.rupiah_per_redeem_point,minimum_redeem_points=EXCLUDED.minimum_redeem_points,
    policy_revision=public.outlet_loyalty_settings.policy_revision+1,
    updated_by=EXCLUDED.updated_by,updated_at=EXCLUDED.updated_at;
  INSERT INTO public.outlet_settings_events(outlet_id,actor_id,event_type,changed_fields)
  VALUES(o,a,'LOYALTY_SETTINGS_UPDATED',changed);
  RETURN jsonb_build_object('updated',true,'changed_fields',to_jsonb(changed),'settings',public.member_loyalty_settings_effective(o));
END $$;
ALTER FUNCTION public.member_loyalty_settings_update(jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_loyalty_settings_update(jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.member_loyalty_settings_update(jsonb) TO authenticated;

ALTER TABLE public.pos_carts ADD COLUMN redeem_points_requested bigint NOT NULL DEFAULT 0
  CHECK (redeem_points_requested BETWEEN 0 AND 1000000000);
ALTER TABLE public.pos_carts ADD COLUMN redeem_policy_updated_at timestamptz;
ALTER TABLE public.pos_carts ADD COLUMN redeem_policy_revision bigint NOT NULL DEFAULT 0 CHECK(redeem_policy_revision>=0);
ALTER TABLE public.pos_cart_mutation_requests DROP CONSTRAINT pos_cart_mutation_requests_operation_key_check;
ALTER TABLE public.pos_cart_mutation_requests ADD CONSTRAINT pos_cart_mutation_requests_operation_key_check
  CHECK (operation_key IN ('CREATE','ADD_ITEM','SET_QUANTITY','ACK_PRICE','PARK','RESUME','CANCEL','SET_LOYALTY_REDEEM'));
ALTER TYPE public.pos_cart_event_type ADD VALUE 'LOYALTY_REDEMPTION_SET';

CREATE TABLE public.pos_cart_loyalty_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), cart_id uuid NOT NULL, outlet_id uuid NOT NULL,
  member_id uuid, points_requested bigint NOT NULL CHECK(points_requested BETWEEN 0 AND 1000000000),
  policy_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(policy_snapshot)='object'),
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  request_id uuid NOT NULL UNIQUE REFERENCES public.pos_cart_mutation_requests(request_id) ON DELETE RESTRICT,
  revision bigint NOT NULL CHECK(revision>0), created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY(cart_id,outlet_id) REFERENCES public.pos_carts(id,outlet_id) ON DELETE RESTRICT,
  FOREIGN KEY(member_id,outlet_id) REFERENCES public.members(id,outlet_id) ON DELETE RESTRICT
);
CREATE INDEX pos_cart_loyalty_events_cart_time_idx ON public.pos_cart_loyalty_events(cart_id,created_at DESC);
ALTER TABLE public.pos_cart_loyalty_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pos_cart_loyalty_events FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.guard_pos_cart_loyalty_event_immutable() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POS cart loyalty events are append-only'; END $$;
ALTER FUNCTION public.guard_pos_cart_loyalty_event_immutable() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_pos_cart_loyalty_event_immutable() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER pos_cart_loyalty_events_immutable BEFORE UPDATE OR DELETE ON public.pos_cart_loyalty_events
  FOR EACH ROW EXECUTE FUNCTION public.guard_pos_cart_loyalty_event_immutable();

CREATE FUNCTION public.pos_cart_redeem_points_set(p_cart uuid,p_points bigint,p_expected_revision bigint,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c record; cart public.pos_carts%ROWTYPE; m public.members%ROWTYPE; policy jsonb; balance bigint;
  payload jsonb; replay jsonb; result jsonb; v_revision bigint; total numeric(32,2); amount numeric(32,2);
  rate bigint; min_points bigint;
BEGIN
  SELECT * INTO STRICT c FROM public.pos_cart_context();
  IF p_request IS NULL OR p_cart IS NULL OR p_expected_revision IS NULL OR p_points IS NULL OR p_points NOT BETWEEN 0 AND 1000000000 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='POS_LOYALTY_REDEEM_INVALID';
  END IF;
  payload:=jsonb_build_object('cart',p_cart,'points',p_points,'revision',p_expected_revision);
  replay:=public.pos_cart_request_begin(p_request,c.actor_id,c.outlet_id,'SET_LOYALTY_REDEEM',p_cart::text,payload);
  IF replay IS NOT NULL THEN RETURN replay; END IF;
  SELECT * INTO cart FROM public.pos_carts WHERE id=p_cart AND outlet_id=c.outlet_id FOR UPDATE;
  IF NOT FOUND OR (c.actor_role='KASIR' AND cart.created_by<>c.actor_id) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_CART_NOT_FOUND'; END IF;
  IF cart.status<>'ACTIVE' OR cart.revision<>p_expected_revision THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='POS_CART_STALE_REVISION'; END IF;
  IF p_points>0 THEN
    IF cart.member_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_LOYALTY_MEMBER_REQUIRED'; END IF;
    SELECT * INTO m FROM public.members WHERE id=cart.member_id AND outlet_id=c.outlet_id FOR UPDATE;
    IF NOT FOUND OR m.status<>'ACTIVE' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_MEMBER_INACTIVE_OR_NOT_FOUND'; END IF;
    policy:=public.member_loyalty_settings_effective(c.outlet_id);
    IF coalesce((policy->>'program_enabled')::boolean,false) IS NOT TRUE OR coalesce((policy->>'redeem_enabled')::boolean,false) IS NOT TRUE THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_LOYALTY_REDEEM_DISABLED'; END IF;
    rate:=(policy->>'rupiah_per_redeem_point')::bigint; min_points:=(policy->>'minimum_redeem_points')::bigint;
    SELECT coalesce(sum(points_delta),0)::bigint INTO balance FROM public.member_point_ledger WHERE member_id=m.id;
    IF p_points<min_points THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_LOYALTY_BELOW_MINIMUM'; END IF;
    IF p_points>balance THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_LOYALTY_INSUFFICIENT_POINTS'; END IF;
    SELECT coalesce(round(sum(i.quantity*i.observed_unit_price),2),0)::numeric(32,2) INTO total FROM public.pos_cart_items i WHERE i.cart_id=cart.id;
    amount:=p_points::numeric*rate;
    IF amount>total THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_LOYALTY_EXCEEDS_PAYABLE'; END IF;
  END IF;
  v_revision:=cart.revision+1;
  UPDATE public.pos_carts SET redeem_points_requested=p_points,
    redeem_policy_updated_at=CASE WHEN p_points>0 THEN (policy->>'updated_at')::timestamptz END,
    redeem_policy_revision=CASE WHEN p_points>0 THEN (policy->>'policy_revision')::bigint ELSE 0 END,
    revision=v_revision,updated_at=now() WHERE id=cart.id;
  INSERT INTO public.pos_cart_loyalty_events(cart_id,outlet_id,member_id,points_requested,policy_snapshot,actor_id,request_id,revision)
  VALUES(cart.id,c.outlet_id,cart.member_id,p_points,CASE WHEN p_points>0 THEN policy ELSE '{}'::jsonb END,c.actor_id,p_request,v_revision);
  INSERT INTO public.pos_cart_events(cart_id,outlet_id,event_type,actor_id,request_id,revision,event_data)
  VALUES(cart.id,c.outlet_id,'LOYALTY_REDEMPTION_SET',c.actor_id,p_request,v_revision,
    jsonb_build_object('points_requested',p_points,'member_id',cart.member_id));
  result:=jsonb_build_object('ok',true,'cart_id',cart.id,'points_requested',p_points,'revision',v_revision,
    'discount_amount',CASE WHEN p_points>0 THEN amount::text ELSE '0' END,
    'redeem_rate',CASE WHEN p_points>0 THEN rate END,'minimum_redeem_points',CASE WHEN p_points>0 THEN min_points END,
    'policy_updated_at',CASE WHEN p_points>0 THEN policy->>'updated_at' END,
    'policy_revision',CASE WHEN p_points>0 THEN policy->>'policy_revision' END);
  PERFORM public.pos_cart_set_result(p_request,result);
  RETURN result;
END $$;
ALTER FUNCTION public.pos_cart_redeem_points_set(uuid,bigint,bigint,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_cart_redeem_points_set(uuid,bigint,bigint,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_cart_redeem_points_set(uuid,bigint,bigint,uuid) TO authenticated;

CREATE FUNCTION public.pos_member_loyalty_read(p_cart uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c record; cart public.pos_carts%ROWTYPE; member_data jsonb; policy jsonb;
BEGIN
  SELECT * INTO STRICT c FROM public.pos_cart_context();
  SELECT * INTO cart FROM public.pos_carts WHERE id=p_cart AND outlet_id=c.outlet_id
    AND (c.actor_role<>'KASIR' OR created_by=c.actor_id);
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_CART_NOT_FOUND'; END IF;
  policy:=public.member_loyalty_settings_effective(c.outlet_id);
  IF cart.member_id IS NOT NULL THEN
    SELECT jsonb_build_object('id',m.id,'member_number',m.member_number,'full_name',m.full_name,'status',m.status,
      'point_balance',coalesce((SELECT sum(points_delta) FROM public.member_point_ledger l WHERE l.member_id=m.id),0)::bigint)
    INTO member_data FROM public.members m WHERE m.id=cart.member_id AND m.outlet_id=c.outlet_id;
  END IF;
  RETURN jsonb_build_object('member',member_data,'policy',policy,'redeem_points_requested',cart.redeem_points_requested,
    'redeem_policy_updated_at',cart.redeem_policy_updated_at,'redeem_policy_revision',cart.redeem_policy_revision);
END $$;
ALTER FUNCTION public.pos_member_loyalty_read(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_member_loyalty_read(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_member_loyalty_read(uuid) TO authenticated;

-- Include requested points in the existing member-selection operation. Changing or removing a member clears cart redemption.
CREATE OR REPLACE FUNCTION public.pos_cart_member_set(p_cart uuid,p_member uuid,p_expected_revision bigint,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c record; cart public.pos_carts%ROWTYPE; m public.members%ROWTYPE; prior public.pos_cart_member_events%ROWTYPE; result jsonb; v_revision bigint;
BEGIN
 SELECT * INTO STRICT c FROM public.pos_cart_context();
 IF p_request IS NULL OR p_cart IS NULL OR p_expected_revision IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='MEMBER_POS_REQUEST_INVALID'; END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('POS_MEMBER_ASSOCIATION:'||p_request::text,73190418));
 SELECT * INTO prior FROM public.pos_cart_member_events WHERE request_id=p_request;
 IF FOUND THEN
   IF prior.cart_id<>p_cart OR prior.outlet_id<>c.outlet_id OR prior.actor_id<>c.actor_id OR prior.member_id IS DISTINCT FROM p_member
      OR prior.revision<>p_expected_revision+1 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='MEMBER_POS_REQUEST_REUSED'; END IF;
   RETURN jsonb_build_object('ok',true,'cart_id',prior.cart_id,'member_id',prior.member_id,'revision',prior.revision);
 END IF;
 SELECT * INTO cart FROM public.pos_carts WHERE id=p_cart AND outlet_id=c.outlet_id FOR UPDATE;
 IF NOT FOUND OR (c.actor_role='KASIR' AND cart.created_by<>c.actor_id) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_CART_NOT_FOUND'; END IF;
 IF cart.status<>'ACTIVE' OR cart.revision<>p_expected_revision THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='POS_CART_STALE'; END IF;
 IF p_member IS NOT NULL THEN
   SELECT * INTO m FROM public.members WHERE id=p_member AND outlet_id=c.outlet_id AND status='ACTIVE' FOR SHARE;
   IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_MEMBER_INACTIVE_OR_NOT_FOUND'; END IF;
 END IF;
 v_revision:=cart.revision+1;
 UPDATE public.pos_carts SET member_id=p_member,redeem_points_requested=0,redeem_policy_updated_at=NULL,redeem_policy_revision=0,revision=v_revision,updated_at=now() WHERE id=cart.id;
 INSERT INTO public.pos_cart_member_events(cart_id,outlet_id,member_id,actor_id,request_id,revision)
 VALUES(cart.id,c.outlet_id,p_member,c.actor_id,p_request,v_revision);
 result:=jsonb_build_object('ok',true,'cart_id',cart.id,'member_id',p_member,'revision',v_revision);
 RETURN result;
END $$;
ALTER FUNCTION public.pos_cart_member_set(uuid,uuid,bigint,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_cart_member_set(uuid,uuid,bigint,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_cart_member_set(uuid,uuid,bigint,uuid) TO authenticated;

-- Point events carry the exact policy and transaction evidence used at checkout.
ALTER TABLE public.sales DROP CONSTRAINT sales_discount_total_check;
ALTER TABLE public.sales ADD CONSTRAINT sales_discount_total_check CHECK(discount_total>=0);
ALTER TABLE public.member_point_ledger DROP CONSTRAINT member_point_ledger_event_type_check;
ALTER TABLE public.member_point_ledger ADD CONSTRAINT member_point_ledger_event_type_check CHECK(event_type IN
  ('EARN','REDEEM','ADJUSTMENT','REVERSAL','OPENING_BALANCE','SALE_EARN','SALE_REDEEM','SALE_EARN_REVERSAL','SALE_REDEEM_REVERSAL'));
ALTER TABLE public.member_point_ledger ADD COLUMN sale_id uuid REFERENCES public.sales(id) ON DELETE RESTRICT,
  ADD COLUMN policy_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(policy_snapshot)='object'),
  ADD COLUMN checkout_request_id uuid REFERENCES public.pos_checkout_requests(request_id) ON DELETE RESTRICT;
CREATE UNIQUE INDEX member_point_sale_event_once ON public.member_point_ledger(sale_id,event_type) WHERE sale_id IS NOT NULL;
CREATE INDEX member_point_sale_idx ON public.member_point_ledger(sale_id) WHERE sale_id IS NOT NULL;

-- The only sale writer now calculates redemption/earning under the existing sale + stock + costing transaction.

CREATE OR REPLACE FUNCTION public.pos_checkout_complete(p_request_id uuid,p_cart_id uuid,p_expected_cart_revision bigint,
  p_payment_method public.pos_sale_payment_method,p_cash_received_amount numeric DEFAULT NULL,p_reference_text text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=auth.uid(); r public.user_role; o uuid; c public.pos_carts%ROWTYPE; q public.pos_checkout_requests%ROWTYPE;
  auth_state public.inventory_cost_authority_status; period public.stock_authority_periods%ROWTYPE;
  li record; proj public.stock_balance_projection%ROWTYPE; price record; total numeric(32,2):=0; line_total numeric(32,2);
  received numeric(32,2); change_amt numeric(32,2); ref text; payload jsonb; h text; sale uuid; sale_no text;
  batch uuid; mid uuid; before_qty numeric; after_qty numeric; ver bigint; completed timestamptz:=clock_timestamp();
  response jsonb; cashier text; line_count integer:=0; effective_history uuid; effective_at timestamptz; v_line_number integer:=0;
  v_member public.members%ROWTYPE; v_loyalty public.outlet_loyalty_settings%ROWTYPE;
  v_program_enabled boolean:=false; v_redeem_enabled boolean:=false; v_earn_rate bigint; v_redeem_rate bigint; v_minimum_points bigint;
  v_requested_points bigint:=0; v_balance bigint:=0; v_discount numeric(32,2):=0; v_payable numeric(32,2); v_earned_points bigint:=0;
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
  v_requested_points:=c.redeem_points_requested;
  IF c.member_id IS NOT NULL THEN
    SELECT * INTO v_member FROM public.members WHERE id=c.member_id AND outlet_id=o FOR UPDATE;
    IF NOT FOUND OR v_member.status<>'ACTIVE' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_MEMBER_INACTIVE_OR_NOT_FOUND'; END IF;
    SELECT coalesce(sum(points_delta),0)::bigint INTO v_balance FROM public.member_point_ledger WHERE member_id=c.member_id;
  END IF;
  SELECT * INTO v_loyalty FROM public.outlet_loyalty_settings WHERE outlet_id=o FOR SHARE;
  IF FOUND THEN
    v_program_enabled:=v_loyalty.program_enabled; v_redeem_enabled:=v_loyalty.redeem_enabled;
    v_earn_rate:=v_loyalty.rupiah_per_point; v_redeem_rate:=v_loyalty.rupiah_per_redeem_point; v_minimum_points:=v_loyalty.minimum_redeem_points;
  END IF;
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
  v_payable:=total;
  IF v_requested_points>0 THEN
    IF c.member_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_LOYALTY_MEMBER_REQUIRED'; END IF;
    IF NOT v_program_enabled OR NOT v_redeem_enabled OR v_redeem_rate IS NULL OR v_minimum_points IS NULL THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_LOYALTY_REDEEM_DISABLED'; END IF;
    IF v_loyalty.policy_revision IS DISTINCT FROM c.redeem_policy_revision THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_LOYALTY_POLICY_CHANGED'; END IF;
    IF v_requested_points<v_minimum_points THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_LOYALTY_BELOW_MINIMUM'; END IF;
    IF v_requested_points>v_balance THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_LOYALTY_INSUFFICIENT_POINTS'; END IF;
    v_discount:=v_requested_points::numeric*v_redeem_rate;
    IF v_discount>total THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_LOYALTY_EXCEEDS_PAYABLE'; END IF;
    v_payable:=total-v_discount;
  END IF;
  IF v_member.id IS NOT NULL AND v_program_enabled AND v_earn_rate IS NOT NULL THEN
    v_earned_points:=floor(v_payable/v_earn_rate)::bigint;
  END IF;
  IF p_payment_method='CASH' THEN
    received:=round(p_cash_received_amount,2); IF received<v_payable THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_PAYMENT_INVALID'; END IF;
    change_amt:=received-v_payable;
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
  VALUES(sale,o,a,a,p_cart_id,p_request_id,sale_no,total,v_discount,v_payable,completed);
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
  IF v_payable>0 THEN
    INSERT INTO public.sale_payments(sale_id,outlet_id,method,applied_amount,received_amount,change_amount,reference_text,recorded_by)
    VALUES(sale,o,p_payment_method,v_payable,received,change_amt,ref,a);
  END IF;
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
  IF v_requested_points>0 THEN
    INSERT INTO public.member_point_ledger(member_id,outlet_id,event_type,points_delta,source_type,source_reference,occurred_at,actor_id,note,request_id,sale_id,policy_snapshot,checkout_request_id)
    VALUES(c.member_id,o,'SALE_REDEEM',-v_requested_points,'QUENA_POS_SALE',sale::text,completed,a,'Poin digunakan pada transaksi '||sale_no,gen_random_uuid(),sale,
      jsonb_build_object('points',v_requested_points,'rupiah_per_redeem_point',v_redeem_rate,'minimum_redeem_points',v_minimum_points,
        'discount_amount',v_discount::text,'balance_after_event',v_balance-v_requested_points,'policy_revision',v_loyalty.policy_revision,
        'policy_updated_at',v_loyalty.updated_at),p_request_id);
  END IF;
  IF v_earned_points>0 THEN
    INSERT INTO public.member_point_ledger(member_id,outlet_id,event_type,points_delta,source_type,source_reference,occurred_at,actor_id,note,request_id,sale_id,policy_snapshot,checkout_request_id)
    VALUES(c.member_id,o,'SALE_EARN',v_earned_points,'QUENA_POS_SALE',sale::text,completed,a,'Poin diperoleh dari transaksi '||sale_no,gen_random_uuid(),sale,
      jsonb_build_object('eligible_spend',v_payable::text,'awarded_points',v_earned_points,'rupiah_per_point',v_earn_rate,
        'balance_after_event',v_balance-v_requested_points+v_earned_points,'program_enabled',v_program_enabled,
        'policy_revision',v_loyalty.policy_revision,'policy_updated_at',v_loyalty.updated_at),p_request_id);
  END IF;
  UPDATE public.pos_carts SET status='COMPLETED',revision=revision+1,updated_at=now() WHERE id=p_cart_id;
  INSERT INTO public.pos_cart_events(cart_id,outlet_id,event_type,actor_id,checkout_request_id,revision,event_data)
    VALUES(p_cart_id,o,'COMPLETED',a,p_request_id,c.revision+1,jsonb_build_object('sale_number',sale_no));
  response:=jsonb_build_object('sale_id',sale,'sale_number',sale_no,'completed_at',completed,'cashier_label',cashier,
    'items',(SELECT jsonb_agg(jsonb_build_object('name',si.product_name_snapshot,'sku',si.sku_snapshot,'unit',si.unit_snapshot,
      'quantity',si.quantity,'unit_selling_price',si.unit_selling_price,'line_subtotal',si.line_subtotal) ORDER BY si.line_number)
      FROM public.sale_items si WHERE si.sale_id=sale),'subtotal',total,'discount_total',0,'grand_total',total,
    'payment_method',p_payment_method,'cash_received_amount',received,'change_amount',change_amt,'reference_text',ref,
    'discount_total',v_discount,'grand_total',v_payable,
    'points_earned',v_earned_points,'points_redeemed',v_requested_points,'points_discount',v_discount,
    'point_balance',CASE WHEN v_member.id IS NULL THEN NULL ELSE (SELECT coalesce(sum(points_delta),0)::bigint FROM public.member_point_ledger WHERE member_id=v_member.id) END);
  UPDATE public.pos_checkout_requests SET state='COMPLETED',sale_id=sale,result=response,completed_at=completed WHERE request_id=p_request_id;
  UPDATE public.stock_operation_requests SET state='COMPLETED',result=jsonb_build_object('sale_id',sale,'sale_number',sale_no),completed_at=completed WHERE request_id=p_request_id;
  RETURN response;
END; $$;
ALTER FUNCTION public.pos_checkout_complete(uuid,uuid,bigint,public.pos_sale_payment_method,numeric,text) OWNER TO postgres;

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
    'outlet_address',CASE WHEN coalesce(ps.receipt_show_address,true) THEN nullif(concat_ws(', ',nullif(btrim(o.address),''),nullif(btrim(o.city),''),nullif(btrim(o.province),''),nullif(btrim(o.postal_code),'')),'') END,
    'outlet_phone',CASE WHEN coalesce(ps.receipt_show_phone,true) THEN o.phone END,
    'outlet_whatsapp',CASE WHEN coalesce(ps.receipt_show_phone,true) THEN o.whatsapp END,
    'receipt_footer_note',ps.receipt_footer_note,
    'member',CASE WHEN s.member_id IS NULL THEN NULL ELSE jsonb_build_object('member_number',m.member_number,'full_name',m.full_name) END,
    'loyalty',CASE WHEN EXISTS(SELECT 1 FROM public.member_point_ledger l WHERE l.sale_id=s.id) THEN jsonb_build_object(
      'points_earned',coalesce((SELECT sum(l.points_delta) FROM public.member_point_ledger l WHERE l.sale_id=s.id AND l.event_type='SALE_EARN'),0),
      'points_redeemed',coalesce((SELECT -sum(l.points_delta) FROM public.member_point_ledger l WHERE l.sale_id=s.id AND l.event_type='SALE_REDEEM'),0),
      'points_discount',coalesce((SELECT (l.policy_snapshot->>'discount_amount')::numeric FROM public.member_point_ledger l WHERE l.sale_id=s.id AND l.event_type='SALE_REDEEM'),0)
    ) END,
    'items',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',si.product_name_snapshot,'sku',si.sku_snapshot,'unit',si.unit_snapshot,
      'quantity',si.quantity,'unit_selling_price',si.unit_selling_price,'line_subtotal',si.line_subtotal) ORDER BY si.line_number),'[]'::jsonb)
      FROM public.sale_items si WHERE si.sale_id=s.id AND si.outlet_id=s.outlet_id),
    'subtotal',s.subtotal,'discount_total',s.discount_total,'grand_total',s.grand_total,
    'payments',(SELECT coalesce(jsonb_agg(jsonb_build_object('method',sp.method,'applied_amount',sp.applied_amount,
      'received_amount',sp.received_amount,'change_amount',sp.change_amount,'reference_text',sp.reference_text) ORDER BY sp.recorded_at,sp.id),'[]'::jsonb)
      FROM public.sale_payments sp WHERE sp.sale_id=s.id AND sp.outlet_id=s.outlet_id)
  ) INTO v_result
  FROM public.sales s JOIN public.pos_checkout_requests cr ON cr.request_id=s.checkout_request_id AND cr.outlet_id=s.outlet_id
  JOIN public.outlets o ON o.id=s.outlet_id LEFT JOIN public.outlet_pos_settings ps ON ps.outlet_id=o.id
  LEFT JOIN public.members m ON m.id=s.member_id AND m.outlet_id=s.outlet_id
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
