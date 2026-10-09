\set ON_ERROR_STOP on
\timing on

DO $guard$
BEGIN
  IF current_database()<>'quena_stock_staging'
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR inet_server_port()<>5432 OR current_setting('server_version_num')::integer/10000<>15
    OR current_setting('server_encoding')<>'UTF8'
    OR NOT EXISTS(SELECT 1 FROM quena_staging.environment WHERE name='quena_stock_staging') THEN
    RAISE EXCEPTION 'Refusing HPP preview performance check outside guarded local staging';
  END IF;
END $guard$;

BEGIN READ ONLY;
SELECT id AS outlet_id FROM public.outlets WHERE code='QUENA-MART-1' AND is_active \gset
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SELECT set_config('quena.hpp_preview.outlet_id',:'outlet_id',true);

DO $parity$
DECLARE
  v_outlet uuid := current_setting('quena.hpp_preview.outlet_id')::uuid;
  v_search text;
  v_result jsonb;
  v_expected integer;
  v_expected_ids uuid[];
  v_actual_ids uuid[];
  v_filter text;
  v_total integer;
BEGIN
  SELECT coalesce(sku,name) INTO v_search
  FROM public.products p
  JOIN public.stock_balance_projection s ON s.product_id=p.id AND s.outlet_id=v_outlet
  WHERE s.effective_quantity>0
  ORDER BY p.sku NULLS LAST,p.id
  LIMIT 1;
  IF v_search IS NULL THEN RAISE EXCEPTION 'No positive-stock product available for preview search parity'; END IF;

  -- Compare the unchanged evaluator to summary values returned by the public RPC.
  WITH evaluated AS MATERIALIZED (
    SELECT * FROM public.inventory_cost_hpp_acceptance_evaluate(v_outlet)
    WHERE effective_quantity>0
  )
  SELECT count(*)::integer INTO v_expected FROM evaluated;
  v_result := public.inventory_cost_initial_hpp_acceptance_preview(v_outlet,'EXCEPTIONS',NULL,1,20);
  IF v_result->>'ok'<>'true'
    OR (v_result->'summary'->>'positiveStockProducts')::integer<>v_expected
    OR (v_result->>'filter')<>'EXCEPTIONS'
    OR (v_result->>'page')::integer<>1
    OR (v_result->>'pageSize')::integer<>20 THEN
    RAISE EXCEPTION 'Preview summary/response contract diverged from evaluator: %',v_result;
  END IF;

  FOREACH v_filter IN ARRAY ARRAY['EXCEPTIONS','CANDIDATES','WARNINGS'] LOOP
    WITH evaluated AS MATERIALIZED (
      SELECT * FROM public.inventory_cost_hpp_acceptance_evaluate(v_outlet)
      WHERE effective_quantity>0
    )
    SELECT count(*)::integer INTO v_expected FROM evaluated e
    WHERE (v_filter='EXCEPTIONS' AND classification='EXCEPTION')
      OR (v_filter='CANDIDATES' AND classification='AUTO_CANDIDATE')
      OR (v_filter='WARNINGS' AND cardinality(warning_codes)>0);
    SELECT array_agg(product_id ORDER BY product_name,sku,product_id) INTO v_expected_ids
    FROM (
      SELECT e.product_id,e.product_name,e.sku
      FROM public.inventory_cost_hpp_acceptance_evaluate(v_outlet) e
      WHERE e.effective_quantity>0
        AND ((v_filter='EXCEPTIONS' AND e.classification='EXCEPTION')
          OR (v_filter='CANDIDATES' AND e.classification='AUTO_CANDIDATE')
          OR (v_filter='WARNINGS' AND cardinality(e.warning_codes)>0))
      ORDER BY e.product_name,e.sku,e.product_id LIMIT 20
    ) expected_page;

    v_result := public.inventory_cost_initial_hpp_acceptance_preview(v_outlet,v_filter,NULL,1,20);
    SELECT array_agg((value->>'productId')::uuid ORDER BY ordinality) INTO v_actual_ids
    FROM jsonb_array_elements(v_result->'rows') WITH ORDINALITY;
    IF v_result->>'ok'<>'true' OR (v_result->>'total')::integer<>v_expected
      OR v_actual_ids IS DISTINCT FROM v_expected_ids THEN
      RAISE EXCEPTION 'Preview % count/page differs from the evaluator',v_filter;
    END IF;
  END LOOP;

  -- Search, page 2 where present, and empty page semantics.
  WITH evaluated AS MATERIALIZED (
    SELECT * FROM public.inventory_cost_hpp_acceptance_evaluate(v_outlet)
    WHERE effective_quantity>0 AND (product_name ILIKE '%'||v_search||'%' OR sku ILIKE '%'||v_search||'%')
  ) SELECT count(*)::integer INTO v_expected FROM evaluated;
  v_result := public.inventory_cost_initial_hpp_acceptance_preview(v_outlet,'ALL',v_search,1,20);
  IF v_result->>'ok'<>'true' OR (v_result->>'total')::integer<>v_expected THEN
    RAISE EXCEPTION 'Preview search count differs from evaluator';
  END IF;

  WITH evaluated AS MATERIALIZED (
    SELECT * FROM public.inventory_cost_hpp_acceptance_evaluate(v_outlet)
    WHERE effective_quantity>0 AND classification='AUTO_CANDIDATE'
  ) SELECT count(*)::integer INTO v_total FROM evaluated;
  IF v_total>20 THEN
    WITH page_two AS (
      SELECT product_id,product_name,sku FROM public.inventory_cost_hpp_acceptance_evaluate(v_outlet)
      WHERE effective_quantity>0 AND classification='AUTO_CANDIDATE'
      ORDER BY product_name,sku,product_id OFFSET 20 LIMIT 20
    ) SELECT array_agg(product_id ORDER BY product_name,sku,product_id) INTO v_expected_ids FROM page_two;
    v_result := public.inventory_cost_initial_hpp_acceptance_preview(v_outlet,'CANDIDATES',NULL,2,20);
    SELECT array_agg((entry->>'productId')::uuid ORDER BY ordinality) INTO v_actual_ids
    FROM jsonb_array_elements(v_result->'rows') WITH ORDINALITY AS rows(entry,ordinality);
    IF (v_result->>'total')::integer<>v_total OR v_actual_ids IS DISTINCT FROM v_expected_ids THEN
      RAISE EXCEPTION 'Preview page 2 differs from evaluator';
    END IF;
  ELSE
    v_result := public.inventory_cost_initial_hpp_acceptance_preview(v_outlet,'CANDIDATES',NULL,2,20);
    IF jsonb_array_length(v_result->'rows')<>0 OR (v_result->>'total')::integer<>v_total THEN
      RAISE EXCEPTION 'Preview empty page semantics differ from evaluator';
    END IF;
  END IF;
  RAISE NOTICE 'HPP preview summary, filters, search, ordering, and pagination match the unchanged evaluator';
