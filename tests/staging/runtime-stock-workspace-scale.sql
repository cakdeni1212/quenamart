-- Transactional, synthetic ~5,103-row scale fixture for stock_workspace_read_page.
-- All setup, import normalization, projections, RPC calls, and EXPLAIN ANALYZE
-- run inside one transaction and are removed by the final ROLLBACK.
\set ON_ERROR_STOP on

DO $guard$
BEGIN
  IF current_database() <> 'quena_stock_staging'
     OR coalesce(host(inet_server_addr()), '') NOT IN ('127.0.0.1', '::1')
     OR inet_server_port() <> 5432
     OR current_setting('server_version_num')::integer / 10000 <> 15 THEN
    RAISE EXCEPTION 'Refusing scale fixture outside local PostgreSQL 15 quena_stock_staging';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM quena_staging.environment WHERE name = 'quena_stock_staging')
     OR NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929190000')
     OR to_regprocedure('public.stock_workspace_read_page(uuid,text,text,boolean,text,integer,integer)') IS NULL THEN
    RAISE EXCEPTION 'Stock workspace staging marker, migration, or function signature is missing';
  END IF;
  IF (SELECT count(*) FROM public.product_inventory i
      JOIN public.stock_balance_projection p USING (product_id, outlet_id)
      WHERE i.outlet_id = (SELECT id FROM public.outlets WHERE code = 'QUENA-MART-1')
        AND p.effective_quantity IS NOT NULL) <> 8 THEN
    RAISE EXCEPTION 'Expected the intact eight-product functional fixture before scale run';
  END IF;
  IF EXISTS (SELECT 1 FROM public.products WHERE sku LIKE 'SCALE-3C1B-%') THEN
    RAISE EXCEPTION 'Scale namespace is already present; prior run did not roll back cleanly';
  END IF;
  IF EXISTS (SELECT 1 FROM public.product_barcodes WHERE barcode LIKE 'SCALEBC%' OR barcode LIKE 'SCALEALIAS%') THEN
    RAISE EXCEPTION 'Scale barcode namespace is already present; refusing to overlap existing fixture data';
  END IF;
END;
$guard$;

BEGIN;
SET LOCAL statement_timeout = '5min';
SET LOCAL lock_timeout = '15s';

SELECT id AS scale_outlet_id
FROM public.outlets
WHERE code = 'QUENA-MART-1' AND is_active
\gset
SELECT id AS scale_authority_id
FROM public.stock_authority_periods
WHERE outlet_id = :'scale_outlet_id'::uuid AND ended_at IS NULL
\gset

INSERT INTO storage.objects(id, bucket_id, name)
VALUES (
  'e3000000-0000-4000-8000-000000000001',
  'quena-ipos-imports',
  'incoming/a0000000-0000-4000-8000-000000000001/e3000000-0000-4000-8000-000000000002.xlsx'
);

SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true) AS owner_claim \gset
SET LOCAL ROLE authenticated;
SELECT public.request_ipos_import(
  :'scale_outlet_id'::uuid,
  'incoming/a0000000-0000-4000-8000-000000000001/e3000000-0000-4000-8000-000000000002.xlsx',
  'synthetic-stock-scale-5103.xlsx'
) AS scale_request_id \gset
RESET ROLE;

SET LOCAL ROLE service_role;
SELECT public.claim_ipos_import_request(:'scale_request_id'::uuid) AS scale_claim_result \gset
SELECT (:'scale_claim_result'::jsonb ->> 'batch_id') AS scale_batch_id \gset
RESET ROLE;

SELECT set_config('quena.stock_scale_request_id', :'scale_request_id', true) AS scale_request_guc \gset
SELECT set_config('quena.stock_scale_batch_id', :'scale_batch_id', true) AS scale_batch_guc \gset
SELECT set_config('quena.stock_scale_outlet_id', :'scale_outlet_id', true) AS scale_outlet_guc \gset
SELECT set_config('quena.stock_scale_authority_id', :'scale_authority_id', true) AS scale_authority_guc \gset

