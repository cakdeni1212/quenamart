\set ON_ERROR_STOP on
BEGIN;
DO $$ BEGIN
  IF current_setting('server_version_num')::integer/10000<>15 OR current_database()<>'quena_member_loyalty_runtime' THEN
    RAISE EXCEPTION 'Member access runtime test requires disposable PostgreSQL 15'; END IF;
END $$;
INSERT INTO auth.users(id) VALUES ('10000000-0000-4000-8000-000000000001'),('10000000-0000-4000-8000-000000000003') ON CONFLICT DO NOTHING;
INSERT INTO public.outlets(id,name) VALUES('20000000-0000-4000-8000-000000000001','Runtime Outlet') ON CONFLICT DO NOTHING;
INSERT INTO public.stock_authority_periods(outlet_id,started_at) VALUES('20000000-0000-4000-8000-000000000001',now())
  ON CONFLICT DO NOTHING;
INSERT INTO public.pos_carts(id,outlet_id,created_by,status,revision) VALUES
 ('30000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000003','ACTIVE',1)
 ON CONFLICT DO NOTHING;

DO $$ DECLARE created jsonb; duplicate jsonb; replay jsonb; req uuid:=gen_random_uuid(); before_count integer; BEGIN
  IF has_function_privilege('anon','public.member_public_register(text,text,text,uuid,text,text,boolean,boolean)','EXECUTE') THEN
    RAISE EXCEPTION 'Anonymous role can invoke privileged registration RPC'; END IF;
  IF has_table_privilege('anon','public.member_consent_evidence','SELECT') OR has_table_privilege('anon','public.members','SELECT')
    OR has_table_privilege('anon','public.member_point_ledger','SELECT') THEN RAISE EXCEPTION 'Anonymous member data access is too broad'; END IF;
  PERFORM set_config('request.jwt.claim.role','service_role',true);
  before_count:=(SELECT count(*) FROM public.members);
  created:=public.member_public_register('Public Member','081234567890','',req,repeat('a',64),repeat('b',64),true,false);
  IF created->>'status'<>'CREATED' OR created->>'member_number' !~ '^QMEM-[0-9]{8}$'
    OR created ? 'id' OR created ? 'member_token' OR created ? 'phone' OR created ? 'email' THEN
    RAISE EXCEPTION 'Public signup returned missing or sensitive identity fields: %',created; END IF;
  replay:=public.member_public_register('Public Member','081234567890','',req,repeat('a',64),repeat('b',64),true,false);
  IF replay IS DISTINCT FROM created OR (SELECT count(*) FROM public.members)<>before_count+1 THEN
    RAISE EXCEPTION 'Registration replay created another Member'; END IF;
  duplicate:=public.member_public_register('Another Name','+62 812-3456-7890','',gen_random_uuid(),repeat('c',64),repeat('d',64),true,false);
  IF duplicate->>'status'<>'ALREADY_REGISTERED' OR duplicate ? 'member_number' OR duplicate ? 'id'
    OR (SELECT count(*) FROM public.members)<>before_count+1 THEN RAISE EXCEPTION 'Normalized phone duplicate leaked data or created a duplicate'; END IF;
  IF (SELECT count(*) FROM public.member_consent_evidence WHERE member_id=(SELECT id FROM public.members WHERE member_number=created->>'member_number'))<>2
    OR NOT EXISTS(SELECT 1 FROM public.member_consent_evidence WHERE member_id=(SELECT id FROM public.members WHERE member_number=created->>'member_number') AND consent_type='MEMBERSHIP_SERVICE' AND granted)
    OR NOT EXISTS(SELECT 1 FROM public.member_consent_evidence WHERE member_id=(SELECT id FROM public.members WHERE member_number=created->>'member_number') AND consent_type='PROMOTIONAL_WHATSAPP' AND NOT granted) THEN
    RAISE EXCEPTION 'Separate service and promotional consent evidence missing'; END IF;
  IF (SELECT created_by FROM public.members WHERE member_number=created->>'member_number') IS NOT NULL THEN
    RAISE EXCEPTION 'Public registration fabricated a staff actor'; END IF;
END $$;

