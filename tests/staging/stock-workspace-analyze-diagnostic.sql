-- Appended by run-stock-workspace-analyze-diagnostic.sh to the existing
-- transaction-scoped synthetic scale fixture. This performs one identical
-- relational EXPLAIN before/after ANALYZE and then rolls back the fixture.
\set ON_ERROR_STOP on

SELECT con.conname AS constraint_name,
       CASE con.contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'u' THEN 'UNIQUE' ELSE con.contype::text END AS constraint_type,
       pg_catalog.pg_get_constraintdef(con.oid, true) AS constraint_definition
FROM pg_catalog.pg_constraint AS con
JOIN pg_catalog.pg_class AS rel ON rel.oid = con.conrelid
JOIN pg_catalog.pg_namespace AS ns ON ns.oid = rel.relnamespace
WHERE ns.nspname = 'public'
  AND rel.relname = 'product_outlet_settings'
ORDER BY con.contype, con.conname;

SELECT idx.indexname, idx.indexdef
FROM pg_catalog.pg_indexes AS idx
WHERE idx.schemaname = 'public'
  AND idx.tablename = 'product_outlet_settings'
ORDER BY idx.indexname;

SELECT att.attnum AS column_order,
       att.attname AS column_name,
       pg_catalog.format_type(att.atttypid, att.atttypmod) AS data_type,
       att.attnotnull AS not_null
FROM pg_catalog.pg_attribute AS att
JOIN pg_catalog.pg_class AS rel ON rel.oid = att.attrelid
JOIN pg_catalog.pg_namespace AS ns ON ns.oid = rel.relnamespace
WHERE ns.nspname = 'public'
  AND rel.relname = 'product_outlet_settings'
  AND att.attnum > 0
  AND NOT att.attisdropped
ORDER BY att.attnum;

SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true) AS scale_owner_claim \gset
SET LOCAL ROLE authenticated;

DO $analyze_fixture_check$
DECLARE
  v_outlet uuid := current_setting('quena.stock_scale_outlet_id')::uuid;
BEGIN
  IF auth.uid() IS DISTINCT FROM 'a0000000-0000-4000-8000-000000000001'::uuid
     OR public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION 'Diagnostic must run relational plans as authenticated OWNER';
  END IF;
  IF (SELECT count(*) FROM public.product_inventory WHERE outlet_id = v_outlet) <> 5104 THEN
    RAISE EXCEPTION 'Diagnostic fixture must contain 5,104 outlet memberships';
  END IF;
  IF (SELECT count(*) FROM public.stock_balance_projection
      WHERE outlet_id = v_outlet AND effective_quantity IS NOT NULL) <> 5103 THEN
    RAISE EXCEPTION 'Diagnostic fixture must contain 5,103 usable projections';
  END IF;
END;
$analyze_fixture_check$;

PREPARE stock_workspace_analyze_plan(uuid, text, text, boolean, text, integer, integer) AS
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

\echo === PLAN BEFORE ANALYZE: default stock page; inspect product_inventory estimate vs actual, settings join/index/loops, join-filter removals, buffers, and execution time ===
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, COSTS, SUMMARY)
EXECUTE stock_workspace_analyze_plan(:'scale_outlet_id'::uuid, NULL, 'ALL', false, NULL, 1, 50);

RESET ROLE;
ANALYZE public.product_inventory;
ANALYZE public.product_outlet_settings;
ANALYZE public.stock_balance_projection;
ANALYZE public.product_barcodes;
ANALYZE public.products;

SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true) AS scale_owner_claim_after_analyze \gset
SET LOCAL ROLE authenticated;

\echo === PLAN AFTER ANALYZE: exact same prepared query and parameters ===
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, COSTS, SUMMARY)
EXECUTE stock_workspace_analyze_plan(:'scale_outlet_id'::uuid, NULL, 'ALL', false, NULL, 1, 50);

RESET ROLE;
DEALLOCATE stock_workspace_analyze_plan;
ROLLBACK;
\echo 'PASS: before/after ANALYZE diagnostic completed; synthetic data transaction rolled back'
