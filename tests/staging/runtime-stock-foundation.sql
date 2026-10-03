-- Synthetic runtime contract checks. All mutation assertions run in one
-- transaction and are rolled back at the end. Run only through the guarded
-- run-stock-runtime-matrix.sh entry point against local quena_stock_staging.
\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database() <> 'quena_stock_staging'
     OR coalesce(host(inet_server_addr()), '') NOT IN ('127.0.0.1', '::1')
     OR inet_server_port() <> 5432
     OR current_setting('server_version_num')::integer / 10000 <> 15 THEN
    RAISE EXCEPTION 'Refusing runtime matrix outside local PostgreSQL 15 quena_stock_staging';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929180000') THEN
    RAISE EXCEPTION 'Stock foundation migration is not recorded as applied';
  END IF;
END;
$guard$;

BEGIN;

-- Exercise caller grants and role decisions under the authenticated database role.
SET LOCAL ROLE authenticated;
DO $authenticated_role_tests$
DECLARE
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_gudang uuid := 'a0000000-0000-4000-8000-000000000003';
  v_kasir uuid := 'a0000000-0000-4000-8000-000000000004';
  v_outlet uuid;
  v_product uuid;
  v_request uuid;
  v_request_again uuid;
  v_result jsonb;
  v_session uuid;
  v_count integer;
  v_rejected boolean;
  v_resolution text;
  v_resolved_product uuid;