DO $$ DECLARE response jsonb; i integer; before_count integer; BEGIN
  PERFORM set_config('request.jwt.claim.role','service_role',true);
  before_count:=(SELECT count(*) FROM public.members);
  FOR i IN 1..11 LOOP
    response:=public.member_public_register('Rate Test '||i,'081555000'||lpad(i::text,3,'0'),NULL,gen_random_uuid(),repeat('e',64),lpad(to_hex(i),64,'0'),true,false);
    IF i<=10 AND response->>'status'<>'CREATED' THEN RAISE EXCEPTION 'IP rate limit triggered early at %: %',i,response; END IF;
    IF i=11 AND response->>'status'<>'RATE_LIMITED' THEN RAISE EXCEPTION 'IP rate limit did not trigger: %',response; END IF;
  END LOOP;
  IF (SELECT count(*) FROM public.members)<>before_count+10 THEN RAISE EXCEPTION 'Rate-limited attempt mutated Member identity'; END IF;
END $$;

DO $$ DECLARE response jsonb; i integer; BEGIN
  PERFORM set_config('request.jwt.claim.role','service_role',true);
  FOR i IN 1..4 LOOP
    response:=public.member_public_register('Phone Rate Test','081666677777',NULL,gen_random_uuid(),repeat('f',64),repeat('1',64),true,false);
    IF i=1 AND response->>'status'<>'CREATED' THEN RAISE EXCEPTION 'Phone limit fixture did not create first Member'; END IF;
    IF i IN (2,3) AND response->>'status'<>'ALREADY_REGISTERED' THEN RAISE EXCEPTION 'Equivalent phone registration was not rejected: %',response; END IF;
    IF i=4 AND response->>'status'<>'RATE_LIMITED' THEN RAISE EXCEPTION 'Phone rate limit did not trigger: %',response; END IF;
  END LOOP;
END $$;

DO $$ DECLARE result jsonb; v_member_id uuid; token uuid; search jsonb; BEGIN
  PERFORM set_config('request.jwt.claim.role','',true);
  PERFORM set_config('quena.test.actor','10000000-0000-4000-8000-000000000003',true);
  PERFORM set_config('quena.test.role','KASIR',true);
  result:=public.pos_member_register('30000000-0000-4000-8000-000000000003',1,'Kasir Registered','081222233333',NULL,gen_random_uuid(),true,false);
  v_member_id:=(result->>'id')::uuid;
  IF result->>'member_number' !~ '^QMEM-[0-9]{8}$' OR result->>'cart_revision'<>'2'
    OR (SELECT member_id FROM public.pos_carts WHERE id='30000000-0000-4000-8000-000000000003') IS DISTINCT FROM v_member_id THEN
    RAISE EXCEPTION 'Cashier quick registration did not attach atomically'; END IF;
  SELECT member_token INTO token FROM public.members WHERE id=v_member_id;
  search:=public.member_pos_search(token::text,10);
  IF jsonb_array_length(search->'rows')<>1 OR search#>>'{rows,0,exact_match}'<>'true'
    OR search#>>'{rows,0,id}'<>v_member_id::text OR search#>>'{rows,0,phone_masked}'='081222233333'
    OR search#>'{rows,0}' ? 'member_token' OR search#>'{rows,0}' ? 'phone' THEN
    RAISE EXCEPTION 'Exact POS member token lookup or privacy projection failed: %',search; END IF;
  IF (SELECT count(*) FROM public.member_point_ledger WHERE member_id=v_member_id)<>0 THEN RAISE EXCEPTION 'Registration awarded points'; END IF;
  IF (SELECT count(*) FROM public.member_consent_evidence WHERE member_id=v_member_id AND source='POS_ENROLLMENT')<>2 THEN
    RAISE EXCEPTION 'Cashier consent evidence not recorded'; END IF;
  BEGIN
    PERFORM public.member_upsert(NULL,'Bypass','081222244446',NULL,gen_random_uuid());
    RAISE EXCEPTION 'KASIR bypassed consent-aware Member enrollment';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    PERFORM public.pos_member_register('30000000-0000-4000-8000-000000000003',1,'Atomic Failure','081222244447',NULL,gen_random_uuid(),true,false);
    RAISE EXCEPTION 'Stale cart registration was accepted';
  EXCEPTION WHEN serialization_failure THEN NULL; END;
  IF EXISTS(SELECT 1 FROM public.members WHERE phone_normalized='6281222244447') THEN
    RAISE EXCEPTION 'Failed atomic cart attachment left a Member behind'; END IF;
END $$;

SELECT set_config('quena.test.role','GUDANG',true);
DO $$ BEGIN
  BEGIN PERFORM public.member_pos_search('QMEM-',10); RAISE EXCEPTION 'GUDANG accessed POS member lookup';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM public.pos_member_register('30000000-0000-4000-8000-000000000003',2,'Blocked','081222244444',NULL,gen_random_uuid(),true,false);
    RAISE EXCEPTION 'GUDANG created Member'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
ROLLBACK;
