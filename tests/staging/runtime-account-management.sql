BEGIN;
DO $guard$
BEGIN
  IF current_database()<>'quena_stock_staging'
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR inet_server_port()<>5432
    OR current_setting('server_version_num')::integer/10000<>15
    OR current_setting('server_encoding')<>'UTF8'
    OR NOT EXISTS(SELECT 1 FROM quena_staging.environment WHERE name='quena_stock_staging') THEN
    RAISE EXCEPTION 'Refusing account management tests outside guarded local staging';
  END IF;
END;
$guard$;

-- The shared harness emulates only auth.users(id); these columns are standard
-- Supabase Auth fields consumed by the account directory and are test-only.
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS email text;
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS last_sign_in_at timestamptz;
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

INSERT INTO auth.users(id,email,last_sign_in_at) VALUES
 ('a0000000-0000-4000-8000-000000000001','account-owner@example.test',now()),
 ('a0000000-0000-4000-8000-000000000002','account-admin@example.test',NULL),
 ('a0000000-0000-4000-8000-000000000003','account-gudang@example.test',NULL),
 ('a0000000-0000-4000-8000-000000000004','account-kasir@example.test',NULL)
ON CONFLICT(id) DO UPDATE SET email=excluded.email,last_sign_in_at=excluded.last_sign_in_at;
INSERT INTO public.profiles(id,full_name,role,is_active) VALUES
 ('a0000000-0000-4000-8000-000000000001','Staging Owner','OWNER',true),
 ('a0000000-0000-4000-8000-000000000002','Staging Admin','ADMIN',true),
 ('a0000000-0000-4000-8000-000000000003','Staging Gudang','GUDANG',true),
 ('a0000000-0000-4000-8000-000000000004','Staging Kasir','KASIR',true)
ON CONFLICT(id) DO UPDATE SET full_name=excluded.full_name,role=excluded.role,is_active=true;

DO $tests$
DECLARE
  v_owner uuid:='a0000000-0000-4000-8000-000000000001';
  v_admin uuid:='a0000000-0000-4000-8000-000000000002';
  v_gudang uuid:='a0000000-0000-4000-8000-000000000003';
  v_kasir uuid:='a0000000-0000-4000-8000-000000000004';
  v_request uuid; v_user uuid; v_token uuid; v_payload jsonb; v_reply jsonb;
  v_role text; v_code text; v_message text; v_new_name text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,false);
  v_payload:=public.account_management_list(NULL,NULL,NULL,25,0);
  IF jsonb_array_length(v_payload->'rows')<4 OR (v_payload->'rows'->0 ? 'email') IS NOT TRUE THEN
    RAISE EXCEPTION 'OWNER account list did not return bounded commercial identity fields';
  END IF;
  IF has_function_privilege('anon','public.account_management_list(text,text,text,integer,integer)','EXECUTE')
    OR NOT has_function_privilege('authenticated','public.account_management_list(text,text,text,integer,integer)','EXECUTE') THEN
    RAISE EXCEPTION 'Account RPC grants do not match the authenticated-only contract';
  END IF;

  FOR v_role,v_user IN
    SELECT * FROM (VALUES
      ('ADMIN','a2000000-0000-4000-8000-000000000001'::uuid),
      ('KASIR','a2000000-0000-4000-8000-000000000002'::uuid),
      ('GUDANG','a2000000-0000-4000-8000-000000000003'::uuid)
    ) AS invited(role_name,user_id)
  LOOP
    v_request:=gen_random_uuid();
    v_reply:=public.account_management_invite_begin(v_request,format('%s@example.test',lower(v_role)),format('Invited %s',v_role),v_role);
    v_token:=(v_reply->>'claim_token')::uuid;
    IF (public.account_management_invite_begin(v_request,format('%s@example.test',lower(v_role)),format('Invited %s',v_role),v_role)->>'state')<>'PROCESSING' THEN
      RAISE EXCEPTION 'Concurrent retry did not observe the in-progress invitation claim';
    END IF;
    INSERT INTO auth.users(id,email) VALUES(v_user,format('%s@example.test',lower(v_role)));
    PERFORM public.account_management_invite_attach(v_request,v_token,v_user);
    PERFORM public.account_management_invite_complete(v_request,v_token,v_user);
    IF (public.account_management_invite_begin(v_request,format('%s@example.test',lower(v_role)),format('Invited %s',v_role),v_role)->>'state')<>'COMPLETED' THEN
      RAISE EXCEPTION 'Same invitation request did not replay as completed';
    END IF;
    BEGIN
      PERFORM public.account_management_invite_begin(v_request,format('%s@example.test',lower(v_role)),format('Changed %s',v_role),v_role);
      RAISE EXCEPTION 'Changed payload unexpectedly reused an invitation request';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
      IF v_message<>'ACCOUNT_REQUEST_CONFLICT' THEN RAISE; END IF;
    END;
  END LOOP;

  BEGIN
    PERFORM public.account_management_invite_begin(gen_random_uuid(),'account-owner@example.test','Duplicate Email','KASIR');
    RAISE EXCEPTION 'Existing Auth email unexpectedly started a new invitation';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'ACCOUNT_EMAIL_EXISTS' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.account_management_invite_begin(gen_random_uuid(),'new@example.test','Owner Role','OWNER');
    RAISE EXCEPTION 'Employee invitation unexpectedly accepted OWNER role';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'ACCOUNT_INPUT_INVALID' THEN RAISE; END IF;
  END;

  v_request:=gen_random_uuid(); v_user:='a2000000-0000-4000-8000-000000000001';
  PERFORM public.account_management_update(v_user,'Changed Name','KASIR',false);
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_user AND full_name='Changed Name' AND role='KASIR' AND NOT is_active) THEN
    RAISE EXCEPTION 'Edit/deactivation did not update the target profile';
  END IF;
  PERFORM public.account_management_update(v_user,'Changed Name','ADMIN',true);
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_user AND is_active AND role='ADMIN') THEN
    RAISE EXCEPTION 'Reactivation did not preserve the same profile identity';
  END IF;

  BEGIN
    PERFORM public.account_management_update(v_owner,'Changed Owner','ADMIN',true);
    RAISE EXCEPTION 'Self role change unexpectedly succeeded';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'ACCOUNT_SELF_CHANGE_FORBIDDEN' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.account_management_update(v_owner,'Staging Owner','ADMIN',false);
    RAISE EXCEPTION 'Last active Owner deactivation unexpectedly succeeded';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'ACCOUNT_LAST_ACTIVE_OWNER' THEN RAISE; END IF;
  END;

  FOREACH v_user IN ARRAY ARRAY[v_admin,v_gudang,v_kasir] LOOP
    PERFORM set_config('request.jwt.claim.sub',v_user::text,false);
    BEGIN
      PERFORM public.account_management_list(NULL,NULL,NULL,25,0);
      RAISE EXCEPTION 'Non-OWNER account listing unexpectedly succeeded';
    EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
    END;
  END LOOP;
  IF (SELECT count(*) FROM public.profiles WHERE id IN (
      'a2000000-0000-4000-8000-000000000001'::uuid,
      'a2000000-0000-4000-8000-000000000002'::uuid,
      'a2000000-0000-4000-8000-000000000003'::uuid))<>3 THEN
    RAISE EXCEPTION 'Historical actor profiles were not retained';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='account_provisioning_requests' AND column_name ILIKE '%password%') THEN
    RAISE EXCEPTION 'Account request evidence must never contain password fields';
  END IF;
END;
$tests$;

ROLLBACK;
