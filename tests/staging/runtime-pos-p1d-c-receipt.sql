\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database() NOT LIKE 'quena_p1d_b_staging_%'
     OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
     OR inet_server_port()<>55432
     OR current_setting('server_version_num')::integer/10000<>15
     OR (SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal DESC LIMIT 1)<>'20260929360000'
     OR to_regprocedure('public.pos_sale_receipt_read(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Refusing receipt runtime checks outside disposable local PostgreSQL 15 through 360000';
  END IF;
END; $guard$;

DO $security$
DECLARE f regprocedure:='public.pos_sale_receipt_read(uuid)'::regprocedure;
BEGIN
  IF NOT (SELECT prosecdef AND provolatile='s' AND proconfig @> ARRAY['search_path=pg_catalog'] FROM pg_proc WHERE oid=f)
     OR NOT has_function_privilege('authenticated',f,'EXECUTE')
     OR has_function_privilege('anon',f,'EXECUTE')
     OR has_function_privilege('service_role',f,'EXECUTE')
     OR has_table_privilege('authenticated','public.sales','SELECT')
     OR has_table_privilege('authenticated','public.sale_items','SELECT')
     OR has_table_privilege('authenticated','public.sale_payments','SELECT') THEN
    RAISE EXCEPTION 'Receipt read grants, definer, or direct table access are incorrect';
  END IF;
END; $security$;

SELECT id::text AS sale_id, cashier_id::text AS cashier_id
FROM public.sales
WHERE checkout_request_id='f5000000-0000-4000-8000-000000000011'::uuid
\gset

BEGIN;
SELECT set_config('request.jwt.claim.sub', :'cashier_id', true);
SELECT set_config('quena.p1d_c.sale_id', :'sale_id', true);
SELECT set_config('quena.p1d_c.cashier_id', :'cashier_id', true);
SET LOCAL ROLE authenticated;
DO $read$
DECLARE receipt jsonb;
BEGIN
  receipt:=public.pos_sale_receipt_read(current_setting('quena.p1d_c.sale_id')::uuid);
  IF receipt IS NULL
     OR receipt->>'sale_number' NOT LIKE 'QPOS-%'
     OR receipt->>'cashier_label'<>'Stage Kasir'
     OR jsonb_array_length(receipt->'items')<1
     OR jsonb_array_length(receipt->'payments')<>1
     OR (receipt->>'grand_total')::numeric<=0
     OR receipt->'payments'->0->>'method'<>'CASH'
     OR (receipt->'payments'->0->>'received_amount')::numeric<(receipt->>'grand_total')::numeric
     OR (receipt->'payments'->0->>'change_amount')::numeric<0
     OR receipt ?| ARRAY['resolved_cogs_amount','provisional_cogs_amount','wac','hpp','cogs','margin','profit','source_layers','inventory_value']
     OR (receipt->'items'->0) ?| ARRAY['hpp','wac','cogs','margin','profit','inventory_value','source_layer'] THEN
    RAISE EXCEPTION 'Bounded receipt response is missing commercial data or contains costing data: %',receipt;
  END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
  IF public.pos_sale_receipt_read(current_setting('quena.p1d_c.sale_id')::uuid) IS NOT NULL THEN
    RAISE EXCEPTION 'GUDANG must not read a POS receipt';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',current_setting('quena.p1d_c.cashier_id',true),true);
  IF public.pos_sale_receipt_read(gen_random_uuid()) IS NOT NULL THEN
    RAISE EXCEPTION 'Unknown sale ID must not expose receipt data';
  END IF;
END; $read$;
COMMIT;
SELECT 'PASS: authorized KASIR reads one bounded commercial receipt without direct sale-table SELECT' AS result;
