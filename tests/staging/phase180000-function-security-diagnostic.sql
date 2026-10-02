-- Read-only per-function diagnostic for Phase 180000 gate 10.
-- Effective privilege functions include PUBLIC grants and inherited role membership.
WITH expected_functions(signature, proname, expected_authenticated_execute, expected_prosecdef, expected_search_path) AS (
  VALUES
    ('public.validate_stock_movement_reversal()'::text, 'validate_stock_movement_reversal'::text, false, true, ARRAY['search_path=pg_catalog']::text[]),
    ('public.refresh_stock_balance_from_ipos_inventory()'::text, 'refresh_stock_balance_from_ipos_inventory'::text, false, true, ARRAY['search_path=pg_catalog']::text[]),
    ('public.reject_stock_ledger_mutation()'::text, 'reject_stock_ledger_mutation'::text, false, false, ARRAY['search_path=pg_catalog']::text[]),
    ('public.guard_posted_stock_opname()'::text, 'guard_posted_stock_opname'::text, false, false, ARRAY['search_path=pg_catalog']::text[]),
    ('public.guard_posted_stock_opname_item()'::text, 'guard_posted_stock_opname_item'::text, false, false, ARRAY['search_path=pg_catalog']::text[]),
    ('public.stock_apply_balance_delta(uuid,uuid,numeric)'::text, 'stock_apply_balance_delta'::text, false, true, ARRAY['search_path=pg_catalog']::text[]),
    ('public.stock_opname_content_hash(uuid)'::text, 'stock_opname_content_hash'::text, false, true, ARRAY['search_path=pg_catalog']::text[]),
    ('public.issue_stock_operation_intent(text,jsonb)'::text, 'issue_stock_operation_intent'::text, true, true, ARRAY['search_path=pg_catalog']::text[]),
    ('public.read_stock_operation_intent(uuid)'::text, 'read_stock_operation_intent'::text, true, true, ARRAY['search_path=pg_catalog']::text[]),
    -- This RPC is intentionally SECURITY INVOKER with the public schema in its fixed path.
    ('public.resolve_stock_barcode(uuid,text)'::text, 'resolve_stock_barcode'::text, true, false, ARRAY['search_path=pg_catalog, public']::text[]),
    ('public.apply_stock_operation_intent(uuid)'::text, 'apply_stock_operation_intent'::text, true, true, ARRAY['search_path=pg_catalog']::text[])
), resolved AS (
  SELECT e.signature, e.proname, e.expected_authenticated_execute,
         e.expected_prosecdef, e.expected_search_path,
         p.oid AS function_oid, p.prosecdef AS actual_prosecdef,
         p.proconfig AS actual_proconfig, p.proowner AS owner_oid, p.proacl AS function_acl,
         pg_catalog.pg_get_userbyid(p.proowner) AS owner_name,
         (SELECT count(*) FROM pg_catalog.pg_proc p2
          WHERE p2.pronamespace = 'public'::regnamespace AND p2.proname = e.proname) AS same_name_overload_count
  FROM expected_functions e
  LEFT JOIN pg_catalog.pg_proc p ON p.oid = pg_catalog.to_regprocedure(e.signature)::oid
), privileges AS (
  SELECT r.signature, r.proname, r.expected_authenticated_execute,
         r.expected_prosecdef, r.expected_search_path,
         r.function_oid, r.actual_prosecdef, r.actual_proconfig,
         r.owner_oid, r.function_acl, r.owner_name, r.same_name_overload_count,
         CASE WHEN r.function_oid IS NULL THEN false ELSE pg_catalog.has_function_privilege('authenticated', r.function_oid, 'EXECUTE') END AS actual_authenticated_execute,
         CASE WHEN r.function_oid IS NULL THEN false ELSE pg_catalog.has_function_privilege('anon', r.function_oid, 'EXECUTE') END AS anon_execute_effective,
         CASE WHEN r.function_oid IS NULL THEN false ELSE pg_catalog.has_function_privilege('service_role', r.function_oid, 'EXECUTE') END AS service_role_execute_effective,
         CASE WHEN r.function_oid IS NULL THEN false ELSE EXISTS (
           SELECT 1 FROM pg_catalog.aclexplode(coalesce(r.function_acl, pg_catalog.acldefault('f', r.owner_oid))) AS acl_entry
           WHERE acl_entry.grantee = 0 AND acl_entry.privilege_type = 'EXECUTE'
         ) END AS public_execute_acl
  FROM resolved r
)
SELECT v.signature,
       v.function_oid IS NOT NULL AS function_exists,
       CASE WHEN v.actual_prosecdef THEN 'SECURITY DEFINER' WHEN v.function_oid IS NOT NULL THEN 'SECURITY INVOKER' ELSE 'MISSING' END AS actual_security_mode,
       coalesce(v.actual_proconfig, ARRAY[]::text[]) AS actual_proconfig_search_path,
       v.owner_name,
       v.public_execute_acl AS public_execute,
       v.anon_execute_effective AS anon_execute,
       v.actual_authenticated_execute AS authenticated_execute,
       v.expected_authenticated_execute,
       v.service_role_execute_effective AS service_role_execute,
       v.same_name_overload_count,
       coalesce(v.actual_prosecdef = v.expected_prosecdef, false) AS migration_security_mode_matches,
       coalesce(v.actual_proconfig @> v.expected_search_path, false) AS migration_search_path_matches,
       coalesce(v.function_oid IS NOT NULL AND v.owner_name = 'postgres', false) AS postgres_owner,
       coalesce(v.actual_authenticated_execute = v.expected_authenticated_execute, false) AS authenticated_grant_matches,
       coalesce(NOT v.public_execute_acl, false) AS public_execute_denied,
       coalesce(NOT v.anon_execute_effective, false) AS anon_execute_denied,
       coalesce(NOT v.service_role_execute_effective, false) AS service_role_execute_denied,
       coalesce(v.actual_prosecdef = v.expected_prosecdef, false) AS gate10_security_mode_pass,
       coalesce(v.actual_proconfig @> v.expected_search_path, false) AS gate10_search_path_pass,
       (
         v.function_oid IS NOT NULL
         AND v.same_name_overload_count = 1
         AND v.actual_prosecdef = v.expected_prosecdef
         AND v.actual_proconfig @> v.expected_search_path
         AND v.owner_name = 'postgres'
         AND NOT v.public_execute_acl
         AND NOT v.anon_execute_effective
         AND v.actual_authenticated_execute = v.expected_authenticated_execute
         AND NOT v.service_role_execute_effective
       ) AS migration_contract_pass,
       (
         v.function_oid IS NOT NULL
         AND v.same_name_overload_count = 1
         AND v.actual_prosecdef = v.expected_prosecdef
         AND v.actual_proconfig @> v.expected_search_path
         AND v.owner_name = 'postgres'
         AND NOT v.public_execute_acl
         AND NOT v.anon_execute_effective
         AND v.actual_authenticated_execute = v.expected_authenticated_execute
         AND NOT v.service_role_execute_effective
       ) AS current_gate10_predicate_pass,
       array_to_string(array_remove(ARRAY[
         CASE WHEN v.function_oid IS NULL THEN 'FUNCTION_MISSING' END,
         CASE WHEN v.same_name_overload_count IS DISTINCT FROM 1 THEN 'UNEXPECTED_OVERLOAD_COUNT' END,
         CASE WHEN v.actual_prosecdef IS DISTINCT FROM v.expected_prosecdef THEN 'MIGRATION_SECURITY_MODE_MISMATCH' END,
         CASE WHEN v.actual_proconfig IS NULL OR NOT (v.actual_proconfig @> v.expected_search_path) THEN 'MIGRATION_SEARCH_PATH_MISMATCH' END,
         CASE WHEN v.owner_name IS DISTINCT FROM 'postgres' THEN 'OWNER_NOT_POSTGRES' END,
         CASE WHEN v.public_execute_acl THEN 'PUBLIC_EXECUTE_GRANTED' END,
         CASE WHEN v.anon_execute_effective THEN 'ANON_EXECUTE_EFFECTIVE' END,
         CASE WHEN v.service_role_execute_effective THEN 'SERVICE_ROLE_EXECUTE_EFFECTIVE' END,
         CASE WHEN v.actual_authenticated_execute IS DISTINCT FROM v.expected_authenticated_execute THEN 'AUTHENTICATED_EXECUTE_MISMATCH' END
       ], NULL), ', ') AS checker_gate_failure_predicates
FROM privileges AS v
ORDER BY v.signature;
