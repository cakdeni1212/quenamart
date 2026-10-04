-- Read-only post-deployment verification for migration 20260929200000.
-- Run only in SQL Editor opened at the verified Quena Mart project ref.
WITH expected_migrations(version) AS (
  VALUES
    ('20260928'), ('20260928115000'), ('20260928143000'),
    ('20260929100000'), ('20260929130000'), ('20260929150000'),
    ('20260929160000'), ('20260929170000'), ('20260929171000'),
    ('20260929180000'), ('20260929190000'), ('20260929200000')
),
actual_migrations(version) AS (
  SELECT version::text FROM supabase_migrations.schema_migrations
),
ledger_state AS (
  SELECT
    ARRAY(SELECT version FROM actual_migrations ORDER BY version) AS actual_versions,
    ARRAY(SELECT version FROM expected_migrations ORDER BY version) AS expected_versions,
    (SELECT count(*) FROM actual_migrations WHERE version = '20260929200000') AS version_200000_count
),
expected_functions(signature, proname, expected_definer, expected_path) AS (
  VALUES
    ('public.issue_stock_operation_intent(text,jsonb)', 'issue_stock_operation_intent', true, ARRAY['search_path=pg_catalog']::text[]),
    ('public.apply_stock_operation_intent(uuid)', 'apply_stock_operation_intent', true, ARRAY['search_path=pg_catalog']::text[]),
    ('public.stock_opname_progress_counts(uuid)', 'stock_opname_progress_counts', false, ARRAY['search_path=pg_catalog']::text[])
),
function_state AS (
  SELECT e.signature, e.proname, e.expected_definer, e.expected_path,
         p.oid, p.proowner, p.prosecdef, p.proconfig,
         coalesce((SELECT count(*) FROM pg_catalog.pg_proc p2
           WHERE p2.pronamespace = 'public'::regnamespace AND p2.proname = e.proname), 0) AS overload_count,
         has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
         has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
         has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute,
         NOT EXISTS (
           SELECT 1 FROM pg_catalog.aclexplode(coalesce(p.proacl,
             pg_catalog.acldefault('f', p.proowner))) a
           WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'
         ) AS public_execute_revoked,
         lower(regexp_replace(p.prosrc, '[[:space:]]+', ' ', 'g')) AS definition
  FROM expected_functions e
  LEFT JOIN pg_catalog.pg_proc p ON p.oid = to_regprocedure(e.signature)::oid
),
definitions AS (
  SELECT
    max(definition) FILTER (WHERE proname = 'issue_stock_operation_intent') AS issue_def,
    max(definition) FILTER (WHERE proname = 'apply_stock_operation_intent') AS apply_def,
    max(definition) FILTER (WHERE proname = 'stock_opname_progress_counts') AS progress_def
  FROM function_state
),
issue_positions AS (
  SELECT issue_def,
    strpos(issue_def, 'elsif p_operation_key in (''record_count'',') AS revision_ops_start,
    strpos(issue_def, 'elsif p_operation_key = ''reconcile_movement'' then') AS next_ops_start
  FROM definitions
),
issue_branch AS (
  SELECT issue_def, revision_ops_start, next_ops_start,
    CASE WHEN revision_ops_start > 0 AND next_ops_start > revision_ops_start
      THEN substring(issue_def FROM revision_ops_start FOR next_ops_start - revision_ops_start)
      ELSE '' END AS revision_ops_body
  FROM issue_positions
),
apply_positions AS (
  SELECT apply_def,
    strpos(apply_def, 'elsif v_req.operation_key = ''rebase_item'' then') AS rebase_start,
    strpos(apply_def, 'elsif v_req.operation_key = ''review_exception'' then') AS review_start,
    strpos(apply_def, 'elsif v_req.operation_key = ''submit_review'' then') AS submit_start
  FROM definitions
),
apply_branches AS (
  SELECT apply_def,
    CASE WHEN rebase_start > 0 AND review_start > rebase_start
      THEN substring(apply_def FROM rebase_start FOR review_start - rebase_start) ELSE '' END AS rebase_branch,
    CASE WHEN review_start > 0 AND submit_start > review_start
      THEN substring(apply_def FROM review_start FOR submit_start - review_start) ELSE '' END AS review_branch
  FROM apply_positions
),
branch_relations AS (
  SELECT *,
    strpos(rebase_branch, 'from public.stock_opname_sessions') AS rebase_session_relation,
    strpos(rebase_branch, 'for update;') AS rebase_session_lock,
    strpos(rebase_branch, 'from public.stock_opname_items') AS rebase_item_relation,
    strpos(rebase_branch, 'if v_item.revision_no <> v_expected_revision then') AS rebase_revision_check,
    strpos(rebase_branch, 'from public.stock_balance_projection p') AS rebase_projection_check,
    strpos(review_branch, 'from public.stock_opname_sessions') AS review_session_relation,
    strpos(review_branch, 'for update;') AS review_session_lock,
    strpos(review_branch, 'from public.stock_opname_items') AS review_item_relation,
    strpos(review_branch, 'if v_item.revision_no <> v_expected_revision then') AS review_revision_check,
    strpos(review_branch, 'from public.stock_balance_projection p') AS review_projection_check
  FROM apply_branches
),
branch_positions AS (
  SELECT *,
    CASE WHEN rebase_item_relation > 0
      THEN rebase_item_relation - 1 + strpos(substring(rebase_branch FROM rebase_item_relation), 'for update;')
      ELSE 0 END AS rebase_item_lock,
    CASE WHEN review_item_relation > 0
      THEN review_item_relation - 1 + strpos(substring(review_branch FROM review_item_relation), 'for update;')
      ELSE 0 END AS review_item_lock
  FROM branch_relations
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
  SELECT 1, 'migration_ledger_exact_through_200000',
         CASE WHEN l.actual_versions = l.expected_versions AND l.version_200000_count = 1 THEN 'PASS' ELSE 'FAIL' END,
         array_to_string(l.actual_versions, ', '), array_to_string(l.expected_versions, ', '),
         'The complete expected chain must appear exactly once, without missing or unexpected versions.'
  FROM ledger_state l
  UNION ALL
  SELECT 2, 'exact_signatures_and_no_overloads',
         CASE WHEN count(*) = 3 AND bool_and(oid IS NOT NULL) AND bool_and(overload_count = 1)
              THEN 'PASS' ELSE 'FAIL' END,
         count(*) FILTER (WHERE oid IS NOT NULL)::text || '/3 functions; same-name overload count=' ||
           coalesce(sum(overload_count - 1), 0)::text,
         '3 exact signatures; no extra public same-name overloads',
         string_agg(signature, ', ' ORDER BY signature)
  FROM function_state
  UNION ALL
  SELECT 3, 'function_owner_security_path_and_execute_acl',
         CASE WHEN count(*) = 3
                AND bool_and(oid IS NOT NULL)
                AND bool_and(pg_catalog.pg_get_userbyid(proowner) = 'postgres')
                AND bool_and(prosecdef = expected_definer)
                AND bool_and(proconfig = expected_path)
                AND bool_and(authenticated_execute)
                AND bool_and(NOT anon_execute)
                AND bool_and(NOT service_role_execute)
                AND bool_and(public_execute_revoked)
              THEN 'PASS' ELSE 'FAIL' END,
         string_agg(proname || ':owner=' || coalesce(pg_catalog.pg_get_userbyid(proowner), '<missing>') ||
           ',definer=' || coalesce(prosecdef::text, '<missing>') ||
           ',path=' || coalesce(array_to_string(proconfig, ','), '<unset>') ||
           ',authenticated=' || coalesce(authenticated_execute::text, '<missing>') ||
           ',anon=' || coalesce(anon_execute::text, '<missing>') ||
           ',service_role=' || coalesce(service_role_execute::text, '<missing>') ||
           ',public_revoked=' || coalesce(public_execute_revoked::text, '<missing>'), '; ' ORDER BY proname),
         'All postgres-owned; issue/apply DEFINER; progress INVOKER; search_path=pg_catalog; authenticated EXECUTE only',
         'PUBLIC is checked directly in function ACL; anon/service_role are checked with effective privileges.'
  FROM function_state
  UNION ALL
  SELECT 4, 'intent_revision_canonicalization',
         CASE WHEN i.revision_ops_start > 0
                AND i.next_ops_start > i.revision_ops_start
                AND position('rebase_item' IN i.revision_ops_body) > 0
                AND position('review_exception' IN i.revision_ops_body) > 0
                AND position('expected_revision' IN i.revision_ops_body) > 0
                AND position('jsonb_typeof' IN i.revision_ops_body) > 0
                AND position('number' IN i.revision_ops_body) > 0
                AND position('v_expected_revision_numeric < 0' IN i.revision_ops_body) > 0
                AND position('2147483647' IN i.revision_ops_body) > 0
                AND position('trunc(' IN i.revision_ops_body) > 0
                AND position('btrim(' IN i.revision_ops_body) > 0
                AND position('exception reason is required' IN i.revision_ops_body) > 0
                AND position('md5(' IN i.issue_def) > 0
                AND position('v_payload::text' IN i.issue_def) > 0
              THEN 'PASS' ELSE 'FAIL' END,
         'expected_revision validated and canonical payload hashed; exception reason trimmed/nonblank',
         'required nonnegative integer revision, bounded to int range; REBASE_ITEM and REVIEW_EXCEPTION bind the revision',
         'Checks definition markers without invoking the RPC.'
  FROM issue_branch i
  UNION ALL
  SELECT 5, 'rebase_item_revision_guard_order',
         CASE WHEN p.rebase_session_relation > 0
                AND p.rebase_session_lock > p.rebase_session_relation
                AND p.rebase_item_relation > p.rebase_session_lock
                AND p.rebase_item_lock > p.rebase_item_relation
                AND p.rebase_revision_check > p.rebase_item_lock
                AND p.rebase_projection_check > p.rebase_revision_check
                AND position('item_revision_mismatch' IN p.rebase_branch) > 0
                AND position('expectedrevision' IN p.rebase_branch) > 0
                AND position('currentrevision' IN p.rebase_branch) > 0
                AND position('refreshrequired' IN p.rebase_branch) > 0
                AND position('expected_revision_required' IN p.rebase_branch) > 0
                AND position('state = ''stale''' IN p.rebase_branch) > 0
                AND position('completed_at = now()' IN p.rebase_branch) > 0
                AND position('return v_result;' IN substring(p.rebase_branch FROM p.rebase_revision_check FOR p.rebase_projection_check - p.rebase_revision_check)) > 0
                AND position('baseline_refreshed' IN substring(p.rebase_branch FROM p.rebase_projection_check)) > 0
              THEN 'PASS' ELSE 'FAIL' END,
         'session-lock=' || p.rebase_session_lock::text || '; item-lock=' || p.rebase_item_lock::text || '; revision-check=' || p.rebase_revision_check::text ||
           '; projection-check=' || p.rebase_projection_check::text,
         'session and item locks precede revision guard; mismatch result returns before projection lookup; successful rebase path follows projection lookup',
         'This gate verifies control-flow/order markers and does not claim to prove absence of writes.'
  FROM branch_positions p
  UNION ALL
  SELECT 6, 'review_exception_revision_guard_order',
         CASE WHEN p.review_session_relation > 0
                AND p.review_session_lock > p.review_session_relation
                AND p.review_item_relation > p.review_session_lock
                AND p.review_item_lock > p.review_item_relation
                AND p.review_revision_check > p.review_item_lock
                AND p.review_projection_check > p.review_revision_check
                AND position('item_revision_mismatch' IN p.review_branch) > 0
                AND position('expectedrevision' IN p.review_branch) > 0
                AND position('currentrevision' IN p.review_branch) > 0
                AND position('refreshrequired' IN p.review_branch) > 0
                AND position('expected_revision_required' IN p.review_branch) > 0
                AND position('state = ''stale''' IN p.review_branch) > 0
                AND position('completed_at = now()' IN p.review_branch) > 0
                AND position('return v_result;' IN substring(p.review_branch FROM p.review_revision_check FOR p.review_projection_check - p.review_revision_check)) > 0
                AND position('baseline berubah; barang harus dihitung ulang sebelum pengecualian ditinjau' IN p.review_branch) > 0
              THEN 'PASS' ELSE 'FAIL' END,
         'session-lock=' || p.review_session_lock::text || '; item-lock=' || p.review_item_lock::text || '; revision-check=' || p.review_revision_check::text ||
           '; projection-check=' || p.review_projection_check::text,
         'session and item locks precede revision guard; mismatch result returns before projection lookup; projection-stale exception still requires recount',
         'This gate verifies control-flow/order markers and does not claim to prove absence of writes.'
  FROM branch_positions p
  UNION ALL
  SELECT 7, 'shared_unrelated_operation_branches_present',
         CASE WHEN
           position(('cre' || 'ate_session') IN d.issue_def) > 0 AND position('record_count' IN d.issue_def) > 0
           AND position('submit_review' IN d.issue_def) > 0 AND position('return_to_counting' IN d.issue_def) > 0
           AND position('cancel_session' IN d.issue_def) > 0 AND position('post_session' IN d.issue_def) > 0
           AND position('reconcile_movement' IN d.issue_def) > 0 AND position('reverse_movement' IN d.issue_def) > 0
           AND position(('cre' || 'ate_session') IN d.apply_def) > 0 AND position('record_count' IN d.apply_def) > 0
           AND position('submit_review' IN d.apply_def) > 0 AND position('return_to_counting' IN d.apply_def) > 0
           AND position('cancel_session' IN d.apply_def) > 0 AND position('post_session' IN d.apply_def) > 0
           AND position('reconcile_movement' IN d.apply_def) > 0 AND position('reverse_movement' IN d.apply_def) > 0
           THEN 'PASS' ELSE 'FAIL' END,
         'Session creation, RECORD_COUNT, SUBMIT_REVIEW, RETURN_TO_COUNTING, CANCEL_SESSION, POST_SESSION, RECONCILE_MOVEMENT, REVERSE_MOVEMENT present in both shared RPCs',
         'All unrelated supported operation branches remain represented.',
         'Local static review also compared unaffected operation branch bodies against immutable 180000.'
  FROM definitions d
  UNION ALL
  SELECT 8, 'progress_rpc_contract',
         CASE WHEN position('''total''' IN d.progress_def) > 0
                AND position('''counted''' IN d.progress_def) > 0
                AND position('''exception''' IN d.progress_def) > 0
                AND position('''accounted''' IN d.progress_def) > 0
                AND position('''remaining''' IN d.progress_def) > 0
                AND position('''recount_required''' IN d.progress_def) > 0
                AND position('physical_quantity is not null and not i.requires_recount' IN d.progress_def) > 0
                AND position('exception_reviewed_at is not null' IN d.progress_def) > 0
                AND position('product_inventory' IN d.progress_def) = 0
                AND position('hpp' IN d.progress_def) = 0
                AND position('profit' IN d.progress_def) = 0
                AND EXISTS (
                  SELECT 1 FROM pg_catalog.pg_class c
                  WHERE c.oid = 'public.stock_opname_items'::regclass AND c.relrowsecurity
                )
                AND EXISTS (
                  SELECT 1 FROM pg_catalog.pg_policy pol
                  WHERE pol.polrelid = 'public.stock_opname_items'::regclass
                    AND pol.polname = 'stock_opname_items_select_roles'
                    AND pol.polcmd::text = 'r'
                    AND pol.polroles @> ARRAY['authenticated'::regrole::oid]
                )
              THEN 'PASS' ELSE 'FAIL' END,
         'one stable aggregate; all six progress fields; recount rows excluded; no financial/snapshot fields; opname item RLS/select policy present',
         'SECURITY INVOKER and fixed search_path are checked structurally in gate 3; authenticated SELECT follows existing RLS.',
         'Read-only SQL function definition is inspected, never called.'
  FROM definitions d
  UNION ALL
  SELECT 9, 'production_data_counts_informational', 'REVIEW',
         'inventory=' || inventory_rows::text || '; inventory_history=' || inventory_history_rows::text ||
           '; projection=' || projection_rows::text || '; movements=' || movement_rows::text ||
           '; opname_sessions=' || opname_session_rows::text || '; opname_items=' || opname_item_rows::text ||
           '; count_events=' || count_event_rows::text || '; operation_requests=' || operation_request_rows::text,
         'Compare with the pre-deployment read-only snapshot; migration 200000 performs no data migration.',
         'Normal application activity can change counts; no fixture or mutation test is required.'
  FROM data_snapshot
)
SELECT check_order, check_name, status, actual, expected, detail
FROM checks
ORDER BY check_order;
