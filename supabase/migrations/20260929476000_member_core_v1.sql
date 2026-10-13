-- Member identity and immutable loyalty-ledger foundation. Sales remain optional-member.
BEGIN;

CREATE SEQUENCE public.member_number_seq AS bigint START WITH 1 INCREMENT BY 1 NO CYCLE;
REVOKE ALL ON SEQUENCE public.member_number_seq FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.member_normalize_phone(p_phone text)
RETURNS text LANGUAGE plpgsql IMMUTABLE STRICT SET search_path=pg_catalog AS $$
DECLARE d text:=regexp_replace(p_phone,'[^0-9]','','g');
BEGIN
  IF d LIKE '00%' THEN d:=substr(d,3); END IF;
  IF d LIKE '0%' THEN d:='62'||substr(d,2); END IF;
  RETURN d;
END $$;
ALTER FUNCTION public.member_normalize_phone(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_normalize_phone(text) FROM PUBLIC,anon,authenticated,service_role;

CREATE TABLE public.members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  member_number text NOT NULL UNIQUE,
  member_token uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  full_name text NOT NULL CHECK (btrim(full_name)<>'' AND length(btrim(full_name))<=160),
  phone text NOT NULL CHECK (btrim(phone)<>'' AND length(btrim(phone))<=40),
  phone_normalized text GENERATED ALWAYS AS (public.member_normalize_phone(phone)) STORED,
  email text CHECK (email IS NULL OR (btrim(email)<>'' AND length(email)<=254)),
  status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
  joined_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  updated_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  CONSTRAINT members_id_outlet_unique UNIQUE(id,outlet_id),
  CONSTRAINT members_phone_normalized_valid CHECK (phone_normalized ~ '^[0-9]{8,15}$')
);
CREATE UNIQUE INDEX members_active_phone_once ON public.members(outlet_id,phone_normalized) WHERE status='ACTIVE';
CREATE INDEX members_outlet_name_idx ON public.members(outlet_id,lower(full_name),id);
CREATE INDEX members_outlet_number_idx ON public.members(outlet_id,member_number);

ALTER TABLE public.pos_carts ADD COLUMN member_id uuid;
ALTER TABLE public.pos_carts ADD CONSTRAINT pos_carts_member_outlet_fk
  FOREIGN KEY(member_id,outlet_id) REFERENCES public.members(id,outlet_id) ON DELETE RESTRICT;
ALTER TABLE public.sales ADD COLUMN member_id uuid;
ALTER TABLE public.sales ADD CONSTRAINT sales_member_outlet_fk
  FOREIGN KEY(member_id,outlet_id) REFERENCES public.members(id,outlet_id) ON DELETE RESTRICT;
CREATE INDEX sales_member_time_idx ON public.sales(member_id,completed_at DESC,id DESC) WHERE member_id IS NOT NULL;

CREATE TABLE public.member_audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id uuid NOT NULL REFERENCES public.members(id) ON DELETE RESTRICT,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK(event_type IN ('MEMBER_CREATED','MEMBER_UPDATED','MEMBER_STATUS_CHANGED')),
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  changed_fields text[] NOT NULL DEFAULT '{}',
  reason text CHECK(reason IS NULL OR (btrim(reason)<>'' AND length(reason)<=300)),
  request_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(request_id)
);
CREATE INDEX member_audit_member_time_idx ON public.member_audit_events(member_id,created_at DESC,id DESC);

CREATE FUNCTION public.guard_member_audit_immutable()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Member audit evidence is append-only'; END $$;
ALTER FUNCTION public.guard_member_audit_immutable() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_member_audit_immutable() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER member_audit_immutable BEFORE UPDATE OR DELETE ON public.member_audit_events
  FOR EACH ROW EXECUTE FUNCTION public.guard_member_audit_immutable();

