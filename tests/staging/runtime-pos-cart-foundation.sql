\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database() NOT LIKE 'quena_p1b_staging_%'
     OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
     OR inet_server_port()<>55432
     OR current_setting('server_version_num')::integer/10000<>15
     OR (SELECT version FROM quena_staging.applied_migrations ORDER BY ordinal DESC LIMIT 1)<>'20260929330000'
     OR to_regprocedure('public.pos_cart_create(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Refusing P1B runtime outside disposable local PostgreSQL 15 through 330000';
  END IF;
END; $guard$;

BEGIN;
SET LOCAL statement_timeout='60s';
SET LOCAL lock_timeout='10s';
SELECT id::text AS outlet_id FROM public.outlets WHERE code='QUENA-MART-1' AND is_active \gset
SELECT id::text AS product_id FROM public.products WHERE sku='STG-FULL-A' \gset
SELECT id::text AS ambiguous_product_id FROM public.products WHERE sku='STG-AMBIG-A' \gset
SELECT set_config('quena.p1b.product_id',:'product_id',true);
SELECT set_config('quena.p1b.outlet_id',:'outlet_id',true);
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
SET LOCAL ROLE authenticated;

SELECT set_config('quena.p1b.create_result',public.pos_cart_create('f1000000-0000-4000-8000-000000000001')::text,true);
SELECT set_config('quena.p1b.create_replay',public.pos_cart_create('f1000000-0000-4000-8000-000000000001')::text,true);
SELECT set_config('quena.p1b.cart_id',current_setting('quena.p1b.create_result')::jsonb->>'cart_id',true);
SELECT set_config('quena.p1b.create_second',public.pos_cart_create('f1000000-0000-4000-8000-000000000002')::text,true);
SELECT set_config('quena.p1b.add_result',public.pos_cart_add_item(current_setting('quena.p1b.cart_id')::uuid, :'product_id'::uuid, 1, 1, 'f1000000-0000-4000-8000-000000000003')::text,true);
SELECT set_config('quena.p1b.add_replay',public.pos_cart_add_item(current_setting('quena.p1b.cart_id')::uuid, :'product_id'::uuid, 1, 1, 'f1000000-0000-4000-8000-000000000003')::text,true);
SELECT set_config('quena.p1b.add_second_scan',public.pos_cart_add_item(current_setting('quena.p1b.cart_id')::uuid, :'product_id'::uuid, 1, 2, 'f1000000-0000-4000-8000-000000000004')::text,true);
RESET ROLE;
SELECT set_config('quena.p1b.item_id',(SELECT id::text FROM public.pos_cart_items WHERE cart_id=current_setting('quena.p1b.cart_id')::uuid AND product_id=:'product_id'::uuid),true);
SET LOCAL ROLE authenticated;

SELECT set_config('quena.p1b.barcode_match',public.pos_resolve_barcode('STG-FULL-A-BC')::text,true);
SELECT set_config('quena.p1b.barcode_missing',public.pos_resolve_barcode('P1B-MISSING')::text,true);
SELECT set_config('quena.p1b.barcode_ambiguous',public.pos_resolve_barcode('STG-DUP-AMBIG')::text,true);
SELECT set_config('quena.p1b.search',public.pos_search_products('STG-FULL',999)::text,true);

RESET ROLE;
DO $quantity_update$
DECLARE cid uuid:=current_setting('quena.p1b.cart_id')::uuid; iid uuid:=current_setting('quena.p1b.item_id')::uuid; r jsonb;
BEGIN
  r:=public.pos_cart_set_item_quantity(cid,iid,3,3,'f1000000-0000-4000-8000-000000000005');
  IF r->>'revision'<>'4' THEN RAISE EXCEPTION 'quantity update revision failed: %',r; END IF;
  r:=public.pos_cart_set_item_quantity(cid,iid,1.125,4,'f1000000-0000-4000-8000-000000000015');
  IF r->>'revision'<>'5' THEN RAISE EXCEPTION 'three-decimal quantity update failed: %',r; END IF;
  BEGIN
    PERFORM public.pos_cart_set_item_quantity(cid,iid,-1,5,'f1000000-0000-4000-8000-000000000006');
    RAISE EXCEPTION 'negative cart quantity was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  BEGIN
    PERFORM public.pos_cart_set_item_quantity(cid,iid,2,3,'f1000000-0000-4000-8000-000000000007');
    RAISE EXCEPTION 'stale cart revision was accepted';
  EXCEPTION WHEN SQLSTATE '40001' THEN NULL; END;
END; $quantity_update$;

DO $price_change$
DECLARE cid uuid:=current_setting('quena.p1b.cart_id')::uuid; iid uuid:=current_setting('quena.p1b.item_id')::uuid; outlet uuid:=current_setting('quena.p1b.outlet_id')::uuid; current_price numeric; read_result jsonb; ack jsonb;
BEGIN
  PERFORM public.pos_cart_park(cid,5,'f1000000-0000-4000-8000-000000000009');
  UPDATE public.product_selling_prices SET amount=amount+1,updated_at=now()
   WHERE product_id=current_setting('quena.p1b.product_id')::uuid AND outlet_id=outlet;
  current_price:=(SELECT amount FROM public.product_selling_prices WHERE product_id=current_setting('quena.p1b.product_id')::uuid AND outlet_id=outlet);
  read_result:=public.pos_cart_workspace_read(cid,20);
  IF read_result #>> '{carts,0,items,0,price_status}'<>'CHANGED' THEN RAISE EXCEPTION 'stale price was not detected: %',read_result; END IF;
  IF read_result #>> '{carts,0,status}'<>'PARKED' THEN RAISE EXCEPTION 'parked cart status was not persisted'; END IF;
END; $price_change$;

DO $lifecycle$
DECLARE cid uuid:=current_setting('quena.p1b.cart_id')::uuid; iid uuid:=current_setting('quena.p1b.item_id')::uuid; r jsonb;
BEGIN
  r:=public.pos_cart_resume(cid,6,'f1000000-0000-4000-8000-000000000010');
  IF r->>'status'<>'ACTIVE' OR r->>'revision'<>'7' THEN RAISE EXCEPTION 'resume failed: %',r; END IF;
  r:=public.pos_cart_acknowledge_price(cid,iid,(SELECT amount FROM public.product_selling_prices WHERE product_id=current_setting('quena.p1b.product_id')::uuid AND outlet_id=current_setting('quena.p1b.outlet_id')::uuid),7,'f1000000-0000-4000-8000-000000000016');
  IF r->>'revision'<>'8' OR (public.pos_cart_workspace_read(cid,20) #>> '{carts,0,items,0,price_status}')<>'CURRENT' THEN RAISE EXCEPTION 'price acknowledgment failed: %',r; END IF;
  r:=public.pos_cart_set_item_quantity(cid,iid,0,8,'f1000000-0000-4000-8000-000000000011');
  IF r->>'revision'<>'9' OR EXISTS(SELECT 1 FROM public.pos_cart_items WHERE id=iid) THEN RAISE EXCEPTION 'zero quantity did not remove line'; END IF;
  r:=public.pos_cart_cancel(cid,9,'f1000000-0000-4000-8000-000000000012');
  IF r->>'status'<>'CANCELLED' OR r->>'revision'<>'10' THEN RAISE EXCEPTION 'cancel failed: %',r; END IF;
  BEGIN
    PERFORM public.pos_cart_add_item(cid,current_setting('quena.p1b.product_id')::uuid,1,10,'f1000000-0000-4000-8000-000000000013');
    RAISE EXCEPTION 'cancelled cart was editable';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
END; $lifecycle$;

DO $role_and_read$
DECLARE result jsonb; kasir_cart uuid:=current_setting('quena.p1b.cart_id')::uuid;
BEGIN
  IF current_setting('quena.p1b.create_result')::jsonb IS DISTINCT FROM current_setting('quena.p1b.create_replay')::jsonb
    OR current_setting('quena.p1b.add_result')::jsonb IS DISTINCT FROM current_setting('quena.p1b.add_replay')::jsonb THEN
    RAISE EXCEPTION 'same-request replay changed result'; END IF;
  IF (current_setting('quena.p1b.add_result')::jsonb->>'revision')<>'2'
    OR (current_setting('quena.p1b.add_second_scan')::jsonb->>'revision')<>'3'
    OR (SELECT quantity FROM public.pos_cart_items WHERE cart_id=kasir_cart AND product_id=current_setting('quena.p1b.product_id')::uuid)<>1.125 THEN
    RAISE EXCEPTION 'intentional scan/replay quantity contract failed'; END IF;
  IF current_setting('quena.p1b.barcode_match')::jsonb->>'resolution'<>'BARCODE_MATCH'
    OR current_setting('quena.p1b.barcode_missing')::jsonb->>'resolution'<>'BARCODE_NOT_FOUND'
    OR current_setting('quena.p1b.barcode_ambiguous')::jsonb->>'resolution'<>'BARCODE_AMBIGUOUS' THEN
    RAISE EXCEPTION 'barcode contract failed'; END IF;
  IF jsonb_array_length(current_setting('quena.p1b.search')::jsonb->'rows')>25 THEN RAISE EXCEPTION 'search bound exceeded'; END IF;
  IF current_setting('quena.p1b.search')::text ~* 'hpp|wac|inventory_value|source_layer|cogs' THEN RAISE EXCEPTION 'financial field leaked from search'; END IF;
  IF has_table_privilege('authenticated','public.pos_carts','SELECT') OR has_table_privilege('authenticated','public.pos_cart_items','INSERT') THEN
    RAISE EXCEPTION 'authenticated has direct cart table access'; END IF;
  result:=public.pos_cart_workspace_read(NULL,20);
  IF jsonb_array_length(result->'carts')<2 THEN RAISE EXCEPTION 'multiple persistent carts not visible to owner'; END IF;
  IF to_regprocedure('public.complete_sale(uuid,bigint,uuid,jsonb)') IS NOT NULL OR to_regclass('public.sale_payments') IS NOT NULL THEN
    RAISE EXCEPTION 'P1B unexpectedly installed checkout/payment'; END IF;
END; $role_and_read$;

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
DO $manager_access$
DECLARE listed jsonb; created jsonb;
BEGIN
  listed:=public.pos_cart_workspace_read(NULL,20);
  IF jsonb_array_length(listed->'carts')<2 THEN RAISE EXCEPTION 'OWNER cannot inspect authorized outlet carts'; END IF;
  created:=public.pos_cart_create('f1000000-0000-4000-8000-000000000017');
  IF created->>'status'<>'ACTIVE' THEN RAISE EXCEPTION 'OWNER cannot create cart'; END IF;
END; $manager_access$;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
DO $admin_access$
DECLARE created jsonb;
BEGIN
  created:=public.pos_cart_create('f1000000-0000-4000-8000-000000000018');
  IF created->>'status'<>'ACTIVE' THEN RAISE EXCEPTION 'ADMIN cannot create cart'; END IF;
END; $admin_access$;

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
DO $cashier_isolation$
DECLARE listed jsonb; owner_cart uuid;
BEGIN
  owner_cart:=(SELECT id FROM public.pos_carts WHERE created_by='a0000000-0000-4000-8000-000000000001' ORDER BY created_at DESC LIMIT 1);
  listed:=public.pos_cart_workspace_read(NULL,20);
  IF listed::text LIKE '%'||owner_cart::text||'%' THEN RAISE EXCEPTION 'KASIR can read another actor cart'; END IF;
END; $cashier_isolation$;

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
DO $gudang_denied$
BEGIN
  BEGIN
    PERFORM public.pos_cart_create('f1000000-0000-4000-8000-000000000014');
    RAISE EXCEPTION 'GUDANG was allowed to create POS cart';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
END; $gudang_denied$;

ROLLBACK;