-- The rows are synthetic raw inputs in a legitimately PROCESSING batch.
INSERT INTO public.ipos_import_rows(id, batch_id, outlet_id, source_row_number, raw_data, status)
SELECT md5('quena-stock-scale-v1:' || s.n::text)::uuid,
       :'scale_batch_id'::uuid,
       :'scale_outlet_id'::uuid,
       s.n + 2,
       jsonb_build_object(
         'SKU', CASE WHEN s.n = 5096 THEN 'SCALE-3C1B-MISSING' ELSE 'SCALE-3C1B-' || lpad(s.n::text, 5, '0') END,
         'NAMA', CASE WHEN s.n = 5096 THEN 'Stock Scale Missing Projection' ELSE 'Stock Scale Product ' || lpad(s.n::text, 5, '0') END,
         'BARCODE', 'SCALEBC' || lpad(s.n::text, 7, '0'),
         'STOK', CASE WHEN s.n % 10 IN (0, 1) THEN 0 WHEN s.n % 10 IN (2, 3, 4) THEN 3 ELSE 8 END,
         'STOKMIN', CASE WHEN s.n % 4 = 0 THEN 0 ELSE 5 END,
         'RAK', CASE WHEN s.n = 5096 THEN 'Rack-Missing' WHEN s.n % 11 = 0 THEN '' ELSE 'Rack-' || lpad((s.n % 13)::text, 2, '0') END
       ),
       'RAW_ONLY'
FROM generate_series(1, 5096) AS s(n);

SET LOCAL ROLE service_role;
SELECT public.complete_ipos_import_request(:'scale_request_id'::uuid, :'scale_batch_id'::uuid, 5096);
RESET ROLE;

