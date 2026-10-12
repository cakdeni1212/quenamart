\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database() NOT LIKE 'quena_native_product_%'
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR inet_server_port()<>55432
    OR current_setting('server_version_num')::integer/10000<>15
    OR to_regprocedure('public.native_product_create(uuid,text,text,text,text,text,text,text,numeric)') IS NULL
    OR NOT EXISTS(SELECT 1 FROM quena_staging.environment WHERE name='quena_stock_staging') THEN
    RAISE EXCEPTION 'Refusing native product runtime test outside pinned disposable PostgreSQL 15 staging';
  END IF;
END $guard$;

BEGIN;
SELECT id AS outlet_id FROM public.outlets WHERE is_active AND EXISTS(
  SELECT 1 FROM public.stock_authority_periods p WHERE p.outlet_id=outlets.id AND p.ended_at IS NULL
) ORDER BY id LIMIT 1 \gset
SELECT gen_random_uuid() AS request_id, gen_random_uuid() AS admin_request_id,
       gen_random_uuid() AS duplicate_sku_request_id, gen_random_uuid() AS duplicate_barcode_request_id,
       gen_random_uuid() AS denied_request_id \gset
SELECT ('NATIVE-'||substr(replace(gen_random_uuid()::text,'-',''),1,12)) AS sku \gset
SELECT ('890'||substr(replace(gen_random_uuid()::text,'-',''),1,10)) AS barcode \gset
SELECT set_config('quena.test_outlet', :'outlet_id', true),
       set_config('quena.test_request', :'request_id', true),
       set_config('quena.test_sku', :'sku', true),
       set_config('quena.test_barcode', :'barcode', true),
       set_config('quena.test_duplicate_sku_request', :'duplicate_sku_request_id', true),
       set_config('quena.test_duplicate_barcode_request', :'duplicate_barcode_request_id', true),
       set_config('quena.test_denied_request', :'denied_request_id', true);
SELECT count(*) AS movements_before FROM public.stock_movements \gset
SELECT count(*) AS cost_events_before FROM public.inventory_cost_events \gset
SELECT count(*) AS hpp_batches_before FROM public.inventory_cost_hpp_acceptance_batches \gset
SELECT set_config('quena.test_before_movements', :'movements_before', true),
       set_config('quena.test_before_cost_events', :'cost_events_before', true),
       set_config('quena.test_before_hpp_batches', :'hpp_batches_before', true);

-- OWNER can create. Setting the claim and role mirrors an authenticated RPC call.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT public.native_product_create(:'request_id'::uuid, :'sku', 'Native staging product', 'Groceries', 'pcs',
  'Test Brand', 'A-01', :'barcode', 12345.50) AS owner_result \gset
SELECT public.native_product_create(:'request_id'::uuid, :'sku', 'Native staging product', 'Groceries', 'pcs',
  'Test Brand', 'A-01', :'barcode', 12345.50) AS owner_replay \gset
RESET ROLE;
SELECT (:'owner_result'::jsonb->>'product_id')::uuid AS product_id \gset
SELECT set_config('quena.test_product', :'product_id', true),
       set_config('quena.test_result', :'owner_result', true);

