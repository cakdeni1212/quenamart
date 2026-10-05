\set ON_ERROR_STOP on
\timing on

DO $guard$
DECLARE
  v_rpc oid;
BEGIN
  IF current_database() <> 'quena_stock_staging'
     OR coalesce(host(inet_server_addr()), '') NOT IN ('127.0.0.1', '::1')
     OR inet_server_port() <> 5432
     OR current_setting('server_version_num')::integer / 10000 <> 15
     OR current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'Refusing results matrix outside local UTF8 PostgreSQL 15 quena_stock_staging';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM quena_staging.environment WHERE name = 'quena_stock_staging')
    OR NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929210000') THEN
    RAISE EXCEPTION 'Required local staging marker or migration 210000 is missing';
  END IF;
  SELECT p.oid INTO STRICT v_rpc FROM pg_catalog.pg_proc p
  WHERE p.oid = pg_catalog.to_regprocedure(
    'public.stock_opname_posted_results_page(uuid,text,text,integer,integer)');
  IF (SELECT p.prosecdef FROM pg_catalog.pg_proc p WHERE p.oid = v_rpc)
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p, unnest(p.proconfig) c
       WHERE p.oid = v_rpc AND c = 'search_path=pg_catalog')
     OR NOT pg_catalog.has_function_privilege('authenticated', v_rpc, 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', v_rpc, 'EXECUTE')
     OR pg_catalog.has_function_privilege('service_role', v_rpc, 'EXECUTE') THEN
    RAISE EXCEPTION 'FUNCTION_DEFINITION_MISMATCH: results RPC security or ACL differs from contract';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles r
    WHERE r.rolname = session_user AND r.rolsuper) THEN
    RAISE EXCEPTION 'LOCAL_RUNTIME_FIXTURE_REQUIRES_TRUSTED_STAGING_SESSION_USER';
  END IF;
END;
$guard$;

BEGIN;
SET LOCAL statement_timeout = '90s';
SET LOCAL lock_timeout = '8s';

-- Build a legacy pre-snapshot POSTED row directly as the guarded local
-- connection role. It is synthetic, lives inside this transaction, and never
-- uses an operation RPC that would populate the new snapshots.
SET LOCAL ROLE postgres;
DO $legacy_fixture$
DECLARE
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_outlet uuid;
  v_product uuid;
  v_session uuid;
  v_item uuid;
  v_projection public.stock_balance_projection%rowtype;
BEGIN
  SELECT o.id INTO STRICT v_outlet FROM public.outlets o
    WHERE o.code = 'QUENA-MART-1' AND o.is_active;
  SELECT p.id INTO STRICT v_product FROM public.products p WHERE p.sku = 'STG-BASE20';
  SELECT * INTO STRICT v_projection FROM public.stock_balance_projection p
    WHERE p.outlet_id = v_outlet AND p.product_id = v_product;
  IF v_projection.effective_quantity IS NULL OR v_projection.baseline_source_import_row_id IS NULL THEN
    RAISE EXCEPTION 'Legacy fixture requires a usable local projection';
  END IF;
  INSERT INTO public.stock_opname_sessions(
    outlet_id, scope_type, status, created_by, submitted_by, submitted_at,
    approved_by, approved_at, posted_at
  ) VALUES (
    v_outlet, 'PARTIAL', 'POSTED', v_owner, v_owner, now(), v_owner, now(), now()
  ) RETURNING id INTO v_session;
  INSERT INTO public.stock_opname_items(
    session_id, outlet_id, product_id, baseline_quantity,
    baseline_source_import_row_id, baseline_balance_version, physical_quantity,
    revision_no, last_counted_by, last_counted_at, active_scope
  ) VALUES (
    v_session, v_outlet, v_product, v_projection.effective_quantity,
    v_projection.baseline_source_import_row_id, v_projection.balance_version,
    v_projection.effective_quantity, 1, v_owner, now(), false
  ) RETURNING id INTO v_item;
  INSERT INTO public.stock_opname_session_events(
    session_id, event_type, previous_status, next_status, actor_id
  ) VALUES
    (v_session, 'CREATED', NULL, 'COUNTING', v_owner),
    (v_session, 'POSTED', 'REVIEW', 'POSTED', v_owner);
  PERFORM pg_catalog.set_config('quena.results_legacy_session', v_session::text, true);
  PERFORM pg_catalog.set_config('quena.results_legacy_item', v_item::text, true);
