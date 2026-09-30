-- Read-only staging verification. No writes or migration execution.
DO $guard$
BEGIN
  IF current_database() <> 'quena_stock_staging'
     OR coalesce(host(inet_server_addr()), '') NOT IN ('127.0.0.1', '::1')
     OR inet_server_port() <> 5432
     OR current_setting('server_version_num')::integer / 10000 <> 15
     OR current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'Refusing verification outside local UTF8 PostgreSQL 15 quena_stock_staging';
  END IF;
END;
$guard$;

SELECT current_database() AS database_name,
       version() AS server_version,
       current_user AS connected_role,
       inet_server_addr() AS server_address,
       inet_server_port() AS server_port;

SELECT ordinal, version, filename, applied_at
FROM quena_staging.applied_migrations
ORDER BY ordinal;

SELECT fixture_key, seeded_at
FROM quena_staging.fixture_runs;

SELECT count(*) AS synthetic_inventory_rows,
       count(DISTINCT product_id) AS synthetic_products,
       count(DISTINCT outlet_id) AS synthetic_outlets,
       count(*) FILTER (WHERE quantity IS NULL) AS null_quantity_rows,
       count(*) FILTER (WHERE source_import_row_id IS NULL) AS missing_source_rows
FROM public.product_inventory;

SELECT to_regclass('public.stock_authority_periods') IS NOT NULL AS stock_migration_applied \gset
\if :stock_migration_applied
SELECT count(*) AS projection_rows,
       count(*) FILTER (WHERE baseline_quantity = i.quantity) AS matching_bootstrap_rows,
       count(*) FILTER (WHERE baseline_source_import_row_id = i.source_import_row_id) AS matching_source_rows,
       count(*) FILTER (WHERE effective_quantity = i.quantity) AS unchanged_effective_rows
FROM public.stock_balance_projection p
JOIN public.product_inventory i USING (product_id, outlet_id);
\else
\echo 'Stock foundation migration is not applied; projection checks skipped.'
\endif