END $parity$;

-- Each EXPLAIN ANALYZE is a SELECT-only call on the synthetic staging database.
-- The plan reports total RPC execution time; internal evaluator is a PL/pgSQL
-- function, so EXPLAIN without ANALYZE would not reveal its SQL subplans.
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON)
  SELECT public.inventory_cost_initial_hpp_acceptance_preview(:'outlet_id'::uuid,'EXCEPTIONS',NULL,1,20);
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON)
  SELECT public.inventory_cost_initial_hpp_acceptance_preview(:'outlet_id'::uuid,'CANDIDATES',NULL,1,20);
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON)
  SELECT public.inventory_cost_initial_hpp_acceptance_preview(:'outlet_id'::uuid,'WARNINGS',NULL,1,20);
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON)
  SELECT public.inventory_cost_initial_hpp_acceptance_preview(:'outlet_id'::uuid,'ALL',
    (SELECT coalesce(p.sku,p.name) FROM public.products p
      JOIN public.stock_balance_projection s ON s.product_id=p.id AND s.outlet_id=:'outlet_id'::uuid
      WHERE s.effective_quantity>0 ORDER BY p.sku NULLS LAST,p.id LIMIT 1),1,20);
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON)
  SELECT public.inventory_cost_initial_hpp_acceptance_preview(:'outlet_id'::uuid,'CANDIDATES',NULL,2,20);

ROLLBACK;