END;
$legacy_fixture$;

SET LOCAL ROLE authenticated;
DO $results_matrix$
DECLARE
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_admin uuid := 'a0000000-0000-4000-8000-000000000002';
  v_gudang uuid := 'a0000000-0000-4000-8000-000000000003';
  v_kasir uuid := 'a0000000-0000-4000-8000-000000000004';
  v_outlet uuid;
  v_a uuid; v_b uuid; v_c uuid; v_d uuid;
  v_session uuid;
  v_request uuid;
  v_result jsonb;
  v_row jsonb;
  v_filter record;
  v_baseline numeric;
  v_revision integer;
  v_metadata_before jsonb;
  v_result_before text;
  v_expected_summary jsonb := '{"total_items":4,"counted":3,"exceptions":1,"difference":2,"match":1,"increased":1,"decreased":1}'::jsonb;
BEGIN
  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_owner::text, true);
  IF auth.uid() IS DISTINCT FROM v_owner
     OR public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION 'IDENTITY_OR_ROLE_MISMATCH expected OWNER actor=% role=%', auth.uid(), public.current_active_user_role();
  END IF;
  SELECT o.id INTO STRICT v_outlet FROM public.outlets o WHERE o.code = 'QUENA-MART-1' AND o.is_active;
  SELECT p.id INTO STRICT v_a FROM public.products p WHERE p.sku = 'STG-FULL-A';
  SELECT p.id INTO STRICT v_b FROM public.products p WHERE p.sku = 'STG-FULL-B';
  SELECT p.id INTO STRICT v_c FROM public.products p WHERE p.sku = 'STG-STALE';
  SELECT p.id INTO STRICT v_d FROM public.products p WHERE p.sku = 'STG-RECON';
  IF EXISTS (SELECT 1 FROM public.stock_opname_items i
    WHERE i.product_id IN (v_a, v_b, v_c, v_d) AND i.active_scope) THEN
    RAISE EXCEPTION 'Results fixture products have active opname coverage';
  END IF;

  v_request := public.issue_stock_operation_intent('CREATE_SESSION', jsonb_build_object(
    'outlet_id', v_outlet, 'scope_type', 'PARTIAL', 'product_ids', jsonb_build_array(v_a, v_b, v_c, v_d)));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'ok' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Results fixture CREATE_SESSION failed: %', v_result; END IF;
  v_session := (v_result->>'sessionId')::uuid;
  PERFORM pg_catalog.set_config('quena.results_session', v_session::text, true);

  FOR v_row IN SELECT to_jsonb(x) FROM (
    SELECT i.id, i.product_id, i.baseline_quantity, i.revision_no, p.sku
    FROM public.stock_opname_items i JOIN public.products p ON p.id = i.product_id
    WHERE i.session_id = v_session ORDER BY p.sku
  ) x LOOP
    IF v_row->>'sku' = 'STG-RECON' THEN
      v_request := public.issue_stock_operation_intent('REVIEW_EXCEPTION', jsonb_build_object(
        'session_id', v_session, 'product_id', (v_row->>'product_id')::uuid,
        'expected_revision', (v_row->>'revision_no')::integer, 'reason', 'Snapshot matrix exception'));
    ELSE
      v_baseline := (v_row->>'baseline_quantity')::numeric;
      v_revision := (v_row->>'revision_no')::integer;
      v_baseline := CASE v_row->>'sku'
        WHEN 'STG-FULL-A' THEN v_baseline - 2
        WHEN 'STG-FULL-B' THEN v_baseline + 3
        ELSE v_baseline END;
      v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object(
        'session_id', v_session, 'product_id', (v_row->>'product_id')::uuid,
        'physical_quantity', v_baseline, 'expected_revision', v_revision));
    END IF;
    v_result := public.apply_stock_operation_intent(v_request);
    IF v_result->>'ok' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Results fixture count/exception failed: %', v_result; END IF;
  END LOOP;
  v_request := public.issue_stock_operation_intent('SUBMIT_REVIEW', jsonb_build_object('session_id', v_session));
  PERFORM public.apply_stock_operation_intent(v_request);
  -- STG-FULL-A is a negative adjustment, STG-FULL-B is positive, STG-STALE
  -- is zero delta, and STG-RECON is a reviewed exception.
  v_request := public.issue_stock_operation_intent('POST_SESSION', jsonb_build_object('session_id', v_session));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'status' IS DISTINCT FROM 'POSTED' OR (v_result->>'movementCount')::integer <> 2 THEN
    RAISE EXCEPTION 'Results fixture POST_SESSION failed: %', v_result;
  END IF;

  -- Snapshot capture is all-item, including zero delta and exception rows.
  IF (SELECT count(*) FROM public.stock_opname_items i WHERE i.session_id = v_session
      AND i.posted_metadata_captured_at IS NOT NULL) <> 4
     OR (SELECT count(*) FROM public.stock_opname_items i WHERE i.session_id = v_session
      AND i.posted_metadata_captured_at IS DISTINCT FROM
        (SELECT s.posted_metadata_captured_at FROM public.stock_opname_sessions s WHERE s.id = v_session)) <> 0
     OR (SELECT s.posted_outlet_name_snapshot FROM public.stock_opname_sessions s WHERE s.id = v_session)
        IS DISTINCT FROM (SELECT o.name FROM public.outlets o WHERE o.id = v_outlet) THEN
    RAISE EXCEPTION 'Posting snapshot did not capture outlet and every item at one timestamp';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.stock_opname_items i JOIN public.products p ON p.id = i.product_id
    WHERE i.session_id = v_session AND (
      i.posted_product_name_snapshot IS DISTINCT FROM p.name
      OR i.posted_sku_snapshot IS DISTINCT FROM p.sku
      OR i.posted_unit_label_snapshot IS DISTINCT FROM p.unit_label
      OR i.posted_rack_label_snapshot IS DISTINCT FROM (
        SELECT os.rack_label FROM public.product_outlet_settings os
        WHERE os.product_id = p.id AND os.outlet_id = v_outlet)
      OR i.posted_display_barcode_snapshot IS DISTINCT FROM (
        SELECT b.barcode FROM public.product_barcodes b
        WHERE b.product_id = p.id AND b.is_active ORDER BY b.created_at, b.id LIMIT 1))) THEN
    RAISE EXCEPTION 'One or more posted display metadata snapshots differ from posting-time master values';
  END IF;

  v_result := public.stock_opname_posted_results_page(v_session, NULL, 'ALL', 1, 2);
  IF v_result->>'ok' IS DISTINCT FROM 'true'
     OR v_result->'summary' IS DISTINCT FROM v_expected_summary
     OR (v_result->'page'->>'total_matching')::integer <> 4
     OR (v_result->'page'->>'page')::integer <> 1
     OR (v_result->'page'->>'page_size')::integer <> 2
     OR jsonb_array_length(v_result->'rows') <> 2
     OR v_result->'header'->>'outlet_metadata_provenance' IS DISTINCT FROM 'POST_SNAPSHOT'
     OR v_result->'header'->>'status' IS DISTINCT FROM 'POSTED'
     OR jsonb_array_length(v_result->'timeline') = 0
     OR v_result::text ~* '(hpp|cost|profit)' THEN
    RAISE EXCEPTION 'ALL/page/header/summary/privacy result contract failed: %', v_result;
  END IF;
  v_result := public.stock_opname_posted_results_page(v_session, NULL, 'ALL', 2, 2);
  IF (v_result->'page'->>'total_matching')::integer <> 4 OR jsonb_array_length(v_result->'rows') <> 2 THEN
    RAISE EXCEPTION 'Second bounded result page failed: %', v_result;
  END IF;

  FOR v_filter IN SELECT * FROM (VALUES
      ('DIFFERENCE', 2), ('MATCH', 1), ('INCREASE', 1), ('DECREASE', 1), ('EXCEPTION', 1)
    ) AS expected(filter_name, expected_count)
  LOOP
    v_result := public.stock_opname_posted_results_page(v_session, NULL, v_filter.filter_name, 1, 10);
    IF v_result->>'ok' IS DISTINCT FROM 'true'
       OR (v_result->'page'->>'total_matching')::integer <> v_filter.expected_count
       OR jsonb_array_length(v_result->'rows') <> v_filter.expected_count THEN
      RAISE EXCEPTION 'Filter % expected % rows, got %', v_filter.filter_name, v_filter.expected_count, v_result;
    END IF;
  END LOOP;

  v_result := public.stock_opname_posted_results_page(v_session, 'Staging Full A', 'ALL', 1, 10);
  IF (v_result->'page'->>'total_matching')::integer <> 1
     OR v_result->'rows'->0->>'metadata_provenance' IS DISTINCT FROM 'POST_SNAPSHOT' THEN
    RAISE EXCEPTION 'Snapshot product-name search failed: %', v_result;
  END IF;
  v_result := public.stock_opname_posted_results_page(v_session, 'STG-FULL-B', 'ALL', 1, 10);
  IF (v_result->'page'->>'total_matching')::integer <> 1 THEN
    RAISE EXCEPTION 'Snapshot SKU search failed: %', v_result;
  END IF;

  -- Validate fixed exception output. It must never become a zero quantity.
  v_result := public.stock_opname_posted_results_page(v_session, NULL, 'EXCEPTION', 1, 10);
  v_row := v_result->'rows'->0;
  IF v_row->>'physical_quantity' IS NOT NULL
     OR v_row->>'difference' IS NOT NULL
     OR v_row->>'historical_after_quantity' IS NOT NULL
     OR v_row->>'historical_after_state' IS DISTINCT FROM 'NOT_CHANGED_BY_OPNAME'
     OR v_row->>'exception_state' IS DISTINCT FROM 'true'
     OR v_row->>'exception_reason' IS DISTINCT FROM 'Snapshot matrix exception' THEN
    RAISE EXCEPTION 'Reviewed exception result was represented as a quantity: %', v_row;
  END IF;

  -- Verify zero-delta counted result comes from the stored item, not movement rows.
  v_result := public.stock_opname_posted_results_page(v_session, 'STG-STALE', 'MATCH', 1, 10);
  v_row := v_result->'rows'->0;
  IF (v_result->'page'->>'total_matching')::integer <> 1
     OR v_row->>'baseline_quantity' IS DISTINCT FROM v_row->>'physical_quantity'
     OR v_row->>'difference' IS DISTINCT FROM '0'
     OR v_row->>'historical_after_quantity' IS DISTINCT FROM v_row->>'physical_quantity'
     OR EXISTS (SELECT 1 FROM public.stock_movements m
       JOIN public.stock_opname_items i ON i.id = m.opname_item_id
       WHERE i.session_id = v_session AND i.product_id = v_c) THEN
    RAISE EXCEPTION 'Zero-delta historical result is incorrect: %', v_row;
  END IF;

  -- OWNER can read; retain the complete output for comparison after master edits.
  v_result := public.stock_opname_posted_results_page(v_session, NULL, 'ALL', 1, 10);
  PERFORM pg_catalog.set_config('quena.results_snapshot_output', v_result::text, true);
  PERFORM pg_catalog.set_config('quena.results_snapshot_session', v_session::text, true);

  -- Legacy session has no capture marker; its current metadata is explicitly fallback.
  v_result := public.stock_opname_posted_results_page(
    current_setting('quena.results_legacy_session')::uuid, NULL, 'ALL', 1, 10);
  IF v_result->>'ok' IS DISTINCT FROM 'true'
     OR v_result->'header'->>'outlet_metadata_provenance' IS DISTINCT FROM 'CURRENT_FALLBACK'
     OR v_result->'rows'->0->>'metadata_provenance' IS DISTINCT FROM 'CURRENT_FALLBACK'
     OR v_result->'header'->>'outlet_name' IS DISTINCT FROM
       (SELECT o.name FROM public.stock_opname_sessions s JOIN public.outlets o ON o.id = s.outlet_id
        WHERE s.id = current_setting('quena.results_legacy_session')::uuid)
     OR v_result->'rows'->0->>'physical_quantity' IS NULL
     OR v_result->'rows'->0->>'difference' IS DISTINCT FROM '0'
     OR v_result->'rows'->0->>'historical_after_quantity' IS DISTINCT FROM
       v_result->'rows'->0->>'physical_quantity' THEN
    RAISE EXCEPTION 'Legacy result did not use honest CURRENT_FALLBACK metadata or quantity: %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM public.stock_opname_sessions s
      WHERE s.id = current_setting('quena.results_legacy_session')::uuid
        AND s.posted_metadata_captured_at IS NOT NULL)
     OR EXISTS (SELECT 1 FROM public.stock_opname_items i
      WHERE i.id = current_setting('quena.results_legacy_item')::uuid
        AND i.posted_metadata_captured_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Synthetic legacy fixture unexpectedly received a metadata snapshot';
  END IF;

  -- KASIR is denied at the result RPC boundary.
  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_kasir::text, true);
  IF auth.uid() IS DISTINCT FROM v_kasir
     OR public.current_active_user_role() IS DISTINCT FROM 'KASIR'::public.user_role THEN
    RAISE EXCEPTION 'KASIR fixture identity/role mismatch';
  END IF;
  v_result := public.stock_opname_posted_results_page(v_session, NULL, 'ALL', 1, 10);
  IF v_result->>'ok' IS DISTINCT FROM 'false' OR v_result->>'code' IS DISTINCT FROM 'FORBIDDEN' THEN
    RAISE EXCEPTION 'KASIR was not denied posted result read: %', v_result;
  END IF;

  RAISE NOTICE 'PASS: snapshot posting, all filters/search, summary, pagination, zero-delta, exception, legacy fallback, and role gates';
