\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database() <> 'quena_stock_staging'
     OR coalesce(host(inet_server_addr()), '') NOT IN ('127.0.0.1', '::1')
     OR inet_server_port() <> 5432
     OR current_setting('server_version_num')::integer / 10000 <> 15
     OR NOT EXISTS (SELECT 1 FROM quena_staging.environment WHERE name = 'quena_stock_staging')
     OR NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929171000')
     OR NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929180000') THEN
    RAISE EXCEPTION 'Refusing concurrency waiter outside verified local stock staging';
  END IF;
END;
$guard$;
BEGIN;
SET LOCAL statement_timeout = '35s';
SET LOCAL lock_timeout = '25s';
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', :'actor_id', true);
SELECT public.apply_stock_operation_intent(:'request_id'::uuid);
COMMIT;
