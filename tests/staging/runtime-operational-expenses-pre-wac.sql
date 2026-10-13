\set ON_ERROR_STOP on
BEGIN;
DO $guard$ BEGIN
  IF current_database()<>'quena_stock_staging' OR inet_server_port()<>55441
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR to_regprocedure('public.operational_expense_create(uuid,date,text,text,numeric,text,text,boolean)') IS NULL THEN
    RAISE EXCEPTION 'Refusing expense pre-WAC runtime test outside disposable staging';
  END IF;
END $guard$;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false);
SET ROLE authenticated;
DO $pre_wac_expense_test$
DECLARE today date:=timezone('Asia/Jakarta',now())::date; created jsonb; page jsonb; dash jsonb;
BEGIN
  created:=public.operational_expense_create('f4500000-0000-4000-8000-000000000001',today,'LISTRIK','Pre-WAC expense test',1000000,'CASH',NULL,true);
  page:=public.operational_expenses_page(today,today,'','','','',1,20);
  dash:=public.owner_dashboard_operating_expense_read();
  IF page#>>'{summary,total}'<>'1000000.00' OR page#>>'{summary,count}'<>'1'
    OR dash->>'expenses_today'<>'1000000.00' OR dash->>'operating_profit' IS NOT NULL
    OR dash->>'gross_profit_status'='RESOLVED'
    THEN RAISE EXCEPTION 'Pre-WAC expense/profit behavior incorrect: page %, dashboard %',page,dash; END IF;
END $pre_wac_expense_test$;
RESET ROLE;
ROLLBACK;
\echo 'Pre-WAC expense evidence visible; operating profit correctly unavailable.'
