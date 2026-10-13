\set ON_ERROR_STOP on
BEGIN;
DO $$ BEGIN
  IF current_setting('server_version_num')::integer/10000<>15 OR current_database()<>'quena_member_runtime' THEN
    RAISE EXCEPTION 'Member runtime test requires disposable PostgreSQL 15 quena_member_runtime';
  END IF;
END $$;

INSERT INTO auth.users(id) VALUES
 ('10000000-0000-4000-8000-000000000001'),('10000000-0000-4000-8000-000000000002'),
 ('10000000-0000-4000-8000-000000000003'),('10000000-0000-4000-8000-000000000004');
INSERT INTO public.outlets(id,name) VALUES('20000000-0000-4000-8000-000000000001','Runtime Outlet');
INSERT INTO public.stock_authority_periods(outlet_id,started_at) VALUES('20000000-0000-4000-8000-000000000001',now());
INSERT INTO public.pos_carts(id,outlet_id,created_by) VALUES
 ('30000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000003');

SELECT set_config('quena.test.actor','10000000-0000-4000-8000-000000000001',true);
SELECT set_config('quena.test.role','OWNER',true);
DO $$ DECLARE a jsonb; b jsonb; c jsonb; BEGIN
  a:=public.member_upsert(NULL,'Deni','081234567890','',gen_random_uuid());
  b:=public.member_upsert(NULL,'Sari','081333333333',NULL,gen_random_uuid());
  IF a->>'member_number' !~ '^QMEM-[0-9]{8}$' OR b->>'member_number'=a->>'member_number' OR (a->>'id')=(b->>'id') THEN
    RAISE EXCEPTION 'Generated member identities are not unique/stable'; END IF;
  IF a->>'phone' IS DISTINCT FROM '081234567890' OR public.member_normalize_phone('081234567890')<>'6281234567890'
      OR public.member_normalize_phone('+62 812-3456-7890')<>'6281234567890' THEN RAISE EXCEPTION 'Phone preservation/normalization failed'; END IF;
  IF (a->>'point_balance')::bigint<>0 THEN RAISE EXCEPTION 'New member point balance must be zero'; END IF;
  BEGIN
    PERFORM public.member_upsert(NULL,'Duplicate Active','+62 812-3456-7890',NULL,gen_random_uuid());
    RAISE EXCEPTION 'Duplicate active normalized phone was accepted';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  IF (SELECT count(*) FROM public.members WHERE phone_normalized='6281234567890')<>1 THEN RAISE EXCEPTION 'Duplicate member was created'; END IF;
  c:=public.member_pos_search('QMEM-',10);
  IF jsonb_array_length(c->'rows')<2 THEN RAISE EXCEPTION 'Member lookup did not find generated member IDs'; END IF;
END $$;