END;
$results_matrix$;

-- Product/outlet master-data changes are synthetic and transaction-scoped.
-- The posted result must continue to return its captured metadata.
RESET ROLE;
DO $mutate_master$
DECLARE
  v_session uuid := current_setting('quena.results_snapshot_session')::uuid;
  v_outlet uuid;
  v_sku_update_rejected boolean := false;
BEGIN
  SELECT s.outlet_id INTO STRICT v_outlet FROM public.stock_opname_sessions s WHERE s.id = v_session;
  UPDATE public.products p
  SET name = p.name || ' AFTER POST',
      unit_label = coalesce(p.unit_label, 'UNIT') || '-AFTER', updated_at = now()
  WHERE p.id IN (SELECT i.product_id FROM public.stock_opname_items i WHERE i.session_id = v_session);
  BEGIN
    UPDATE public.products p
    SET sku = p.sku || '-AFTER'
    WHERE p.id IN (SELECT i.product_id FROM public.stock_opname_items i WHERE i.session_id = v_session);
  EXCEPTION WHEN raise_exception THEN
    v_sku_update_rejected := true;
  END;
  IF NOT v_sku_update_rejected THEN
    RAISE EXCEPTION 'SKU metadata change unexpectedly bypassed the established immutable-SKU guard';
  END IF;
  INSERT INTO public.product_outlet_settings(product_id, outlet_id, rack_label, created_by, updated_by)
  SELECT i.product_id, v_outlet, 'RACK-AFTER-POST',
      'a0000000-0000-4000-8000-000000000001'::uuid,
      'a0000000-0000-4000-8000-000000000001'::uuid
  FROM public.stock_opname_items i WHERE i.session_id = v_session
  ON CONFLICT (product_id, outlet_id) DO UPDATE
    SET rack_label = EXCLUDED.rack_label, updated_at = now();
  UPDATE public.product_barcodes b
  SET barcode = b.barcode || '-AFTER-POST', updated_at = now()
  WHERE b.is_active AND b.product_id IN (
    SELECT i.product_id FROM public.stock_opname_items i WHERE i.session_id = v_session);
  UPDATE public.outlets o SET name = o.name || ' AFTER POST', updated_at = now()
  WHERE o.id = v_outlet;
