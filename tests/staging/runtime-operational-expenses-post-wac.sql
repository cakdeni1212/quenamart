\set ON_ERROR_STOP on
BEGIN;
DO $guard$ BEGIN
  IF current_database()<>'quena_stock_staging' OR inet_server_port()<>55441
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR NOT EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE status='WAC_ACTIVE')
    OR to_regprocedure('public.owner_dashboard_operating_expense_read()') IS NULL THEN
    RAISE EXCEPTION 'Refusing expense post-WAC runtime test outside active disposable staging';
  END IF;
END $guard$;
INSERT INTO auth.users(id) VALUES ('a4500000-0000-4000-8000-000000000001'),('a4500000-0000-4000-8000-000000000002') ON CONFLICT DO NOTHING;
INSERT INTO public.profiles(id,full_name,role,is_active) VALUES
 ('a4500000-0000-4000-8000-000000000001','Stage Expense Admin','ADMIN',true),
 ('a4500000-0000-4000-8000-000000000002','Stage Expense Warehouse','GUDANG',true)
ON CONFLICT(id) DO UPDATE SET role=EXCLUDED.role,is_active=true,full_name=EXCLUDED.full_name;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false);
SET ROLE authenticated;
DO $expense_lifecycle$
DECLARE today date:=timezone('Asia/Jakarta',now())::date; a jsonb; replay jsonb; b jsonb; c jsonb; page jsonb; detail jsonb; dash jsonb;
  conflict boolean:=false; immutable boolean:=false; msg text; before_gross numeric; expected numeric; actor uuid;
BEGIN
  a:=public.operational_expense_create('f4500000-0000-4000-8000-000000000101',today,'LISTRIK','Listrik toko',1000000,'CASH',NULL,true);
  replay:=public.operational_expense_create('f4500000-0000-4000-8000-000000000101',today,'LISTRIK','Listrik toko',1000000,'CASH',NULL,true);
  IF replay->>'id' IS DISTINCT FROM a->>'id' THEN RAISE EXCEPTION 'Same create request did not replay'; END IF;
  BEGIN PERFORM public.operational_expense_create('f4500000-0000-4000-8000-000000000101',today,'LISTRIK','Different payload',1000000,'CASH',NULL,true);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT; conflict:=msg='EXPENSE_REQUEST_CONFLICT'; END;
  IF NOT conflict THEN RAISE EXCEPTION 'Changed create payload was not rejected'; END IF;
  b:=public.operational_expense_create('f4500000-0000-4000-8000-000000000102',today,'INTERNET','Internet toko',500000,'BANK_TRANSFER',NULL,true);
  c:=public.operational_expense_create('f4500000-0000-4000-8000-000000000103',today,'ATK','Draft alat tulis',250000,'CASH',NULL,false);
  page:=public.operational_expenses_page(today,today,'','','','',1,20);
  IF page#>>'{summary,total}'<>'1500000.00' OR page#>>'{summary,count}'<>'2' THEN RAISE EXCEPTION 'Draft leaked into financial summary: %',page; END IF;
  PERFORM public.operational_expense_cancel((b->>'id')::uuid,'f4500000-0000-4000-8000-000000000104','Salah input saat uji staging');
  page:=public.operational_expenses_page(today,today,'','','','',1,20);
  detail:=public.operational_expense_detail((b->>'id')::uuid);
  IF page#>>'{summary,total}'<>'1000000.00' OR page#>>'{summary,count}'<>'1'
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(page->'rows') r WHERE r->>'id'=b->>'id' AND r->>'status'='CANCELLED')
    OR detail->>'status'<>'CANCELLED' OR detail->>'cancellation_reason'<>'Salah input saat uji staging'
    THEN RAISE EXCEPTION 'Cancelled expense not excluded/preserved: %, %',page,detail; END IF;
  BEGIN PERFORM public.operational_expense_update_draft((a->>'id')::uuid,1,today,'LISTRIK','Illegitimate edit',1000000,'CASH',NULL);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT; immutable:=msg='EXPENSE_NOT_EDITABLE'; END;
  IF NOT immutable THEN RAISE EXCEPTION 'Posted expense was editable'; END IF;
  dash:=public.owner_dashboard_operating_expense_read();
  before_gross:=(dash->>'gross_profit')::numeric; expected:=before_gross-1000000;
  IF dash->>'gross_profit_status'<>'RESOLVED' OR dash->>'expenses_today'<>'1000000.00'
    OR (dash->>'operating_profit')::numeric<>expected THEN RAISE EXCEPTION 'Operating profit formula/cancel exclusion incorrect: % expected %',dash,expected; END IF;
  PERFORM set_config('request.jwt.claim.sub','a4500000-0000-4000-8000-000000000001',false);
  IF (public.operational_expense_create('f4500000-0000-4000-8000-000000000105',today,'KONSUMSI','Admin expense test',1,'CASH',NULL,false)->>'status')<>'DRAFT'
    THEN RAISE EXCEPTION 'ADMIN expense permission failed'; END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',false);
  conflict:=false;
  BEGIN PERFORM public.operational_expense_create('f4500000-0000-4000-8000-000000000106',today,'KONSUMSI','Kasir denied',1,'CASH',NULL,false);
  EXCEPTION WHEN insufficient_privilege THEN conflict:=true; END;
  IF NOT conflict THEN RAISE EXCEPTION 'KASIR expense creation was allowed'; END IF;
  PERFORM set_config('request.jwt.claim.sub','a4500000-0000-4000-8000-000000000002',false); conflict:=false;
  BEGIN PERFORM public.operational_expense_create('f4500000-0000-4000-8000-000000000107',today,'KONSUMSI','Gudang denied',1,'CASH',NULL,false);
  EXCEPTION WHEN insufficient_privilege THEN conflict:=true; END;
  IF NOT conflict THEN RAISE EXCEPTION 'GUDANG expense creation was allowed'; END IF;
  conflict:=false; BEGIN PERFORM public.operational_expenses_page(today,today,'','','','',1,20);
  EXCEPTION WHEN insufficient_privilege THEN conflict:=true; END;
  IF NOT conflict THEN RAISE EXCEPTION 'GUDANG expense read was allowed'; END IF;
END $expense_lifecycle$;
RESET ROLE;
ROLLBACK;
\echo 'WAC expense lifecycle, exclusions, dashboard formula, replay, immutability, and role checks passed.'
