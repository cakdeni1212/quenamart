-- Local-only POST_SESSION matrix. Mutations use existing operation intents and
-- apply RPCs under authenticated synthetic actors; the outer transaction rolls back.
\set ON_ERROR_STOP on
\timing on

DO $guard$
BEGIN
  IF current_database() <> 'quena_stock_staging'
     OR coalesce(host(inet_server_addr()), '') NOT IN ('127.0.0.1', '::1')
     OR inet_server_port() <> 5432
     OR current_setting('server_version_num')::integer / 10000 <> 15
     OR current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'Refusing POST_SESSION runtime checks outside local UTF8 PostgreSQL 15 quena_stock_staging';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929180000')
     OR NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929190000')
     OR NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929200000') THEN
    RAISE EXCEPTION 'Required local stock migrations 180000, 190000, and 200000 are not ledgered';
  END IF;
END;
$guard$;

-- Read-only check of the effective local function bodies. The matrix must not
-- exercise an installation whose stock-role guards differ from the reviewed
-- migration contract.
DO $function_guard$
DECLARE
  v_issue text;
  v_apply text;
  v_issue_access_pos integer;
  v_issue_gudang_pos integer;
  v_issue_insert_pos integer;
  v_apply_access_pos integer;
  v_apply_actor_pos integer;
  v_apply_gudang_pos integer;
  v_apply_post_branch_pos integer;
  v_apply_reconcile_branch_pos integer;
  v_apply_owner_admin_pos integer;
