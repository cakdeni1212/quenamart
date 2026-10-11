\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database() NOT LIKE 'quena_p1d_b_staging_%'
     OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
     OR inet_server_port()<>55432 OR current_setting('server_version_num')::integer/10000<>15 THEN
    RAISE EXCEPTION 'Refusing concurrency fixture outside disposable local PostgreSQL 15';
  END IF;
END; $guard$;
BEGIN;
DROP TABLE IF EXISTS quena_staging.p1d_b_race_fixture;
DROP TABLE IF EXISTS quena_staging.p1d_b_race_gate;
CREATE TABLE quena_staging.p1d_b_race_fixture(
  cart_a uuid NOT NULL, revision_a bigint NOT NULL, request_a uuid NOT NULL,
  cart_b uuid NOT NULL, revision_b bigint NOT NULL, request_b uuid NOT NULL,
  product_id uuid NOT NULL, outlet_id uuid NOT NULL
);
CREATE TABLE quena_staging.p1d_b_race_gate(go boolean NOT NULL DEFAULT false);
INSERT INTO quena_staging.p1d_b_race_gate VALUES(false);
SELECT id AS outlet_id FROM public.outlets WHERE code='QUENA-MART-1' AND is_active \gset
SELECT id AS product_id FROM public.products WHERE sku='STG-FULL-A' \gset
SELECT set_config('quena.race.outlet',:'outlet_id',true);
SELECT set_config('quena.race.product',:'product_id',true);
DO $fixture_guard$
BEGIN
  IF (SELECT effective_quantity FROM public.stock_balance_projection
      WHERE outlet_id=current_setting('quena.race.outlet')::uuid AND product_id=current_setting('quena.race.product')::uuid)<>5
    OR (SELECT valued_quantity FROM public.inventory_cost_projections
      WHERE outlet_id=current_setting('quena.race.outlet')::uuid AND product_id=current_setting('quena.race.product')::uuid)<>0 THEN
    RAISE EXCEPTION 'Expected STG-FULL-A to start with five unvalued units';
  END IF;
END; $fixture_guard$;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
SET LOCAL ROLE authenticated;
SELECT (public.pos_cart_create('f5000000-0000-4000-8000-000000000021'::uuid)->>'cart_id') AS setup_cart \gset
SELECT (public.pos_cart_add_item(:'setup_cart'::uuid,:'product_id'::uuid,4,1,'f5000000-0000-4000-8000-000000000022'::uuid)->>'revision') AS setup_revision \gset
SELECT public.pos_checkout_complete('f5000000-0000-4000-8000-000000000023'::uuid,:'setup_cart'::uuid,:'setup_revision'::bigint,
  'CASH'::public.pos_sale_payment_method,5000,NULL);
SELECT (public.pos_cart_create('f5000000-0000-4000-8000-000000000024'::uuid)->>'cart_id') AS cart_a \gset
SELECT (public.pos_cart_add_item(:'cart_a'::uuid,:'product_id'::uuid,1,1,'f5000000-0000-4000-8000-000000000025'::uuid)->>'revision') AS revision_a \gset
SELECT (public.pos_cart_create('f5000000-0000-4000-8000-000000000026'::uuid)->>'cart_id') AS cart_b \gset
SELECT (public.pos_cart_add_item(:'cart_b'::uuid,:'product_id'::uuid,1,1,'f5000000-0000-4000-8000-000000000027'::uuid)->>'revision') AS revision_b \gset
RESET ROLE;
INSERT INTO quena_staging.p1d_b_race_fixture VALUES(
  :'cart_a'::uuid,:'revision_a'::bigint,'f5000000-0000-4000-8000-000000000028'::uuid,
  :'cart_b'::uuid,:'revision_b'::bigint,'f5000000-0000-4000-8000-000000000029'::uuid,
  :'product_id'::uuid,:'outlet_id'::uuid);
COMMIT;
SELECT 'PASS: stock is now one unit and two independent ACTIVE carts each request one' AS result;