END;
$mutate_master$;

SET LOCAL ROLE authenticated;
DO $snapshot_stability_and_roles$
DECLARE
  v_session uuid := current_setting('quena.results_snapshot_session')::uuid;
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_admin uuid := 'a0000000-0000-4000-8000-000000000002';
  v_gudang uuid := 'a0000000-0000-4000-8000-000000000003';
  v_result jsonb;
  v_expected jsonb := current_setting('quena.results_snapshot_output')::jsonb;
  v_role_actor uuid;
BEGIN
  FOR v_role_actor IN SELECT unnest(ARRAY[v_owner, v_admin, v_gudang]) LOOP
    PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_role_actor::text, true);
    IF auth.uid() IS DISTINCT FROM v_role_actor
       OR public.current_active_user_role() NOT IN ('OWNER'::public.user_role,
          'ADMIN'::public.user_role, 'GUDANG'::public.user_role) THEN
      RAISE EXCEPTION 'Allowed results read identity/role mismatch actor=% role=%', auth.uid(), public.current_active_user_role();
    END IF;
    v_result := public.stock_opname_posted_results_page(v_session, NULL, 'ALL', 1, 10);
    IF v_result IS DISTINCT FROM v_expected THEN
      RAISE EXCEPTION 'Posting-time result metadata changed after master mutation for actor %', v_role_actor;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS: mutable product/outlet display metadata remains snapshotted; SKU re-key remains rejected by its existing guard';