BEGIN
  IF pg_catalog.to_regprocedure('public.issue_stock_operation_intent(text,jsonb)') IS NULL
     OR pg_catalog.to_regprocedure('public.apply_stock_operation_intent(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FUNCTION_DEFINITION_MISMATCH: expected issue/apply signatures are missing';
  END IF;

  SELECT lower(regexp_replace(p.prosrc, '[[:space:]]+', ' ', 'g')) INTO STRICT v_issue
    FROM pg_catalog.pg_proc p
    WHERE p.oid = pg_catalog.to_regprocedure('public.issue_stock_operation_intent(text,jsonb)');
  SELECT lower(regexp_replace(p.prosrc, '[[:space:]]+', ' ', 'g')) INTO STRICT v_apply
    FROM pg_catalog.pg_proc p
    WHERE p.oid = pg_catalog.to_regprocedure('public.apply_stock_operation_intent(uuid)');

  v_issue_access_pos := position('v_role is null or v_role = ''kasir''::public.user_role' in v_issue);
  v_issue_gudang_pos := position('p_operation_key = ''post_session'' and v_role = ''gudang''::public.user_role' in v_issue);
  v_issue_insert_pos := position('insert into public.stock_operation_requests' in v_issue);
  IF v_issue_access_pos = 0 OR v_issue_gudang_pos = 0 OR v_issue_insert_pos = 0
     OR v_issue_access_pos > v_issue_insert_pos OR v_issue_gudang_pos > v_issue_insert_pos THEN
    RAISE EXCEPTION 'FUNCTION_DEFINITION_MISMATCH: issue role guards are missing or occur after request creation';
  END IF;
  v_apply_access_pos := position('v_role is null or v_role = ''kasir''::public.user_role' in v_apply);
  v_apply_actor_pos := position('r.request_id = p_request_id and r.actor_id = v_actor for update' in v_apply);
  v_apply_gudang_pos := position('v_role = ''gudang''::public.user_role and v_req.operation_key in' in v_apply);
  v_apply_post_branch_pos := position('elsif v_req.operation_key = ''post_session'' then' in v_apply);
  v_apply_reconcile_branch_pos := position('elsif v_req.operation_key = ''reconcile_movement'' then' in v_apply);
  v_apply_owner_admin_pos := position('v_role not in (''owner''::public.user_role, ''admin''::public.user_role)' in v_apply);
  IF v_apply_access_pos = 0 OR v_apply_actor_pos = 0 OR v_apply_gudang_pos = 0
     OR v_apply_post_branch_pos = 0 OR v_apply_reconcile_branch_pos = 0
     OR v_apply_owner_admin_pos = 0 OR v_apply_access_pos > v_apply_actor_pos
     OR v_apply_actor_pos > v_apply_gudang_pos
     OR v_apply_post_branch_pos > v_apply_owner_admin_pos
     OR v_apply_owner_admin_pos > v_apply_reconcile_branch_pos THEN
    RAISE EXCEPTION 'FUNCTION_DEFINITION_MISMATCH: apply access, actor-binding, or OWNER/ADMIN post guard is missing';
  END IF;
  IF position('''post_session''' in substring(v_apply from v_apply_gudang_pos for 300)) = 0 THEN
    RAISE EXCEPTION 'FUNCTION_DEFINITION_MISMATCH: apply GUDANG denial does not cover POST_SESSION';
  END IF;
END;
$function_guard$;

BEGIN;
SET LOCAL statement_timeout = '90s';
SET LOCAL lock_timeout = '8s';
SET LOCAL ROLE authenticated;

DO $matrix$
DECLARE
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_admin uuid := 'a0000000-0000-4000-8000-000000000002';
  v_gudang uuid := 'a0000000-0000-4000-8000-000000000003';
  v_kasir uuid := 'a0000000-0000-4000-8000-000000000004';
  v_outlet uuid;
  v_a uuid; v_b uuid; v_c uuid; v_d uuid; v_e uuid;
  v_session uuid; v_admin_session uuid; v_changed_session uuid; v_stale_session uuid;
  v_failed_session uuid;
  v_request uuid; v_retry uuid; v_other_request uuid; v_original_movement uuid;
  v_result jsonb; v_replay jsonb; v_count_result jsonb;
  v_item record;
  v_revision integer;
  v_base numeric;
  v_before_a numeric; v_before_b numeric;
  v_version_a bigint; v_version_b bigint;
  v_moves_before bigint; v_batches_before bigint; v_count bigint;
  v_denied boolean;
  v_issue_sqlstate text;
  v_denied_request uuid;
  v_session_count bigint;
  v_guard_session_status text;
  v_guard_batch_count bigint;
  v_guard_movement_count bigint;
  v_guard_balance_event_count bigint;
  v_guard_projection jsonb;
  v_batch_id uuid;
  v_replay_batch_count_before bigint; v_replay_batch_count_after bigint;
  v_replay_movement_count_before bigint; v_replay_movement_count_after bigint;
  v_replay_balance_event_count_before bigint; v_replay_balance_event_count_after bigint;
  v_replay_posted_event_count_before bigint; v_replay_posted_event_count_after bigint;
  v_replay_projection_before jsonb; v_replay_projection_after jsonb;
  v_expected_metadata jsonb; v_actual_metadata jsonb;
  v_replay_metadata_before jsonb; v_replay_metadata_after jsonb;
  v_outlet_name_before text;
  v_replay_session_status_before text; v_replay_session_status_after text;
  v_inventory_before text; v_inventory_after text;
  v_exception_item uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  IF auth.uid() IS DISTINCT FROM v_owner THEN
    RAISE EXCEPTION 'IDENTITY_MISMATCH expected_actor=% actual_actor=%', v_owner, auth.uid();
  END IF;
  IF public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION 'ROLE_MISMATCH expected_role=OWNER actual_role=%', public.current_active_user_role();
  END IF;
  SELECT o.id INTO STRICT v_outlet FROM public.outlets o WHERE o.code = 'QUENA-MART-1' AND o.is_active;
  SELECT id INTO STRICT v_a FROM public.products WHERE sku = 'STG-FULL-A';
  SELECT id INTO STRICT v_b FROM public.products WHERE sku = 'STG-FULL-B';
  SELECT id INTO STRICT v_c FROM public.products WHERE sku = 'STG-STALE';
  SELECT id INTO STRICT v_d FROM public.products WHERE sku = 'STG-RECON';
  SELECT id INTO STRICT v_e FROM public.products WHERE sku = 'STG-BASE20';
  IF (SELECT count(*) FROM public.stock_balance_projection p
      WHERE p.outlet_id = v_outlet AND p.product_id IN (v_a, v_b, v_c, v_d, v_e)
        AND p.effective_quantity IS NOT NULL AND p.baseline_source_import_row_id IS NOT NULL) <> 5 THEN
    RAISE EXCEPTION 'POST_SESSION fixture products do not have usable stock projections';
  END IF;
  IF EXISTS (SELECT 1 FROM public.stock_opname_items i
      WHERE i.product_id IN (v_a, v_b, v_c, v_d, v_e) AND i.active_scope) THEN
    RAISE EXCEPTION 'POST_SESSION fixture products have active opname coverage; inspect staging before retry';
  END IF;
  SELECT md5(coalesce(string_agg(i.product_id::text || ':' || coalesce(i.quantity::text, '<null>') || ':' ||
      coalesce(i.minimum_quantity::text, '<null>') || ':' || coalesce(i.source_import_row_id::text, '<null>'),
      E'\n' ORDER BY i.product_id), '')) INTO v_inventory_before
    FROM public.product_inventory i WHERE i.outlet_id = v_outlet;

  -- A known rejected POST from COUNTING must not capture posting metadata.
  v_request := public.issue_stock_operation_intent('CREATE_SESSION', jsonb_build_object(
    'outlet_id', v_outlet, 'scope_type', 'PARTIAL', 'product_ids', jsonb_build_array(v_e)));
  v_result := public.apply_stock_operation_intent(v_request);
  v_failed_session := (v_result->>'sessionId')::uuid;
  v_request := public.issue_stock_operation_intent('POST_SESSION', jsonb_build_object('session_id', v_failed_session));
  v_issue_sqlstate := NULL;
  BEGIN
    PERFORM public.apply_stock_operation_intent(v_request);
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_issue_sqlstate := SQLSTATE;
  END;
  IF v_issue_sqlstate IS DISTINCT FROM '22023'
     OR EXISTS (SELECT 1 FROM public.stock_opname_sessions s
        WHERE s.id = v_failed_session AND s.posted_metadata_captured_at IS NOT NULL)
     OR EXISTS (SELECT 1 FROM public.stock_opname_items i
        WHERE i.session_id = v_failed_session AND i.posted_metadata_captured_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Rejected COUNTING post captured result metadata';
  END IF;
  v_request := public.issue_stock_operation_intent('CANCEL_SESSION', jsonb_build_object('session_id', v_failed_session));
  PERFORM public.apply_stock_operation_intent(v_request);

  -- OWNER multi-item post: negative, positive, zero, and reviewed exception.
  v_request := public.issue_stock_operation_intent('CREATE_SESSION', jsonb_build_object(
    'outlet_id', v_outlet, 'scope_type', 'PARTIAL', 'product_ids', jsonb_build_array(v_a, v_b, v_c, v_d)));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'ok' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'OWNER setup session creation failed'; END IF;
  v_session := (v_result->>'sessionId')::uuid;
  SELECT count(*) INTO v_count FROM public.stock_opname_items i WHERE i.session_id = v_session;
  IF v_count <> 4 THEN RAISE EXCEPTION 'OWNER session expected four scoped items, got %', v_count; END IF;

  FOR v_item IN SELECT i.id, i.product_id, i.baseline_quantity, i.revision_no, p.sku
    FROM public.stock_opname_items i JOIN public.products p ON p.id = i.product_id
    WHERE i.session_id = v_session ORDER BY p.sku
  LOOP
    IF v_item.sku = 'STG-RECON' THEN
      v_exception_item := v_item.id;
      v_request := public.issue_stock_operation_intent('REVIEW_EXCEPTION', jsonb_build_object(
        'session_id', v_session, 'product_id', v_item.product_id,
        'expected_revision', v_item.revision_no, 'reason', 'Synthetic item exception'));
    ELSE
      v_base := CASE v_item.sku WHEN 'STG-FULL-A' THEN v_item.baseline_quantity - 2
        WHEN 'STG-FULL-B' THEN v_item.baseline_quantity + 3 ELSE v_item.baseline_quantity END;
      v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
        'session_id', v_session, 'product_id', v_item.product_id,
        'physical_quantity', v_base, 'expected_revision', v_item.revision_no));
    END IF;
    v_count_result := public.apply_stock_operation_intent(v_request);
    IF v_count_result->>'ok' IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'OWNER count/exception setup failed for %: %', v_item.sku, v_count_result;
    END IF;
  END LOOP;
  v_request := public.issue_stock_operation_intent('SUBMIT_REVIEW', jsonb_build_object('session_id', v_session));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'status' IS DISTINCT FROM 'REVIEW' THEN RAISE EXCEPTION 'OWNER session failed to enter REVIEW'; END IF;

  SELECT p.effective_quantity, p.balance_version INTO STRICT v_before_a, v_version_a
    FROM public.stock_balance_projection p WHERE p.product_id = v_a AND p.outlet_id = v_outlet;
  SELECT p.effective_quantity, p.balance_version INTO STRICT v_before_b, v_version_b
    FROM public.stock_balance_projection p WHERE p.product_id = v_b AND p.outlet_id = v_outlet;
  v_request := public.issue_stock_operation_intent('POST_SESSION', jsonb_build_object('session_id', v_session));
  SELECT o.name INTO STRICT v_outlet_name_before FROM public.outlets o WHERE o.id = v_outlet;
  SELECT jsonb_object_agg(i.product_id::text, jsonb_build_object(
      'product_name', p.name, 'sku', p.sku, 'rack', os.rack_label,
      'unit', p.unit_label, 'display_barcode', (
        SELECT b.barcode FROM public.product_barcodes b
        WHERE b.product_id = p.id AND b.is_active ORDER BY b.created_at, b.id LIMIT 1
      ))) INTO v_expected_metadata
    FROM public.stock_opname_items i
    JOIN public.products p ON p.id = i.product_id
    LEFT JOIN public.product_outlet_settings os ON os.product_id = p.id AND os.outlet_id = i.outlet_id
    WHERE i.session_id = v_session;
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'ok' IS DISTINCT FROM 'true' OR v_result->>'status' IS DISTINCT FROM 'POSTED'
     OR (v_result->>'movementCount')::integer <> 2 OR v_result->>'movementBatchId' IS NULL THEN
    RAISE EXCEPTION 'OWNER multi-item POST_SESSION result is incorrect: %', v_result;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.stock_opname_sessions s
      WHERE s.id = v_session AND s.status = 'POSTED' AND s.approved_by = v_owner
        AND s.approved_at IS NOT NULL AND s.posted_at IS NOT NULL) THEN
    RAISE EXCEPTION 'OWNER post did not record POSTED status and actor/timestamps';
  END IF;
  SELECT jsonb_object_agg(i.product_id::text, jsonb_build_object(
      'product_name', i.posted_product_name_snapshot,
      'sku', i.posted_sku_snapshot,
      'rack', i.posted_rack_label_snapshot,
      'unit', i.posted_unit_label_snapshot,
      'display_barcode', i.posted_display_barcode_snapshot))
    INTO v_actual_metadata FROM public.stock_opname_items i WHERE i.session_id = v_session;
  IF v_actual_metadata IS DISTINCT FROM v_expected_metadata
     OR (SELECT s.posted_outlet_name_snapshot FROM public.stock_opname_sessions s WHERE s.id = v_session) IS DISTINCT FROM v_outlet_name_before
     OR (SELECT s.posted_metadata_captured_at FROM public.stock_opname_sessions s WHERE s.id = v_session) IS NULL
     OR (SELECT count(*) FROM public.stock_opname_items i WHERE i.session_id = v_session
         AND i.posted_metadata_captured_at = (SELECT s.posted_metadata_captured_at
           FROM public.stock_opname_sessions s WHERE s.id = v_session)) <> 4 THEN
    RAISE EXCEPTION 'OWNER post did not snapshot outlet and every item at posting: expected %, actual %',
      v_expected_metadata, v_actual_metadata;
  END IF;
  IF (SELECT count(*) FROM public.stock_movement_batches b
      WHERE b.id = (v_result->>'movementBatchId')::uuid AND b.outlet_id = v_outlet
        AND b.source_system = 'STOCK_OPNAME' AND b.created_by = v_owner
        AND b.operation_request_id = v_request) <> 1 THEN
    RAISE EXCEPTION 'OWNER post batch does not match the operation request';
  END IF;
  IF (SELECT count(*) FROM public.stock_movements m
      WHERE m.source_reference = v_session::text AND m.source_system = 'STOCK_OPNAME'
        AND m.movement_type = 'OPNAME_ADJUSTMENT') <> 2 THEN
    RAISE EXCEPTION 'OWNER post did not create exactly two nonzero adjustment rows';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.stock_movements m WHERE m.source_reference = v_session::text
      AND m.product_id = v_a AND m.quantity_delta = -2
      AND m.balance_before = v_before_a AND m.balance_after = v_before_a - 2
      AND m.opname_item_id IS NOT NULL AND m.created_by = v_owner)
     OR NOT EXISTS (SELECT 1 FROM public.stock_movements m WHERE m.source_reference = v_session::text
      AND m.product_id = v_b AND m.quantity_delta = 3
      AND m.balance_before = v_before_b AND m.balance_after = v_before_b + 3
      AND m.opname_item_id IS NOT NULL AND m.created_by = v_owner) THEN
    RAISE EXCEPTION 'OWNER movement signed delta or before/after balance is incorrect';
  END IF;
  IF (SELECT p.effective_quantity FROM public.stock_balance_projection p WHERE p.product_id = v_a AND p.outlet_id = v_outlet) <> v_before_a - 2
     OR (SELECT p.effective_quantity FROM public.stock_balance_projection p WHERE p.product_id = v_b AND p.outlet_id = v_outlet) <> v_before_b + 3
     OR (SELECT p.balance_version FROM public.stock_balance_projection p WHERE p.product_id = v_a AND p.outlet_id = v_outlet) <> v_version_a + 1
     OR (SELECT p.balance_version FROM public.stock_balance_projection p WHERE p.product_id = v_b AND p.outlet_id = v_outlet) <> v_version_b + 1 THEN
    RAISE EXCEPTION 'OWNER post projection quantities or versions are incorrect';
  END IF;
  IF EXISTS (SELECT 1 FROM public.stock_movements m WHERE m.source_reference = v_session::text AND m.product_id = v_c)
     OR (SELECT p.balance_version FROM public.stock_balance_projection p WHERE p.product_id = v_c AND p.outlet_id = v_outlet) <>
        (SELECT i.baseline_balance_version FROM public.stock_opname_items i WHERE i.session_id = v_session AND i.product_id = v_c)
     OR EXISTS (SELECT 1 FROM public.stock_movements m WHERE m.source_reference = v_session::text AND m.product_id = v_d)
     OR NOT EXISTS (SELECT 1 FROM public.stock_opname_items i WHERE i.id = v_exception_item
        AND i.physical_quantity IS NULL AND i.exception_reviewed_at IS NOT NULL AND NOT i.requires_recount) THEN
    RAISE EXCEPTION 'Zero-delta or reviewed-exception item created an adjustment or lost its exception';
  END IF;
  IF (SELECT count(*) FROM public.stock_balance_projection_events e WHERE e.request_id = v_request) <> 2
     OR NOT EXISTS (SELECT 1 FROM public.stock_opname_session_events e
        WHERE e.session_id = v_session AND e.event_type = 'POSTED' AND e.request_id = v_request) THEN
    RAISE EXCEPTION 'Projection/session posting events are incomplete';
  END IF;

  -- Snapshot the complete stock effect before replay so the exact UUID retry
  -- proves it adds no batch, movement, projection event, or session event.
  v_batch_id := (v_result->>'movementBatchId')::uuid;
  SELECT count(*) INTO v_replay_batch_count_before FROM public.stock_movement_batches b
    WHERE b.id = v_batch_id AND b.operation_request_id = v_request
      AND b.outlet_id = v_outlet AND b.source_system = 'STOCK_OPNAME';
  SELECT count(*) INTO v_replay_movement_count_before FROM public.stock_movements m
    WHERE m.batch_id = v_batch_id AND m.source_reference = v_session::text;
  SELECT count(*) INTO v_replay_balance_event_count_before FROM public.stock_balance_projection_events e
    WHERE e.request_id = v_request;
  SELECT jsonb_object_agg(p.product_id::text, jsonb_build_object(
      'quantity', p.effective_quantity, 'balance_version', p.balance_version))
    INTO v_replay_projection_before
    FROM public.stock_balance_projection p
    WHERE p.outlet_id = v_outlet AND p.product_id IN (v_a, v_b, v_c, v_d);
  SELECT s.status::text INTO STRICT v_replay_session_status_before
    FROM public.stock_opname_sessions s WHERE s.id = v_session;
  SELECT count(*) INTO v_replay_posted_event_count_before FROM public.stock_opname_session_events e
    WHERE e.session_id = v_session AND e.event_type = 'POSTED';
  SELECT jsonb_build_object(
      'outlet_name', s.posted_outlet_name_snapshot,
      'outlet_captured_at', s.posted_metadata_captured_at,
      'items', (SELECT jsonb_object_agg(i.product_id::text, jsonb_build_object(
        'product_name', i.posted_product_name_snapshot, 'sku', i.posted_sku_snapshot,
        'rack', i.posted_rack_label_snapshot, 'unit', i.posted_unit_label_snapshot,
        'barcode', i.posted_display_barcode_snapshot, 'captured_at', i.posted_metadata_captured_at))
        FROM public.stock_opname_items i WHERE i.session_id = s.id))
    INTO v_replay_metadata_before FROM public.stock_opname_sessions s WHERE s.id = v_session;
  IF v_replay_batch_count_before <> 1 OR v_replay_movement_count_before <> 2
     OR v_replay_balance_event_count_before <> 2 OR v_replay_posted_event_count_before <> 1 THEN
    RAISE EXCEPTION 'OWNER first post did not establish the expected pre-replay batch/movement/event counts';
  END IF;

  -- Exact retry uses the same completed request UUID; no new intent is issued.
  v_replay := public.apply_stock_operation_intent(v_request);
  IF v_replay IS DISTINCT FROM v_result THEN RAISE EXCEPTION 'OWNER exact post retry did not replay stored result'; END IF;
  SELECT count(*) INTO v_replay_batch_count_after FROM public.stock_movement_batches b
    WHERE b.id = v_batch_id AND b.operation_request_id = v_request
      AND b.outlet_id = v_outlet AND b.source_system = 'STOCK_OPNAME';
  SELECT count(*) INTO v_replay_movement_count_after FROM public.stock_movements m
    WHERE m.batch_id = v_batch_id AND m.source_reference = v_session::text;
  SELECT count(*) INTO v_replay_balance_event_count_after FROM public.stock_balance_projection_events e
    WHERE e.request_id = v_request;
  SELECT jsonb_object_agg(p.product_id::text, jsonb_build_object(
      'quantity', p.effective_quantity, 'balance_version', p.balance_version))
    INTO v_replay_projection_after
    FROM public.stock_balance_projection p
    WHERE p.outlet_id = v_outlet AND p.product_id IN (v_a, v_b, v_c, v_d);
  SELECT s.status::text INTO STRICT v_replay_session_status_after
    FROM public.stock_opname_sessions s WHERE s.id = v_session;
  SELECT count(*) INTO v_replay_posted_event_count_after FROM public.stock_opname_session_events e
    WHERE e.session_id = v_session AND e.event_type = 'POSTED';
  SELECT jsonb_build_object(
      'outlet_name', s.posted_outlet_name_snapshot,
      'outlet_captured_at', s.posted_metadata_captured_at,
      'items', (SELECT jsonb_object_agg(i.product_id::text, jsonb_build_object(
        'product_name', i.posted_product_name_snapshot, 'sku', i.posted_sku_snapshot,
        'rack', i.posted_rack_label_snapshot, 'unit', i.posted_unit_label_snapshot,
        'barcode', i.posted_display_barcode_snapshot, 'captured_at', i.posted_metadata_captured_at))
        FROM public.stock_opname_items i WHERE i.session_id = s.id))
    INTO v_replay_metadata_after FROM public.stock_opname_sessions s WHERE s.id = v_session;
  IF v_replay_batch_count_after <> v_replay_batch_count_before
     OR v_replay_movement_count_after <> v_replay_movement_count_before
     OR v_replay_balance_event_count_after <> v_replay_balance_event_count_before
     OR v_replay_projection_after IS DISTINCT FROM v_replay_projection_before
     OR v_replay_session_status_after IS DISTINCT FROM v_replay_session_status_before
     OR v_replay_session_status_after IS DISTINCT FROM 'POSTED'
     OR v_replay_posted_event_count_after <> v_replay_posted_event_count_before
     OR v_replay_metadata_after IS DISTINCT FROM v_replay_metadata_before THEN
    RAISE EXCEPTION 'OWNER exact post retry changed stock writes, projection state, session status, or POSTED event count';
  END IF;
  SELECT count(*) INTO v_moves_before FROM public.stock_movements m WHERE m.source_reference = v_session::text;
  SELECT count(*) INTO v_batches_before FROM public.stock_movement_batches b WHERE b.id = v_batch_id;
  v_other_request := public.issue_stock_operation_intent('POST_SESSION', jsonb_build_object('session_id', v_session));
  v_denied := false;
  BEGIN
    PERFORM public.apply_stock_operation_intent(v_other_request);
  EXCEPTION WHEN SQLSTATE '22023' THEN v_denied := true;
  END;
  IF NOT v_denied OR (SELECT count(*) FROM public.stock_movements m WHERE m.source_reference = v_session::text) <> v_moves_before
     OR (SELECT count(*) FROM public.stock_movement_batches b WHERE b.id = (v_result->>'movementBatchId')::uuid) <> v_batches_before
     OR (SELECT jsonb_build_object('outlet_name', s.posted_outlet_name_snapshot,
          'outlet_captured_at', s.posted_metadata_captured_at,
          'items', (SELECT jsonb_object_agg(i.product_id::text, jsonb_build_object(
            'product_name', i.posted_product_name_snapshot, 'sku', i.posted_sku_snapshot,
            'rack', i.posted_rack_label_snapshot, 'unit', i.posted_unit_label_snapshot,
            'barcode', i.posted_display_barcode_snapshot, 'captured_at', i.posted_metadata_captured_at))
            FROM public.stock_opname_items i WHERE i.session_id = s.id))
         FROM public.stock_opname_sessions s WHERE s.id = v_session) IS DISTINCT FROM v_replay_metadata_before THEN
    RAISE EXCEPTION 'New POST_SESSION request after POSTED was not safely rejected';
  END IF;

  -- ADMIN also posts successfully; a zero-delta only session creates no batch or movements.
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  IF auth.uid() IS DISTINCT FROM v_admin THEN
    RAISE EXCEPTION 'IDENTITY_MISMATCH expected_actor=% actual_actor=%', v_admin, auth.uid();
  END IF;
  IF public.current_active_user_role() IS DISTINCT FROM 'ADMIN'::public.user_role THEN
    RAISE EXCEPTION 'ROLE_MISMATCH expected_role=ADMIN actual_role=%', public.current_active_user_role();
  END IF;
  v_request := public.issue_stock_operation_intent('CREATE_SESSION', jsonb_build_object(
    'outlet_id', v_outlet, 'scope_type', 'PARTIAL', 'product_ids', jsonb_build_array(v_a)));
  v_result := public.apply_stock_operation_intent(v_request);
  v_admin_session := (v_result->>'sessionId')::uuid;
  SELECT i.baseline_quantity, i.revision_no INTO STRICT v_base, v_revision
    FROM public.stock_opname_items i WHERE i.session_id = v_admin_session AND i.product_id = v_a;
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_admin_session, 'product_id', v_a, 'physical_quantity', v_base, 'expected_revision', v_revision));
  IF (public.apply_stock_operation_intent(v_request)->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'ADMIN zero count failed'; END IF;
  v_request := public.issue_stock_operation_intent('SUBMIT_REVIEW', jsonb_build_object('session_id', v_admin_session));
  PERFORM public.apply_stock_operation_intent(v_request);
  v_request := public.issue_stock_operation_intent('POST_SESSION', jsonb_build_object('session_id', v_admin_session));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'status' IS DISTINCT FROM 'POSTED' OR (v_result->>'movementCount')::integer <> 0
     OR v_result->>'movementBatchId' IS NOT NULL
     OR EXISTS (SELECT 1 FROM public.stock_movements m WHERE m.source_reference = v_admin_session::text)
     OR NOT EXISTS (SELECT 1 FROM public.stock_opname_sessions s WHERE s.id = v_admin_session AND s.approved_by = v_admin) THEN
    RAISE EXCEPTION 'ADMIN zero-delta post did not finish without movement rows/batch';
  END IF;

  -- Snapshot visible state as OWNER. Compare only after restoring OWNER because
  -- KASIR RLS intentionally hides opname sessions and stock rows.
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  IF auth.uid() IS DISTINCT FROM v_owner THEN
    RAISE EXCEPTION 'IDENTITY_MISMATCH expected_actor=% actual_actor=%', v_owner, auth.uid();
  END IF;
  IF public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION 'ROLE_MISMATCH expected_role=OWNER actual_role=%', public.current_active_user_role();
  END IF;
  SELECT count(*) INTO v_session_count FROM public.stock_opname_sessions;
  SELECT s.status::text INTO STRICT v_guard_session_status
    FROM public.stock_opname_sessions s WHERE s.id = v_session;
  SELECT count(*) INTO v_guard_batch_count FROM public.stock_movement_batches;
  SELECT count(*) INTO v_guard_movement_count FROM public.stock_movements;
  SELECT count(*) INTO v_guard_balance_event_count FROM public.stock_balance_projection_events;
  SELECT jsonb_object_agg(p.product_id::text, jsonb_build_object(
      'quantity', p.effective_quantity, 'balance_version', p.balance_version)) INTO v_guard_projection
    FROM public.stock_balance_projection p
    WHERE p.outlet_id = v_outlet AND p.product_id IN (v_a, v_b, v_c, v_d);

  -- GUDANG issue denial: verify identity, authorization SQLSTATE, no returned
  -- request UUID (and therefore no issue result), then compare effects as OWNER.
  PERFORM set_config('request.jwt.claim.sub', v_gudang::text, true);
  IF auth.uid() IS DISTINCT FROM v_gudang THEN
    RAISE EXCEPTION 'IDENTITY_MISMATCH expected_actor=% actual_actor=%', v_gudang, auth.uid();
  END IF;
  IF public.current_active_user_role() IS DISTINCT FROM 'GUDANG'::public.user_role THEN
    RAISE EXCEPTION 'ROLE_MISMATCH expected_role=GUDANG actual_role=%', public.current_active_user_role();
  END IF;
  v_issue_sqlstate := NULL;
  v_denied_request := NULL;
  BEGIN
    v_denied_request := public.issue_stock_operation_intent('POST_SESSION', jsonb_build_object('session_id', v_session));
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_issue_sqlstate = RETURNED_SQLSTATE;
  END;
  IF v_issue_sqlstate IS DISTINCT FROM '42501' THEN
    RAISE EXCEPTION 'ISSUE_AUTHORIZATION_FAILURE role=GUDANG expected_sqlstate=42501 actual_sqlstate=%', coalesce(v_issue_sqlstate, 'NO_EXCEPTION');
  END IF;
  IF v_denied_request IS NOT NULL THEN
    RAISE EXCEPTION 'UNEXPECTED_REQUEST_CREATED role=GUDANG request_id=%', v_denied_request;
  END IF;
  -- issue_stock_operation_intent is one SQL statement. Its raised authorization
  -- error rolls back that statement's subtransaction; stock_operation_requests
  -- is intentionally not directly selectable by authenticated callers.
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  IF auth.uid() IS DISTINCT FROM v_owner THEN
    RAISE EXCEPTION 'IDENTITY_MISMATCH expected_actor=% actual_actor=%', v_owner, auth.uid();
  END IF;
  IF public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION 'ROLE_MISMATCH expected_role=OWNER actual_role=%', public.current_active_user_role();
  END IF;
  IF (SELECT count(*) FROM public.stock_opname_sessions) <> v_session_count
     OR (SELECT s.status::text FROM public.stock_opname_sessions s WHERE s.id = v_session) IS DISTINCT FROM v_guard_session_status THEN
    RAISE EXCEPTION 'UNEXPECTED_SESSION_CHANGE role=GUDANG';
  END IF;
  IF (SELECT count(*) FROM public.stock_movement_batches) <> v_guard_batch_count
     OR (SELECT count(*) FROM public.stock_movements) <> v_guard_movement_count
     OR (SELECT count(*) FROM public.stock_balance_projection_events) <> v_guard_balance_event_count
     OR (SELECT jsonb_object_agg(p.product_id::text, jsonb_build_object(
          'quantity', p.effective_quantity, 'balance_version', p.balance_version))
         FROM public.stock_balance_projection p
         WHERE p.outlet_id = v_outlet AND p.product_id IN (v_a, v_b, v_c, v_d)) IS DISTINCT FROM v_guard_projection THEN
    RAISE EXCEPTION 'UNEXPECTED_SESSION_CHANGE role=GUDANG posting-state changed';
  END IF;

  -- Repeat the same independent checks for KASIR. Do not compare RLS-filtered
  -- KASIR counts with the OWNER snapshot above.
  PERFORM set_config('request.jwt.claim.sub', v_kasir::text, true);
  IF auth.uid() IS DISTINCT FROM v_kasir THEN
    RAISE EXCEPTION 'IDENTITY_MISMATCH expected_actor=% actual_actor=%', v_kasir, auth.uid();
  END IF;
  IF public.current_active_user_role() IS DISTINCT FROM 'KASIR'::public.user_role THEN
    RAISE EXCEPTION 'ROLE_MISMATCH expected_role=KASIR actual_role=%', public.current_active_user_role();
  END IF;
  v_issue_sqlstate := NULL;
  v_denied_request := NULL;
  BEGIN
    v_denied_request := public.issue_stock_operation_intent('POST_SESSION', jsonb_build_object('session_id', v_session));
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_issue_sqlstate = RETURNED_SQLSTATE;
  END;
  IF v_issue_sqlstate IS DISTINCT FROM '42501' THEN
    RAISE EXCEPTION 'ISSUE_AUTHORIZATION_FAILURE role=KASIR expected_sqlstate=42501 actual_sqlstate=%', coalesce(v_issue_sqlstate, 'NO_EXCEPTION');
  END IF;
  IF v_denied_request IS NOT NULL THEN
    RAISE EXCEPTION 'UNEXPECTED_REQUEST_CREATED role=KASIR request_id=%', v_denied_request;
  END IF;
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  IF auth.uid() IS DISTINCT FROM v_owner THEN
    RAISE EXCEPTION 'IDENTITY_MISMATCH expected_actor=% actual_actor=%', v_owner, auth.uid();
  END IF;
  IF public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION 'ROLE_MISMATCH expected_role=OWNER actual_role=%', public.current_active_user_role();
  END IF;
  IF (SELECT count(*) FROM public.stock_opname_sessions) <> v_session_count
     OR (SELECT s.status::text FROM public.stock_opname_sessions s WHERE s.id = v_session) IS DISTINCT FROM v_guard_session_status THEN
    RAISE EXCEPTION 'UNEXPECTED_SESSION_CHANGE role=KASIR';
  END IF;
  IF (SELECT count(*) FROM public.stock_movement_batches) <> v_guard_batch_count
     OR (SELECT count(*) FROM public.stock_movements) <> v_guard_movement_count
     OR (SELECT count(*) FROM public.stock_balance_projection_events) <> v_guard_balance_event_count
     OR (SELECT jsonb_object_agg(p.product_id::text, jsonb_build_object(
          'quantity', p.effective_quantity, 'balance_version', p.balance_version))
         FROM public.stock_balance_projection p
         WHERE p.outlet_id = v_outlet AND p.product_id IN (v_a, v_b, v_c, v_d)) IS DISTINCT FROM v_guard_projection THEN
    RAISE EXCEPTION 'UNEXPECTED_SESSION_CHANGE role=KASIR posting-state changed';
  END IF;

  -- SESSION_CHANGED: request is bound to old item content, then session is
  -- returned to counting, recounted, and resubmitted before that UUID is applied.
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  IF auth.uid() IS DISTINCT FROM v_owner THEN
    RAISE EXCEPTION 'IDENTITY_MISMATCH expected_actor=% actual_actor=%', v_owner, auth.uid();
  END IF;
  IF public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION 'ROLE_MISMATCH expected_role=OWNER actual_role=%', public.current_active_user_role();
  END IF;
  v_request := public.issue_stock_operation_intent('CREATE_SESSION', jsonb_build_object(
    'outlet_id', v_outlet, 'scope_type', 'PARTIAL', 'product_ids', jsonb_build_array(v_e)));
  v_result := public.apply_stock_operation_intent(v_request);
  v_changed_session := (v_result->>'sessionId')::uuid;
  SELECT i.baseline_quantity, i.revision_no INTO STRICT v_base, v_revision FROM public.stock_opname_items i
    WHERE i.session_id = v_changed_session AND i.product_id = v_e;
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_changed_session, 'product_id', v_e, 'physical_quantity', v_base, 'expected_revision', v_revision));
  PERFORM public.apply_stock_operation_intent(v_request);
  v_request := public.issue_stock_operation_intent('SUBMIT_REVIEW', jsonb_build_object('session_id', v_changed_session));
  PERFORM public.apply_stock_operation_intent(v_request);
  v_request := public.issue_stock_operation_intent('POST_SESSION', jsonb_build_object('session_id', v_changed_session));
  -- Save the pending post UUID before using other operation requests.
  v_retry := v_request;
  v_request := public.issue_stock_operation_intent('RETURN_TO_COUNTING', jsonb_build_object('session_id', v_changed_session));
  PERFORM public.apply_stock_operation_intent(v_request);
  SELECT i.baseline_quantity, i.revision_no INTO STRICT v_base, v_revision FROM public.stock_opname_items i
    WHERE i.session_id = v_changed_session AND i.product_id = v_e;
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
    'session_id', v_changed_session, 'product_id', v_e, 'physical_quantity', v_base + 1, 'expected_revision', v_revision));
  PERFORM public.apply_stock_operation_intent(v_request);
  v_request := public.issue_stock_operation_intent('SUBMIT_REVIEW', jsonb_build_object('session_id', v_changed_session));
  PERFORM public.apply_stock_operation_intent(v_request);
  SELECT count(*) INTO v_moves_before FROM public.stock_movements m WHERE m.source_reference = v_changed_session::text;
  v_result := public.apply_stock_operation_intent(v_retry);
  IF v_result->>'code' IS DISTINCT FROM 'SESSION_CHANGED'
     OR v_result->>'recountRequired' IS DISTINCT FROM 'true'
     OR NOT EXISTS (SELECT 1 FROM public.stock_opname_sessions s WHERE s.id = v_changed_session AND s.status = 'REVIEW')
     OR EXISTS (SELECT 1 FROM public.stock_opname_sessions s WHERE s.id = v_changed_session AND s.posted_metadata_captured_at IS NOT NULL)
     OR EXISTS (SELECT 1 FROM public.stock_opname_items i WHERE i.session_id = v_changed_session AND i.posted_metadata_captured_at IS NOT NULL)
     OR (SELECT count(*) FROM public.stock_movements m WHERE m.source_reference = v_changed_session::text) <> v_moves_before THEN
    RAISE EXCEPTION 'SESSION_CHANGED result changed stock or failed to preserve review state: %', v_result;
  END IF;

  -- STALE_BASELINE: create a previously posted positive movement, capture it in
  -- a new two-item session, then reverse the old movement before posting.
  v_request := public.issue_stock_operation_intent('CREATE_SESSION', jsonb_build_object(
    'outlet_id', v_outlet, 'scope_type', 'PARTIAL', 'product_ids', jsonb_build_array(v_a, v_b)));
  v_result := public.apply_stock_operation_intent(v_request);
  v_stale_session := (v_result->>'sessionId')::uuid;
  FOR v_item IN SELECT i.product_id, i.baseline_quantity, i.revision_no, p.sku
    FROM public.stock_opname_items i JOIN public.products p ON p.id = i.product_id
    WHERE i.session_id = v_stale_session ORDER BY p.sku
  LOOP
    v_base := CASE v_item.sku WHEN 'STG-FULL-A' THEN v_item.baseline_quantity ELSE v_item.baseline_quantity + 1 END;
    v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
      'session_id', v_stale_session, 'product_id', v_item.product_id,
      'physical_quantity', v_base, 'expected_revision', v_item.revision_no));
    PERFORM public.apply_stock_operation_intent(v_request);
  END LOOP;
  v_request := public.issue_stock_operation_intent('SUBMIT_REVIEW', jsonb_build_object('session_id', v_stale_session));
  PERFORM public.apply_stock_operation_intent(v_request);
  SELECT m.id INTO STRICT v_original_movement FROM public.stock_movements m
    WHERE m.source_reference = v_session::text AND m.product_id = v_a AND m.quantity_delta = -2;
  v_request := public.issue_stock_operation_intent('REVERSE_MOVEMENT', jsonb_build_object(
    'movement_id', v_original_movement, 'reason', 'Synthetic stale-baseline setup'));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'reversesMovementId' IS DISTINCT FROM v_original_movement::text THEN RAISE EXCEPTION 'Stale setup reversal failed'; END IF;
  SELECT p.effective_quantity, p.balance_version INTO STRICT v_before_a, v_version_a
    FROM public.stock_balance_projection p WHERE p.product_id = v_a AND p.outlet_id = v_outlet;
  SELECT p.effective_quantity, p.balance_version INTO STRICT v_before_b, v_version_b
    FROM public.stock_balance_projection p WHERE p.product_id = v_b AND p.outlet_id = v_outlet;
  SELECT count(*) INTO v_moves_before FROM public.stock_movements m WHERE m.source_reference = v_stale_session::text;
  SELECT count(*) INTO v_batches_before FROM public.stock_movement_batches b;
  v_request := public.issue_stock_operation_intent('POST_SESSION', jsonb_build_object('session_id', v_stale_session));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'code' IS DISTINCT FROM 'STALE_BASELINE' OR (v_result->>'staleItemCount')::integer <> 1
     OR NOT EXISTS (SELECT 1 FROM public.stock_opname_sessions s WHERE s.id = v_stale_session AND s.status = 'COUNTING')
     OR EXISTS (SELECT 1 FROM public.stock_opname_sessions s WHERE s.id = v_stale_session AND s.posted_metadata_captured_at IS NOT NULL)
     OR EXISTS (SELECT 1 FROM public.stock_opname_items i WHERE i.session_id = v_stale_session AND i.posted_metadata_captured_at IS NOT NULL)
     OR NOT EXISTS (SELECT 1 FROM public.stock_opname_items i WHERE i.session_id = v_stale_session AND i.product_id = v_a AND i.requires_recount)
     OR EXISTS (SELECT 1 FROM public.stock_movements m WHERE m.source_reference = v_stale_session::text)
     OR (SELECT count(*) FROM public.stock_movements m WHERE m.source_reference = v_stale_session::text) <> v_moves_before
     OR (SELECT count(*) FROM public.stock_movement_batches b) <> v_batches_before
     OR (SELECT p.effective_quantity FROM public.stock_balance_projection p WHERE p.product_id = v_a AND p.outlet_id = v_outlet) <> v_before_a
     OR (SELECT p.effective_quantity FROM public.stock_balance_projection p WHERE p.product_id = v_b AND p.outlet_id = v_outlet) <> v_before_b
     OR (SELECT p.balance_version FROM public.stock_balance_projection p WHERE p.product_id = v_a AND p.outlet_id = v_outlet) <> v_version_a
     OR (SELECT p.balance_version FROM public.stock_balance_projection p WHERE p.product_id = v_b AND p.outlet_id = v_outlet) <> v_version_b THEN
    RAISE EXCEPTION 'STALE_BASELINE did not atomically prevent all session movements/projection changes: %', v_result;
  END IF;
  IF (SELECT count(*) FROM public.stock_opname_count_events e JOIN public.stock_opname_items i ON i.id = e.item_id
      WHERE i.session_id = v_stale_session AND e.event_type = 'STALE_BASELINE') <> 1
     OR NOT EXISTS (SELECT 1 FROM public.stock_opname_session_events e
        WHERE e.session_id = v_stale_session AND e.event_type = 'BASELINE_STALE') THEN
    RAISE EXCEPTION 'STALE_BASELINE did not append expected recount/session events';
  END IF;

  SELECT md5(coalesce(string_agg(i.product_id::text || ':' || coalesce(i.quantity::text, '<null>') || ':' ||
      coalesce(i.minimum_quantity::text, '<null>') || ':' || coalesce(i.source_import_row_id::text, '<null>'),
      E'\n' ORDER BY i.product_id), '')) INTO v_inventory_after
    FROM public.product_inventory i WHERE i.outlet_id = v_outlet;
  IF v_inventory_after IS DISTINCT FROM v_inventory_before THEN
    RAISE EXCEPTION 'POST_SESSION runtime operations changed the normalized iPos inventory snapshot';
  END IF;

  RAISE NOTICE 'PASS: OWNER negative/positive/zero/exception multi-item post, ADMIN post, GUDANG/KASIR denial';
  RAISE NOTICE 'PASS: movement batch/rows, signed deltas, before/after, projection versions/events, POSTED state';
  RAISE NOTICE 'PASS: exact replay, new post rejection, SESSION_CHANGED, all-or-none STALE_BASELINE';
END;
$matrix$;

ROLLBACK;
\echo 'PASS: POST_SESSION matrix transaction rolled back; runner will compare the durable fingerprint'
