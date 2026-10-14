-- Public membership registration and privacy-safe POS member lookup.
BEGIN;

ALTER TABLE public.members ALTER COLUMN created_by DROP NOT NULL;
ALTER TABLE public.members ALTER COLUMN updated_by DROP NOT NULL;

CREATE TABLE public.member_consent_evidence (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id uuid NOT NULL REFERENCES public.members(id) ON DELETE RESTRICT,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  consent_type text NOT NULL CHECK (consent_type IN ('MEMBERSHIP_SERVICE','PROMOTIONAL_WHATSAPP')),
  granted boolean NOT NULL,
  source text NOT NULL CHECK (source IN ('PUBLIC_REGISTRATION','POS_ENROLLMENT')),
  policy_version text NOT NULL CHECK (length(btrim(policy_version)) BETWEEN 1 AND 60),
  actor_id uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  request_id uuid NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(request_id,consent_type),
  FOREIGN KEY(member_id,outlet_id) REFERENCES public.members(id,outlet_id) ON DELETE RESTRICT
);
CREATE INDEX member_consent_member_time_idx ON public.member_consent_evidence(member_id,occurred_at DESC);
ALTER TABLE public.member_consent_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_consent_evidence FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.member_consent_evidence FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.guard_member_consent_immutable() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Member consent evidence is append-only'; END $$;
ALTER FUNCTION public.guard_member_consent_immutable() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_member_consent_immutable() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER member_consent_immutable BEFORE UPDATE OR DELETE ON public.member_consent_evidence
  FOR EACH ROW EXECUTE FUNCTION public.guard_member_consent_immutable();

