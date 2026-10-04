-- Read-only preflight for migration 20260929200000.
-- Before running this query, verify the SQL Editor is open at the Dashboard
-- project URL ending in /project/giwuzemjmimuvhtvjfhq and confirm that ref in
-- Project Settings. PostgreSQL catalogs do not expose a dependable project ref.
WITH expected_migrations(version) AS (
  VALUES
    ('20260928'), ('20260928115000'), ('20260928143000'),
    ('20260929100000'), ('20260929130000'), ('20260929150000'),
    ('20260929160000'), ('20260929170000'), ('20260929171000'),
    ('20260929180000'), ('20260929190000')
),
actual_migrations(version) AS (
  SELECT version::text FROM supabase_migrations.schema_migrations
),
ledger_state AS (
  SELECT
    ARRAY(SELECT version FROM actual_migrations ORDER BY version) AS actual_versions,
    ARRAY(SELECT version FROM expected_migrations ORDER BY version) AS expected_versions,
    (SELECT count(*) FROM actual_migrations WHERE version = '20260929190000') AS version_190000_count,
    (SELECT count(*) FROM actual_migrations WHERE version = '20260929200000') AS version_200000_count
),
workspace_function AS (
  SELECT p.oid, p.proowner, p.prosecdef, p.proconfig, p.proacl,
         has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
         has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
         has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute,
         coalesce((SELECT count(*) FROM pg_catalog.pg_proc p2
           WHERE p2.pronamespace = 'public'::regnamespace
             AND p2.proname = 'stock_workspace_read_page'), 0) AS same_name_count,
         lower(regexp_replace(pg_catalog.pg_get_functiondef(p.oid), '[[:space:]]+', ' ', 'g')) AS definition,
         NOT EXISTS (
           SELECT 1 FROM pg_catalog.aclexplode(coalesce(p.proacl,
             pg_catalog.acldefault('f', p.proowner))) a
           WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'
         ) AS public_execute_revoked
  FROM (SELECT to_regprocedure(
    'public.stock_workspace_read_page(uuid,text,text,boolean,text,integer,integer)'
  )::oid AS function_oid) expected
  LEFT JOIN pg_catalog.pg_proc p ON p.oid = expected.function_oid
),
pending_revision_requests AS (
  SELECT count(*) AS pending_count,
         count(*) FILTER (WHERE NOT (request_payload ? 'expected_revision')) AS legacy_count
  FROM public.stock_operation_requests
  WHERE operation_key IN ('REBASE_ITEM', 'REVIEW_EXCEPTION')
    AND state = 'PENDING'
),
data_snapshot AS (
  SELECT
    (SELECT count(*) FROM public.product_inventory) AS inventory_rows,
    (SELECT count(*) FROM public.product_inventory_history) AS inventory_history_rows,
    (SELECT count(*) FROM public.stock_balance_projection) AS projection_rows,
    (SELECT count(*) FROM public.stock_movements) AS movement_rows,
    (SELECT count(*) FROM public.stock_opname_sessions) AS opname_session_rows,
    (SELECT count(*) FROM public.stock_opname_items) AS opname_item_rows,
    (SELECT count(*) FROM public.stock_opname_count_events) AS count_event_rows,
    (SELECT count(*) FROM public.stock_operation_requests) AS operation_request_rows
),
checks(check_order, check_name, status, actual, expected, detail) AS (
  SELECT 1, 'project_ref_manual_confirmation', 'REVIEW',
         'Confirm Dashboard URL project ref = giwuzemjmimuvhtvjfhq',
         'giwuzemjmimuvhtvjfhq',
         'Do not run from another project tab; SQL catalog data cannot prove the Supabase project ref.'
  UNION ALL
  SELECT 2, 'database_context',
         CASE WHEN current_database() = 'postgres' AND current_setting('server_version_num')::integer / 10000 >= 15 THEN 'PASS' ELSE 'FAIL' END,
         current_database() || ' / PostgreSQL ' || current_setting('server_version'),
         'postgres / PostgreSQL 15 or later',
         'Cross-check the target project in the Dashboard before proceeding.'
  UNION ALL
  SELECT 3, 'migration_ledger_through_190000',
         CASE WHEN l.actual_versions = l.expected_versions AND l.version_190000_count = 1 THEN 'PASS' ELSE 'FAIL' END,
         array_to_string(l.actual_versions, ', '), array_to_string(l.expected_versions, ', '),
         'Complete chain must match exactly; missing or unexpected versions block deployment.'
  FROM ledger_state l
  UNION ALL
  SELECT 4, 'migration_200000_absent',
         CASE WHEN l.version_200000_count = 0
                AND to_regprocedure('public.stock_opname_progress_counts(uuid)') IS NULL
              THEN 'PASS' ELSE 'FAIL' END,
         'ledger rows=' || l.version_200000_count::text || '; progress RPC=' ||
           CASE WHEN to_regprocedure('public.stock_opname_progress_counts(uuid)') IS NULL THEN 'absent' ELSE 'present' END,
         '200000 absent from ledger and progress RPC absent',
         'If either is present, stop and investigate; do not replay migration SQL.'
  FROM ledger_state l
  UNION ALL
  SELECT 5, '190000_workspace_contract',
         CASE WHEN w.oid IS NOT NULL
                AND pg_catalog.pg_get_userbyid(w.proowner) = 'postgres'
                AND NOT w.prosecdef
                AND w.proconfig = ARRAY['search_path=pg_catalog, public']::text[]
                AND w.authenticated_execute AND NOT w.anon_execute
                AND NOT w.service_role_execute AND w.public_execute_revoked
                AND w.same_name_count = 1
                AND position('bp.effective_quantity' IN w.definition) > 0
                AND position('product_inventory' IN w.definition) > 0
                AND position('i.quantity' IN w.definition) = 0
                AND position('hpp' IN w.definition) = 0
                AND position('profit' IN w.definition) = 0
              THEN 'PASS' ELSE 'FAIL' END,
         CASE WHEN w.oid IS NULL THEN 'exact function absent' ELSE
           'owner=' || pg_catalog.pg_get_userbyid(w.proowner) ||
           '; invoker=' || (NOT w.prosecdef)::text ||
           '; search_path=' || coalesce(array_to_string(w.proconfig, ','), '<unset>') ||
           '; overloads=' || w.same_name_count::text END,
         'stock_workspace_read_page(uuid,text,text,boolean,text,integer,integer): postgres, INVOKER, search_path=pg_catalog, public, authenticated only',
         'Expected deployed 190000 contract must be intact before replacing shared stock operation functions.'
  FROM (SELECT * FROM workspace_function) w
  UNION ALL
  SELECT 6, 'pending_revision_operations',
         CASE WHEN p.pending_count = 0 THEN 'PASS' ELSE 'FAIL' END,
         'pending REBASE_ITEM/REVIEW_EXCEPTION=' || p.pending_count::text ||
           '; missing expected_revision=' || p.legacy_count::text,
         '0 pending revision operations',
         'Any pending request in either operation is unexpected for this pre-UI deployment; inspect safely before proceeding.'
  FROM pending_revision_requests p
  UNION ALL
  SELECT 7, 'production_data_predeploy_snapshot', 'REVIEW',
         'inventory=' || inventory_rows::text || '; inventory_history=' || inventory_history_rows::text ||
           '; projection=' || projection_rows::text || '; movements=' || movement_rows::text ||
           '; opname_sessions=' || opname_session_rows::text || '; opname_items=' || opname_item_rows::text ||
           '; count_events=' || count_event_rows::text || '; operation_requests=' || operation_request_rows::text,
         'Capture these informational counts for post-deployment comparison.',
         'No row mutation is part of preflight or migration 200000.'
  FROM data_snapshot
)
SELECT check_order, check_name, status, actual, expected, detail
FROM checks
ORDER BY check_order;