CREATE TABLE public.member_point_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id uuid NOT NULL,
  outlet_id uuid NOT NULL,
  event_type text NOT NULL CHECK(event_type IN ('EARN','REDEEM','ADJUSTMENT','REVERSAL','OPENING_BALANCE')),
  points_delta bigint NOT NULL CHECK(points_delta<>0),
  source_type text NOT NULL CHECK(length(btrim(source_type)) BETWEEN 1 AND 40),
  source_reference text NOT NULL CHECK(length(btrim(source_reference)) BETWEEN 1 AND 160),
  occurred_at timestamptz NOT NULL,
  actor_id uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  note text CHECK(note IS NULL OR (btrim(note)<>'' AND length(note)<=500)),
  request_id uuid NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT member_point_ledger_member_fk FOREIGN KEY(member_id,outlet_id)
    REFERENCES public.members(id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT member_point_source_once UNIQUE(member_id,source_type,source_reference,event_type)
);
CREATE INDEX member_point_ledger_member_time_idx ON public.member_point_ledger(member_id,occurred_at DESC,id DESC);
CREATE FUNCTION public.guard_member_point_ledger_immutable()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Member point ledger is append-only'; END $$;
ALTER FUNCTION public.guard_member_point_ledger_immutable() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_member_point_ledger_immutable() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER member_point_ledger_immutable BEFORE UPDATE OR DELETE ON public.member_point_ledger
  FOR EACH ROW EXECUTE FUNCTION public.guard_member_point_ledger_immutable();

ALTER TABLE public.members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.members FORCE ROW LEVEL SECURITY;
ALTER TABLE public.member_audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_audit_events FORCE ROW LEVEL SECURITY;
ALTER TABLE public.member_point_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_point_ledger FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.members,public.member_audit_events,public.member_point_ledger FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.member_current_outlet()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE n integer; o uuid;
BEGIN
 SELECT count(*)::integer,(array_agg(outlet_id ORDER BY started_at DESC))[1] INTO n,o
 FROM public.stock_authority_periods WHERE ended_at IS NULL;
 IF n<>1 OR o IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='MEMBER_OUTLET_UNAVAILABLE'; END IF;
 RETURN o;
END $$;
ALTER FUNCTION public.member_current_outlet() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_current_outlet() FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.member_workspace_page(p_search text DEFAULT '',p_page integer DEFAULT 1,p_page_size integer DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid;
 q text:=left(replace(replace(btrim(coalesce(p_search,'')),'%',''),'_',''),80); pg integer:=greatest(coalesce(p_page,1),1);
 sz integer:=least(greatest(coalesce(p_page_size,20),1),30); rows_json jsonb; total integer;
BEGIN
 IF a IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
   RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='MEMBER_WORKSPACE_DENIED'; END IF;
 o:=public.member_current_outlet();
 WITH selected AS (
   SELECT m.id,m.member_number,m.full_name,m.phone,m.email,m.status,m.joined_at,
     coalesce((SELECT sum(l.points_delta) FROM public.member_point_ledger l WHERE l.member_id=m.id),0)::bigint point_balance,
     count(s.id)::integer transaction_count,coalesce(sum(s.grand_total),0)::numeric(32,2) total_spend
   FROM public.members m LEFT JOIN public.sales s ON s.member_id=m.id AND s.status='COMPLETED' AND s.source_system='QUENA_POS'
   WHERE m.outlet_id=o AND (q='' OR lower(m.full_name) LIKE lower(q)||'%' OR (public.member_normalize_phone(q)<>'' AND m.phone_normalized LIKE public.member_normalize_phone(q)||'%')
     OR m.member_number LIKE q||'%' OR m.member_token::text=q)
   GROUP BY m.id
 ) SELECT count(*) INTO total FROM selected;
 WITH selected AS (
   SELECT m.id,m.member_number,m.member_token,m.full_name,m.phone,m.email,m.status,m.joined_at,
     coalesce((SELECT sum(l.points_delta) FROM public.member_point_ledger l WHERE l.member_id=m.id),0)::bigint point_balance,
     count(s.id)::integer transaction_count,coalesce(sum(s.grand_total),0)::numeric(32,2) total_spend
   FROM public.members m LEFT JOIN public.sales s ON s.member_id=m.id AND s.status='COMPLETED' AND s.source_system='QUENA_POS'
   WHERE m.outlet_id=o AND (q='' OR lower(m.full_name) LIKE lower(q)||'%' OR (public.member_normalize_phone(q)<>'' AND m.phone_normalized LIKE public.member_normalize_phone(q)||'%')
     OR m.member_number LIKE q||'%' OR m.member_token::text=q)
   GROUP BY m.id
 ) SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.full_name,x.id),'[]'::jsonb) INTO rows_json
 FROM (SELECT * FROM selected ORDER BY full_name,id OFFSET (pg-1)*sz LIMIT sz) x;
 RETURN jsonb_build_object('rows',rows_json,'total',total,'page',pg,'pageSize',sz);