CREATE TABLE public.member_public_registration_limits (
  scope text NOT NULL CHECK (scope IN ('IP','PHONE')),
  digest text NOT NULL CHECK (digest ~ '^[0-9a-f]{64}$'),
  window_started_at timestamptz NOT NULL,
  attempt_count integer NOT NULL CHECK (attempt_count > 0),
  PRIMARY KEY(scope,digest)
);
CREATE TABLE public.member_public_registration_requests (
  request_id uuid PRIMARY KEY,
  status text NOT NULL CHECK (status IN ('CREATED','ALREADY_REGISTERED','RATE_LIMITED')),
  member_number text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((status='CREATED') = (member_number IS NOT NULL))
);
CREATE INDEX member_public_registration_limits_window_idx ON public.member_public_registration_limits(window_started_at);
CREATE INDEX member_public_registration_requests_created_idx ON public.member_public_registration_requests(created_at);
ALTER TABLE public.member_public_registration_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_public_registration_limits FORCE ROW LEVEL SECURITY;
ALTER TABLE public.member_public_registration_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_public_registration_requests FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.member_public_registration_limits,public.member_public_registration_requests FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.member_mask_phone(p_phone text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog AS $$
  SELECT CASE WHEN length(p_phone)<=4 THEN repeat('•',length(p_phone))
    ELSE left(p_phone,least(2,length(p_phone)-4)) || repeat('•',greatest(length(p_phone)-6,2)) || right(p_phone,4) END
$$;
ALTER FUNCTION public.member_mask_phone(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_mask_phone(text) FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.member_pos_search(p_search text,p_limit integer DEFAULT 10)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid;
  q text:=left(replace(replace(btrim(coalesce(p_search,'')),'%',''),'_',''),80); result jsonb;
BEGIN
 IF a IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'KASIR'::public.user_role) THEN
   RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='MEMBER_POS_LOOKUP_DENIED'; END IF;
 o:=public.member_current_outlet();
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.full_name,x.member_number),'[]'::jsonb) INTO result FROM (
   SELECT id,member_number,full_name,public.member_mask_phone(phone) phone_masked,status,
     coalesce((SELECT sum(points_delta) FROM public.member_point_ledger WHERE member_id=m.id),0)::bigint point_balance,
     (member_number=q OR member_token::text=q OR phone_normalized=public.member_normalize_phone(q)) exact_match
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

CREATE OR REPLACE FUNCTION public.member_pos_cart_read(p_cart uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c record; selected_cart public.pos_carts%ROWTYPE; result jsonb;
BEGIN
 SELECT * INTO STRICT c FROM public.pos_cart_context();
 SELECT * INTO selected_cart FROM public.pos_carts WHERE id=p_cart AND outlet_id=c.outlet_id
   AND (c.actor_role<>'KASIR' OR created_by=c.actor_id);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_CART_NOT_FOUND'; END IF;
 SELECT CASE WHEN m.id IS NULL THEN NULL ELSE jsonb_build_object(
   'id',m.id,'member_number',m.member_number,'full_name',m.full_name,'phone_masked',public.member_mask_phone(m.phone),'status',m.status,'point_balance',
   coalesce((SELECT sum(l.points_delta) FROM public.member_point_ledger l WHERE l.member_id=m.id),0)::bigint) END
 INTO result FROM (SELECT 1) seed LEFT JOIN public.members m ON m.id=selected_cart.member_id AND m.outlet_id=c.outlet_id;
 RETURN jsonb_build_object('member',result);
END $$;
ALTER FUNCTION public.member_pos_cart_read(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_pos_cart_read(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.member_pos_cart_read(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.pos_member_loyalty_read(p_cart uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c record; cart public.pos_carts%ROWTYPE; member_data jsonb; policy jsonb;
BEGIN
  SELECT * INTO STRICT c FROM public.pos_cart_context();
  SELECT * INTO cart FROM public.pos_carts WHERE id=p_cart AND outlet_id=c.outlet_id
    AND (c.actor_role<>'KASIR' OR created_by=c.actor_id);
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_CART_NOT_FOUND'; END IF;
  policy:=public.member_loyalty_settings_effective(c.outlet_id);
  IF cart.member_id IS NOT NULL THEN
    SELECT jsonb_build_object('id',m.id,'member_number',m.member_number,'full_name',m.full_name,'phone_masked',public.member_mask_phone(m.phone),'status',m.status,
      'point_balance',coalesce((SELECT sum(points_delta) FROM public.member_point_ledger l WHERE l.member_id=m.id),0)::bigint)
    INTO member_data FROM public.members m WHERE m.id=cart.member_id AND m.outlet_id=c.outlet_id;
  END IF;
  RETURN jsonb_build_object('member',member_data,'policy',policy,'redeem_points_requested',cart.redeem_points_requested,
    'redeem_policy_updated_at',cart.redeem_policy_updated_at,'redeem_policy_revision',cart.redeem_policy_revision);
END $$;
ALTER FUNCTION public.pos_member_loyalty_read(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_member_loyalty_read(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_member_loyalty_read(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.member_upsert(p_member_id uuid,p_full_name text,p_phone text,p_email text,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid; m public.members%ROWTYPE;
  fields text[]; t text:=btrim(coalesce(p_full_name,'')); ph text:=btrim(coalesce(p_phone,'')); em text:=nullif(btrim(coalesce(p_email,'')),'');
BEGIN
 IF a IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
   RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='MEMBER_WRITE_DENIED'; END IF;
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

CREATE FUNCTION public.pos_member_register(p_cart uuid,p_expected_revision bigint,p_full_name text,p_phone text,p_email text,p_request_id uuid,
  p_membership_consent boolean,p_promotional_consent boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid; cart_result jsonb; normalized text;
  new_member public.members%ROWTYPE; t text:=btrim(coalesce(p_full_name,'')); ph text:=btrim(coalesce(p_phone,'')); em text:=nullif(btrim(coalesce(p_email,'')),'');
BEGIN
 IF a IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'KASIR'::public.user_role) THEN
   RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='MEMBER_WRITE_DENIED'; END IF;
 IF p_membership_consent IS DISTINCT FROM true OR p_promotional_consent IS NULL OR p_request_id IS NULL
   OR t='' OR length(t)>160 OR ph='' OR length(ph)>40 OR public.member_normalize_phone(ph)!~'^[0-9]{8,15}$'
   OR (em IS NOT NULL AND (length(em)>254 OR em !~* '^[A-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,}$')) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='MEMBER_FIELDS_INVALID'; END IF;
 o:=public.member_current_outlet();
 normalized:=public.member_normalize_phone(ph);
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('MEMBER_PHONE:'||o::text||':'||normalized,478014));
 IF EXISTS(SELECT 1 FROM public.members WHERE outlet_id=o AND phone_normalized=normalized) THEN
   RAISE EXCEPTION USING ERRCODE='23505',MESSAGE='MEMBER_PHONE_DUPLICATE'; END IF;
 INSERT INTO public.members(outlet_id,member_number,full_name,phone,email,created_by,updated_by)
 VALUES(o,'QMEM-'||lpad(nextval('public.member_number_seq')::text,8,'0'),t,ph,em,a,a) RETURNING * INTO new_member;
 INSERT INTO public.member_audit_events(member_id,outlet_id,event_type,actor_id,changed_fields,request_id)
 VALUES(new_member.id,o,'MEMBER_CREATED',a,ARRAY['full_name','phone','email'],p_request_id);
 cart_result:=public.pos_cart_member_set(p_cart,new_member.id,p_expected_revision,p_request_id);
 INSERT INTO public.member_consent_evidence(member_id,outlet_id,consent_type,granted,source,policy_version,actor_id,request_id)
 VALUES(new_member.id,o,'MEMBERSHIP_SERVICE',true,'POS_ENROLLMENT','membership-service-v1',a,p_request_id),
       (new_member.id,o,'PROMOTIONAL_WHATSAPP',p_promotional_consent,'POS_ENROLLMENT','whatsapp-marketing-v1',a,p_request_id);
 RETURN jsonb_build_object('id',new_member.id,'member_number',new_member.member_number,'full_name',new_member.full_name,
   'phone',new_member.phone,'status',new_member.status,'point_balance',0,'cart_revision',cart_result->'revision');
END $$;
ALTER FUNCTION public.pos_member_register(uuid,bigint,text,text,text,uuid,boolean,boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_member_register(uuid,bigint,text,text,text,uuid,boolean,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_member_register(uuid,bigint,text,text,text,uuid,boolean,boolean) TO authenticated;

CREATE FUNCTION public.member_public_register(p_full_name text,p_phone text,p_email text,p_request_id uuid,
  p_ip_digest text,p_phone_digest text,p_membership_consent boolean,p_promotional_consent boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE name_value text:=btrim(coalesce(p_full_name,'')); phone_value text:=btrim(coalesce(p_phone,''));
  email_value text:=nullif(btrim(coalesce(p_email,'')),''); normalized text; outlet uuid; new_member public.members%ROWTYPE;
  count_value integer; response jsonb; existing_request public.member_public_registration_requests%ROWTYPE;
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='MEMBER_PUBLIC_REGISTER_DENIED'; END IF;
 IF p_request_id IS NULL OR p_ip_digest IS NULL OR p_ip_digest !~ '^[0-9a-f]{64}$'
   OR p_phone_digest IS NULL OR p_phone_digest !~ '^[0-9a-f]{64}$'
   OR p_membership_consent IS DISTINCT FROM true OR p_promotional_consent IS NULL
   OR name_value='' OR length(name_value)>160 OR length(phone_value)>40
   OR public.member_normalize_phone(phone_value)!~'^[0-9]{8,15}$'
   OR (email_value IS NOT NULL AND (length(email_value)>254 OR email_value !~* '^[A-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,}$')) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='MEMBER_PUBLIC_FIELDS_INVALID'; END IF;
 normalized:=public.member_normalize_phone(phone_value);
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('MEMBER_PUBLIC_REQUEST:'||p_request_id::text,478011));
 SELECT * INTO existing_request FROM public.member_public_registration_requests WHERE request_id=p_request_id;
 IF FOUND THEN RETURN jsonb_build_object('status',existing_request.status,'member_number',existing_request.member_number); END IF;
 DELETE FROM public.member_public_registration_limits WHERE window_started_at<now()-interval '1 day';
 DELETE FROM public.member_public_registration_requests WHERE created_at<now()-interval '30 days';
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('MEMBER_PUBLIC_IP:'||p_ip_digest,478012));
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('MEMBER_PUBLIC_PHONE:'||p_phone_digest,478013));
 INSERT INTO public.member_public_registration_limits(scope,digest,window_started_at,attempt_count)
 VALUES('IP',p_ip_digest,now(),1) ON CONFLICT(scope,digest) DO UPDATE SET
   attempt_count=CASE WHEN member_public_registration_limits.window_started_at<=now()-interval '1 hour' THEN 1 ELSE member_public_registration_limits.attempt_count+1 END,
   window_started_at=CASE WHEN member_public_registration_limits.window_started_at<=now()-interval '1 hour' THEN now() ELSE member_public_registration_limits.window_started_at END
 RETURNING attempt_count INTO count_value;
 IF count_value>10 THEN
   INSERT INTO public.member_public_registration_requests(request_id,status) VALUES(p_request_id,'RATE_LIMITED');
   RETURN jsonb_build_object('status','RATE_LIMITED');
 END IF;
 INSERT INTO public.member_public_registration_limits(scope,digest,window_started_at,attempt_count)
 VALUES('PHONE',p_phone_digest,now(),1) ON CONFLICT(scope,digest) DO UPDATE SET
   attempt_count=CASE WHEN member_public_registration_limits.window_started_at<=now()-interval '1 hour' THEN 1 ELSE member_public_registration_limits.attempt_count+1 END,
   window_started_at=CASE WHEN member_public_registration_limits.window_started_at<=now()-interval '1 hour' THEN now() ELSE member_public_registration_limits.window_started_at END
 RETURNING attempt_count INTO count_value;
 IF count_value>3 THEN
   INSERT INTO public.member_public_registration_requests(request_id,status) VALUES(p_request_id,'RATE_LIMITED');
   RETURN jsonb_build_object('status','RATE_LIMITED');
 END IF;
 outlet:=public.member_current_outlet();
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('MEMBER_PHONE:'||outlet::text||':'||normalized,478014));
 IF EXISTS(SELECT 1 FROM public.members WHERE outlet_id=public.member_current_outlet() AND phone_normalized=normalized) THEN
   INSERT INTO public.member_public_registration_requests(request_id,status) VALUES(p_request_id,'ALREADY_REGISTERED');
   RETURN jsonb_build_object('status','ALREADY_REGISTERED');
 END IF;
 INSERT INTO public.members(outlet_id,member_number,full_name,phone,email,created_by,updated_by)
 VALUES(outlet,'QMEM-'||lpad(nextval('public.member_number_seq')::text,8,'0'),name_value,phone_value,email_value,NULL,NULL)
 RETURNING * INTO new_member;
 INSERT INTO public.member_consent_evidence(member_id,outlet_id,consent_type,granted,source,policy_version,request_id)
 VALUES(new_member.id,outlet,'MEMBERSHIP_SERVICE',true,'PUBLIC_REGISTRATION','membership-service-v1',p_request_id),
       (new_member.id,outlet,'PROMOTIONAL_WHATSAPP',p_promotional_consent,'PUBLIC_REGISTRATION','whatsapp-marketing-v1',p_request_id);
 INSERT INTO public.member_public_registration_requests(request_id,status,member_number)
 VALUES(p_request_id,'CREATED',new_member.member_number);
 RETURN jsonb_build_object('status','CREATED','member_number',new_member.member_number);
END $$;
ALTER FUNCTION public.member_public_register(text,text,text,uuid,text,text,boolean,boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.member_public_register(text,text,text,uuid,text,text,boolean,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.member_public_register(text,text,text,uuid,text,text,boolean,boolean) TO service_role;

COMMIT;
