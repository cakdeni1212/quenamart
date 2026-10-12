BEGIN;

-- Invitation state only coordinates Supabase Auth with the profile transaction.
-- It deliberately contains no passwords, tokens, or client supplied role authority.
CREATE TABLE public.account_provisioning_requests (
  request_id uuid PRIMARY KEY,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  requested_email text NOT NULL,
  full_name text NOT NULL,
  requested_role public.user_role NOT NULL CHECK (requested_role IN (
    'ADMIN'::public.user_role, 'KASIR'::public.user_role, 'GUDANG'::public.user_role
  )),
  state text NOT NULL DEFAULT 'PENDING' CHECK (state IN ('PENDING','COMPLETED','FAILED')),
  claim_token uuid,
  claim_expires_at timestamptz,
  auth_user_id uuid UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  CONSTRAINT account_provisioning_state_consistent CHECK (
    (state='COMPLETED' AND auth_user_id IS NOT NULL AND completed_at IS NOT NULL)
    OR state<>'COMPLETED'
  )
);

CREATE UNIQUE INDEX account_provisioning_pending_email_uq
  ON public.account_provisioning_requests (lower(requested_email))
  WHERE state='PENDING';
CREATE INDEX account_provisioning_actor_created_idx
  ON public.account_provisioning_requests(actor_id,created_at DESC);