END $$;
ALTER FUNCTION public.member_workspace_page(text,integer,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_workspace_page(text,integer,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.member_workspace_page(text,integer,integer) TO authenticated;

CREATE FUNCTION public.member_pos_search(p_search text,p_limit integer DEFAULT 10)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid; q text:=left(replace(replace(btrim(coalesce(p_search,'')),'%',''),'_',''),80); result jsonb;
BEGIN
 IF a IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'KASIR'::public.user_role) THEN
   RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='MEMBER_POS_LOOKUP_DENIED'; END IF;
 o:=public.member_current_outlet();
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.full_name,x.member_number),'[]'::jsonb) INTO result FROM (
   SELECT id,member_number,member_token,full_name,phone,status,
     coalesce((SELECT sum(points_delta) FROM public.member_point_ledger WHERE member_id=m.id),0)::bigint point_balance
   FROM public.members m WHERE outlet_id=o AND status='ACTIVE' AND q<>'' AND
     (lower(full_name) LIKE lower(q)||'%' OR (public.member_normalize_phone(q)<>'' AND phone_normalized LIKE public.member_normalize_phone(q)||'%') OR member_number LIKE q||'%' OR member_token::text=q)
   ORDER BY CASE WHEN member_number=q OR member_token::text=q OR phone_normalized=public.member_normalize_phone(q) THEN 0 ELSE 1 END,full_name,id
   LIMIT least(greatest(coalesce(p_limit,10),1),10)
 ) x;
 RETURN jsonb_build_object('rows',result);
END $$;
ALTER FUNCTION public.member_pos_search(text,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_pos_search(text,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.member_pos_search(text,integer) TO authenticated;

CREATE FUNCTION public.member_detail_read(p_member uuid,p_page integer DEFAULT 1,p_page_size integer DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid; m jsonb; tx jsonb; ledger jsonb; pg integer:=greatest(coalesce(p_page,1),1); sz integer:=least(greatest(coalesce(p_page_size,20),1),30);
BEGIN
 IF a IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='MEMBER_WORKSPACE_DENIED'; END IF;
 o:=public.member_current_outlet();
 SELECT to_jsonb(x) INTO m FROM (
   SELECT mb.id,mb.member_number,mb.member_token,mb.full_name,mb.phone,mb.email,mb.status,mb.joined_at,mb.created_at,mb.updated_at,
     coalesce((SELECT sum(l.points_delta) FROM public.member_point_ledger l WHERE l.member_id=mb.id),0)::bigint point_balance,
     (SELECT count(*) FROM public.sales s WHERE s.member_id=mb.id AND s.status='COMPLETED' AND s.source_system='QUENA_POS')::integer transaction_count,
     coalesce((SELECT sum(s.grand_total) FROM public.sales s WHERE s.member_id=mb.id AND s.status='COMPLETED' AND s.source_system='QUENA_POS'),0)::numeric(32,2)::text total_spend
   FROM public.members mb WHERE mb.id=p_member AND mb.outlet_id=o
 ) x;
 IF m IS NULL THEN RETURN NULL; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.completed_at DESC,x.id DESC),'[]'::jsonb) INTO tx FROM (
   SELECT s.id,s.sale_number,s.completed_at,s.grand_total::text,
     (SELECT count(*)::integer FROM public.sale_items i WHERE i.sale_id=s.id)::integer item_count,s.source_system
   FROM public.sales s WHERE s.member_id=p_member AND s.status='COMPLETED' AND s.source_system='QUENA_POS'
   ORDER BY s.completed_at DESC,s.id DESC OFFSET (pg-1)*sz LIMIT sz
 ) x;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.occurred_at DESC,x.id DESC),'[]'::jsonb) INTO ledger FROM (
   SELECT id,event_type,points_delta,source_type,source_reference,occurred_at,note
   FROM public.member_point_ledger WHERE member_id=p_member ORDER BY occurred_at DESC,id DESC OFFSET (pg-1)*sz LIMIT sz
 ) x;
 RETURN jsonb_build_object('member',m,'transactions',tx,'pointsHistory',ledger,'page',pg,'pageSize',sz);