END;
$snapshot_stability_and_roles$;

RESET ROLE;
DO $scale_fixture$
DECLARE
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_outlet uuid;
  v_session uuid := pg_catalog.gen_random_uuid();
BEGIN
  SELECT o.id INTO STRICT v_outlet FROM public.outlets o
    WHERE o.code = 'QUENA-MART-1' AND o.is_active;
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.generate_series(1, 5103) AS g(n)
    JOIN public.products p
      ON p.id = pg_catalog.md5('stock-opname-results-scale-' || n::text)::uuid
      OR p.sku = 'RSLT-SCALE-' || pg_catalog.lpad(n::text, 5, '0')
  ) THEN
    RAISE EXCEPTION 'Scale fixture identifiers already exist; refusing to mutate local fixtures';
  END IF;
  INSERT INTO public.stock_opname_sessions(
    id, outlet_id, scope_type, status, created_by, submitted_by, submitted_at,
    approved_by, approved_at, posted_at
  ) VALUES (v_session, v_outlet, 'FULL', 'POSTED', v_owner, v_owner, now(), v_owner, now(), now());
  INSERT INTO public.products(id, sku, name, created_by, updated_by)
  SELECT pg_catalog.md5('stock-opname-results-scale-' || n::text)::uuid,
      'RSLT-SCALE-' || pg_catalog.lpad(n::text, 5, '0'),
      'Stock Opname Results Scale Product ' || pg_catalog.lpad(n::text, 5, '0'),
      v_owner, v_owner
  FROM pg_catalog.generate_series(1, 5103) AS g(n);
  INSERT INTO public.stock_opname_items(
    session_id, outlet_id, product_id, exception_reason,
    exception_reviewed_by, exception_reviewed_at, active_scope
  )
  SELECT v_session, v_outlet,
      pg_catalog.md5('stock-opname-results-scale-' || n::text)::uuid,
      'Synthetic bounded results fixture', v_owner, now(), false
  FROM pg_catalog.generate_series(1, 5103) AS g(n);
  INSERT INTO public.stock_opname_session_events(
    session_id, event_type, previous_status, next_status, actor_id
  ) VALUES (v_session, 'POSTED', 'REVIEW', 'POSTED', v_owner);
  PERFORM pg_catalog.set_config('quena.results_scale_session', v_session::text, true);
