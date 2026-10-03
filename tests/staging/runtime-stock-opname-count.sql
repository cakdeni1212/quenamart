-- Local-only RECORD_COUNT contract matrix. All stock mutations go through
-- authenticated operation intents, and the outer transaction always rolls back.
\set ON_ERROR_STOP on
\timing on

DO $guard$
BEGIN
  IF current_database() <> 'quena_stock_staging'
     OR coalesce(host(inet_server_addr()), '') NOT IN ('127.0.0.1', '::1')
     OR inet_server_port() <> 5432
     OR current_setting('server_version_num')::integer / 10000 <> 15
     OR current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'Refusing RECORD_COUNT runtime checks outside local UTF8 PostgreSQL 15 quena_stock_staging';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929180000')
     OR NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929190000') THEN
    RAISE EXCEPTION 'Required local stock migrations 180000 and 190000 are not ledgered';
  END IF;
END;
$guard$;

BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '8s';
SET LOCAL ROLE authenticated;

DO $count_runtime$
DECLARE
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_admin uuid := 'a0000000-0000-4000-8000-000000000002';
  v_gudang uuid := 'a0000000-0000-4000-8000-000000000003';
  v_kasir uuid := 'a0000000-0000-4000-8000-000000000004';
  v_outlet uuid;
  v_item_product uuid;
  v_decimal_product uuid;
  v_gudang_product uuid;
  v_baseline_product uuid;
  v_session uuid;
  v_setup_session uuid;
  v_stale_session uuid;
  v_request uuid;
  v_retry uuid;
  v_result jsonb;
  v_replay jsonb;
  v_baseline numeric;
  v_projection_quantity numeric;
  v_projection_version bigint;
  v_inventory_fingerprint text;
  v_inventory_after text;
  v_projection_fingerprint text;
  v_projection_after text;
  v_event_count bigint;
  v_item_revision integer;
  v_movement uuid;
  v_kasir_denied boolean;
  v_error text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  IF public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION 'Synthetic OWNER profile is not active';
  END IF;
  SELECT o.id INTO STRICT v_outlet FROM public.outlets o WHERE o.code = 'QUENA-MART-1' AND o.is_active;
  SELECT p.id INTO STRICT v_item_product FROM public.products p WHERE p.sku = 'STG-FULL-A';
  SELECT p.id INTO STRICT v_decimal_product FROM public.products p WHERE p.sku = 'STG-FULL-B';
  SELECT p.id INTO STRICT v_gudang_product FROM public.products p WHERE p.sku = 'STG-STALE';
  SELECT p.id INTO STRICT v_baseline_product FROM public.products p WHERE p.sku = 'STG-BASE20';

  IF EXISTS (
    SELECT 1 FROM public.stock_opname_items i
    WHERE i.outlet_id = v_outlet AND i.active_scope
      AND i.product_id IN (v_item_product, v_decimal_product, v_gudang_product, v_baseline_product)
  ) THEN
    RAISE EXCEPTION 'Precondition failed: a test product already has active opname coverage';
  END IF;

  v_request := public.issue_stock_operation_intent('CREATE_SESSION', jsonb_build_object(
    'outlet_id', v_outlet, 'scope_type', 'PARTIAL',
    'product_ids', jsonb_build_array(v_item_product, v_decimal_product, v_gudang_product),
    'note', 'RECORD_COUNT rollback matrix'));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'ok' IS DISTINCT FROM 'true' OR v_result->>'status' IS DISTINCT FROM 'COUNTING' THEN
    RAISE EXCEPTION 'Could not create synthetic counting session for RECORD_COUNT matrix';
  END IF;
  v_session := (v_result->>'sessionId')::uuid;

  SELECT md5(coalesce(string_agg(i.product_id::text || ':' || coalesce(i.quantity::text, '<null>') || ':' ||
      coalesce(i.minimum_quantity::text, '<null>') || ':' || coalesce(i.source_import_row_id::text, '<null>'), E'\n' ORDER BY i.product_id), ''))
  INTO v_inventory_fingerprint FROM public.product_inventory i
  WHERE i.outlet_id = v_outlet AND i.product_id IN (v_item_product, v_decimal_product, v_gudang_product);
  SELECT md5(coalesce(string_agg(p.product_id::text || ':' || coalesce(p.effective_quantity::text, '<null>') || ':' ||
      p.balance_version::text || ':' || coalesce(p.unreconciled_movement_delta::text, '<null>'), E'\n' ORDER BY p.product_id), ''))
  INTO v_projection_fingerprint FROM public.stock_balance_projection p
  WHERE p.outlet_id = v_outlet AND p.product_id IN (v_item_product, v_decimal_product, v_gudang_product);

  -- OWNER: valid zero physical count, then exact same-request replay.
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_session, 'product_id', v_item_product,
    'physical_quantity', 0, 'expected_revision', 0, 'barcode_id', null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'ok' IS DISTINCT FROM 'true' OR v_result->>'revision' IS DISTINCT FROM '1'
     OR (SELECT i.physical_quantity FROM public.stock_opname_items i WHERE i.session_id = v_session AND i.product_id = v_item_product) IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'OWNER zero count did not persist revision 1';
  END IF;
  SELECT count(*) INTO v_event_count FROM public.stock_opname_count_events e WHERE e.request_id = v_request;
  v_replay := public.apply_stock_operation_intent(v_request);
  IF v_replay IS DISTINCT FROM v_result
     OR (SELECT count(*) FROM public.stock_opname_count_events e WHERE e.request_id = v_request) IS DISTINCT FROM v_event_count
     OR v_event_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Exact RECORD_COUNT request retry did not replay exactly once';
  END IF;
  RAISE NOTICE 'PASS: OWNER zero count and exact request replay';

  -- ADMIN: 3-decimal count and deliberate replacement through a new revision.
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  IF public.current_active_user_role() IS DISTINCT FROM 'ADMIN'::public.user_role THEN
    RAISE EXCEPTION 'Synthetic ADMIN profile is not active';
  END IF;
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_session, 'product_id', v_decimal_product,
    'physical_quantity', 1.234, 'expected_revision', 0, 'barcode_id', null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'ok' IS DISTINCT FROM 'true' OR v_result->>'revision' IS DISTINCT FROM '1'
     OR (SELECT i.physical_quantity FROM public.stock_opname_items i WHERE i.session_id = v_session AND i.product_id = v_decimal_product) IS DISTINCT FROM 1.234 THEN
    RAISE EXCEPTION 'ADMIN three-decimal count did not persist';
  END IF;
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_session, 'product_id', v_decimal_product,
    'physical_quantity', 2.345, 'expected_revision', 1, 'barcode_id', null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'ok' IS DISTINCT FROM 'true' OR v_result->>'revision' IS DISTINCT FROM '2'
     OR (SELECT i.physical_quantity FROM public.stock_opname_items i WHERE i.session_id = v_session AND i.product_id = v_decimal_product) IS DISTINCT FROM 2.345
     OR (SELECT count(*) FROM public.stock_opname_count_events e JOIN public.stock_opname_items i ON i.id = e.item_id
         WHERE i.session_id = v_session AND i.product_id = v_decimal_product AND e.event_type = 'RECOUNTED' AND e.revision_no = 2) IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'ADMIN replacement count did not append revision 2';
  END IF;
  RAISE NOTICE 'PASS: ADMIN three-decimal count and replacement revision';

  -- GUDANG may count; KASIR must be rejected before any intent is recorded.
  PERFORM set_config('request.jwt.claim.sub', v_gudang::text, true);
  IF public.current_active_user_role() IS DISTINCT FROM 'GUDANG'::public.user_role THEN
    RAISE EXCEPTION 'Synthetic GUDANG profile is not active';
  END IF;
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_session, 'product_id', v_gudang_product,
    'physical_quantity', 4.5, 'expected_revision', 0, 'barcode_id', null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'ok' IS DISTINCT FROM 'true' OR v_result->>'revision' IS DISTINCT FROM '1' THEN
    RAISE EXCEPTION 'GUDANG RECORD_COUNT was not accepted';
  END IF;
  PERFORM set_config('request.jwt.claim.sub', v_kasir::text, true);
  v_kasir_denied := false;
  BEGIN
    PERFORM public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
      'session_id', v_session, 'product_id', v_gudang_product,
      'physical_quantity', 5, 'expected_revision', 1, 'barcode_id', null));
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_kasir_denied := true;
  END;
  IF NOT v_kasir_denied THEN RAISE EXCEPTION 'KASIR unexpectedly issued a RECORD_COUNT intent'; END IF;
  RAISE NOTICE 'PASS: GUDANG allowed; KASIR denied';

  -- A stale client revision returns a terminal result without changing item,
  -- revision, or successful count-event history. A fresh revision can proceed.
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  SELECT count(*) INTO v_event_count FROM public.stock_opname_count_events e
  JOIN public.stock_opname_items i ON i.id = e.item_id
  WHERE i.session_id = v_session AND i.product_id = v_item_product;
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_session, 'product_id', v_item_product,
    'physical_quantity', 8, 'expected_revision', 0, 'barcode_id', null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'code' IS DISTINCT FROM 'STALE_BASELINE'
     OR v_result->>'reason' IS DISTINCT FROM 'ITEM_REVISION_MISMATCH'
     OR v_result->>'expectedRevision' IS DISTINCT FROM '0' OR v_result->>'currentRevision' IS DISTINCT FROM '1'
     OR (SELECT i.physical_quantity FROM public.stock_opname_items i WHERE i.session_id = v_session AND i.product_id = v_item_product) IS DISTINCT FROM 0
     OR (SELECT i.revision_no FROM public.stock_opname_items i WHERE i.session_id = v_session AND i.product_id = v_item_product) IS DISTINCT FROM 1
     OR (SELECT count(*) FROM public.stock_opname_count_events e JOIN public.stock_opname_items i ON i.id = e.item_id
         WHERE i.session_id = v_session AND i.product_id = v_item_product) IS DISTINCT FROM v_event_count THEN
    RAISE EXCEPTION 'Stale client revision mutated the count item or successful count history';
  END IF;
  v_replay := public.apply_stock_operation_intent(v_request);
  IF v_replay IS DISTINCT FROM v_result THEN RAISE EXCEPTION 'Stale exact retry did not replay its terminal result'; END IF;
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_session, 'product_id', v_item_product,
    'physical_quantity', 0.5, 'expected_revision', 1, 'barcode_id', null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'ok' IS DISTINCT FROM 'true' OR v_result->>'revision' IS DISTINCT FROM '2'
     OR (SELECT i.physical_quantity FROM public.stock_opname_items i WHERE i.session_id = v_session AND i.product_id = v_item_product) IS DISTINCT FROM 0.5 THEN
    RAISE EXCEPTION 'Refreshed expected_revision did not permit a new count';
  END IF;
  RAISE NOTICE 'PASS: stale expected_revision rejected without mutation; refreshed revision succeeds';

  SELECT md5(coalesce(string_agg(i.product_id::text || ':' || coalesce(i.quantity::text, '<null>') || ':' ||
      coalesce(i.minimum_quantity::text, '<null>') || ':' || coalesce(i.source_import_row_id::text, '<null>'), E'\n' ORDER BY i.product_id), ''))
  INTO v_inventory_after FROM public.product_inventory i
  WHERE i.outlet_id = v_outlet AND i.product_id IN (v_item_product, v_decimal_product, v_gudang_product);
  SELECT md5(coalesce(string_agg(p.product_id::text || ':' || coalesce(p.effective_quantity::text, '<null>') || ':' ||
      p.balance_version::text || ':' || coalesce(p.unreconciled_movement_delta::text, '<null>'), E'\n' ORDER BY p.product_id), ''))
  INTO v_projection_after FROM public.stock_balance_projection p
  WHERE p.outlet_id = v_outlet AND p.product_id IN (v_item_product, v_decimal_product, v_gudang_product);
  IF v_inventory_after IS DISTINCT FROM v_inventory_fingerprint THEN
    RAISE EXCEPTION 'RECORD_COUNT changed product_inventory';
  END IF;
  IF v_projection_after IS DISTINCT FROM v_projection_fingerprint THEN
    RAISE EXCEPTION 'RECORD_COUNT changed stock projection quantities or versions';
  END IF;
  RAISE NOTICE 'PASS: counts did not change product_inventory or stock projection';

  -- Exercise projection-stale RECORD_COUNT using only existing trusted paths:
  -- post an opname movement, create a new session, then reverse that movement.
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  SELECT p.effective_quantity INTO STRICT v_baseline FROM public.stock_balance_projection p
  WHERE p.product_id = v_baseline_product AND p.outlet_id = v_outlet;
  v_request := public.issue_stock_operation_intent('CREATE_SESSION', jsonb_build_object(
    'outlet_id', v_outlet, 'scope_type', 'PARTIAL',
    'product_ids', jsonb_build_array(v_baseline_product), 'note', 'RECORD_COUNT baseline setup'));
  v_setup_session := (public.apply_stock_operation_intent(v_request)->>'sessionId')::uuid;
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_setup_session, 'product_id', v_baseline_product,
    'physical_quantity', v_baseline + 1, 'expected_revision', 0, 'barcode_id', null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'ok' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Baseline setup count failed'; END IF;
  v_request := public.issue_stock_operation_intent('SUBMIT_REVIEW', jsonb_build_object('session_id', v_setup_session));
  PERFORM public.apply_stock_operation_intent(v_request);
  v_request := public.issue_stock_operation_intent('POST_SESSION', jsonb_build_object('session_id', v_setup_session));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'status' IS DISTINCT FROM 'POSTED' THEN RAISE EXCEPTION 'Trusted baseline setup posting failed'; END IF;
  SELECT m.id INTO STRICT v_movement
  FROM public.stock_movements m JOIN public.stock_opname_items i ON i.id = m.opname_item_id
  WHERE i.session_id = v_setup_session AND m.movement_type = 'OPNAME_ADJUSTMENT';

  v_request := public.issue_stock_operation_intent('CREATE_SESSION', jsonb_build_object(
    'outlet_id', v_outlet, 'scope_type', 'PARTIAL',
    'product_ids', jsonb_build_array(v_baseline_product), 'note', 'RECORD_COUNT baseline stale target'));
  v_stale_session := (public.apply_stock_operation_intent(v_request)->>'sessionId')::uuid;
  v_request := public.issue_stock_operation_intent('REVERSE_MOVEMENT', jsonb_build_object(
    'movement_id', v_movement, 'reason', 'RECORD_COUNT rollback baseline-stale setup'));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'reversesMovementId' IS DISTINCT FROM v_movement::text THEN
    RAISE EXCEPTION 'Trusted reversal setup failed';
  END IF;
  SELECT p.effective_quantity, p.balance_version INTO STRICT v_projection_quantity, v_projection_version
  FROM public.stock_balance_projection p WHERE p.product_id = v_baseline_product AND p.outlet_id = v_outlet;

  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_stale_session, 'product_id', v_baseline_product,
    'physical_quantity', v_projection_quantity, 'expected_revision', 0, 'barcode_id', null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'code' IS DISTINCT FROM 'STALE_BASELINE'
     OR v_result->>'reason' IS DISTINCT FROM 'PROJECTION_BASELINE_CHANGED'
     OR NOT (SELECT i.requires_recount FROM public.stock_opname_items i WHERE i.session_id = v_stale_session AND i.product_id = v_baseline_product)
     OR (SELECT i.physical_quantity FROM public.stock_opname_items i WHERE i.session_id = v_stale_session AND i.product_id = v_baseline_product) IS NOT NULL
     OR (SELECT p.balance_version FROM public.stock_balance_projection p WHERE p.product_id = v_baseline_product AND p.outlet_id = v_outlet) IS DISTINCT FROM v_projection_version
     OR (SELECT p.effective_quantity FROM public.stock_balance_projection p WHERE p.product_id = v_baseline_product AND p.outlet_id = v_outlet) IS DISTINCT FROM v_projection_quantity THEN
    RAISE EXCEPTION 'Projection-stale RECORD_COUNT was not safely rejected without projection mutation';
  END IF;
  SELECT count(*) INTO v_event_count FROM public.stock_opname_count_events e
  JOIN public.stock_opname_items i ON i.id = e.item_id
  WHERE i.session_id = v_stale_session AND e.request_id = v_request AND e.event_type = 'STALE_BASELINE';
  v_replay := public.apply_stock_operation_intent(v_request);
  IF v_replay IS DISTINCT FROM v_result
     OR (SELECT count(*) FROM public.stock_opname_count_events e JOIN public.stock_opname_items i ON i.id = e.item_id
         WHERE i.session_id = v_stale_session AND e.request_id = v_request AND e.event_type = 'STALE_BASELINE') IS DISTINCT FROM v_event_count
     OR v_event_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Projection-stale exact retry appended another event';
  END IF;
  RAISE NOTICE 'PASS: projection baseline stale result is distinct, terminal, and does not change effective stock';
END;
$count_runtime$;

ROLLBACK;
\echo 'PASS: RECORD_COUNT matrix completed; transaction rolled back.'
