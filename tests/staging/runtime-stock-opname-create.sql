-- Local-only CREATE_SESSION contract checks. The authenticated role invokes the
-- deployed issue/apply RPCs. Every successful test case is rolled back through
-- a PL/pgSQL exception subtransaction, then the outer transaction is rolled
-- back as a final safety net.
\set ON_ERROR_STOP on
\timing on

DO $guard$
BEGIN
  IF current_database() <> 'quena_stock_staging'
     OR coalesce(host(inet_server_addr()), '') NOT IN ('127.0.0.1', '::1')
     OR inet_server_port() <> 5432
     OR current_setting('server_version_num')::integer / 10000 <> 15
     OR current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'Refusing CREATE_SESSION runtime checks outside local UTF8 PostgreSQL 15 quena_stock_staging';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929180000')
     OR NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929190000') THEN
    RAISE EXCEPTION 'Required local stock migrations 180000 and 190000 are not ledgered';
  END IF;
END;
$guard$;

BEGIN;
SET LOCAL statement_timeout = '45s';
SET LOCAL lock_timeout = '8s';
SET LOCAL ROLE authenticated;

DO $create_session_runtime$
DECLARE
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_admin uuid := 'a0000000-0000-4000-8000-000000000002';
  v_gudang uuid := 'a0000000-0000-4000-8000-000000000003';
  v_kasir uuid := 'a0000000-0000-4000-8000-000000000004';
  v_outlet uuid;
  v_full_a uuid;
  v_full_b uuid;
  v_base_product uuid;
  v_missing_product uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddd0001';
  v_payload jsonb;
  v_canonical_retry_payload jsonb;
  v_request uuid;
  v_same_pending_request uuid;
  v_reissued_request uuid;
  v_other_actor_request uuid;
  v_result jsonb;
  v_replay jsonb;
  v_scope_count bigint;
  v_inventory_fingerprint text;
  v_projection_fingerprint text;
  v_inventory_before text;
  v_projection_before text;
  v_movement_count bigint;
  v_batch_count bigint;
  v_sessions_before bigint;
  v_sessions_at_kasir bigint;
  v_session_id uuid;
  v_constraint text;
  v_rejected boolean;
  v_exception_message text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  IF public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION 'Synthetic OWNER profile is not active';
  END IF;
  SELECT o.id INTO STRICT v_outlet FROM public.outlets o
  WHERE o.code = 'QUENA-MART-1' AND o.is_active;
  SELECT p.id INTO STRICT v_full_a FROM public.products p WHERE p.sku = 'STG-FULL-A';
  SELECT p.id INTO STRICT v_full_b FROM public.products p WHERE p.sku = 'STG-FULL-B';
  SELECT p.id INTO STRICT v_base_product FROM public.products p WHERE p.sku = 'STG-BASE20';

  SELECT count(*) INTO v_scope_count
  FROM public.stock_balance_projection p
  WHERE p.outlet_id = v_outlet AND p.effective_quantity IS NOT NULL
    AND p.baseline_source_import_row_id IS NOT NULL;
  IF v_scope_count = 0 OR EXISTS (
    SELECT 1 FROM public.stock_balance_projection p
    WHERE p.outlet_id = v_outlet
      AND (p.effective_quantity IS NULL OR p.baseline_source_import_row_id IS NULL)
  ) THEN
    RAISE EXCEPTION 'Synthetic outlet lacks a complete usable FULL projection scope';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.stock_opname_items i
    WHERE i.outlet_id = v_outlet AND i.active_scope
  ) THEN
    RAISE EXCEPTION 'Precondition failed: synthetic outlet already has active opname coverage; inspect staging before retry';
  END IF;

  SELECT md5(coalesce(string_agg(
    i.product_id::text || ':' || coalesce(i.quantity::text, '<null>') || ':' ||
    coalesce(i.minimum_quantity::text, '<null>') || ':' || coalesce(i.source_import_row_id::text, '<null>'),
    E'\n' ORDER BY i.product_id), ''))
  INTO v_inventory_before
  FROM public.product_inventory i WHERE i.outlet_id = v_outlet;
  SELECT md5(coalesce(string_agg(
    p.product_id::text || ':' || coalesce(p.baseline_quantity::text, '<null>') || ':' ||
    coalesce(p.unreconciled_movement_delta::text, '<null>') || ':' ||
    coalesce(p.effective_quantity::text, '<null>') || ':' ||
    coalesce(p.balance_version::text, '<null>') || ':' ||
    coalesce(p.baseline_source_import_row_id::text, '<null>'),
    E'\n' ORDER BY p.product_id), ''))
  INTO v_projection_before
  FROM public.stock_balance_projection p WHERE p.outlet_id = v_outlet;
  SELECT count(*) INTO v_movement_count FROM public.stock_movements m WHERE m.outlet_id = v_outlet;
  SELECT count(*) INTO v_batch_count FROM public.stock_movement_batches b WHERE b.outlet_id = v_outlet;
  SELECT count(*) INTO v_sessions_before FROM public.stock_opname_sessions s WHERE s.outlet_id = v_outlet;

  -- OWNER FULL: canonical payload, database-materialized projection scope,
  -- captured baseline/version/source, same-request replay, post-completion
  -- reissue behavior, overlap guard, and no stock/inventory side effects.
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
    v_payload := jsonb_build_object('outlet_id', v_outlet, 'scope_type', 'FULL',
      'product_ids', '[]'::jsonb, 'note', 'CREATE_SESSION runtime OWNER FULL');
    v_request := public.issue_stock_operation_intent('CREATE_SESSION', v_payload);
    v_same_pending_request := public.issue_stock_operation_intent('CREATE_SESSION', v_payload);
    IF v_request IS DISTINCT FROM v_same_pending_request THEN
      RAISE EXCEPTION 'Identical pending FULL intent did not reuse request UUID';
    END IF;
    v_result := public.apply_stock_operation_intent(v_request);
    IF v_result->>'ok' IS DISTINCT FROM 'true' OR v_result->>'status' IS DISTINCT FROM 'COUNTING'
       OR (v_result->>'sessionId') IS NULL THEN
      RAISE EXCEPTION 'OWNER FULL CREATE_SESSION did not return a COUNTING session';
    END IF;
    v_session_id := (v_result->>'sessionId')::uuid;
    IF NOT EXISTS (
      SELECT 1 FROM public.stock_opname_sessions s
      WHERE s.id = v_session_id AND s.outlet_id = v_outlet AND s.scope_type = 'FULL'
        AND s.status = 'COUNTING' AND s.created_by = v_owner
    ) THEN
      RAISE EXCEPTION 'OWNER FULL session row does not match the CREATE_SESSION result';
    END IF;
    IF (SELECT count(*) FROM public.stock_opname_items i WHERE i.session_id = v_session_id) <>
       (SELECT count(*) FROM public.stock_balance_projection p WHERE p.outlet_id = v_outlet) THEN
      RAISE EXCEPTION 'FULL scope did not materialize exactly the outlet projection';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.stock_opname_items i
      JOIN public.stock_balance_projection p
        ON p.product_id = i.product_id AND p.outlet_id = i.outlet_id
      WHERE i.session_id = v_session_id
        AND (i.baseline_quantity IS DISTINCT FROM p.effective_quantity
          OR i.baseline_source_import_row_id IS DISTINCT FROM p.baseline_source_import_row_id
          OR i.baseline_balance_version IS DISTINCT FROM p.balance_version)
    ) THEN
      RAISE EXCEPTION 'FULL baseline quantity/version/provenance differs from the projection at creation';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.stock_opname_session_events e
      WHERE e.request_id = v_request AND e.session_id = v_session_id
        AND e.event_type = 'CREATED' AND e.next_status = 'COUNTING'
    ) IS NOT TRUE THEN
      RAISE EXCEPTION 'CREATE_SESSION event is missing or inconsistent';
    END IF;

    v_replay := public.apply_stock_operation_intent(v_request);
    IF v_replay IS DISTINCT FROM v_result THEN
      RAISE EXCEPTION 'Exact apply retry did not replay the completed result';
    END IF;
    IF (SELECT count(*) FROM public.stock_opname_session_events e
        WHERE e.request_id = v_request AND e.event_type = 'CREATED') <> 1
       OR (SELECT count(*) FROM public.stock_opname_items i WHERE i.session_id = v_session_id) <> v_scope_count THEN
      RAISE EXCEPTION 'Exact request retry created duplicate session events or items';
    END IF;

    v_reissued_request := public.issue_stock_operation_intent('CREATE_SESSION', v_payload);
    IF v_reissued_request IS NULL OR v_reissued_request = v_request THEN
      RAISE EXCEPTION 'Exact post-completion reissue did not create a new request identity';
    END IF;
    v_rejected := false;
    v_constraint := NULL;
    BEGIN
      PERFORM public.apply_stock_operation_intent(v_reissued_request);
    EXCEPTION WHEN unique_violation THEN
      GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
      v_rejected := true;
    END;
    IF NOT v_rejected OR v_constraint IS DISTINCT FROM 'stock_opname_no_active_overlap' THEN
      RAISE EXCEPTION 'Post-completion new request was not rejected by the active-scope overlap index (constraint=%)', v_constraint;
    END IF;
    IF public.read_stock_operation_intent(v_reissued_request)->>'state' IS DISTINCT FROM 'PENDING' THEN
      RAISE EXCEPTION 'Failed overlap apply did not leave its separately issued request pending';
    END IF;
    IF (SELECT count(*) FROM public.stock_opname_sessions s WHERE s.outlet_id = v_outlet) <> v_sessions_before + 1
       OR (SELECT count(*) FROM public.stock_opname_items i WHERE i.session_id = v_session_id) <> v_scope_count THEN
      RAISE EXCEPTION 'Overlap rejection left a partial/duplicate session or item set';
    END IF;

    -- Independent actor proves the database protects a product-level partial
    -- overlap as well as an identical FULL retry.
    PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
    IF public.current_active_user_role() IS DISTINCT FROM 'ADMIN'::public.user_role THEN
      RAISE EXCEPTION 'Synthetic ADMIN profile is not active';
    END IF;
    v_other_actor_request := public.issue_stock_operation_intent('CREATE_SESSION',
      jsonb_build_object('outlet_id', v_outlet, 'scope_type', 'PARTIAL',
        'product_ids', jsonb_build_array(v_full_a), 'note', 'CREATE_SESSION overlap probe'));
    v_rejected := false;
    v_constraint := NULL;
    BEGIN
      PERFORM public.apply_stock_operation_intent(v_other_actor_request);
    EXCEPTION WHEN unique_violation THEN
      GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
      v_rejected := true;
    END;
    IF NOT v_rejected OR v_constraint IS DISTINCT FROM 'stock_opname_no_active_overlap' THEN
      RAISE EXCEPTION 'Independent ADMIN partial overlap was not rejected by the database index (constraint=%)', v_constraint;
    END IF;

    SELECT md5(coalesce(string_agg(
      i.product_id::text || ':' || coalesce(i.quantity::text, '<null>') || ':' ||
      coalesce(i.minimum_quantity::text, '<null>') || ':' || coalesce(i.source_import_row_id::text, '<null>'),
      E'\n' ORDER BY i.product_id), '')) INTO v_inventory_fingerprint
    FROM public.product_inventory i WHERE i.outlet_id = v_outlet;
    SELECT md5(coalesce(string_agg(
      p.product_id::text || ':' || coalesce(p.baseline_quantity::text, '<null>') || ':' ||
      coalesce(p.unreconciled_movement_delta::text, '<null>') || ':' ||
      coalesce(p.effective_quantity::text, '<null>') || ':' ||
      coalesce(p.balance_version::text, '<null>') || ':' ||
      coalesce(p.baseline_source_import_row_id::text, '<null>'),
      E'\n' ORDER BY p.product_id), '')) INTO v_projection_fingerprint
    FROM public.stock_balance_projection p WHERE p.outlet_id = v_outlet;
    IF v_inventory_fingerprint IS DISTINCT FROM v_inventory_before
       OR v_projection_fingerprint IS DISTINCT FROM v_projection_before
       OR (SELECT count(*) FROM public.stock_movements m WHERE m.outlet_id = v_outlet) <> v_movement_count
       OR (SELECT count(*) FROM public.stock_movement_batches b WHERE b.outlet_id = v_outlet) <> v_batch_count THEN
      RAISE EXCEPTION 'CREATE_SESSION mutated inventory, projection quantities, movement ledger, or batches';
    END IF;

    RAISE NOTICE 'PASS: OWNER FULL, captured projection baseline, exact retry replay, post-completion reissue identity/overlap behavior, no stock side effects';
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = '__ROLLBACK_OWNER_CASE__';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM <> '__ROLLBACK_OWNER_CASE__' THEN RAISE; END IF;
  END;

  -- ADMIN PARTIAL: explicitly supplied IDs only; duplicate IDs canonicalize to
  -- one sorted product list and produce no duplicate opname line.
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
    IF public.current_active_user_role() IS DISTINCT FROM 'ADMIN'::public.user_role THEN
      RAISE EXCEPTION 'Synthetic ADMIN profile is not active';
    END IF;
    v_payload := jsonb_build_object('outlet_id', v_outlet, 'scope_type', 'PARTIAL',
      'product_ids', jsonb_build_array(v_full_b, v_full_a, v_full_a), 'note', 'CREATE_SESSION runtime ADMIN PARTIAL');
    v_request := public.issue_stock_operation_intent('CREATE_SESSION', v_payload);
    v_canonical_retry_payload := jsonb_build_object('outlet_id', v_outlet, 'scope_type', 'PARTIAL',
      'product_ids', jsonb_build_array(v_full_a, v_full_b), 'note', 'CREATE_SESSION runtime ADMIN PARTIAL');
    IF public.issue_stock_operation_intent('CREATE_SESSION', v_canonical_retry_payload) <> v_request THEN
      RAISE EXCEPTION 'Duplicate/reordered PARTIAL selections did not canonicalize to the same pending request';
    END IF;
    v_result := public.apply_stock_operation_intent(v_request);
    v_session_id := (v_result->>'sessionId')::uuid;
    IF v_result->>'ok' IS DISTINCT FROM 'true' OR v_result->>'status' IS DISTINCT FROM 'COUNTING'
       OR NOT EXISTS (SELECT 1 FROM public.stock_opname_sessions s WHERE s.id = v_session_id
         AND s.scope_type = 'PARTIAL' AND s.status = 'COUNTING' AND s.created_by = v_admin) THEN
      RAISE EXCEPTION 'ADMIN PARTIAL CREATE_SESSION did not create a COUNTING session';
    END IF;
    IF (SELECT count(*) FROM public.stock_opname_items i WHERE i.session_id = v_session_id) <> 2
       OR EXISTS (SELECT 1 FROM public.stock_opname_items i WHERE i.session_id = v_session_id
         AND i.product_id NOT IN (v_full_a, v_full_b)) THEN
      RAISE EXCEPTION 'PARTIAL scope contains products outside the explicit selection';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.stock_opname_items i
      JOIN public.stock_balance_projection p ON p.product_id = i.product_id AND p.outlet_id = i.outlet_id
      WHERE i.session_id = v_session_id AND
        (i.baseline_quantity IS DISTINCT FROM p.effective_quantity
         OR i.baseline_source_import_row_id IS DISTINCT FROM p.baseline_source_import_row_id
         OR i.baseline_balance_version IS DISTINCT FROM p.balance_version)
    ) THEN RAISE EXCEPTION 'PARTIAL baseline capture differs from the current stock projection'; END IF;
    RAISE NOTICE 'PASS: ADMIN PARTIAL explicit selection and duplicate-ID canonicalization';
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = '__ROLLBACK_ADMIN_CASE__';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM <> '__ROLLBACK_ADMIN_CASE__' THEN RAISE; END IF;
  END;

  -- GUDANG may create a PARTIAL COUNTING session but receives no approval/post
  -- operation in this test. The role check is the production JWT/profile path.
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_gudang::text, true);
    IF public.current_active_user_role() IS DISTINCT FROM 'GUDANG'::public.user_role THEN
      RAISE EXCEPTION 'Synthetic GUDANG profile is not active';
    END IF;
    v_request := public.issue_stock_operation_intent('CREATE_SESSION',
      jsonb_build_object('outlet_id', v_outlet, 'scope_type', 'PARTIAL',
        'product_ids', jsonb_build_array(v_base_product), 'note', 'CREATE_SESSION runtime GUDANG PARTIAL'));
    v_result := public.apply_stock_operation_intent(v_request);
    v_session_id := (v_result->>'sessionId')::uuid;
    IF v_result->>'ok' IS DISTINCT FROM 'true' OR v_result->>'status' IS DISTINCT FROM 'COUNTING'
       OR NOT EXISTS (SELECT 1 FROM public.stock_opname_sessions s WHERE s.id = v_session_id
         AND s.scope_type = 'PARTIAL' AND s.status = 'COUNTING' AND s.created_by = v_gudang)
       OR (SELECT count(*) FROM public.stock_opname_items i WHERE i.session_id = v_session_id) <> 1
       OR NOT EXISTS (SELECT 1 FROM public.stock_opname_items i WHERE i.session_id = v_session_id AND i.product_id = v_base_product) THEN
      RAISE EXCEPTION 'GUDANG PARTIAL CREATE_SESSION result/scope is invalid';
    END IF;
    RAISE NOTICE 'PASS: GUDANG PARTIAL CREATE_SESSION allowed';
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = '__ROLLBACK_GUDANG_CASE__';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM <> '__ROLLBACK_GUDANG_CASE__' THEN RAISE; END IF;
  END;

  -- KASIR must be rejected at intent issuance; no apply request can be created.
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_kasir::text, true);
    IF public.current_active_user_role() IS DISTINCT FROM 'KASIR'::public.user_role THEN
      RAISE EXCEPTION 'Synthetic KASIR profile is not active';
    END IF;
    v_sessions_at_kasir := (SELECT count(*) FROM public.stock_opname_sessions s WHERE s.outlet_id = v_outlet);
    v_rejected := false;
    BEGIN
      PERFORM public.issue_stock_operation_intent('CREATE_SESSION',
        jsonb_build_object('outlet_id', v_outlet, 'scope_type', 'PARTIAL',
          'product_ids', jsonb_build_array(v_base_product), 'note', 'CREATE_SESSION runtime KASIR denied'));
    EXCEPTION WHEN insufficient_privilege THEN
      v_rejected := true;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'KASIR was allowed to issue CREATE_SESSION'; END IF;
    IF (SELECT count(*) FROM public.stock_opname_sessions s WHERE s.outlet_id = v_outlet) <> v_sessions_at_kasir THEN
      RAISE EXCEPTION 'KASIR rejection left an opname session';
    END IF;
    RAISE NOTICE 'PASS: KASIR CREATE_SESSION denied before a request/session is created';
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = '__ROLLBACK_KASIR_CASE__';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM <> '__ROLLBACK_KASIR_CASE__' THEN RAISE; END IF;
  END;

  -- A nonexistent/no-projection product must not be interpreted as zero stock.
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
    v_request := public.issue_stock_operation_intent('CREATE_SESSION',
      jsonb_build_object('outlet_id', v_outlet, 'scope_type', 'PARTIAL',
        'product_ids', jsonb_build_array(v_missing_product), 'note', 'CREATE_SESSION missing projection probe'));
    v_rejected := false;
    v_exception_message := NULL;
    BEGIN
      PERFORM public.apply_stock_operation_intent(v_request);
    EXCEPTION WHEN SQLSTATE '22023' THEN
      GET STACKED DIAGNOSTICS v_exception_message = MESSAGE_TEXT;
      v_rejected := true;
    END;
    IF NOT v_rejected OR v_exception_message NOT LIKE '%without an available stock baseline%' THEN
      RAISE EXCEPTION 'PARTIAL product without projection was not rejected safely (message=%)', v_exception_message;
    END IF;
    RAISE NOTICE 'PASS: PARTIAL product without usable projection rejected; no zero fallback';
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = '__ROLLBACK_NO_PROJECTION_CASE__';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM <> '__ROLLBACK_NO_PROJECTION_CASE__' THEN RAISE; END IF;
  END;

  -- Each case has asserted its result in-transaction. Durable cleanup is
  -- deliberately checked by the shell runner only after the outer ROLLBACK.
END;
$create_session_runtime$;

ROLLBACK;
\echo 'PASS: CREATE_SESSION role, FULL/PARTIAL scope, baseline capture, overlap, retry, and no-mutation assertions completed; transaction rolled back.'
