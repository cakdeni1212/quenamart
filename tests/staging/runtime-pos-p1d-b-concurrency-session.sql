\set ON_ERROR_STOP on
SELECT CASE WHEN :'use_b'::boolean THEN cart_b ELSE cart_a END AS cart_id,
  CASE WHEN :'use_b'::boolean THEN revision_b ELSE revision_a END AS revision,
  CASE WHEN :'use_b'::boolean THEN request_b ELSE request_a END AS request_id
  FROM quena_staging.p1d_b_race_fixture \gset
SELECT set_config('quena.race.cart',:'cart_id',false);
SELECT set_config('quena.race.revision',:'revision',false);
SELECT set_config('quena.race.request',:'request_id',false);
SELECT 'READY' AS ready;
DO $barrier$
DECLARE started timestamptz:=clock_timestamp(); v_go boolean;
BEGIN
  LOOP
    SELECT go INTO v_go FROM quena_staging.p1d_b_race_gate;
    EXIT WHEN v_go;
    IF clock_timestamp()-started>interval '20 seconds' THEN RAISE EXCEPTION 'concurrency barrier timeout'; END IF;
    PERFORM pg_sleep(0.01);
  END LOOP;
END; $barrier$;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',false);
SET ROLE authenticated;
DO $attempt$
BEGIN
  PERFORM public.pos_checkout_complete(current_setting('quena.race.request')::uuid,
    current_setting('quena.race.cart')::uuid,current_setting('quena.race.revision')::bigint,
    'CASH'::public.pos_sale_payment_method,5000,NULL);
  RAISE NOTICE 'RESULT=SUCCESS';
EXCEPTION WHEN SQLSTATE 'P0001' THEN
  RAISE NOTICE 'RESULT=%',SQLERRM;
END; $attempt$;