DO $$ DECLARE m uuid; token uuid; sale uuid; result jsonb; replay jsonb; req uuid:=gen_random_uuid(); BEGIN
 SELECT (member_upsert(NULL,'Kasir Member','081111111111',NULL,gen_random_uuid())->>'id')::uuid INTO m;
 SELECT member_token INTO token FROM public.members WHERE id=m;
 SELECT member_token INTO token FROM public.members WHERE id=m;
 result:=public.pos_cart_member_set('30000000-0000-4000-8000-000000000001',m,1,req);
 IF result->>'member_id'<>m::text OR (public.member_pos_cart_read('30000000-0000-4000-8000-000000000001')->'member'->>'id') IS DISTINCT FROM m::text THEN
   RAISE EXCEPTION 'Active member did not attach/read through POS contract'; END IF;
 replay:=public.pos_cart_member_set('30000000-0000-4000-8000-000000000001',m,1,req);
 IF replay IS DISTINCT FROM result OR (SELECT revision FROM public.pos_carts WHERE id='30000000-0000-4000-8000-000000000001')<>2 THEN RAISE EXCEPTION 'Member association replay mutated cart twice'; END IF;
 BEGIN PERFORM public.pos_cart_member_set('30000000-0000-4000-8000-000000000001',NULL,1,req);
   RAISE EXCEPTION 'Conflicting member request identity was accepted'; EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL; END;
 UPDATE public.members SET status='INACTIVE' WHERE id=m;
 BEGIN
   PERFORM public.pos_cart_member_set('30000000-0000-4000-8000-000000000001',m,2,gen_random_uuid());
   RAISE EXCEPTION 'Inactive member association was allowed';
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL; END;
 BEGIN
   INSERT INTO public.sales(outlet_id,pos_cart_id,source_system) VALUES('20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','QUENA_POS') RETURNING id INTO sale;
   RAISE EXCEPTION 'Checkout insert accepted stale inactive member';
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL; END;
 IF EXISTS(SELECT 1 FROM public.sales) THEN RAISE EXCEPTION 'Rejected stale member left partial sale'; END IF;
 UPDATE public.members SET status='ACTIVE' WHERE id=m;
 INSERT INTO public.sales(outlet_id,pos_cart_id,source_system) VALUES('20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','QUENA_POS') RETURNING id INTO sale;
 IF (SELECT member_id FROM public.sales WHERE id=sale) IS DISTINCT FROM m THEN RAISE EXCEPTION 'Sale did not retain canonical member reference'; END IF;
 PERFORM public.member_upsert(m,'Kasir Member Diperbarui','081222222222','member@example.id',gen_random_uuid());
 IF (SELECT count(*) FROM public.sales WHERE member_id=m AND source_system='QUENA_POS')<>1 THEN RAISE EXCEPTION 'Member edit broke historical sale relationship'; END IF;
 INSERT INTO public.sales(outlet_id,pos_cart_id,source_system,member_id)
 VALUES('20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','IPOS_IMPORT',m);
 IF (SELECT count(*) FROM public.sales WHERE source_system='IPOS_IMPORT' AND member_id IS NOT NULL)<>0 THEN RAISE EXCEPTION 'iPos sale was assigned a fabricated member'; END IF;
END $$;

DO $$ DECLARE mid uuid; rid uuid:=gen_random_uuid(); BEGIN
 SELECT id INTO mid FROM public.members ORDER BY member_number LIMIT 1;
 INSERT INTO public.member_point_ledger(member_id,outlet_id,event_type,points_delta,source_type,source_reference,occurred_at,request_id)
 VALUES(mid,'20000000-0000-4000-8000-000000000001','EARN',25,'TEST','SALE-1',now(),rid);
 IF public.member_point_balance(mid)<>25 THEN RAISE EXCEPTION 'Ledger sum projection mismatch'; END IF;
 BEGIN UPDATE public.member_point_ledger SET points_delta=50 WHERE request_id=rid;
   RAISE EXCEPTION 'Point ledger update was allowed'; EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
 IF public.member_point_balance(mid)<>25 THEN RAISE EXCEPTION 'Ledger immutability invariant failed'; END IF;
END $$;

SELECT set_config('quena.test.role','KASIR',true);
DO $$ BEGIN
  PERFORM public.member_pos_search('0811',10);
  BEGIN PERFORM public.member_workspace_page('',1,20); RAISE EXCEPTION 'KASIR accessed member financial workspace';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  PERFORM public.member_upsert(NULL,'Kasir Member Baru','081444444444',NULL,gen_random_uuid());
END $$;
SELECT set_config('quena.test.role','GUDANG',true);
DO $$ BEGIN
  BEGIN PERFORM public.member_pos_search('0811',10); RAISE EXCEPTION 'GUDANG accessed POS member lookup';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT set_config('quena.test.actor','10000000-0000-4000-8000-000000000002',true);
SELECT set_config('quena.test.role','ADMIN',true);
DO $$ DECLARE x jsonb; BEGIN
  x:=public.member_workspace_page('',1,20);
  IF jsonb_array_length(x->'rows')<2 THEN RAISE EXCEPTION 'ADMIN member workspace read failed'; END IF;
  PERFORM public.member_status_set((SELECT id FROM public.members ORDER BY member_number LIMIT 1),'INACTIVE','Runtime test status change',gen_random_uuid());
  IF (SELECT count(*) FROM public.member_audit_events WHERE event_type='MEMBER_STATUS_CHANGED' AND reason='Runtime test status change')<>1 THEN RAISE EXCEPTION 'Member status audit missing reason'; END IF;
END $$;

ROLLBACK;
