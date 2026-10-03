-- Read-only RPC behavior and authenticated role checks for Phase 3C.1B.
-- Run only through apply-stock-workspace-read.sh on local staging.
\set ON_ERROR_STOP on

DO $guard$
BEGIN
  IF current_database() <> 'quena_stock_staging'
     OR coalesce(host(inet_server_addr()), '') NOT IN ('127.0.0.1', '::1')
     OR inet_server_port() <> 5432
     OR current_setting('server_version_num')::integer / 10000 <> 15 THEN
    RAISE EXCEPTION 'Refusing Stock workspace RPC test outside local PostgreSQL 15 quena_stock_staging';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929190000') THEN
    RAISE EXCEPTION 'Stock workspace read migration is not recorded as applied';
  END IF;
END;
$guard$;

DO $privileges$
DECLARE
  v_proc regprocedure := 'public.stock_workspace_read_page(uuid,text,text,boolean,text,integer,integer)'::regprocedure;
  v_public_execute boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS p
    CROSS JOIN LATERAL pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) AS acl
    WHERE p.oid = v_proc
      AND acl.grantee = 0
      AND acl.privilege_type = 'EXECUTE'
  ) INTO v_public_execute;
  IF v_public_execute
     OR has_function_privilege('anon', v_proc, 'EXECUTE')
     OR has_function_privilege('service_role', v_proc, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_proc, 'EXECUTE') THEN
    RAISE EXCEPTION 'Stock workspace RPC EXECUTE grants do not match the authenticated-only contract';
  END IF;
END;
$privileges$;