DO $owner_assertions$
DECLARE v_product uuid:=current_setting('quena.test_product')::uuid;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.products p WHERE p.id=v_product AND p.sku=current_setting('quena.test_sku'))
    OR NOT EXISTS(SELECT 1 FROM public.product_selling_prices s WHERE s.product_id=v_product
      AND s.outlet_id=current_setting('quena.test_outlet')::uuid AND s.amount=12345.50)
    OR (SELECT count(*) FROM public.product_selling_price_history h WHERE h.product_id=v_product
      AND h.outlet_id=current_setting('quena.test_outlet')::uuid AND h.amount=12345.50)<>1
    OR NOT EXISTS(SELECT 1 FROM public.product_barcodes b WHERE b.product_id=v_product
      AND b.barcode=current_setting('quena.test_barcode') AND b.is_active AND b.source_import_row_id IS NULL)
    OR NOT EXISTS(SELECT 1 FROM public.product_inventory i WHERE i.product_id=v_product
      AND i.outlet_id=current_setting('quena.test_outlet')::uuid AND i.quantity=0
      AND i.source_import_row_id IS NULL)
    OR NOT EXISTS(SELECT 1 FROM public.stock_native_zero_baselines b
      WHERE b.request_id=current_setting('quena.test_request')::uuid AND b.product_id=v_product
        AND b.outlet_id=current_setting('quena.test_outlet')::uuid AND b.source_system='QUENA_NATIVE'
        AND b.accepted_baseline_quantity=0 AND b.actor_id='a0000000-0000-4000-8000-000000000001')
    OR NOT EXISTS(SELECT 1 FROM public.stock_balance_projection p
      WHERE p.product_id=v_product AND p.outlet_id=current_setting('quena.test_outlet')::uuid
        AND p.baseline_quantity=0 AND p.unreconciled_movement_delta=0 AND p.effective_quantity=0
        AND p.native_zero_baseline_request_id=current_setting('quena.test_request')::uuid
        AND p.baseline_source_import_row_id IS NULL AND p.baseline_batch_id IS NULL AND p.baseline_commit_id IS NULL)
    OR NOT EXISTS(SELECT 1 FROM public.stock_balance_projection_events e
      WHERE e.product_id=v_product AND e.outlet_id=current_setting('quena.test_outlet')::uuid
        AND e.event_type='NATIVE_ZERO_BASELINE_ACCEPTED'
        AND e.native_zero_baseline_request_id=current_setting('quena.test_request')::uuid
        AND e.balance_before=0 AND e.balance_after=0 AND e.quantity_delta=0)
    OR NOT EXISTS(SELECT 1 FROM public.native_product_creation_requests r WHERE r.request_id=current_setting('quena.test_request')::uuid
      AND r.actor_id='a0000000-0000-4000-8000-000000000001' AND r.outlet_id=current_setting('quena.test_outlet')::uuid
      AND r.product_id=v_product AND r.source_system='QUENA_NATIVE') THEN
    RAISE EXCEPTION 'Owner native product, zero baseline, price history, barcode, or provenance evidence is missing';
  END IF;
  IF (SELECT result FROM public.native_product_creation_requests WHERE request_id=current_setting('quena.test_request')::uuid)
      IS DISTINCT FROM current_setting('quena.test_result')::jsonb THEN
    RAISE EXCEPTION 'Stored replay result differs from the first result';
  END IF;
END $owner_assertions$;

DO $conflict_assertions$
DECLARE v_message text;
BEGIN
  BEGIN
    PERFORM public.native_product_create(current_setting('quena.test_request')::uuid,current_setting('quena.test_sku'),
      'Changed name','Groceries','pcs','Test Brand','A-01',current_setting('quena.test_barcode'),12345.50);
    RAISE EXCEPTION 'Changed request payload unexpectedly replayed';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'NATIVE_PRODUCT_REQUEST_CONFLICT' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.native_product_create(current_setting('quena.test_duplicate_sku_request')::uuid,
      current_setting('quena.test_sku'),'Another product','Groceries','pcs',NULL,NULL,NULL,1000);
    RAISE EXCEPTION 'Duplicate SKU unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'NATIVE_PRODUCT_SKU_EXISTS' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.native_product_create(current_setting('quena.test_duplicate_barcode_request')::uuid,
      NULL,'Another product','Groceries','pcs',NULL,NULL,current_setting('quena.test_barcode'),1000);
    RAISE EXCEPTION 'Duplicate barcode unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'NATIVE_PRODUCT_BARCODE_EXISTS' THEN RAISE; END IF;
  END;
END $conflict_assertions$;

-- Verify exact barcode and manual-search contracts return the native product and outlet price.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
SET LOCAL ROLE authenticated;
SELECT public.pos_resolve_barcode(current_setting('quena.test_barcode')) AS barcode_result \gset
SELECT public.pos_search_products('Native staging product',25) AS search_result \gset
RESET ROLE;
SELECT set_config('quena.barcode_result', :'barcode_result', true),
       set_config('quena.search_result', :'search_result', true);