BEGIN
  -- Establish the OWNER JWT before any SELECT protected by authenticated RLS.
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  SELECT id INTO STRICT v_outlet FROM public.outlets WHERE code = 'QUENA-MART-1';
  SELECT id INTO STRICT v_product FROM public.products WHERE sku = 'STG-BASE20';

  SELECT r.resolution, r.product_id INTO v_resolution, v_resolved_product
  FROM public.resolve_stock_barcode(v_outlet, '000000000020') r;
  IF v_resolution <> 'BARCODE_MATCH' OR v_resolved_product <> v_product THEN
    RAISE EXCEPTION 'Leading-zero barcode did not resolve exactly';
  END IF;
  SELECT r.resolution, r.product_id INTO v_resolution, v_resolved_product
  FROM public.resolve_stock_barcode(v_outlet, 'STG-BASE20-ALIAS-A') r;
  IF v_resolution <> 'BARCODE_MATCH' OR v_resolved_product <> v_product THEN
    RAISE EXCEPTION 'Same-product alias was treated as ambiguous';
  END IF;
  SELECT r.resolution, r.product_id INTO v_resolution, v_resolved_product
  FROM public.resolve_stock_barcode(v_outlet, 'STG-DUP-AMBIG') r;
  IF v_resolution <> 'BARCODE_AMBIGUOUS' OR v_resolved_product IS NOT NULL THEN
    RAISE EXCEPTION 'Cross-product barcode ambiguity was not returned safely';
  END IF;
  SELECT r.resolution INTO v_resolution
  FROM public.resolve_stock_barcode(v_outlet, 'STG-NOT-REGISTERED') r;
  IF v_resolution <> 'BARCODE_NOT_FOUND' THEN RAISE EXCEPTION 'Unknown barcode result is wrong'; END IF;
  SELECT r.resolution INTO v_resolution
  FROM public.resolve_stock_barcode(v_outlet, 'STG' || chr(1) || 'CONTROL') r;
  IF v_resolution <> 'BARCODE_NOT_FOUND' THEN RAISE EXCEPTION 'Control-character barcode was not rejected'; END IF;
  RAISE NOTICE 'PASS: barcode 0/1/many, aliases, leading zeros, and controls';

  -- Repeated intent issuance for the same pending semantic operation returns one ID.
  v_request := public.issue_stock_operation_intent('CREATE_SESSION',
    jsonb_build_object('outlet_id', v_outlet, 'scope_type', 'PARTIAL',
      'product_ids', jsonb_build_array(v_product), 'note', 'runtime happy path'));
  v_request_again := public.issue_stock_operation_intent('CREATE_SESSION',
    jsonb_build_object('outlet_id', v_outlet, 'scope_type', 'PARTIAL',
      'product_ids', jsonb_build_array(v_product), 'note', 'runtime happy path'));
  IF v_request <> v_request_again THEN RAISE EXCEPTION 'Identical pending intents were not reused'; END IF;
  v_result := public.apply_stock_operation_intent(v_request);
  v_session := (v_result->>'sessionId')::uuid;

  -- RECORD_COUNT binds the item revision observed by the caller.
  v_rejected := false;
  BEGIN
    PERFORM public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
      'session_id', v_session, 'product_id', v_product, 'physical_quantity', 3, 'barcode_id', null));
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'RECORD_COUNT accepted a missing expected_revision'; END IF;
  v_rejected := false;
  BEGIN
    PERFORM public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
      'session_id', v_session, 'product_id', v_product, 'physical_quantity', 3,
      'expected_revision', 0.5, 'barcode_id', null));
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'RECORD_COUNT accepted a fractional expected_revision'; END IF;

  -- Physical zero is recorded at revision 0. A second logical client with the
  -- same observed revision is rejected after the first advances the item.
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_session, 'product_id', v_product, 'physical_quantity', 0, 'expected_revision', 0,
    'barcode_id', null));
  PERFORM public.apply_stock_operation_intent(v_request);
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_session, 'product_id', v_product, 'physical_quantity', 99, 'expected_revision', 0,
    'barcode_id', null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'code' <> 'STALE_BASELINE'
     OR v_result->>'reason' <> 'ITEM_REVISION_MISMATCH'
     OR v_result->>'expectedRevision' <> '0' OR v_result->>'currentRevision' <> '1'
     OR (SELECT physical_quantity FROM public.stock_opname_items WHERE session_id = v_session AND product_id = v_product) <> 0
     OR (SELECT revision_no FROM public.stock_opname_items WHERE session_id = v_session AND product_id = v_product) <> 1
     OR EXISTS (SELECT 1 FROM public.stock_opname_count_events WHERE request_id = v_request) THEN
    RAISE EXCEPTION 'Stale client revision overwrote or mutated the current count';
  END IF;
  IF public.apply_stock_operation_intent(v_request) IS DISTINCT FROM v_result
     OR (SELECT physical_quantity FROM public.stock_opname_items WHERE session_id = v_session AND product_id = v_product) <> 0 THEN
    RAISE EXCEPTION 'Exact stale client-revision retry was not idempotent';
  END IF;

  -- Refresh to the currently observed revision and record the valid recount.
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_session, 'product_id', v_product, 'physical_quantity', 17, 'expected_revision', 1,
    'barcode_id', null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'variance' <> '-3' OR v_result->>'revision' <> '2' THEN
    RAISE EXCEPTION 'Recount variance/revision is incorrect';
  END IF;
  SELECT count(*) INTO v_count
  FROM public.stock_opname_count_events e
  JOIN public.stock_opname_items i ON i.id = e.item_id
  WHERE i.session_id = v_session AND e.revision_no IN (1, 2)
    AND ((e.revision_no = 1 AND e.physical_quantity = 0)
      OR (e.revision_no = 2 AND e.physical_quantity = 17));
  IF v_count <> 2 THEN RAISE EXCEPTION 'Zero/recount event history is missing'; END IF;

  v_request := public.issue_stock_operation_intent('SUBMIT_REVIEW', jsonb_build_object('session_id', v_session));
  PERFORM public.apply_stock_operation_intent(v_request);
  v_request := public.issue_stock_operation_intent('POST_SESSION', jsonb_build_object('session_id', v_session));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'status' <> 'POSTED' OR v_result->>'movementCount' <> '1' THEN
    RAISE EXCEPTION 'Opname posting did not post exactly one adjustment';
  END IF;
  IF (SELECT quantity FROM public.product_inventory WHERE product_id = v_product AND outlet_id = v_outlet) <> 20
     OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id = v_product AND outlet_id = v_outlet) <> 17 THEN
    RAISE EXCEPTION 'Opname changed iPos snapshot or failed to update effective projection';
  END IF;
  IF (SELECT count(*) FROM public.stock_movements WHERE opname_item_id IN
      (SELECT id FROM public.stock_opname_items WHERE session_id = v_session)
      AND movement_type = 'OPNAME_ADJUSTMENT') <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one OPNAME_ADJUSTMENT movement';
  END IF;
  IF public.apply_stock_operation_intent(v_request) IS DISTINCT FROM v_result THEN
    RAISE EXCEPTION 'Completed post retry did not replay the original result';
  END IF;
  IF (SELECT count(*) FROM public.stock_movements WHERE opname_item_id IN
      (SELECT id FROM public.stock_opname_items WHERE session_id = v_session)
      AND movement_type = 'OPNAME_ADJUSTMENT') <> 1 THEN
    RAISE EXCEPTION 'Posting retry duplicated a movement';
  END IF;
  RAISE NOTICE 'PASS: count/recount, variance, immutable posting, snapshot separation, exact retry';

  -- GUDANG can count/review, but cannot post or read costs.
  PERFORM set_config('request.jwt.claim.sub', v_gudang::text, true);
  SELECT count(*) INTO v_count FROM public.product_costs WHERE product_id = v_product;
  IF v_count <> 0 THEN RAISE EXCEPTION 'GUDANG can read product costs'; END IF;
  v_request := public.issue_stock_operation_intent('CREATE_SESSION', jsonb_build_object(
    'outlet_id', v_outlet, 'scope_type', 'PARTIAL',
    'product_ids', jsonb_build_array((SELECT id FROM public.products WHERE sku = 'STG-STALE')),
    'note', 'Gudang runtime'));
  v_session := (public.apply_stock_operation_intent(v_request)->>'sessionId')::uuid;
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_session, 'product_id', (SELECT id FROM public.products WHERE sku = 'STG-STALE'),
    'physical_quantity', 0, 'expected_revision', 0, 'barcode_id', null));
  PERFORM public.apply_stock_operation_intent(v_request);
  v_request := public.issue_stock_operation_intent('SUBMIT_REVIEW', jsonb_build_object('session_id', v_session));
  PERFORM public.apply_stock_operation_intent(v_request);
  BEGIN
    PERFORM public.issue_stock_operation_intent('POST_SESSION', jsonb_build_object('session_id', v_session));
    RAISE EXCEPTION 'GUDANG unexpectedly issued a post intent';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  v_request := public.issue_stock_operation_intent('CANCEL_SESSION', jsonb_build_object('session_id', v_session));
  PERFORM public.apply_stock_operation_intent(v_request);

  PERFORM set_config('request.jwt.claim.sub', v_kasir::text, true);
  SELECT count(*) INTO v_count FROM public.stock_balance_projection;
  IF v_count <> 0 THEN RAISE EXCEPTION 'KASIR can read the Stock projection'; END IF;
  BEGIN
    PERFORM public.issue_stock_operation_intent('CREATE_SESSION', jsonb_build_object(
      'outlet_id', v_outlet, 'scope_type', 'PARTIAL', 'product_ids', jsonb_build_array(v_product)));
    RAISE EXCEPTION 'KASIR unexpectedly issued a stock intent';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  IF has_function_privilege('anon', 'public.issue_stock_operation_intent(text,jsonb)', 'EXECUTE')
     OR has_function_privilege('service_role', 'public.apply_stock_operation_intent(uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.stock_apply_balance_delta(uuid,uuid,numeric)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Unexpected anonymous/service/private-helper execution grant';
  END IF;
  IF has_table_privilege('authenticated', 'public.stock_movements', 'INSERT')
     OR has_table_privilege('authenticated', 'public.stock_movements', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.stock_movements', 'DELETE') THEN
    RAISE EXCEPTION 'Authenticated direct stock-movement DML is granted';
  END IF;
  RAISE NOTICE 'PASS: GUDANG/KASIR restrictions, HPP isolation, private helpers, direct DML';
END;
$authenticated_role_tests$;
RESET ROLE;

-- Owner-only primitives are exercised as the local staging superuser while
-- retaining actor claims. They are not granted to authenticated callers.
DO $owner_and_integrity_tests$
DECLARE
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_outlet uuid;
  v_product uuid;
  v_source uuid;
  v_before numeric;
  v_after numeric;
  v_result jsonb;
  v_request uuid;
  v_session uuid;
  v_item uuid;
  v_movement uuid;
  v_reversal uuid;
  v_count integer;
  v_stale_revision integer;
  v_second_stale_revision integer;
  v_replay_result jsonb;
  v_blocked boolean;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  SELECT id INTO STRICT v_outlet FROM public.outlets WHERE code = 'QUENA-MART-1';
  SELECT p.id, i.source_import_row_id INTO STRICT v_product, v_source
  FROM public.products p JOIN public.product_inventory i ON i.product_id = p.id
  WHERE p.sku = 'STG-BASE20' AND i.outlet_id = v_outlet;

  SELECT effective_quantity INTO v_before FROM public.stock_balance_projection
  WHERE product_id = v_product AND outlet_id = v_outlet;
  v_blocked := false;
  BEGIN
    PERFORM public.stock_apply_balance_delta(v_product, v_outlet, -21);
  EXCEPTION WHEN OTHERS THEN v_blocked := true;
  END;
  SELECT effective_quantity INTO v_after FROM public.stock_balance_projection
  WHERE product_id = v_product AND outlet_id = v_outlet;
  IF NOT v_blocked OR v_before <> v_after THEN
    RAISE EXCEPTION 'Negative effective balance was not rejected atomically';
  END IF;

  -- An inventory source-pointer update can record an observation, but cannot
  -- replace the accepted bootstrap baseline or the movement overlay.
  UPDATE public.product_inventory
  SET source_import_row_id = source_import_row_id
  WHERE product_id = v_product AND outlet_id = v_outlet;
  IF (SELECT baseline_quantity FROM public.stock_balance_projection WHERE product_id = v_product AND outlet_id = v_outlet) <> 20
     OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id = v_product AND outlet_id = v_outlet) <> 17
     OR (SELECT last_observation_status FROM public.stock_balance_projection WHERE product_id = v_product AND outlet_id = v_outlet) <> 'SOURCE_CHRONOLOGY_UNVERIFIED' THEN
    RAISE EXCEPTION 'iPos observation changed accepted stock baseline/overlay';
  END IF;

  SELECT m.id INTO STRICT v_movement
  FROM public.stock_movements m
  JOIN public.stock_opname_items i ON i.id = m.opname_item_id
  JOIN public.stock_opname_sessions s ON s.id = i.session_id
  JOIN public.products p ON p.id = m.product_id
  WHERE p.sku = 'STG-BASE20' AND s.status = 'POSTED'
    AND m.movement_type = 'OPNAME_ADJUSTMENT';
  v_request := public.issue_stock_operation_intent('REVERSE_MOVEMENT',
    jsonb_build_object('movement_id', v_movement, 'reason', 'Runtime test reversal'));
  v_result := public.apply_stock_operation_intent(v_request);
  v_reversal := (SELECT id FROM public.stock_movements WHERE reverses_movement_id = v_movement);
  IF (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id = v_product AND outlet_id = v_outlet) <> 20
     OR (SELECT quantity_delta FROM public.stock_movements WHERE id = v_reversal) <> 3 THEN
    RAISE EXCEPTION 'Reversal did not exactly restore effective quantity';
  END IF;

  v_request := public.issue_stock_operation_intent('RECONCILE_MOVEMENT', jsonb_build_object(
    'movement_id', v_movement, 'source_import_row_id', v_source, 'reason', 'Explicit staging reconciliation'));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'movementCount' <> '2'
     OR (SELECT count(*) FROM public.stock_movement_source_reconciliations WHERE reconciliation_group_id = v_movement) <> 2
     OR (SELECT effective_quantity FROM public.stock_balance_projection WHERE product_id = v_product AND outlet_id = v_outlet) <> 20 THEN
    RAISE EXCEPTION 'Original/reversal pair was not reconciled atomically by net delta';
  END IF;
  IF public.apply_stock_operation_intent(v_request) IS DISTINCT FROM v_result THEN
    RAISE EXCEPTION 'Reconciliation retry did not replay';
  END IF;
  v_blocked := false;
  BEGIN
    PERFORM public.issue_stock_operation_intent('REVERSE_MOVEMENT',
      jsonb_build_object('movement_id', v_movement, 'reason', 'Must reject reconciled movement'));
    RAISE EXCEPTION 'Reconciled movement unexpectedly accepted reversal intent';
  EXCEPTION WHEN OTHERS THEN v_blocked := true;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'Reconciled movement reversal was not blocked'; END IF;
  RAISE NOTICE 'PASS: negative stock rejection, observation-only import, reversal group reconciliation';

  -- Stale count is recorded at a new revision, does not post, and requires rebase/recount.
  v_product := (SELECT id FROM public.products WHERE sku = 'STG-STALE');
  v_request := public.issue_stock_operation_intent('CREATE_SESSION', jsonb_build_object(
    'outlet_id', v_outlet, 'scope_type', 'PARTIAL', 'product_ids', jsonb_build_array(v_product), 'note', 'Stale baseline test'));
  v_session := (public.apply_stock_operation_intent(v_request)->>'sessionId')::uuid;
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_session, 'product_id', v_product, 'physical_quantity', 9, 'expected_revision', 0, 'barcode_id', null));
  PERFORM public.apply_stock_operation_intent(v_request);
  PERFORM public.stock_apply_balance_delta(v_product, v_outlet, 1);
  v_request := public.issue_stock_operation_intent('SUBMIT_REVIEW', jsonb_build_object('session_id', v_session));
  PERFORM public.apply_stock_operation_intent(v_request);
  v_request := public.issue_stock_operation_intent('POST_SESSION', jsonb_build_object('session_id', v_session));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'code' <> 'STALE_BASELINE'
     OR (SELECT status FROM public.stock_opname_sessions WHERE id = v_session) <> 'COUNTING'
     OR NOT (SELECT requires_recount FROM public.stock_opname_items WHERE session_id = v_session AND product_id = v_product) THEN
    RAISE EXCEPTION 'Stale posting did not require recount';
  END IF;
  IF EXISTS (SELECT 1 FROM public.stock_movements WHERE source_event_key like v_session::text || ':%') THEN
    RAISE EXCEPTION 'Stale posting partially created an opname movement';
  END IF;
  SELECT id INTO STRICT v_item FROM public.stock_opname_items WHERE session_id = v_session AND product_id = v_product;
  SELECT max(revision_no) INTO v_stale_revision FROM public.stock_opname_count_events
  WHERE item_id = v_item AND event_type = 'STALE_BASELINE';
  IF v_stale_revision IS NULL
     OR (SELECT revision_no FROM public.stock_opname_items WHERE id = v_item) <> v_stale_revision THEN
    RAISE EXCEPTION 'Stale posting did not reserve its event revision on the item';
  END IF;
  v_replay_result := public.apply_stock_operation_intent(v_request);
  IF v_replay_result IS DISTINCT FROM v_result
     OR (SELECT count(*) FROM public.stock_opname_count_events
         WHERE item_id = v_item AND event_type = 'STALE_BASELINE') <> 1 THEN
    RAISE EXCEPTION 'Retrying the same stale post changed its result or consumed another revision';
  END IF;

  -- Two distinct stale count requests serialize on the item and each consume
  -- one revision. Replaying either request must not consume another revision.
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_session, 'product_id', v_product, 'physical_quantity', 8,
    'expected_revision', (SELECT revision_no FROM public.stock_opname_items WHERE session_id = v_session AND product_id = v_product),
    'barcode_id', null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'code' <> 'STALE_BASELINE' OR v_result->>'reason' <> 'PROJECTION_BASELINE_CHANGED' THEN
    RAISE EXCEPTION 'Stale projection baseline was not distinguished and rejected';
  END IF;
  SELECT revision_no INTO STRICT v_stale_revision FROM public.stock_opname_count_events
  WHERE request_id = v_request AND event_type = 'STALE_BASELINE';
  IF public.apply_stock_operation_intent(v_request) IS DISTINCT FROM v_result
     OR (SELECT count(*) FROM public.stock_opname_count_events WHERE request_id = v_request) <> 1 THEN
    RAISE EXCEPTION 'Exact stale-count retry consumed another revision or event';
  END IF;
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_session, 'product_id', v_product, 'physical_quantity', 7,
    'expected_revision', (SELECT revision_no FROM public.stock_opname_items WHERE session_id = v_session AND product_id = v_product),
    'barcode_id', null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'code' <> 'STALE_BASELINE' THEN RAISE EXCEPTION 'Second stale count was not rejected'; END IF;
  SELECT revision_no INTO STRICT v_second_stale_revision FROM public.stock_opname_count_events
  WHERE request_id = v_request AND event_type = 'STALE_BASELINE';
  IF v_second_stale_revision <= v_stale_revision THEN
    RAISE EXCEPTION 'Distinct stale count requests reused or reordered an item revision';
  END IF;
  IF (SELECT count(DISTINCT revision_no) FROM public.stock_opname_count_events WHERE item_id = v_item)
     <> (SELECT count(*) FROM public.stock_opname_count_events WHERE item_id = v_item) THEN
    RAISE EXCEPTION 'Count-event revisions are not unique for the item';
  END IF;
  v_request := public.issue_stock_operation_intent('REBASE_ITEM', jsonb_build_object(
    'session_id', v_session, 'product_id', v_product,
    'expected_revision', (SELECT revision_no FROM public.stock_opname_items WHERE session_id = v_session AND product_id = v_product)));
  PERFORM public.apply_stock_operation_intent(v_request);
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_session, 'product_id', v_product, 'physical_quantity', 11,
    'expected_revision', (SELECT revision_no FROM public.stock_opname_items WHERE session_id = v_session AND product_id = v_product),
    'barcode_id', null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'revision' IS NULL OR (v_result->>'revision')::integer <= v_second_stale_revision THEN
    RAISE EXCEPTION 'Next valid recount did not advance beyond both stale revisions';
  END IF;
  v_request := public.issue_stock_operation_intent('SUBMIT_REVIEW', jsonb_build_object('session_id', v_session));
  PERFORM public.apply_stock_operation_intent(v_request);
  v_request := public.issue_stock_operation_intent('POST_SESSION', jsonb_build_object('session_id', v_session));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'status' <> 'POSTED' THEN RAISE EXCEPTION 'Recounted session did not post'; END IF;
  RAISE NOTICE 'PASS: stale baseline blocks posting until rebase/recount';

  -- FULL scope is captured at creation; all existing projection products are items.
  v_request := public.issue_stock_operation_intent('CREATE_SESSION', jsonb_build_object(
    'outlet_id', v_outlet, 'scope_type', 'FULL', 'product_ids', '[]'::jsonb, 'note', 'Full snapshot test'));
  v_session := (public.apply_stock_operation_intent(v_request)->>'sessionId')::uuid;
  IF (SELECT count(*) FROM public.stock_opname_items WHERE session_id = v_session)
     <> (SELECT count(*) FROM public.stock_balance_projection WHERE outlet_id = v_outlet) THEN
    RAISE EXCEPTION 'FULL session did not materialize current projection scope';
  END IF;
  v_blocked := false;
  BEGIN
    v_request := public.issue_stock_operation_intent('SUBMIT_REVIEW', jsonb_build_object('session_id', v_session));
    PERFORM public.apply_stock_operation_intent(v_request);
  EXCEPTION WHEN OTHERS THEN v_blocked := true;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FULL session submitted with uncounted items'; END IF;
  v_request := public.issue_stock_operation_intent('CANCEL_SESSION', jsonb_build_object('session_id', v_session));
  PERFORM public.apply_stock_operation_intent(v_request);

  -- Trigger/row immutability is tested as database owner; failures are isolated in subtransactions.
  v_blocked := false;
  BEGIN
    UPDATE public.stock_movements SET quantity_delta = quantity_delta WHERE id = v_movement;
  EXCEPTION WHEN OTHERS THEN v_blocked := true;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'Posted movement UPDATE was not rejected'; END IF;
  v_blocked := false;
  BEGIN
    DELETE FROM public.stock_movement_source_reconciliations WHERE movement_id = v_movement;
  EXCEPTION WHEN OTHERS THEN v_blocked := true;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'Reconciliation DELETE was not rejected'; END IF;

  UPDATE public.stock_authority_periods
  SET mode = 'QUENA_MOVEMENT_LEDGER'::public.stock_authority_mode
  WHERE outlet_id = v_outlet AND ended_at IS NULL;
  UPDATE public.product_inventory SET source_import_row_id = source_import_row_id
  WHERE product_id = (SELECT id FROM public.products WHERE sku = 'STG-BASE20') AND outlet_id = v_outlet;
  IF (SELECT last_observation_status FROM public.stock_balance_projection WHERE product_id = (SELECT id FROM public.products WHERE sku = 'STG-BASE20') AND outlet_id = v_outlet)
       <> 'QUENA_AUTHORITY_OBSERVATION'
     OR (SELECT baseline_quantity FROM public.stock_balance_projection WHERE product_id = (SELECT id FROM public.products WHERE sku = 'STG-BASE20') AND outlet_id = v_outlet) <> 20 THEN
    RAISE EXCEPTION 'iPos observation altered QUENA_MOVEMENT_LEDGER baseline';
  END IF;
  RAISE NOTICE 'PASS: FULL scope, immutable history, QUENA authority observation-only behavior';
END;
$owner_and_integrity_tests$;

ROLLBACK;
\echo 'PASS: all runtime assertions completed; test transaction rolled back.'
