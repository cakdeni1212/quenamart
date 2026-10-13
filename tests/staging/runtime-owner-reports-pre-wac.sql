\set ON_ERROR_STOP on
BEGIN;
INSERT INTO public.operational_expenses(id,outlet_id,expense_number,expense_date,category,description,amount,
  payment_method,status,created_by,created_by_name,updated_by,posted_by,posted_by_name,posted_at)
SELECT gen_random_uuid(),o.id,'QEXP-REPORT-PREWAC',timezone('Asia/Jakarta',now())::date,'LISTRIK','pre-WAC report assertion',1000000,
  'CASH','POSTED','a0000000-0000-4000-8000-000000000001','Stage Owner','a0000000-0000-4000-8000-000000000001',
  'a0000000-0000-4000-8000-000000000001','Stage Owner',now()
FROM public.outlets o WHERE o.code='QUENA-MART-1';
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false);
SET ROLE authenticated;
DO $pre_wac_reports$
DECLARE today_business date:=timezone('Asia/Jakarta',now())::date;result jsonb;
BEGIN
  result:=public.owner_reports_read(today_business,today_business,today_business-1,today_business-1);
  IF (result->'kpis'->>'expenses')::numeric<>1000000
    OR result->'kpis'->>'profit_status'<>'COSTING_INACTIVE'
    OR result->'kpis'->>'gross_profit' IS NOT NULL
    OR result->'kpis'->>'gross_margin' IS NOT NULL
    OR result->'kpis'->>'operating_profit' IS NOT NULL THEN
    RAISE EXCEPTION 'Pre-WAC reports fabricated profit: %',result->'kpis';
  END IF;
END $pre_wac_reports$;
RESET ROLE;
ROLLBACK;
SELECT 'OWNER_REPORTS_PRE_WAC_UNAVAILABLE_PASS' AS result;
