WITH expected_migrations(version) AS (
  VALUES
    ('20260928'), ('20260928115000'), ('20260928143000'),
    ('20260929100000'), ('20260929130000'), ('20260929150000'),
    ('20260929160000'), ('20260929170000'), ('20260929171000')
),
expected_functions(signature, proname) AS (
  VALUES
    ('public.issue_product_field_correction_intent(uuid,uuid,text,uuid,jsonb,text,text)', 'issue_product_field_correction_intent'),
    ('public.apply_product_field_correction_payload(uuid,uuid,uuid,text,jsonb,text,uuid,text)', 'apply_product_field_correction_payload'),
    ('public.apply_product_field_correction_intent(uuid)', 'apply_product_field_correction_intent'),
    ('public.apply_product_field_correction(uuid,uuid,uuid,text,jsonb,text,uuid,text)', 'apply_product_field_correction')
),
resolved_functions AS (
  SELECT e.signature, e.proname, to_regprocedure(e.signature)::oid AS function_oid
  FROM expected_functions e
),
function_security AS (
  SELECT r.*,
         p.proowner,
         p.prosecdef,
         p.proconfig,
         p.proacl,
         p.oid,
         has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
         has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
         has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute,
         (
           SELECT count(*)
           FROM pg_catalog.pg_proc p2
           WHERE p2.pronamespace = 'public'::regnamespace
             AND p2.proname = r.proname
         ) AS same_name_functions,
         NOT EXISTS (
           SELECT 1
           FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
           WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'
         ) AS public_execute_revoked
  FROM resolved_functions r
  LEFT JOIN pg_catalog.pg_proc p ON p.oid = r.function_oid
),
function_definitions AS (
  SELECT
    lower(regexp_replace(pg_get_functiondef(p.oid), '[[:space:]]+', ' ', 'g')) AS issue_definition
  FROM pg_catalog.pg_proc p
  WHERE p.oid = to_regprocedure(
    'public.issue_product_field_correction_intent(uuid,uuid,text,uuid,jsonb,text,text)'
  )::oid
),
payload_definition AS (
  SELECT
    lower(regexp_replace(pg_get_functiondef(p.oid), '[[:space:]]+', ' ', 'g')) AS payload_definition
  FROM pg_catalog.pg_proc p
  WHERE p.oid = to_regprocedure(
    'public.apply_product_field_correction_payload(uuid,uuid,uuid,text,jsonb,text,uuid,text)'
  )::oid
),
ledger AS (
  SELECT
    ARRAY(SELECT version::text FROM supabase_migrations.schema_migrations ORDER BY version::text) AS actual_versions,
    ARRAY(SELECT version FROM expected_migrations ORDER BY version) AS expected_versions
),
planned_stock_relations(relname) AS (
  VALUES
    ('stock_authority_periods'), ('stock_balance_projection'),
    ('stock_balance_baseline_events'), ('stock_operation_requests'),
    ('stock_opname_sessions'), ('stock_opname_items'),
    ('stock_opname_count_events'), ('stock_opname_session_events'),
    ('stock_movement_batches'), ('stock_movements'),
    ('stock_movement_source_reconciliations'), ('stock_balance_projection_events')
),
stock_relation_state AS (
  SELECT count(*) FILTER (WHERE to_regclass('public.' || relname) IS NOT NULL) AS existing_relations
  FROM planned_stock_relations
),
stock_type_state AS (
  SELECT count(*) AS existing_types
  FROM pg_catalog.pg_type t
  JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public'
    AND t.typname IN (
      'stock_authority_mode', 'stock_movement_type', 'stock_movement_source',
      'stock_opname_scope', 'stock_opname_status', 'stock_count_event_type',
      'stock_opname_event_type', 'stock_request_state'
    )
),
data_counts AS (
  SELECT
    (SELECT count(*) FROM public.product_inventory) AS inventory_rows,
    (SELECT count(*) FROM public.product_inventory_history) AS inventory_history_rows,
    (SELECT count(*) FROM public.product_barcodes WHERE is_active) AS active_barcode_rows,
    (SELECT count(*) FROM public.product_field_correction_requests) AS correction_request_rows,
    (SELECT count(*) FROM public.product_field_correction_intents) AS correction_intent_rows
),
checks AS (
  SELECT
    'migration_ledger'::text AS check_name,
    CASE WHEN l.actual_versions = l.expected_versions THEN 'PASS' ELSE 'FAIL' END AS status,
    array_to_string(l.actual_versions, ', ') AS actual,
    array_to_string(l.expected_versions, ', ') AS expected
  FROM ledger l

  UNION ALL
  SELECT
    'function_signatures_and_overloads',
    CASE WHEN count(*) = 4
           AND bool_and(function_oid IS NOT NULL)
           AND bool_and(same_name_functions = 1)
         THEN 'PASS' ELSE 'FAIL' END,
    'resolved=' || count(*) FILTER (WHERE function_oid IS NOT NULL)::text ||
      '/4; overloads=' || coalesce(sum(same_name_functions - 1), 0)::text,
    'four exact signatures; no same-name overloads'
  FROM function_security

  UNION ALL
  SELECT
    'function_security_and_grants',
    CASE WHEN bool_and(pg_get_userbyid(proowner) = 'postgres')
           AND bool_and(prosecdef)
           AND bool_and(proconfig @> ARRAY['search_path=pg_catalog']::text[])
           AND bool_and(public_execute_revoked)
           AND bool_and(NOT anon_execute)
           AND bool_and(NOT service_role_execute)
           AND bool_and(
             CASE
               WHEN proname IN ('issue_product_field_correction_intent',
                                'apply_product_field_correction_intent',
                                'apply_product_field_correction')
                 THEN authenticated_execute
               ELSE NOT authenticated_execute
             END
           )
         THEN 'PASS' ELSE 'FAIL' END,
    'all four functions checked; helper is private',
    'postgres owner; SECURITY DEFINER; search_path=pg_catalog; authenticated only on public RPCs'
  FROM function_security

  UNION ALL
  SELECT
    'ambiguity_fixes_present',
    CASE WHEN
      EXISTS (
        SELECT 1 FROM function_definitions
        WHERE position('v_actor_id uuid := auth.uid()' IN issue_definition) > 0
          AND position('v_request_payload jsonb' IN issue_definition) > 0
          AND position('i.actor_id=issue_correction_intent_block.v_actor_id' IN issue_definition) > 0
          AND position('i.request_payload=issue_correction_intent_block.v_request_payload' IN issue_definition) > 0
      )
      AND EXISTS (
        SELECT 1 FROM payload_definition
        WHERE regexp_count(payload_definition,
          'update public[.]product_field_correction_intents as pci') = 2
          AND regexp_count(payload_definition,
            'pci[.]actor_id[[:space:]]*=[[:space:]]*apply_correction_payload_block[.]actor_id') = 2
      )
      THEN 'PASS' ELSE 'FAIL' END,
    'issuer locals renamed; helper completion UPDATEs table-qualified',
    'issuer and both shared-helper completion paths contain the forward fix'

  UNION ALL
  SELECT
    'stock_migration_180000_absent',
    CASE WHEN
      (SELECT count(*) FROM supabase_migrations.schema_migrations
       WHERE version::text = '20260929180000') = 0
      AND srs.existing_relations = 0
      AND sts.existing_types = 0
      AND to_regprocedure('public.apply_stock_operation_intent(uuid)') IS NULL
      THEN 'PASS' ELSE 'FAIL' END,
    'migration_180000=' ||
      (SELECT count(*)::text FROM supabase_migrations.schema_migrations
       WHERE version::text = '20260929180000') ||
      '; stock_relations=' || srs.existing_relations::text ||
      '; stock_types=' || sts.existing_types::text,
    'migration, planned stock relations/types, and stock RPC absent'
  FROM stock_relation_state srs CROSS JOIN stock_type_state sts

  UNION ALL
  SELECT
    'read_only_data_counts',
    'REVIEW',
    'inventory=' || inventory_rows::text ||
      '; inventory_history=' || inventory_history_rows::text ||
      '; active_barcodes=' || active_barcode_rows::text ||
      '; correction_requests=' || correction_request_rows::text ||
      '; correction_intents=' || correction_intent_rows::text,
    'compare with captured pre-deployment counts; migration 171000 contains no data DML'
  FROM data_counts
)
SELECT check_name, status, actual, expected
FROM checks
ORDER BY check_name;