BEGIN;
SET LOCAL ROLE authenticated;
DO $workspace_contract$
DECLARE
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_admin uuid := 'a0000000-0000-4000-8000-000000000002';
  v_gudang uuid := 'a0000000-0000-4000-8000-000000000003';
  v_kasir uuid := 'a0000000-0000-4000-8000-000000000004';
  v_outlet uuid;
  v_result jsonb;
  v_rows jsonb;
  v_rejected boolean;
  v_inventory_count bigint;
  v_projection_count bigint;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  IF auth.uid() IS DISTINCT FROM v_owner
     OR public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION 'Stock workspace fixture OWNER claim/profile is missing, inactive, or not visible';
  END IF;

  SELECT o.id INTO v_outlet
  FROM public.outlets AS o
  WHERE o.code = 'QUENA-MART-1' AND o.is_active;
  IF v_outlet IS NULL THEN
    RAISE EXCEPTION 'Stock workspace fixture outlet QUENA-MART-1 is missing, inactive, or hidden by RLS';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.stock_authority_periods AS ap
    WHERE ap.outlet_id = v_outlet AND ap.ended_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Stock workspace fixture has no visible active authority period for QUENA-MART-1';
  END IF;

  SELECT count(*) INTO v_inventory_count
  FROM public.product_inventory AS i
  WHERE i.outlet_id = v_outlet;
  SELECT count(*) INTO v_projection_count
  FROM public.product_inventory AS i
  JOIN public.stock_balance_projection AS bp
    ON bp.product_id = i.product_id AND bp.outlet_id = i.outlet_id
  WHERE i.outlet_id = v_outlet AND bp.effective_quantity IS NOT NULL;
  IF v_inventory_count <> 8 OR v_projection_count <> 8 THEN
    RAISE EXCEPTION 'Stock workspace fixture membership/projection mismatch: inventory=%, usable_projection=%',
      v_inventory_count, v_projection_count;
  END IF;

  v_result := public.stock_workspace_read_page(v_outlet, null, 'ALL', false, null, 1, 51);
  v_rows := v_result -> 'rows';
  IF jsonb_typeof(v_rows) <> 'array' OR jsonb_array_length(v_rows) > 50
     OR (v_result #>> '{pagination,page_size}')::integer <> 50
     OR (v_result #>> '{pagination,page}')::integer <> 1
     OR (v_result #>> '{pagination,filtered_total}')::bigint <> 8
     OR (v_result #>> '{pagination,page_count}')::integer <> 1
     OR (v_result #>> '{summary,total}')::bigint <> 8
     OR (v_result #>> '{integrity,missing_projection_count}')::bigint <> 0 THEN
    RAISE EXCEPTION 'OWNER default workspace result violates the bounded fixture contract';
  END IF;
  IF (v_rows -> 0) ?| ARRAY['hpp', 'cost', 'profit', 'quantity'] THEN
    RAISE EXCEPTION 'Stock workspace response contains a forbidden field';
  END IF;

  v_result := public.stock_workspace_read_page(v_outlet, 'Baseline 20', 'ALL', false, null, 1, 50);
  IF (v_result #>> '{pagination,filtered_total}')::bigint <> 1
     OR (v_result #>> '{summary,total}')::bigint <> 1 THEN
    RAISE EXCEPTION 'Name search did not match the expected product';
  END IF;
  v_result := public.stock_workspace_read_page(v_outlet, 'STG-BASE20', 'ALL', false, null, 1, 50);
  IF (v_result #>> '{pagination,filtered_total}')::bigint <> 1 THEN
    RAISE EXCEPTION 'SKU search did not match the expected product';
  END IF;
  v_result := public.stock_workspace_read_page(v_outlet, 'ALIAS-A', 'ALL', false, null, 1, 50);
  IF (v_result #>> '{pagination,filtered_total}')::bigint <> 1
     OR jsonb_array_length(v_result -> 'rows') <> 1 THEN
    RAISE EXCEPTION 'Active alias search duplicated or missed its product';
  END IF;
  v_result := public.stock_workspace_read_page(v_outlet, null, 'ALL', false, 'Staging', 1, 50);
  IF (v_result #>> '{pagination,filtered_total}')::bigint <> 8
     OR (v_result #>> '{summary,total}')::bigint <> 8 THEN
    RAISE EXCEPTION 'Category filter did not match the fixture products';
  END IF;
  v_result := public.stock_workspace_read_page(v_outlet, null, 'ALL', true, null, 1, 50);
  IF (v_result #>> '{pagination,filtered_total}')::bigint <> 0
     OR (v_result #>> '{summary,total}')::bigint <> 0 THEN
    RAISE EXCEPTION 'Rack-empty filter unexpectedly matched the racked fixture';
  END IF;

  v_result := public.stock_workspace_read_page(v_outlet, null, 'HABIS', false, null, 1, 50);
  IF (v_result #>> '{pagination,filtered_total}')::bigint <> 0
     OR (v_result #>> '{pagination,page}')::integer <> 1
     OR (v_result #>> '{pagination,page_count}')::integer <> 0
     OR (v_result #>> '{summary,total}')::bigint <> 8
     OR (v_result #>> '{summary,safe}')::bigint <> 8 THEN
    RAISE EXCEPTION 'Zero-result status filter or status-independent summary is incorrect';
  END IF;
  v_result := public.stock_workspace_read_page(v_outlet, null, 'AMAN', false, null, 99, 3);
  IF (v_result #>> '{pagination,page}')::integer <> 3
     OR (v_result #>> '{pagination,page_count}')::integer <> 3
     OR jsonb_array_length(v_result -> 'rows') <> 2
     OR (v_result #>> '{pagination,filtered_total}')::bigint <> 8 THEN
    RAISE EXCEPTION 'Out-of-range page did not clamp to the last valid page';
  END IF;
  BEGIN
    PERFORM public.stock_workspace_read_page(v_outlet, null, 'UNKNOWN', false, null, 1, 50);
    RAISE EXCEPTION 'Invalid status was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  PERFORM public.stock_workspace_read_page(v_outlet, null, 'ALL', false, null, 1, 50);
  PERFORM set_config('request.jwt.claim.sub', v_gudang::text, true);
  PERFORM public.stock_workspace_read_page(v_outlet, null, 'ALL', false, null, 1, 50);

  PERFORM set_config('request.jwt.claim.sub', v_kasir::text, true);
  v_rejected := false;
  BEGIN
    PERFORM public.stock_workspace_read_page(v_outlet, null, 'ALL', false, null, 1, 50);
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'KASIR was allowed to read the Stock workspace'; END IF;
END;
$workspace_contract$;

SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true);
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
SELECT public.stock_workspace_read_page(
  (SELECT o.id FROM public.outlets AS o WHERE o.code = 'QUENA-MART-1'),
  null, 'ALL', false, null, 1, 50
);
ROLLBACK;

\echo 'PASS: Stock workspace bounded page, search/filter/summary, and OWNER/ADMIN/GUDANG/KASIR checks'