ALTER TABLE public.account_provisioning_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.account_provisioning_requests FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.account_management_list(
  p_search text DEFAULT NULL,
  p_role text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_limit integer DEFAULT 25,
  p_offset integer DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE v_actor uuid:=auth.uid(); v_rows jsonb; v_total bigint;
BEGIN
  IF v_actor IS NULL OR public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='ACCOUNT_UNAUTHORIZED';
  END IF;
  IF p_role IS NOT NULL AND p_role NOT IN ('OWNER','ADMIN','KASIR','GUDANG') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='ACCOUNT_FILTER_INVALID';
  END IF;
  IF p_status IS NOT NULL AND p_status NOT IN ('ACTIVE','INACTIVE') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='ACCOUNT_FILTER_INVALID';
  END IF;
  IF p_search IS NOT NULL AND length(p_search)>100 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='ACCOUNT_FILTER_INVALID';
  END IF;
  IF p_limit IS NULL OR p_limit<1 OR p_limit>50 OR p_offset IS NULL OR p_offset<0 OR p_offset>50000 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='ACCOUNT_PAGE_INVALID';
  END IF;
  WITH filtered AS (
    SELECT p.id,p.full_name,u.email,p.role::text AS role,p.is_active,u.last_sign_in_at
    FROM public.profiles p
    JOIN auth.users u ON u.id=p.id
    WHERE (p_search IS NULL OR btrim(p_search)='' OR p.full_name ILIKE '%'||btrim(p_search)||'%' OR u.email ILIKE '%'||btrim(p_search)||'%')
      AND (p_role IS NULL OR p.role::text=p_role)
      AND (p_status IS NULL OR p.is_active=(p_status='ACTIVE'))
  ), page_rows AS (
    SELECT * FROM filtered ORDER BY lower(coalesce(full_name,'')),id LIMIT p_limit OFFSET p_offset
  )
  SELECT coalesce((SELECT jsonb_agg(jsonb_build_object(
      'id',r.id,'full_name',r.full_name,'email',r.email,'role',r.role,
      'is_active',r.is_active,'last_sign_in_at',r.last_sign_in_at
    ) ORDER BY lower(coalesce(r.full_name,'')),r.id) FROM page_rows r),'[]'::jsonb),
    (SELECT count(*) FROM filtered)
    INTO v_rows,v_total;
  RETURN jsonb_build_object('rows',v_rows,'total',v_total,'limit',p_limit,'offset',p_offset);
END;
$$;

CREATE OR REPLACE FUNCTION public.account_management_invite_begin(
  p_request_id uuid,p_email text,p_full_name text,p_role text
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE v_actor uuid:=auth.uid(); v_request public.account_provisioning_requests%rowtype;
  v_email text:=lower(btrim(coalesce(p_email,''))); v_name text:=btrim(coalesce(p_full_name,''));
  v_role public.user_role; v_token uuid;
BEGIN
  IF v_actor IS NULL OR public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='ACCOUNT_UNAUTHORIZED';
  END IF;
  IF p_request_id IS NULL OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     OR length(v_email)>254 OR v_name='' OR length(v_name)>120
     OR p_role IS NULL OR p_role NOT IN ('ADMIN','KASIR','GUDANG') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='ACCOUNT_INPUT_INVALID';
  END IF;
  v_role:=p_role::public.user_role;
  SELECT * INTO v_request FROM public.account_provisioning_requests WHERE request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF v_request.actor_id IS DISTINCT FROM v_actor OR v_request.requested_email IS DISTINCT FROM v_email
       OR v_request.full_name IS DISTINCT FROM v_name OR v_request.requested_role IS DISTINCT FROM v_role THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='ACCOUNT_REQUEST_CONFLICT';
    END IF;
    IF v_request.state='COMPLETED' THEN
      RETURN jsonb_build_object('state','COMPLETED','user_id',v_request.auth_user_id);
    END IF;
    IF v_request.state='PENDING' AND v_request.claim_expires_at>now() THEN
      RETURN jsonb_build_object('state','PROCESSING');
    END IF;
    IF EXISTS(SELECT 1 FROM auth.users u WHERE lower(u.email)=v_email
      AND u.id IS DISTINCT FROM v_request.auth_user_id
      AND u.raw_user_meta_data->>'quena_account_request_id' IS DISTINCT FROM p_request_id::text) THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='ACCOUNT_EMAIL_EXISTS';
    END IF;
    v_token:=gen_random_uuid();
    UPDATE public.account_provisioning_requests SET state='PENDING',claim_token=v_token,
      claim_expires_at=now()+interval '5 minutes' WHERE request_id=p_request_id;
    RETURN jsonb_build_object('state','CLAIMED','claim_token',v_token,'user_id',v_request.auth_user_id);
  END IF;
  IF EXISTS(SELECT 1 FROM auth.users u WHERE lower(u.email)=v_email) THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='ACCOUNT_EMAIL_EXISTS';
  END IF;
  v_token:=gen_random_uuid();
  INSERT INTO public.account_provisioning_requests(request_id,actor_id,requested_email,full_name,requested_role,claim_token,claim_expires_at)
  VALUES(p_request_id,v_actor,v_email,v_name,v_role,v_token,now()+interval '5 minutes');
  RETURN jsonb_build_object('state','CLAIMED','claim_token',v_token,'user_id',NULL);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='ACCOUNT_INVITATION_PENDING';
END;
$$;

CREATE OR REPLACE FUNCTION public.account_management_invite_attach(
  p_request_id uuid,p_claim_token uuid,p_auth_user_id uuid
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE v_actor uuid:=auth.uid(); v_request public.account_provisioning_requests%rowtype; v_email text;
BEGIN
  IF v_actor IS NULL OR public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='ACCOUNT_UNAUTHORIZED';
  END IF;
  SELECT * INTO v_request FROM public.account_provisioning_requests WHERE request_id=p_request_id FOR UPDATE;
  IF NOT FOUND OR v_request.actor_id<>v_actor THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='ACCOUNT_REQUEST_NOT_FOUND'; END IF;
  IF v_request.state='COMPLETED' AND v_request.auth_user_id=p_auth_user_id THEN
    RETURN jsonb_build_object('state','COMPLETED','user_id',p_auth_user_id);
  END IF;
  IF v_request.state<>'PENDING' OR v_request.claim_token IS DISTINCT FROM p_claim_token
     OR v_request.claim_expires_at<now() THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='ACCOUNT_REQUEST_CONFLICT'; END IF;
  SELECT lower(email) INTO v_email FROM auth.users WHERE id=p_auth_user_id;
  IF v_email IS DISTINCT FROM v_request.requested_email THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='ACCOUNT_REQUEST_CONFLICT'; END IF;
  IF EXISTS(SELECT 1 FROM public.profiles WHERE id=p_auth_user_id) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='ACCOUNT_PROFILE_EXISTS'; END IF;
  UPDATE public.account_provisioning_requests SET auth_user_id=p_auth_user_id
  WHERE request_id=p_request_id AND actor_id=v_actor;
  RETURN jsonb_build_object('state','PENDING','user_id',p_auth_user_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.account_management_invite_complete(
  p_request_id uuid,p_claim_token uuid,p_auth_user_id uuid
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE v_actor uuid:=auth.uid(); v_request public.account_provisioning_requests%rowtype;
BEGIN
  IF v_actor IS NULL OR public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='ACCOUNT_UNAUTHORIZED';
  END IF;
  SELECT * INTO v_request FROM public.account_provisioning_requests WHERE request_id=p_request_id FOR UPDATE;
  IF NOT FOUND OR v_request.actor_id<>v_actor THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='ACCOUNT_REQUEST_NOT_FOUND'; END IF;
  IF v_request.state='COMPLETED' AND v_request.auth_user_id=p_auth_user_id THEN
    RETURN jsonb_build_object('state','COMPLETED','user_id',p_auth_user_id);
  END IF;
  IF v_request.state<>'PENDING' OR v_request.claim_token IS DISTINCT FROM p_claim_token
     OR v_request.claim_expires_at<now() OR v_request.auth_user_id IS DISTINCT FROM p_auth_user_id THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='ACCOUNT_REQUEST_CONFLICT';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM auth.users u WHERE u.id=p_auth_user_id AND lower(u.email)=v_request.requested_email)
     OR EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=p_auth_user_id) THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='ACCOUNT_PROFILE_CREATE_FAILED';
  END IF;
  INSERT INTO public.profiles(id,full_name,role,is_active)
  VALUES(p_auth_user_id,v_request.full_name,v_request.requested_role,true);
  UPDATE public.account_provisioning_requests SET state='COMPLETED',completed_at=now(),claim_token=NULL,claim_expires_at=NULL
  WHERE request_id=p_request_id;
  RETURN jsonb_build_object('state','COMPLETED','user_id',p_auth_user_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.account_management_invite_status(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE v_actor uuid:=auth.uid(); v_request public.account_provisioning_requests%rowtype;
BEGIN
  IF v_actor IS NULL OR public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='ACCOUNT_UNAUTHORIZED';
  END IF;
  SELECT * INTO v_request FROM public.account_provisioning_requests WHERE request_id=p_request_id AND actor_id=v_actor;
  IF NOT FOUND THEN RETURN jsonb_build_object('state','NOT_FOUND'); END IF;
  RETURN jsonb_build_object('state',v_request.state,'user_id',v_request.auth_user_id,'claim_token',v_request.claim_token);
END;
$$;

CREATE OR REPLACE FUNCTION public.account_management_invite_fail(p_request_id uuid,p_claim_token uuid)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE v_actor uuid:=auth.uid();
BEGIN
  IF v_actor IS NULL OR public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='ACCOUNT_UNAUTHORIZED';
  END IF;
  UPDATE public.account_provisioning_requests SET state='FAILED',auth_user_id=NULL,claim_token=NULL,claim_expires_at=NULL
  WHERE request_id=p_request_id AND actor_id=v_actor AND state='PENDING' AND claim_token=p_claim_token;
END;
$$;

CREATE OR REPLACE FUNCTION public.account_management_update(
  p_target_user_id uuid,p_full_name text,p_role text,p_is_active boolean
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE v_actor uuid:=auth.uid(); v_target public.profiles%rowtype; v_active_owners bigint;
BEGIN
  IF v_actor IS NULL OR public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='ACCOUNT_UNAUTHORIZED';
  END IF;
  IF p_target_user_id IS NULL OR btrim(coalesce(p_full_name,''))='' OR length(btrim(p_full_name))>120
     OR p_role IS NULL OR p_role NOT IN ('ADMIN','KASIR','GUDANG') OR p_is_active IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='ACCOUNT_INPUT_INVALID';
  END IF;
  SELECT * INTO v_target FROM public.profiles WHERE id=p_target_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='ACCOUNT_NOT_FOUND'; END IF;
  IF v_target.role='OWNER'::public.user_role THEN
    IF NOT p_is_active THEN
      SELECT count(*) INTO v_active_owners FROM public.profiles WHERE role='OWNER'::public.user_role AND is_active;
      IF v_active_owners<=1 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='ACCOUNT_LAST_ACTIVE_OWNER'; END IF;
    END IF;
    IF p_target_user_id=v_actor THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='ACCOUNT_SELF_CHANGE_FORBIDDEN'; END IF;
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='ACCOUNT_OWNER_REQUIRES_ELEVATED_FLOW';
  END IF;
  IF p_target_user_id=v_actor THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='ACCOUNT_SELF_CHANGE_FORBIDDEN'; END IF;
  UPDATE public.profiles SET full_name=btrim(p_full_name),role=p_role::public.user_role,is_active=p_is_active,updated_at=now()
  WHERE id=p_target_user_id;
  RETURN jsonb_build_object('id',p_target_user_id,'full_name',btrim(p_full_name),'role',p_role,'is_active',p_is_active);
END;
$$;

REVOKE ALL ON FUNCTION public.account_management_list(text,text,text,integer,integer) FROM PUBLIC,anon,service_role;
REVOKE ALL ON FUNCTION public.account_management_invite_begin(uuid,text,text,text) FROM PUBLIC,anon,service_role;
REVOKE ALL ON FUNCTION public.account_management_invite_attach(uuid,uuid,uuid) FROM PUBLIC,anon,service_role;
REVOKE ALL ON FUNCTION public.account_management_invite_complete(uuid,uuid,uuid) FROM PUBLIC,anon,service_role;
REVOKE ALL ON FUNCTION public.account_management_invite_status(uuid) FROM PUBLIC,anon,service_role;
REVOKE ALL ON FUNCTION public.account_management_invite_fail(uuid,uuid) FROM PUBLIC,anon,service_role;
REVOKE ALL ON FUNCTION public.account_management_update(uuid,text,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.account_management_list(text,text,text,integer,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.account_management_invite_begin(uuid,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.account_management_invite_attach(uuid,uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.account_management_invite_complete(uuid,uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.account_management_invite_status(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.account_management_invite_fail(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.account_management_update(uuid,text,text,boolean) TO authenticated;

COMMIT;