-- Commit synthetic rows through the same Phase 2B normalization RPC contract.
SET LOCAL ROLE service_role;
DO $scale_normalization$
DECLARE
  v_request uuid := current_setting('quena.stock_scale_request_id')::uuid;
  v_batch uuid := current_setting('quena.stock_scale_batch_id')::uuid;
  v_outlet uuid := current_setting('quena.stock_scale_outlet_id')::uuid;
  v_rows jsonb;
  v_expected jsonb;
  v_payload jsonb;
  v_result jsonb;
  v_commit uuid;
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
    'source_row_id', md5('quena-stock-scale-v1:' || s.n::text),
    'source_row', s.n + 2,
    'action', 'CREATE',
    'sku', CASE WHEN s.n = 5096 THEN 'SCALE-3C1B-MISSING' ELSE 'SCALE-3C1B-' || lpad(s.n::text, 5, '0') END,
    'expected_product_id', NULL,
    'normalized_data', jsonb_build_object(
      'sku', CASE WHEN s.n = 5096 THEN 'SCALE-3C1B-MISSING' ELSE 'SCALE-3C1B-' || lpad(s.n::text, 5, '0') END,
      'name', CASE WHEN s.n = 5096 THEN 'Stock Scale Missing Projection' ELSE 'Stock Scale Product ' || lpad(s.n::text, 5, '0') END,
      'categoryLabel', CASE WHEN s.n = 5096 THEN 'Scale-Missing' ELSE 'Scale-Category-' || (((s.n - 1) % 5) + 1)::text END,
      'brandLabel', 'Synthetic',
      'unitLabel', 'ea',
      'departmentLabel', 'Scale Test',
      'sourceDescription', 'Synthetic local stock workspace scale fixture',
      'sourceReferenceCode', CASE WHEN s.n = 5096 THEN 'SCALE-3C1B-MISSING' ELSE 'SCALE-3C1B-' || lpad(s.n::text, 5, '0') END,
      'barcode', 'SCALEBC' || lpad(s.n::text, 7, '0'),
      'barcodeState', 'VALID',
      'rackLabel', CASE WHEN s.n = 5096 THEN 'Rack-Missing' WHEN s.n % 11 = 0 THEN NULL ELSE 'Rack-' || lpad((s.n % 13)::text, 2, '0') END,
      'quantity', (CASE WHEN s.n % 10 IN (0, 1) THEN 0 WHEN s.n % 10 IN (2, 3, 4) THEN 3 ELSE 8 END)::text,
      'minimumQuantity', (CASE WHEN s.n % 4 = 0 THEN 0 ELSE 5 END)::text,
      'sellingPrice', NULL,
      'hpp', NULL
    ),
    'audit_findings', '[]'::jsonb,
    'issues', '[]'::jsonb,
    'blocked_override_fields', '[]'::jsonb
  ) ORDER BY s.n)
  INTO v_rows
  FROM generate_series(1, 5096) AS s(n);

  WITH proposed AS (
    SELECT x.normalized_data ->> 'sku' AS sku,
           x.normalized_data ->> 'barcode' AS barcode
    FROM jsonb_to_recordset(v_rows) AS x(normalized_data jsonb)
  ), sku_set AS (
    SELECT DISTINCT p.sku FROM proposed AS p WHERE p.sku IS NOT NULL AND p.sku <> ''
  ), candidate_products AS (
    SELECT p.id FROM public.products AS p JOIN sku_set AS s ON s.sku = p.sku
  ), barcode_set AS (
    SELECT DISTINCT p.barcode FROM proposed AS p WHERE p.barcode IS NOT NULL AND p.barcode <> ''
  )
  SELECT jsonb_build_object(
    'products', coalesce((
      SELECT jsonb_agg(jsonb_build_object('id', p.id, 'sku', p.sku, 'name', p.name) ORDER BY p.id)
      FROM public.products AS p
    ), '[]'::jsonb),
    'barcodes', coalesce((
      SELECT jsonb_agg(jsonb_build_object('id', b.id, 'product_id', b.product_id,
        'barcode', b.barcode, 'source_import_row_id', b.source_import_row_id) ORDER BY b.id)
      FROM public.product_barcodes AS b
      WHERE b.is_active AND (
        b.product_id IN (SELECT cp.id FROM candidate_products AS cp)
        OR b.barcode IN (SELECT bs.barcode FROM barcode_set AS bs)
      )
    ), '[]'::jsonb),
    'overrides', coalesce((
      SELECT jsonb_agg(jsonb_build_object('id', o.id, 'product_id', o.product_id,
        'barcode_id', o.barcode_id, 'outlet_id', o.outlet_id,
        'field_key', o.field_key, 'corrected_value', o.corrected_value) ORDER BY o.id)
      FROM public.product_field_overrides AS o
      WHERE o.is_active AND o.product_id IN (SELECT cp.id FROM candidate_products AS cp)
    ), '[]'::jsonb)
  ) INTO v_expected;

  v_payload := jsonb_build_object(
    'normalizationVersion', 'ipos-v1-preflight',
    'batchId', v_batch::text,
    'outletId', v_outlet::text,
    'expectedState', v_expected,
    'rows', v_rows
  );
  v_result := public.commit_ipos_normalization(v_batch, 'ipos-v1-preflight', v_payload);
  IF v_result ->> 'linkedRows' <> '5096' OR v_result ->> 'invalidRows' <> '0' THEN
    RAISE EXCEPTION 'Synthetic normalization did not link all 5,096 scale rows';
  END IF;
  v_commit := (v_result ->> 'commitId')::uuid;
  PERFORM set_config('quena.stock_scale_commit_id', v_commit::text, true);
END;
$scale_normalization$;
RESET ROLE;

-- The trusted import refresh leaves new products as observation-only, unusable
-- projection rows. For this synthetic performance fixture, seed accepted test
-- baselines using the exact completed row/batch/commit provenance generated above.
UPDATE public.stock_balance_projection AS bp
SET baseline_quantity = (c.normalized_data ->> 'quantity')::numeric,
    baseline_source_import_row_id = c.source_row_id,
    baseline_batch_id = c.batch_id,
    baseline_commit_id = c.commit_id,
    updated_at = pg_catalog.now()
FROM public.ipos_normalization_commit_rows AS c
WHERE c.commit_id = current_setting('quena.stock_scale_commit_id')::uuid
  AND c.source_row_number <= 5097
  AND bp.product_id = c.product_id
  AND bp.outlet_id = c.outlet_id;

