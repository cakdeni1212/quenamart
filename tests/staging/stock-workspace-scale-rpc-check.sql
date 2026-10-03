-- Appended to the shared transaction-scoped synthetic scale fixture by
-- run-stock-workspace-scale-rpc-check.sh. The only application calls below
-- are the seven requested read-only RPC cases; fixture effects are rolled back.
\set ON_ERROR_STOP on

ANALYZE public.product_inventory;
ANALYZE public.product_outlet_settings;
ANALYZE public.stock_balance_projection;
ANALYZE public.product_barcodes;
ANALYZE public.products;

SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true) AS scale_owner_claim_after_analyze \gset
SET LOCAL ROLE authenticated;

DO $scale_rpc_checks$
DECLARE
  v_outlet uuid := current_setting('quena.stock_scale_outlet_id')::uuid;
  v_case record;
  v_result jsonb;
  v_elapsed_ms numeric;
  v_started timestamptz;
  v_expected_empty bigint;
  v_expected_low bigint;
  v_expected_safe bigint;
  v_expected_rack_empty bigint;
  v_returned_rows bigint;
  v_filtered_total bigint;
  v_summary_total bigint;
  v_page_count integer;
  v_slow_cases integer := 0;
  v_explain json;
  v_explain_sql text;
BEGIN
  IF auth.uid() IS DISTINCT FROM 'a0000000-0000-4000-8000-000000000001'::uuid
     OR public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION 'Scale RPC checks must execute as simulated authenticated OWNER';
  END IF;
  IF (SELECT count(*) FROM public.product_inventory WHERE outlet_id = v_outlet) <> 5104 THEN
    RAISE EXCEPTION 'Expected 5,104 outlet memberships (8 baseline + 5,096 synthetic)';
  END IF;
  IF (SELECT count(*) FROM public.stock_balance_projection
      WHERE outlet_id = v_outlet AND effective_quantity IS NOT NULL) <> 5103 THEN
    RAISE EXCEPTION 'Expected 5,103 usable projections; one synthetic membership intentionally has none';
  END IF;

  SELECT count(*) FILTER (WHERE q = 0),
         count(*) FILTER (WHERE q > 0 AND minimum_stock > 0 AND q <= minimum_stock),
         count(*) FILTER (WHERE NOT (q = 0 OR (minimum_stock > 0 AND q <= minimum_stock))),
         count(*) FILTER (WHERE n % 11 = 0)
  INTO v_expected_empty, v_expected_low, v_expected_safe, v_expected_rack_empty
  FROM (
    SELECT s.n,
      CASE WHEN s.n % 10 IN (0, 1) THEN 0 WHEN s.n % 10 IN (2, 3, 4) THEN 3 ELSE 8 END AS q,
      CASE WHEN s.n % 4 = 0 THEN 0 ELSE 5 END AS minimum_stock
    FROM generate_series(1, 5095) AS s(n)
  ) AS synthetic;
  v_expected_safe := v_expected_safe + 8;

  IF v_expected_empty + v_expected_low + v_expected_safe <> 5103 THEN
    RAISE EXCEPTION 'Synthetic status distribution does not total 5,103 usable projections';
  END IF;

  FOR v_case IN
    SELECT * FROM (VALUES
      ('A-default-page-1'::text, NULL::text, 'ALL'::text, false, NULL::text, 1, 50, 5103::bigint, 5103::bigint),
      ('B-page-50'::text, NULL::text, 'ALL'::text, false, NULL::text, 50, 50, 5103::bigint, 5103::bigint),
      ('C-HABIS'::text, NULL::text, 'HABIS'::text, false, NULL::text, 1, 50, v_expected_empty, 5103::bigint),
      ('D-MENIPIS'::text, NULL::text, 'MENIPIS'::text, false, NULL::text, 1, 50, v_expected_low, 5103::bigint),
      ('E-rack-empty'::text, NULL::text, 'ALL'::text, true, NULL::text, 1, 50, v_expected_rack_empty, v_expected_rack_empty),
      ('F-selective-SKU'::text, 'SCALE-3C1B-00001'::text, 'ALL'::text, false, NULL::text, 1, 50, 1::bigint, 1::bigint),
      ('G-selective-barcode'::text, 'SCALEALIAS00001'::text, 'ALL'::text, false, NULL::text, 1, 50, 1::bigint, 1::bigint)
    ) AS cases(case_name, q, stock_status, rack_empty, category, page_no, page_size, expected_filtered_total, expected_summary_total)
  LOOP
    v_started := pg_catalog.clock_timestamp();
    v_result := public.stock_workspace_read_page(
      v_outlet,
      v_case.q,
      v_case.stock_status,
      v_case.rack_empty,
      v_case.category,
      v_case.page_no,
      v_case.page_size
    );
    v_elapsed_ms := extract(epoch FROM (pg_catalog.clock_timestamp() - v_started)) * 1000;
    v_returned_rows := jsonb_array_length(v_result -> 'rows');
    v_filtered_total := (v_result #>> '{pagination,filtered_total}')::bigint;
    v_summary_total := (v_result #>> '{summary,total}')::bigint;
    v_page_count := (v_result #>> '{pagination,page_count}')::integer;

    IF v_filtered_total <> v_case.expected_filtered_total
       OR v_summary_total <> v_case.expected_summary_total
       OR v_returned_rows > 50
       OR v_returned_rows > greatest(least(v_case.page_size, v_filtered_total - ((v_case.page_no - 1) * v_case.page_size)), 0)
       OR (v_case.case_name = 'A-default-page-1' AND v_page_count <> 103)
       OR (v_case.case_name = 'B-page-50' AND (v_page_count <> 103 OR v_returned_rows <> 50))
       OR (v_case.case_name = 'A-default-page-1' AND
           ((v_result #>> '{summary,empty}')::bigint <> v_expected_empty
            OR (v_result #>> '{summary,low}')::bigint <> v_expected_low
            OR (v_result #>> '{summary,safe}')::bigint <> v_expected_safe)) THEN
      RAISE EXCEPTION 'Correctness failed for %: returned_rows=% filtered_total=% summary_total=% page_count=%',
        v_case.case_name, v_returned_rows, v_filtered_total, v_summary_total, v_page_count;
    END IF;

    RAISE NOTICE 'RPC case=% returned_rows=% filtered_total=% summary_total=% elapsed_ms=% buffers=not collected for fast-path call',
      v_case.case_name, v_returned_rows, v_filtered_total, v_summary_total, round(v_elapsed_ms, 3);

    IF v_elapsed_ms > 1000 THEN
      v_slow_cases := v_slow_cases + 1;
      v_explain_sql := pg_catalog.format(
        'EXPLAIN (ANALYZE, BUFFERS, VERBOSE, COSTS, SUMMARY, FORMAT JSON) SELECT public.stock_workspace_read_page(%L::uuid, %L::text, %L::text, %L::boolean, %L::text, %s::integer, %s::integer)',
        v_outlet,
        v_case.q,
        v_case.stock_status,
        v_case.rack_empty,
        v_case.category,
        v_case.page_no,
        v_case.page_size
      );
      EXECUTE v_explain_sql INTO v_explain;
      RAISE NOTICE 'TARGETED EXPLAIN case=% plan_json=%', v_case.case_name, v_explain;
    END IF;
  END LOOP;

  IF v_slow_cases = 0 THEN
    RAISE NOTICE 'ACCEPTANCE PASS: all seven RPC cases were correct and completed within 1,000 ms';
  ELSE
    RAISE NOTICE 'ACCEPTANCE FAIL: % RPC case(s) exceeded 1,000 ms; targeted EXPLAIN output is above; no optimization was applied', v_slow_cases;
  END IF;
END;
$scale_rpc_checks$;

RESET ROLE;
ROLLBACK;
\echo 'PASS: representative post-ANALYZE RPC checks completed; synthetic fixture changes rolled back'