DO $pos_assertions$
BEGIN
  IF (current_setting('quena.barcode_result')::jsonb#>>'{resolution}')<>'BARCODE_MATCH'
    OR (current_setting('quena.barcode_result')::jsonb#>>'{product,unit_price}')::numeric<>12345.50
    OR NOT (current_setting('quena.search_result')::jsonb#>'{rows}') @> jsonb_build_array(jsonb_build_object('sku',current_setting('quena.test_sku'),'unit_price',12345.50)) THEN
    RAISE EXCEPTION 'Native product was not available through POS barcode and search contracts';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_path_query(current_setting('quena.barcode_result')::jsonb,'$.**') j
      WHERE lower(j::text) LIKE '%hpp%' OR lower(j::text) LIKE '%wac%' OR lower(j::text) LIKE '%cogs%') THEN
    RAISE EXCEPTION 'Costing data appeared in the commercial POS lookup';
  END IF;
END $pos_assertions$;

-- ADMIN is allowed; KASIR and GUDANG are denied.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
SET LOCAL ROLE authenticated;
SELECT public.native_product_create(:'admin_request_id'::uuid,NULL,'Admin native product','Household','box',NULL,NULL,NULL,2500) AS admin_result \gset
RESET ROLE;
SELECT (:'admin_result'::jsonb->>'product_id') AS admin_product \gset
SELECT set_config('quena.test_admin_product', :'admin_product', true);
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
SET LOCAL ROLE authenticated;
DO $kasir_denied$
DECLARE v_message text;
BEGIN
  BEGIN
    PERFORM public.native_product_create(current_setting('quena.test_denied_request')::uuid,NULL,
      'Denied product','Other','pcs',NULL,NULL,NULL,1000);
    RAISE EXCEPTION 'KASIR creation unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'NATIVE_PRODUCT_UNAUTHORIZED' THEN RAISE; END IF;
  END;
END $kasir_denied$;
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
DO $gudang_denied$
DECLARE v_message text;
BEGIN
  BEGIN
    PERFORM public.native_product_create(gen_random_uuid(),NULL,'Denied product','Other','pcs',NULL,NULL,NULL,1000);
    RAISE EXCEPTION 'GUDANG creation unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'NATIVE_PRODUCT_UNAUTHORIZED' THEN RAISE; END IF;
  END;
END $gudang_denied$;
RESET ROLE;

DO $no_stock_or_cost_writes$
BEGIN
  IF (SELECT count(*) FROM public.stock_movements)<>current_setting('quena.test_before_movements')::bigint
    OR (SELECT count(*) FROM public.inventory_cost_events)<>current_setting('quena.test_before_cost_events')::bigint
    OR (SELECT count(*) FROM public.inventory_cost_hpp_acceptance_batches)<>current_setting('quena.test_before_hpp_batches')::bigint
    OR (SELECT count(*) FROM public.stock_balance_projection b WHERE b.product_id IN
      (current_setting('quena.test_product')::uuid,current_setting('quena.test_admin_product')::uuid))<>2
    OR EXISTS(SELECT 1 FROM public.stock_balance_projection b WHERE b.product_id IN
      (current_setting('quena.test_product')::uuid,current_setting('quena.test_admin_product')::uuid)
      AND (b.effective_quantity<>0 OR b.unreconciled_movement_delta<>0)) THEN
    RAISE EXCEPTION 'Native product creation wrote stock movements/cost/HPP or did not create a zero projection';
  END IF;
END $no_stock_or_cost_writes$;

-- Native enrollment is explicit; an ordinary product_inventory insert with
-- no iPos source still fails the original strict iPos provenance check.
DO $ipos_provenance_remains_strict$
DECLARE v_product uuid:=gen_random_uuid(); v_message text;
BEGIN
  INSERT INTO public.products(id,sku,name,unit_label,created_by,updated_by)
  VALUES(v_product,'IPOS-STRICT-'||substr(replace(gen_random_uuid()::text,'-',''),1,12),
    'iPos provenance guard fixture','pcs','a0000000-0000-4000-8000-000000000001',
    'a0000000-0000-4000-8000-000000000001');
  BEGIN
    INSERT INTO public.product_inventory(product_id,outlet_id,quantity,created_by,updated_by)
    VALUES(v_product,current_setting('quena.test_outlet')::uuid,0,
      'a0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001');
    RAISE EXCEPTION 'Ordinary inventory insert bypassed iPos provenance validation';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'Stock baseline refresh requires an iPos source row' THEN RAISE; END IF;
  END;
  DELETE FROM public.products WHERE id=v_product;
  IF NOT EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
      WHERE c.oid='public.product_inventory'::regclass
        AND t.tgname='product_inventory_refresh_stock_projection_insert'
        AND t.tgenabled='O') THEN
    RAISE EXCEPTION 'The existing iPos stock refresh trigger was disabled';
  END IF;
END $ipos_provenance_remains_strict$;
ROLLBACK;

\echo 'PASS: native product owner/admin authorization, idempotency, conflicts, POS lookup, and zero stock/cost mutation'