INSERT INTO public.stock_balance_baseline_events(
  product_id, outlet_id, source_import_row_id, batch_id, normalization_commit_id, event_type
)
SELECT c.product_id, c.outlet_id, c.source_row_id, c.batch_id, c.commit_id, 'BOOTSTRAP'
FROM public.ipos_normalization_commit_rows AS c
WHERE c.commit_id = current_setting('quena.stock_scale_commit_id')::uuid
  AND c.source_row_number <= 5097;

INSERT INTO public.product_barcodes(
  id, product_id, barcode, is_active, source_import_row_id, created_by, updated_by
)
SELECT md5('quena-stock-scale-alias-id-v1:' || s.n::text)::uuid,
       p.id,
       'SCALEALIAS' || lpad(s.n::text, 5, '0'),
       true,
       NULL,
       'a0000000-0000-4000-8000-000000000001'::uuid,
       'a0000000-0000-4000-8000-000000000001'::uuid
FROM generate_series(1, 5095) AS s(n)
JOIN public.products AS p ON p.sku = 'SCALE-3C1B-' || lpad(s.n::text, 5, '0')
WHERE s.n % 100 = 1;

-- Execute the actual RPC as authenticated OWNER under RLS/SECURITY INVOKER.
SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true) AS scale_owner_claim \gset
SET LOCAL ROLE authenticated;

DO $scale_correctness$
DECLARE
  v_outlet uuid := current_setting('quena.stock_scale_outlet_id')::uuid;
  v_result jsonb;
  v_expected_empty bigint;
  v_expected_low bigint;
  v_expected_safe bigint;
  v_expected_rack_empty bigint;
  v_expected_category bigint;