END;
$scale_fixture$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true);
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT public.stock_opname_posted_results_page(
  current_setting('quena.results_scale_session')::uuid, NULL, 'EXCEPTION', 1, 40);
DO $scale_assertions$
DECLARE
  v_result jsonb;
  v_session uuid := current_setting('quena.results_scale_session')::uuid;
BEGIN
  IF public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION 'Scale test identity did not resolve to OWNER';
  END IF;
  v_result := public.stock_opname_posted_results_page(v_session, NULL, 'EXCEPTION', 999, 10000);
  IF v_result->>'ok' IS DISTINCT FROM 'true'
     OR (v_result->'summary'->>'total_items')::integer <> 5103
     OR (v_result->'summary'->>'exceptions')::integer <> 5103
     OR (v_result->'page'->>'total_matching')::integer <> 5103
     OR (v_result->'page'->>'page')::integer <> 52
     OR (v_result->'page'->>'page_size')::integer <> 100
     OR jsonb_array_length(v_result->'rows') <> 3 THEN
    RAISE EXCEPTION '5103-row summary/bounded/normalized pagination failed: %', v_result;
  END IF;
  v_result := public.stock_opname_posted_results_page(v_session, 'Scale Product 05103', 'EXCEPTION', 1, 40);
  IF (v_result->'page'->>'total_matching')::integer <> 1
     OR v_result->'rows'->0->>'sku' IS DISTINCT FROM 'RSLT-SCALE-05103' THEN
    RAISE EXCEPTION '5103-row name/SKU search failed: %', v_result;
  END IF;
  RAISE NOTICE 'PASS: bounded aggregate/search/pagination at 5,103 synthetic result items';
END;
$scale_assertions$;

ROLLBACK;
\echo 'PASS: results matrix transaction rolled back; runner will compare durable fingerprints'