END $$;
ALTER FUNCTION public.member_detail_read(uuid,integer,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_detail_read(uuid,integer,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.member_detail_read(uuid,integer,integer) TO authenticated;

CREATE FUNCTION public.member_upsert(p_member_id uuid,p_full_name text,p_phone text,p_email text,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid; m public.members%ROWTYPE; mid uuid;
 fields text[]; t text:=btrim(coalesce(p_full_name,'')); ph text:=btrim(coalesce(p_phone,'')); em text:=nullif(btrim(coalesce(p_email,'')),'');
BEGIN
 IF a IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'KASIR'::public.user_role)
   OR (p_member_id IS NOT NULL AND r='KASIR'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='MEMBER_WRITE_DENIED'; END IF;
 IF p_request_id IS NULL OR t='' OR length(t)>160 OR ph='' OR length(ph)>40 OR public.member_normalize_phone(ph)!~'^[0-9]{8,15}$'
   OR (em IS NOT NULL AND (length(em)>254 OR em !~* '^[A-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,}$')) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='MEMBER_FIELDS_INVALID'; END IF;
 o:=public.member_current_outlet();
 IF p_member_id IS NULL THEN
   INSERT INTO public.members(outlet_id,member_number,full_name,phone,email,created_by,updated_by)
   VALUES(o,'QMEM-'||lpad(nextval('public.member_number_seq')::text,8,'0'),t,ph,em,a,a) RETURNING * INTO m;
   INSERT INTO public.member_audit_events(member_id,outlet_id,event_type,actor_id,changed_fields,request_id)
   VALUES(m.id,o,'MEMBER_CREATED',a,ARRAY['full_name','phone','email'],p_request_id);
   RETURN jsonb_build_object('id',m.id,'member_number',m.member_number,'member_token',m.member_token,'full_name',m.full_name,'phone',m.phone,'email',m.email,'status',m.status,'point_balance',0);
 END IF;
 SELECT * INTO m FROM public.members WHERE id=p_member_id AND outlet_id=o FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='MEMBER_NOT_FOUND'; END IF;
 fields:=array_remove(ARRAY[CASE WHEN m.full_name IS DISTINCT FROM t THEN 'full_name' END,
   CASE WHEN m.phone IS DISTINCT FROM ph THEN 'phone' END,CASE WHEN m.email IS DISTINCT FROM em THEN 'email' END],NULL);
 IF cardinality(fields)=0 THEN RETURN jsonb_build_object('id',m.id,'member_number',m.member_number,'member_token',m.member_token,'full_name',m.full_name,'phone',m.phone,'email',m.email,'status',m.status,'point_balance',coalesce((SELECT sum(points_delta) FROM public.member_point_ledger WHERE member_id=m.id),0)); END IF;
 UPDATE public.members SET full_name=t,phone=ph,email=em,updated_by=a,updated_at=now() WHERE id=m.id RETURNING * INTO m;
 INSERT INTO public.member_audit_events(member_id,outlet_id,event_type,actor_id,changed_fields,request_id)
 VALUES(m.id,o,'MEMBER_UPDATED',a,fields,p_request_id);
 RETURN jsonb_build_object('id',m.id,'member_number',m.member_number,'member_token',m.member_token,'full_name',m.full_name,'phone',m.phone,'email',m.email,'status',m.status,'point_balance',coalesce((SELECT sum(points_delta) FROM public.member_point_ledger WHERE member_id=m.id),0));
END $$;
ALTER FUNCTION public.member_upsert(uuid,text,text,text,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_upsert(uuid,text,text,text,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.member_upsert(uuid,text,text,text,uuid) TO authenticated;

CREATE FUNCTION public.member_status_set(p_member_id uuid,p_status text,p_reason text,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid; m public.members%ROWTYPE;
BEGIN
 IF a IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='MEMBER_WRITE_DENIED'; END IF;
 IF p_status IS NULL OR p_status NOT IN ('ACTIVE','INACTIVE') OR p_request_id IS NULL OR p_reason IS NULL OR btrim(p_reason)='' OR length(btrim(p_reason))>300 THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='MEMBER_STATUS_INVALID'; END IF;
 o:=public.member_current_outlet(); SELECT * INTO m FROM public.members WHERE id=p_member_id AND outlet_id=o FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='MEMBER_NOT_FOUND'; END IF;
 IF m.status=p_status THEN RETURN jsonb_build_object('id',m.id,'status',m.status,'changed',false); END IF;
 UPDATE public.members SET status=p_status,updated_by=a,updated_at=now() WHERE id=m.id;
 INSERT INTO public.member_audit_events(member_id,outlet_id,event_type,actor_id,changed_fields,request_id,reason)
 VALUES(m.id,o,'MEMBER_STATUS_CHANGED',a,ARRAY['status'],p_request_id,btrim(p_reason));
 RETURN jsonb_build_object('id',m.id,'status',p_status,'changed',true);
END $$;
ALTER FUNCTION public.member_status_set(uuid,text,text,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_status_set(uuid,text,text,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.member_status_set(uuid,text,text,uuid) TO authenticated;

-- The separate association event preserves auditability without expanding the legacy cart enum.
CREATE TABLE public.pos_cart_member_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), cart_id uuid NOT NULL, outlet_id uuid NOT NULL,
 member_id uuid, actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
 request_id uuid NOT NULL UNIQUE, revision bigint NOT NULL CHECK(revision>0), created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(cart_id,outlet_id) REFERENCES public.pos_carts(id,outlet_id) ON DELETE RESTRICT,
 FOREIGN KEY(member_id,outlet_id) REFERENCES public.members(id,outlet_id) ON DELETE RESTRICT
);

CREATE FUNCTION public.pos_cart_member_set(p_cart uuid,p_member uuid,p_expected_revision bigint,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c record; cart public.pos_carts%ROWTYPE; m public.members%ROWTYPE; prior public.pos_cart_member_events%ROWTYPE; result jsonb;
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
 UPDATE public.pos_carts SET member_id=p_member,revision=revision+1,updated_at=now() WHERE id=cart.id;
 INSERT INTO public.pos_cart_member_events(cart_id,outlet_id,member_id,actor_id,request_id,revision)
 VALUES(cart.id,c.outlet_id,p_member,c.actor_id,p_request,cart.revision+1);
 result:=jsonb_build_object('ok',true,'cart_id',cart.id,'member_id',p_member,'revision',cart.revision+1);
 RETURN result;
END $$;

CREATE INDEX pos_cart_member_events_time_idx ON public.pos_cart_member_events(cart_id,created_at DESC);
CREATE FUNCTION public.guard_pos_cart_member_event_immutable() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POS member association events are append-only'; END $$;
ALTER FUNCTION public.guard_pos_cart_member_event_immutable() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_pos_cart_member_event_immutable() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER pos_cart_member_events_immutable BEFORE UPDATE OR DELETE ON public.pos_cart_member_events FOR EACH ROW EXECUTE FUNCTION public.guard_pos_cart_member_event_immutable();
ALTER FUNCTION public.pos_cart_member_set(uuid,uuid,bigint,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_cart_member_set(uuid,uuid,bigint,uuid) FROM PUBLIC,anon,service_role;
REVOKE ALL ON public.pos_cart_member_events FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.pos_cart_member_set(uuid,uuid,bigint,uuid) TO authenticated;

CREATE FUNCTION public.member_pos_cart_read(p_cart uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c record; selected_cart public.pos_carts%ROWTYPE; result jsonb;
BEGIN
 SELECT * INTO STRICT c FROM public.pos_cart_context();
 SELECT * INTO selected_cart FROM public.pos_carts WHERE id=p_cart AND outlet_id=c.outlet_id
   AND (c.actor_role<>'KASIR' OR created_by=c.actor_id);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_CART_NOT_FOUND'; END IF;
 SELECT CASE WHEN m.id IS NULL THEN NULL ELSE jsonb_build_object(
   'id',m.id,'member_number',m.member_number,'member_token',m.member_token,'full_name',m.full_name,
   'phone',m.phone,'status',m.status,'point_balance',
   coalesce((SELECT sum(l.points_delta) FROM public.member_point_ledger l WHERE l.member_id=m.id),0)::bigint) END
 INTO result FROM (SELECT 1) seed LEFT JOIN public.members m ON m.id=selected_cart.member_id AND m.outlet_id=c.outlet_id;
 RETURN jsonb_build_object('member',result);
END $$;
ALTER FUNCTION public.member_pos_cart_read(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_pos_cart_read(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.member_pos_cart_read(uuid) TO authenticated;

CREATE FUNCTION public.member_checkout_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE m uuid;
BEGIN
 IF NEW.source_system<>'QUENA_POS'::public.pos_sale_source THEN
   NEW.member_id:=NULL;
   RETURN NEW;
 END IF;
 SELECT c.member_id INTO m FROM public.pos_carts c WHERE c.id=NEW.pos_cart_id AND c.outlet_id=NEW.outlet_id;
 IF m IS NOT NULL THEN
   PERFORM 1 FROM public.members WHERE id=m AND outlet_id=NEW.outlet_id AND status='ACTIVE' FOR SHARE;
   IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='POS_MEMBER_INACTIVE_OR_NOT_FOUND'; END IF;
 END IF;
 NEW.member_id:=m;
 RETURN NEW;
END $$;
ALTER FUNCTION public.member_checkout_guard() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_checkout_guard() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER sales_member_checkout_guard BEFORE INSERT ON public.sales FOR EACH ROW EXECUTE FUNCTION public.member_checkout_guard();

CREATE FUNCTION public.member_workspace_read(p_search text DEFAULT '',p_page integer DEFAULT 1,p_page_size integer DEFAULT 20)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT public.member_workspace_page(p_search,p_page,p_page_size)
$$;
ALTER FUNCTION public.member_workspace_read(text,integer,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_workspace_read(text,integer,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.member_workspace_read(text,integer,integer) TO authenticated;

CREATE FUNCTION public.member_point_balance(p_member uuid)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(sum(points_delta),0)::bigint FROM public.member_point_ledger WHERE member_id=p_member
$$;
ALTER FUNCTION public.member_point_balance(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_point_balance(uuid) FROM PUBLIC,anon,authenticated,service_role;

REVOKE ALL ON FUNCTION public.member_current_outlet() FROM PUBLIC,anon,authenticated,service_role;

COMMIT;