BEGIN
  IF auth.uid() <> 'a0000000-0000-4000-8000-000000000001'::uuid
     OR public.current_active_user_role() <> 'OWNER'::public.user_role THEN
    RAISE EXCEPTION 'Scale benchmark is not executing as the simulated authenticated OWNER';
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
         count(*) FILTER (WHERE n % 11 = 0),
         count(*) FILTER (WHERE (n - 1) % 5 = 0)
  INTO v_expected_empty, v_expected_low, v_expected_safe, v_expected_rack_empty, v_expected_category
  FROM (
    SELECT s.n,
      CASE WHEN s.n % 10 IN (0, 1) THEN 0 WHEN s.n % 10 IN (2, 3, 4) THEN 3 ELSE 8 END AS q,
      CASE WHEN s.n % 4 = 0 THEN 0 ELSE 5 END AS minimum_stock
    FROM generate_series(1, 5095) AS s(n)
  ) AS synthetic;
  v_expected_safe := v_expected_safe + 8;

  v_result := public.stock_workspace_read_page(v_outlet, NULL, 'ALL', false, NULL, 1, 50);
  IF jsonb_array_length(v_result -> 'rows') <> 50
     OR (v_result #>> '{pagination,filtered_total}')::bigint <> 5103
     OR (v_result #>> '{pagination,page_count}')::integer <> 103
     OR (v_result #>> '{summary,total}')::bigint <> 5103
     OR (v_result #>> '{summary,empty}')::bigint <> v_expected_empty
     OR (v_result #>> '{summary,low}')::bigint <> v_expected_low
     OR (v_result #>> '{summary,safe}')::bigint <> v_expected_safe
     OR (v_result #>> '{summary,total}')::bigint <>
       (v_result #>> '{summary,empty}')::bigint
       + (v_result #>> '{summary,low}')::bigint
       + (v_result #>> '{summary,safe}')::bigint
     OR (v_result #>> '{integrity,missing_projection_count}')::bigint <> 1 THEN
    RAISE EXCEPTION 'Default 5,103-row result, status summary, or missing projection integrity is incorrect';
  END IF;
  IF (v_result #> '{rows,0}') ?| ARRAY['hpp', 'cost', 'profit', 'quantity'] THEN
    RAISE EXCEPTION 'Scale RPC response contains a forbidden financial or snapshot quantity field';
  END IF;

  v_result := public.stock_workspace_read_page(v_outlet, NULL, 'ALL', false, NULL, 2, 50);
  IF jsonb_array_length(v_result -> 'rows') <> 50 OR (v_result #>> '{pagination,page}')::integer <> 2 THEN
    RAISE EXCEPTION 'Scale page 2 result is incorrect';
  END IF;
  v_result := public.stock_workspace_read_page(v_outlet, NULL, 'ALL', false, NULL, 50, 50);
  IF jsonb_array_length(v_result -> 'rows') <> 50 OR (v_result #>> '{pagination,page}')::integer <> 50 THEN
    RAISE EXCEPTION 'Scale page 50 result is incorrect';
  END IF;

  v_result := public.stock_workspace_read_page(v_outlet, NULL, 'HABIS', false, NULL, 1, 50);
  IF (v_result #>> '{pagination,filtered_total}')::bigint <> v_expected_empty
     OR (v_result #>> '{summary,total}')::bigint <> 5103 THEN
    RAISE EXCEPTION 'HABIS filter or status-independent summary is incorrect at scale';
  END IF;
  v_result := public.stock_workspace_read_page(v_outlet, NULL, 'MENIPIS', false, NULL, 1, 50);
  IF (v_result #>> '{pagination,filtered_total}')::bigint <> v_expected_low THEN
    RAISE EXCEPTION 'MENIPIS filter is incorrect at scale';
  END IF;
  v_result := public.stock_workspace_read_page(v_outlet, NULL, 'AMAN', false, NULL, 1, 50);
  IF (v_result #>> '{pagination,filtered_total}')::bigint <> v_expected_safe THEN
    RAISE EXCEPTION 'AMAN filter is incorrect at scale';
  END IF;

  v_result := public.stock_workspace_read_page(v_outlet, NULL, 'ALL', true, NULL, 1, 50);
  IF (v_result #>> '{pagination,filtered_total}')::bigint <> v_expected_rack_empty
     OR (v_result #>> '{summary,total}')::bigint <> v_expected_rack_empty THEN
    RAISE EXCEPTION 'Rack-empty filter is incorrect at scale';
  END IF;
  v_result := public.stock_workspace_read_page(v_outlet, NULL, 'ALL', false, 'Scale-Category-1', 1, 50);
  IF (v_result #>> '{pagination,filtered_total}')::bigint <> v_expected_category
     OR (v_result #>> '{summary,total}')::bigint <> v_expected_category THEN
    RAISE EXCEPTION 'Category filter is incorrect at scale';
  END IF;

  v_result := public.stock_workspace_read_page(v_outlet, 'Stock Scale Product 00001', 'ALL', false, NULL, 1, 50);
  IF (v_result #>> '{pagination,filtered_total}')::bigint <> 1 THEN RAISE EXCEPTION 'Name search failed'; END IF;
  v_result := public.stock_workspace_read_page(v_outlet, 'SCALE-3C1B-00001', 'ALL', false, NULL, 1, 50);
  IF (v_result #>> '{pagination,filtered_total}')::bigint <> 1 THEN RAISE EXCEPTION 'SKU search failed'; END IF;
  v_result := public.stock_workspace_read_page(v_outlet, 'SCALEBC0000001', 'ALL', false, NULL, 1, 50);
  IF (v_result #>> '{pagination,filtered_total}')::bigint <> 1 THEN RAISE EXCEPTION 'Active barcode search failed'; END IF;
  v_result := public.stock_workspace_read_page(v_outlet, 'SCALEALIAS00001', 'ALL', false, NULL, 1, 50);
  IF (v_result #>> '{pagination,filtered_total}')::bigint <> 1
     OR jsonb_array_length(v_result -> 'rows') <> 1 THEN
    RAISE EXCEPTION 'Same-product barcode alias search multiplied or missed its product';
  END IF;

  v_result := public.stock_workspace_read_page(v_outlet, 'SCALE-3C1B-MISSING', 'ALL', false, NULL, 1, 50);
  IF jsonb_array_length(v_result -> 'rows') <> 0
     OR (v_result #>> '{pagination,filtered_total}')::bigint <> 0
     OR (v_result #>> '{summary,total}')::bigint <> 0
     OR (v_result #>> '{integrity,missing_projection_count}')::bigint <> 1 THEN
    RAISE EXCEPTION 'Missing projection was not excluded and reported separately';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.product_inventory AS i
    JOIN public.products AS p ON p.id = i.product_id
    WHERE i.outlet_id = v_outlet AND p.sku = 'SCALE-3C1B-MISSING' AND i.quantity = 8
  ) THEN
    RAISE EXCEPTION 'Missing-projection control product must have a nonnull inventory snapshot quantity';
  END IF;

  RAISE NOTICE 'Correctness passed: memberships=5104 usable_projections=5103 status_counts=(%,%,%) rack_empty=% category1=%',
    v_expected_empty, v_expected_low, v_expected_safe, v_expected_rack_empty, v_expected_category;
END;
$scale_correctness$;

-- Show actual end-to-end RPC timing/buffers. Plain EXPLAIN around a PL/pgSQL
-- function reports invocation-level work; the prepared relational query below
-- exposes row-query scans/joins and its correlated barcode lookup.
\echo === PERFORMANCE A: default RPC call ===
SELECT jsonb_array_length(r -> 'rows') AS returned_rows,
       r #>> '{pagination,filtered_total}' AS filtered_total,
       r #>> '{summary,total}' AS summary_total
FROM (SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, NULL, 'ALL', false, NULL, 1, 50) AS r) AS call;
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, NULL, 'ALL', false, NULL, 1, 50);

PREPARE stock_scale_row_plan(uuid, text, text, boolean, text, integer, integer) AS
WITH membership AS MATERIALIZED (
  SELECT i.product_id, p.name, p.sku, p.category_label AS category, os.rack_label AS rack,
         i.minimum_quantity AS minimum_stock, bp.effective_quantity,
         (bp.product_id IS NOT NULL AND bp.effective_quantity IS NOT NULL) AS projection_usable,
         (SELECT b.barcode FROM public.product_barcodes AS b
          WHERE b.product_id = i.product_id AND b.is_active
          ORDER BY b.created_at, b.id LIMIT 1) AS barcode
  FROM public.product_inventory AS i
  JOIN public.products AS p ON p.id = i.product_id
  LEFT JOIN public.stock_balance_projection AS bp
    ON bp.product_id = i.product_id AND bp.outlet_id = i.outlet_id
  LEFT JOIN public.product_outlet_settings AS os
    ON os.product_id = i.product_id AND os.outlet_id = i.outlet_id
  WHERE i.outlet_id = $1
), matching AS MATERIALIZED (
  SELECT m.* FROM membership AS m
  WHERE ($2 IS NULL OR m.name ILIKE '%' || $2 || '%' OR m.sku ILIKE '%' || $2 || '%'
    OR EXISTS (SELECT 1 FROM public.product_barcodes AS bx
      WHERE bx.product_id = m.product_id AND bx.is_active AND bx.barcode ILIKE '%' || $2 || '%'))
    AND ($5 IS NULL OR m.category = $5)
    AND (NOT coalesce($4, false) OR nullif(btrim(m.rack), '') IS NULL)
), classified AS MATERIALIZED (
  SELECT m.*, CASE WHEN m.effective_quantity = 0 THEN 'HABIS'
    WHEN coalesce(m.minimum_stock, 0) > 0 AND m.effective_quantity <= m.minimum_stock THEN 'MENIPIS'
    ELSE 'AMAN' END AS stock_status
  FROM matching AS m WHERE m.projection_usable
)
SELECT c.product_id, c.name, c.sku, c.barcode, c.category, c.rack,
       c.effective_quantity, c.minimum_stock, c.stock_status
FROM classified AS c
WHERE $3 = 'ALL' OR c.stock_status = $3
ORDER BY c.name COLLATE "C", c.sku COLLATE "C", c.product_id
LIMIT least(greatest(coalesce($7, 50), 1), 50)
OFFSET (greatest(coalesce($6, 1), 1) - 1) * least(greatest(coalesce($7, 50), 1), 50);

\echo === PERFORMANCE B1: page 2 ===
SELECT jsonb_array_length(r -> 'rows') AS returned_rows, r #>> '{pagination,filtered_total}' AS filtered_total
FROM (SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, NULL, 'ALL', false, NULL, 2, 50) AS r) AS call;
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, NULL, 'ALL', false, NULL, 2, 50);
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
EXECUTE stock_scale_row_plan(:'scale_outlet_id'::uuid, NULL, 'ALL', false, NULL, 2, 50);

\echo === PERFORMANCE B2: page 50 ===
SELECT jsonb_array_length(r -> 'rows') AS returned_rows, r #>> '{pagination,filtered_total}' AS filtered_total
FROM (SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, NULL, 'ALL', false, NULL, 50, 50) AS r) AS call;
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, NULL, 'ALL', false, NULL, 50, 50);
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
EXECUTE stock_scale_row_plan(:'scale_outlet_id'::uuid, NULL, 'ALL', false, NULL, 50, 50);

\echo === PERFORMANCE C: HABIS ===
SELECT jsonb_array_length(r -> 'rows') AS returned_rows, r #>> '{pagination,filtered_total}' AS filtered_total
FROM (SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, NULL, 'HABIS', false, NULL, 1, 50) AS r) AS call;
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, NULL, 'HABIS', false, NULL, 1, 50);
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
EXECUTE stock_scale_row_plan(:'scale_outlet_id'::uuid, NULL, 'HABIS', false, NULL, 1, 50);

\echo === PERFORMANCE D: MENIPIS ===
SELECT jsonb_array_length(r -> 'rows') AS returned_rows, r #>> '{pagination,filtered_total}' AS filtered_total
FROM (SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, NULL, 'MENIPIS', false, NULL, 1, 50) AS r) AS call;
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, NULL, 'MENIPIS', false, NULL, 1, 50);
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
EXECUTE stock_scale_row_plan(:'scale_outlet_id'::uuid, NULL, 'MENIPIS', false, NULL, 1, 50);

\echo === PERFORMANCE E: rack_empty ===
SELECT jsonb_array_length(r -> 'rows') AS returned_rows, r #>> '{pagination,filtered_total}' AS filtered_total
FROM (SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, NULL, 'ALL', true, NULL, 1, 50) AS r) AS call;
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, NULL, 'ALL', true, NULL, 1, 50);
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
EXECUTE stock_scale_row_plan(:'scale_outlet_id'::uuid, NULL, 'ALL', true, NULL, 1, 50);

\echo === PERFORMANCE F1: selective name/SKU search ===
SELECT jsonb_array_length(r -> 'rows') AS returned_rows, r #>> '{pagination,filtered_total}' AS filtered_total
FROM (SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, 'Stock Scale Product 00001', 'ALL', false, NULL, 1, 50) AS r) AS call;
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, 'Stock Scale Product 00001', 'ALL', false, NULL, 1, 50);
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
EXECUTE stock_scale_row_plan(:'scale_outlet_id'::uuid, 'Stock Scale Product 00001', 'ALL', false, NULL, 1, 50);
SELECT jsonb_array_length(r -> 'rows') AS returned_rows, r #>> '{pagination,filtered_total}' AS filtered_total
FROM (SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, 'SCALE-3C1B-00001', 'ALL', false, NULL, 1, 50) AS r) AS call;
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, 'SCALE-3C1B-00001', 'ALL', false, NULL, 1, 50);
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
EXECUTE stock_scale_row_plan(:'scale_outlet_id'::uuid, 'SCALE-3C1B-00001', 'ALL', false, NULL, 1, 50);

\echo === PERFORMANCE G: active barcode alias search ===
SELECT jsonb_array_length(r -> 'rows') AS returned_rows, r #>> '{pagination,filtered_total}' AS filtered_total
FROM (SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, 'SCALEALIAS00001', 'ALL', false, NULL, 1, 50) AS r) AS call;
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
SELECT public.stock_workspace_read_page(:'scale_outlet_id'::uuid, 'SCALEALIAS00001', 'ALL', false, NULL, 1, 50);
EXPLAIN (ANALYZE, BUFFERS, COSTS, SUMMARY)
EXECUTE stock_scale_row_plan(:'scale_outlet_id'::uuid, 'SCALEALIAS00001', 'ALL', false, NULL, 1, 50);

DEALLOCATE stock_scale_row_plan;
RESET ROLE;
ROLLBACK;
\echo 'PASS: ~5,103-product synthetic Stock workspace scale assertions completed; all fixture/import/projection changes rolled back'
