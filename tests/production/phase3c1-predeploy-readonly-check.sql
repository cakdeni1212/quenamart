-- Phase 3C.1A pre-deployment compatibility inspection.
-- Before running, verify in Supabase Dashboard that the selected project ref is
-- giwuzemjmimuvhtvjfhq. PostgreSQL catalog SQL does not prove the project ref.
-- Review all result sets. Stop if any required dependency is missing, any
-- planned-name collision exists, or any required data check is nonzero.

-- Connection identity. Confirm the project ref separately in the Dashboard.
SELECT current_database() AS current_database,
       current_user AS session_user_name,
       inet_server_addr() AS server_address,
       inet_server_port() AS server_port,
       current_setting('server_version') AS server_version,
       current_setting('server_version_num')::integer AS server_version_num;

-- Migration ledger location and expected applied state.
SELECT to_regclass('supabase_migrations.schema_migrations') AS migration_ledger_relation;

SELECT count(*) AS total_migrations,
       min(version) AS earliest_version,
       max(version) AS latest_version,
       count(*) FILTER (WHERE version = '20260929130000') AS has_130000,
       count(*) FILTER (WHERE version = '20260929150000') AS has_150000,
       count(*) FILTER (WHERE version = '20260929160000') AS has_160000,
       count(*) FILTER (WHERE version = '20260929170000') AS has_170000,
       count(*) FILTER (WHERE version = '20260929171000') AS has_171000,
       count(*) FILTER (WHERE version = '20260929180000') AS has_180000,
       count(*) FILTER (WHERE version > '20260929170000') AS versions_after_170000,
       array_agg(version ORDER BY version) FILTER (
         WHERE version IN ('20260929130000','20260929150000','20260929160000',
                           '20260929170000','20260929171000','20260929180000')
       ) AS relevant_versions
FROM supabase_migrations.schema_migrations;

-- Required relations and their actual relation kinds.
WITH expected(relname, schemaname) AS (
  VALUES
    ('profiles','public'), ('outlets','public'), ('products','public'),
    ('product_inventory','public'), ('product_inventory_history','public'),
    ('product_field_overrides','public'), ('product_barcodes','public'),
    ('product_field_audit_reviews','public'),
    ('product_field_correction_requests','public'),
    ('product_field_correction_intents','public'),
    ('ipos_import_batches','public'), ('ipos_import_rows','public'),
    ('ipos_normalization_commits','public'),
    ('ipos_normalization_commit_rows','public'), ('users','auth')
)
SELECT e.schemaname, e.relname, c.relkind,
       CASE WHEN c.oid IS NULL THEN NULL ELSE c.oid::regclass::text END AS resolved_relation,
       c.oid IS NOT NULL AS object_exists
FROM expected e
LEFT JOIN pg_catalog.pg_namespace n ON n.nspname = e.schemaname
LEFT JOIN pg_catalog.pg_class c ON c.relnamespace = n.oid AND c.relname = e.relname
ORDER BY e.schemaname, e.relname;

-- Required columns and their actual types. ipos_normalization_commit_rows has
-- (commit_id, source_row_number) as its primary key; it has no generic id.
WITH expected(schemaname, relname, attname) AS (
  VALUES
    ('public','profiles','id'), ('public','profiles','role'), ('public','profiles','is_active'),
    ('public','outlets','id'),
    ('public','products','id'), ('public','products','last_import_row_id'),
    ('public','product_inventory','product_id'), ('public','product_inventory','outlet_id'),
    ('public','product_inventory','quantity'), ('public','product_inventory','minimum_quantity'),
    ('public','product_inventory','source_import_row_id'),
    ('public','product_inventory_history','product_id'),
    ('public','product_inventory_history','outlet_id'),
    ('public','product_inventory_history','quantity'),
    ('public','product_inventory_history','minimum_quantity'),
    ('public','product_field_overrides','id'), ('public','product_field_overrides','product_id'),
    ('public','product_field_overrides','outlet_id'), ('public','product_field_overrides','field_key'),
    ('public','product_field_overrides','corrected_value'), ('public','product_field_overrides','is_active'),
    ('public','product_barcodes','id'), ('public','product_barcodes','product_id'),
    ('public','product_barcodes','barcode'), ('public','product_barcodes','is_active'),
    ('public','ipos_import_batches','id'), ('public','ipos_import_batches','outlet_id'),
    ('public','ipos_import_batches','status'),
    ('public','ipos_import_rows','id'), ('public','ipos_import_rows','batch_id'),
    ('public','ipos_import_rows','outlet_id'), ('public','ipos_import_rows','product_id'),
    ('public','ipos_import_rows','status'),
    ('public','ipos_normalization_commits','id'), ('public','ipos_normalization_commits','batch_id'),
    ('public','ipos_normalization_commits','outlet_id'), ('public','ipos_normalization_commits','status'),
    ('public','ipos_normalization_commit_rows','commit_id'),
    ('public','ipos_normalization_commit_rows','batch_id'),
    ('public','ipos_normalization_commit_rows','outlet_id'),
    ('public','ipos_normalization_commit_rows','source_row_id'),
    ('public','ipos_normalization_commit_rows','source_row_number'),
    ('public','ipos_normalization_commit_rows','product_id'),
    ('public','ipos_normalization_commit_rows','action'),
    ('public','ipos_normalization_commit_rows','normalized_data'),
    ('public','ipos_normalization_commit_rows','validation_errors'),
    ('public','product_field_audit_reviews','id'),
    ('public','product_field_correction_requests','request_id'),
    ('public','product_field_correction_intents','request_id'),
    ('public','product_field_correction_intents','actor_id'),
    ('public','product_field_correction_intents','request_payload'),
    ('auth','users','id')
)
SELECT e.schemaname, e.relname, e.attname,
       a.atttypid::regtype AS actual_type,
       a.attnum IS NOT NULL AS column_exists
FROM expected e
LEFT JOIN pg_catalog.pg_namespace n ON n.nspname = e.schemaname
LEFT JOIN pg_catalog.pg_class c ON c.relnamespace = n.oid AND c.relname = e.relname
LEFT JOIN pg_catalog.pg_attribute a
  ON a.attrelid = c.oid AND a.attname = e.attname
 AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY e.schemaname, e.relname, e.attname;

-- Required role and import-related enum types and labels.
SELECT n.nspname, t.typname, t.typtype, e.enumlabel
FROM pg_catalog.pg_type t
JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
LEFT JOIN pg_catalog.pg_enum e ON e.enumtypid = t.oid
WHERE (n.nspname = 'public' AND t.typname IN (
         'user_role','ipos_import_batch_status','ipos_import_row_status',
         'product_audit_finding_code','product_field_audit_status'
       ))
   OR (n.nspname = 'auth' AND t.typname = 'users')
ORDER BY n.nspname, t.typname, e.enumsortorder;

-- Required functions: exact signatures, ownership/security settings, and grants.
WITH expected(signature) AS (
  VALUES
    ('auth.uid()'),
    ('public.current_active_user_role()'),
    ('public.commit_ipos_normalization(uuid,text,jsonb)'),
    ('public.apply_product_field_correction(uuid,uuid,uuid,text,jsonb,text,uuid,text)'),
    ('public.issue_product_field_correction_intent(uuid,uuid,text,uuid,jsonb,text,text)'),
    ('public.apply_product_field_correction_intent(uuid)')
)
SELECT e.signature,
       p.oid::regprocedure AS resolved_signature,
       r.rolname AS owner,
       p.prosecdef AS security_definer,
       p.proconfig AS function_settings,
       p.proacl AS function_acl,
       p.oid IS NOT NULL AS exact_signature_exists
FROM expected e
LEFT JOIN pg_catalog.pg_proc p ON p.oid = to_regprocedure(e.signature)
LEFT JOIN pg_catalog.pg_roles r ON r.oid = p.proowner
ORDER BY e.signature;

-- Relevant dependency constraints, including composite keys referenced by
-- 180000 foreign keys. Definitions are shown to check key order and columns.
SELECT c.conrelid::regclass AS relation, c.conname, c.contype,
       pg_catalog.pg_get_constraintdef(c.oid) AS definition
FROM pg_catalog.pg_constraint c
WHERE c.conrelid IN (
  to_regclass('public.product_inventory'),
  to_regclass('public.product_inventory_history'),
  to_regclass('public.ipos_import_rows'),
  to_regclass('public.ipos_import_batches'),
  to_regclass('public.ipos_normalization_commits'),
  to_regclass('public.ipos_normalization_commit_rows'),
  to_regclass('public.product_barcodes'),
  to_regclass('public.product_field_correction_intents'),
  to_regclass('public.product_field_correction_requests')
)
ORDER BY c.conrelid::regclass::text, c.conname;

-- 171000's existing correction-intent index dependency and all indexes on the
-- import proposal/source relations used by the stock bootstrap.
SELECT schemaname, tablename, indexname, indexdef
FROM pg_catalog.pg_indexes
WHERE schemaname = 'public'
  AND tablename IN (
    'product_field_correction_intents','ipos_import_rows',
    'ipos_normalization_commits','ipos_normalization_commit_rows',
    'product_inventory','product_barcodes'
  )
ORDER BY tablename, indexname;

-- Every planned 180000 enum name must be absent from public.
WITH expected(typname) AS (
  VALUES ('stock_authority_mode'), ('stock_movement_type'), ('stock_movement_source'),
         ('stock_opname_scope'), ('stock_opname_status'), ('stock_count_event_type'),
         ('stock_opname_event_type'), ('stock_request_state')
)
SELECT e.typname, t.oid::regtype AS existing_type, t.typtype,
       t.oid IS NOT NULL AS collision
FROM expected e
LEFT JOIN pg_catalog.pg_type t
  ON t.typnamespace = 'public'::regnamespace AND t.typname = e.typname
ORDER BY e.typname;

-- Every planned 180000 relation name must be absent from public, regardless of
-- whether an existing object is a table, view, sequence, index, or other relation.
WITH expected(relname) AS (
  VALUES ('stock_authority_periods'), ('stock_balance_projection'),
         ('stock_balance_baseline_events'), ('stock_operation_requests'),
         ('stock_opname_sessions'), ('stock_opname_items'),
         ('stock_opname_count_events'), ('stock_opname_session_events'),
         ('stock_movement_batches'), ('stock_movements'),
         ('stock_movement_source_reconciliations'), ('stock_balance_projection_events')
)
SELECT e.relname, c.relkind,
       CASE WHEN c.oid IS NULL THEN NULL ELSE c.oid::regclass::text END AS existing_relation,
       c.oid IS NOT NULL AS collision
FROM expected e
LEFT JOIN pg_catalog.pg_class c
  ON c.relnamespace = 'public'::regnamespace AND c.relname = e.relname
ORDER BY e.relname;

-- Every explicitly named and generated constraint must be absent on its target
-- relation. Constraint names are relation-scoped in PostgreSQL.
WITH expected(relname, conname) AS (
  VALUES
    ('stock_authority_periods','stock_authority_periods_pkey'),
    ('stock_authority_periods','stock_authority_period_reason_nonblank'),
    ('stock_authority_periods','stock_authority_period_time_valid'),
    ('stock_authority_periods','stock_authority_period_id_outlet_unique'),
    ('stock_balance_projection','stock_balance_projection_pkey'),
    ('stock_balance_projection','stock_balance_authority_period_fk'),
    ('stock_balance_projection','stock_balance_baseline_source_fk'),
    ('stock_balance_projection','stock_balance_observation_source_fk'),
    ('stock_balance_projection','stock_balance_baseline_identity_consistent'),
    ('stock_balance_projection','stock_balance_quantity_precision'),
    ('stock_balance_projection','stock_balance_version_positive'),
    ('stock_balance_projection','stock_balance_observation_status_valid'),
    ('stock_balance_baseline_events','stock_balance_baseline_events_pkey'),
    ('stock_balance_baseline_events','stock_balance_baseline_event_source_fk'),
    ('stock_balance_baseline_events','stock_balance_baseline_event_once'),
    ('stock_operation_requests','stock_operation_requests_pkey'),
    ('stock_operation_requests','stock_operation_request_hash_valid'),
    ('stock_operation_requests','stock_operation_request_state_consistent'),
    ('stock_opname_sessions','stock_opname_sessions_pkey'),
    ('stock_opname_sessions','stock_opname_note_nonblank'),
    ('stock_opname_sessions','stock_opname_lifecycle_valid'),
    ('stock_opname_sessions','stock_opname_id_outlet_unique'),
    ('stock_opname_items','stock_opname_items_pkey'),
    ('stock_opname_items','stock_opname_item_session_outlet_fk'),
    ('stock_opname_items','stock_opname_item_baseline_fk'),
    ('stock_opname_items','stock_opname_item_barcode_product_fk'),
    ('stock_opname_items','stock_opname_item_unique_product'),
    ('stock_opname_items','stock_opname_item_id_product_outlet_unique'),
    ('stock_opname_items','stock_opname_item_quantity_valid'),
    ('stock_opname_items','stock_opname_item_baseline_pair'),
    ('stock_opname_items','stock_opname_item_exception_consistent'),
    ('stock_opname_items','stock_opname_item_count_actor_consistent'),
    ('stock_opname_items','stock_opname_item_revision_nonnegative'),
    ('stock_opname_count_events','stock_opname_count_events_pkey'),
    ('stock_opname_count_events','stock_opname_count_event_revision_positive'),
    ('stock_opname_count_events','stock_opname_count_event_quantity_valid'),
    ('stock_opname_count_events','stock_opname_count_event_barcode_fk'),
    ('stock_opname_count_events','stock_opname_count_event_request_unique'),
    ('stock_opname_session_events','stock_opname_session_events_pkey'),
    ('stock_opname_session_events','stock_opname_session_event_request_unique'),
    ('stock_movement_batches','stock_movement_batches_pkey'),
    ('stock_movement_batches','stock_movement_batches_operation_request_id_key'),
    ('stock_movement_batches','stock_movement_batch_period_outlet_fk'),
    ('stock_movement_batches','stock_movement_batch_id_outlet_unique'),
    ('stock_movement_batches','stock_movement_batch_source_context_unique'),
    ('stock_movements','stock_movements_pkey'),
    ('stock_movements','stock_movement_batch_fk'),
    ('stock_movements','stock_movement_opname_item_fk'),
    ('stock_movements','stock_movement_source_row_fk'),
    ('stock_movements','stock_movement_id_product_outlet_unique'),
    ('stock_movements','stock_movement_delta_signed_nonzero'),
    ('stock_movements','stock_movement_balance_valid'),
    ('stock_movements','stock_movement_source_event_nonblank'),
    ('stock_movements','stock_movement_source_reference_nonblank'),
    ('stock_movements','stock_movement_identity_present'),
    ('stock_movements','stock_movement_manual_reason_required'),
    ('stock_movements','stock_movement_reason_source_valid'),
    ('stock_movements','stock_movement_sign_valid'),
    ('stock_movements','stock_movement_reversal_shape'),
    ('stock_movements','stock_movement_opname_shape'),
    ('stock_movement_source_reconciliations','stock_movement_source_reconciliations_pkey'),
    ('stock_movement_source_reconciliations','stock_movement_reconciliation_movement_fk'),
    ('stock_movement_source_reconciliations','stock_movement_reconciliation_source_fk'),
    ('stock_movement_source_reconciliations','stock_movement_reconciliation_reason_nonblank'),
    ('stock_movement_source_reconciliations','stock_movement_reconciled_once'),
    ('stock_movement_source_reconciliations','stock_movement_reconciliation_request_member_unique'),
    ('stock_movement_source_reconciliations','stock_movement_reconciliation_group_member_unique'),
    ('stock_balance_projection_events','stock_balance_projection_events_pkey'),
    ('stock_balance_projection_events','stock_balance_projection_event_product_fk'),
    ('stock_balance_projection_events','stock_balance_projection_event_period_fk'),
    ('stock_balance_projection_events','stock_balance_projection_event_quantity_valid')
)
SELECT e.relname, e.conname, c.contype,
       pg_catalog.pg_get_constraintdef(c.oid) AS existing_definition,
       c.oid IS NOT NULL AS collision
FROM expected e
LEFT JOIN pg_catalog.pg_constraint c
  ON c.conrelid = to_regclass('public.' || e.relname) AND c.conname = e.conname
ORDER BY e.relname, e.conname;

-- Explicit and generated backing-index names. Index names share a namespace
-- within public, so this checks the schema, not only the planned target table.
WITH expected(indexname) AS (
  VALUES
    ('stock_authority_one_current_period_per_outlet'),
    ('stock_authority_periods_pkey'), ('stock_authority_period_id_outlet_unique'),
    ('stock_balance_outlet_product_idx'), ('ipos_normalization_rows_stock_source_lookup_idx'),
    ('stock_balance_projection_pkey'), ('stock_balance_baseline_events_product_time_idx'),
    ('stock_balance_baseline_events_pkey'), ('stock_balance_baseline_event_once'),
    ('stock_operation_one_pending_intent_per_target'), ('stock_operation_request_actor_recent_idx'),
    ('stock_operation_requests_pkey'), ('stock_opname_outlet_status_created_idx'),
    ('stock_opname_sessions_pkey'), ('stock_opname_id_outlet_unique'),
    ('stock_opname_no_active_overlap'), ('stock_opname_items_session_idx'),
    ('stock_opname_items_pkey'), ('stock_opname_item_unique_product'),
    ('stock_opname_item_id_product_outlet_unique'), ('stock_opname_count_events_item_time_idx'),
    ('stock_opname_count_events_pkey'), ('stock_opname_count_event_request_unique'),
    ('stock_opname_session_events_session_time_idx'), ('stock_opname_session_events_pkey'),
    ('stock_opname_session_event_request_unique'), ('stock_movement_batches_pkey'),
    ('stock_movement_batches_operation_request_id_key'),
    ('stock_movement_batch_id_outlet_unique'), ('stock_movement_batch_source_context_unique'),
    ('stock_movements_pkey'), ('stock_movement_id_product_outlet_unique'),
    ('stock_movement_one_reversal_per_original'), ('stock_movement_source_event_once'),
    ('stock_movements_product_time_idx'), ('stock_movements_batch_idx'),
    ('stock_movement_reconciliation_snapshot_idx'),
    ('stock_movement_source_reconciliations_pkey'), ('stock_movement_reconciled_once'),
    ('stock_movement_reconciliation_request_member_unique'),
    ('stock_movement_reconciliation_group_member_unique'),
    ('stock_balance_projection_request_event_once'),
    ('stock_balance_projection_events_product_time_idx'),
    ('stock_balance_projection_events_pkey')
)
SELECT e.indexname, i.indrelid::regclass AS owning_relation,
       i.indexrelid::regclass AS existing_index,
       i.indexrelid IS NOT NULL AS collision
FROM expected e
LEFT JOIN pg_catalog.pg_class c
  ON c.relnamespace = 'public'::regnamespace AND c.relname = e.indexname
 AND c.relkind = 'i'
LEFT JOIN pg_catalog.pg_index i ON i.indexrelid = c.oid
ORDER BY e.indexname;

-- Exact planned function signatures must be absent. Same-name overloads are
-- reported separately because function replacement targets only an exact signature.
WITH expected(signature, proname) AS (
  VALUES
    ('public.validate_stock_movement_reversal()','validate_stock_movement_reversal'),
    ('public.refresh_stock_balance_from_ipos_inventory()','refresh_stock_balance_from_ipos_inventory'),
    ('public.reject_stock_ledger_mutation()','reject_stock_ledger_mutation'),
    ('public.guard_posted_stock_opname()','guard_posted_stock_opname'),
    ('public.guard_posted_stock_opname_item()','guard_posted_stock_opname_item'),
    ('public.stock_apply_balance_delta(uuid,uuid,numeric)','stock_apply_balance_delta'),
    ('public.stock_opname_content_hash(uuid)','stock_opname_content_hash'),
    ('public.issue_stock_operation_intent(text,jsonb)','issue_stock_operation_intent'),
    ('public.read_stock_operation_intent(uuid)','read_stock_operation_intent'),
    ('public.resolve_stock_barcode(uuid,text)','resolve_stock_barcode'),
    ('public.apply_stock_operation_intent(uuid)','apply_stock_operation_intent')
)
SELECT e.signature,
       to_regprocedure(e.signature) AS exact_signature,
       to_regprocedure(e.signature) IS NOT NULL AS exact_collision,
       (SELECT string_agg(pg_catalog.pg_get_function_identity_arguments(p.oid), '; ')
        FROM pg_catalog.pg_proc p
        WHERE p.pronamespace = 'public'::regnamespace AND p.proname = e.proname
       ) AS same_name_overloads
FROM expected e
ORDER BY e.proname;

-- Planned trigger names are checked on their exact target relations.
WITH expected(relname, triggername) AS (
  VALUES
    ('stock_movements','stock_movement_validate_reversal'),
    ('product_inventory','product_inventory_refresh_stock_projection_insert'),
    ('product_inventory','product_inventory_refresh_stock_projection_source_update'),
    ('stock_movement_batches','stock_movement_batches_immutable'),
    ('stock_movements','stock_movements_immutable'),
    ('stock_movement_source_reconciliations','stock_reconciliations_immutable'),
    ('stock_balance_baseline_events','stock_baseline_events_immutable'),
    ('stock_balance_projection_events','stock_projection_events_immutable'),
    ('stock_opname_count_events','stock_count_events_immutable'),
    ('stock_opname_session_events','stock_session_events_immutable'),
    ('stock_opname_sessions','stock_opname_session_guard'),
    ('stock_opname_items','stock_opname_item_guard')
)
SELECT e.relname, e.triggername, t.tgenabled,
       pg_catalog.pg_get_triggerdef(t.oid) AS existing_definition,
       t.oid IS NOT NULL AS collision
FROM expected e
LEFT JOIN pg_catalog.pg_trigger t
  ON t.tgrelid = to_regclass('public.' || e.relname)
 AND t.tgname = e.triggername AND NOT t.tgisinternal
ORDER BY e.relname, e.triggername;

-- Planned row-security policy names are checked on their exact target relations.
WITH expected(relname, policyname) AS (
  VALUES
    ('stock_authority_periods','stock_authority_periods_select_roles'),
    ('stock_balance_projection','stock_balance_projection_select_roles'),
    ('stock_balance_baseline_events','stock_balance_baseline_events_select_roles'),
    ('stock_balance_projection_events','stock_balance_projection_events_select_roles'),
    ('stock_opname_sessions','stock_opname_sessions_select_roles'),
    ('stock_opname_items','stock_opname_items_select_roles'),
    ('stock_opname_count_events','stock_opname_count_events_select_roles'),
    ('stock_opname_session_events','stock_opname_session_events_select_roles'),
    ('stock_movement_batches','stock_movement_batches_select_roles'),
    ('stock_movements','stock_movements_select_roles'),
    ('stock_movement_source_reconciliations','stock_movement_reconciliations_select_managers')
)
SELECT e.relname, e.policyname, p.polcmd,
       pg_catalog.pg_get_expr(p.polqual, p.polrelid) AS using_expression,
       p.oid IS NOT NULL AS collision
FROM expected e
LEFT JOIN pg_catalog.pg_policy p
  ON p.polrelid = to_regclass('public.' || e.relname) AND p.polname = e.policyname
ORDER BY e.relname, e.policyname;

-- Inventory totals and quantity validity. The schema's supported range is
-- [0, 100000000000) at no more than three decimal places.
SELECT count(*) AS inventory_rows,
       count(DISTINCT product_id) AS distinct_products,
       count(DISTINCT outlet_id) AS distinct_outlets,
       count(*) FILTER (WHERE quantity IS NULL) AS null_quantity,
       count(*) FILTER (WHERE minimum_quantity IS NULL) AS null_minimum_quantity,
       count(*) FILTER (WHERE quantity < 0) AS negative_quantity,
       count(*) FILTER (WHERE quantity >= 100000000000) AS quantity_out_of_range,
       count(*) FILTER (WHERE quantity <> trunc(quantity, 3)) AS quantity_precision_over_3,
       count(*) FILTER (WHERE minimum_quantity < 0) AS negative_minimum_quantity,
       count(*) FILTER (WHERE minimum_quantity >= 100000000000) AS minimum_out_of_range,
       count(*) FILTER (WHERE minimum_quantity <> trunc(minimum_quantity, 3)) AS minimum_precision_over_3,
       count(*) FILTER (WHERE source_import_row_id IS NULL) AS null_source_row,
       count(*) FILTER (WHERE p.id IS NULL) AS missing_product,
       count(*) FILTER (WHERE o.id IS NULL) AS missing_outlet,
       count(*) - count(DISTINCT (i.product_id, i.outlet_id)) AS duplicate_product_outlet_rows
FROM public.product_inventory i
LEFT JOIN public.products p ON p.id = i.product_id
LEFT JOIN public.outlets o ON o.id = i.outlet_id;

-- Inventory row counts and active outlet status.
SELECT o.id AS outlet_id, o.code AS outlet_code, o.is_active,
       count(i.product_id) AS inventory_rows
FROM public.outlets o
LEFT JOIN public.product_inventory i ON i.outlet_id = o.id
GROUP BY o.id, o.code, o.is_active
ORDER BY o.code;

-- Exact 180000 bootstrap eligibility. This mirrors the migration's required
-- valid source, completed batch/commit, matching product/outlet, valid STOK,
-- and exact proposed-quantity equality. No sensitive quantity values returned.
SELECT count(*) AS inventory_rows,
       count(*) FILTER (WHERE i.quantity IS NULL) AS null_quantity,
       count(*) FILTER (WHERE i.source_import_row_id IS NULL) AS null_source_row,
       count(*) FILTER (WHERE NOT EXISTS (
         SELECT 1
         FROM public.ipos_import_rows r
         JOIN public.ipos_import_batches b
           ON b.id = r.batch_id AND b.outlet_id = r.outlet_id AND b.status = 'COMPLETED'
         JOIN public.ipos_normalization_commit_rows cr
           ON cr.source_row_id = r.id AND cr.batch_id = r.batch_id
          AND cr.product_id = i.product_id AND cr.action IN ('CREATE','UPDATE')
         JOIN public.ipos_normalization_commits nc
           ON nc.id = cr.commit_id AND nc.batch_id = r.batch_id
          AND nc.outlet_id = r.outlet_id AND nc.status = 'COMPLETED'
         WHERE r.id = i.source_import_row_id
           AND r.product_id = i.product_id AND r.outlet_id = i.outlet_id
           AND r.status = 'VALID'
           AND CASE jsonb_typeof(cr.normalized_data->'quantity')
             WHEN 'number' THEN (cr.normalized_data->>'quantity')::numeric = i.quantity
             WHEN 'string' THEN CASE
               WHEN cr.normalized_data->>'quantity' ~ '^-?[0-9]+([.][0-9]+)?$'
               THEN (cr.normalized_data->>'quantity')::numeric = i.quantity
               ELSE false
             END
             ELSE false
           END
           AND NOT EXISTS (
             SELECT 1
             FROM pg_catalog.jsonb_array_elements(cr.validation_errors) AS error_item(value)
             WHERE error_item.value->>'code' = 'INVALID_NUMERIC_VALUE'
               AND error_item.value->>'field' = 'STOK'
           )
       )) AS rows_without_eligible_bootstrap_provenance,
       count(*) FILTER (WHERE EXISTS (
         SELECT 1 FROM public.product_field_overrides o
         WHERE o.product_id = i.product_id AND o.outlet_id = i.outlet_id
           AND o.field_key = 'quantity' AND o.is_active
       )) AS rows_with_active_quantity_override
FROM public.product_inventory i;

-- Source pointer, product/outlet, raw-row, and completed-batch diagnostics.
SELECT count(*) FILTER (WHERE i.source_import_row_id IS NULL) AS null_source_pointer,
       count(*) FILTER (WHERE r.id IS NULL) AS missing_source_row,
       count(*) FILTER (WHERE r.id IS NOT NULL AND r.status <> 'VALID') AS source_not_valid,
       count(*) FILTER (WHERE r.id IS NOT NULL AND
         (r.product_id IS DISTINCT FROM i.product_id OR r.outlet_id IS DISTINCT FROM i.outlet_id)
       ) AS source_product_outlet_mismatch,
       count(*) FILTER (WHERE r.id IS NOT NULL AND b.id IS NULL) AS missing_batch,
       count(*) FILTER (WHERE b.id IS NOT NULL AND b.status <> 'COMPLETED') AS batch_not_completed
FROM public.product_inventory i
LEFT JOIN public.ipos_import_rows r ON r.id = i.source_import_row_id
LEFT JOIN public.ipos_import_batches b ON b.id = r.batch_id;

-- Quantity/minimum-quantity override counts only; corrected values are omitted.
SELECT field_key, is_active, count(*) AS override_count
FROM public.product_field_overrides
WHERE field_key IN ('quantity','minimum_quantity')
GROUP BY field_key, is_active
ORDER BY field_key, is_active;

-- Normalized quantity consistency with active overrides, counts only.
SELECT count(*) FILTER (WHERE o.field_key = 'quantity' AND o.is_active) AS active_quantity_overrides,
       count(*) FILTER (WHERE o.field_key = 'minimum_quantity' AND o.is_active) AS active_minimum_overrides,
       count(*) FILTER (WHERE o.field_key = 'quantity' AND o.is_active
         AND (o.corrected_value IS DISTINCT FROM to_jsonb(i.quantity))) AS active_quantity_value_mismatches,
       count(*) FILTER (WHERE o.field_key = 'minimum_quantity' AND o.is_active
         AND (o.corrected_value IS DISTINCT FROM to_jsonb(i.minimum_quantity))) AS active_minimum_value_mismatches
FROM public.product_field_overrides o
LEFT JOIN public.product_inventory i
  ON i.product_id = o.product_id AND i.outlet_id = o.outlet_id
WHERE o.field_key IN ('quantity','minimum_quantity') AND o.is_active;

-- Active barcode totals, aggregate only.
SELECT count(*) AS active_associations,
       count(DISTINCT barcode) AS distinct_active_barcode_values,
       count(*) FILTER (WHERE btrim(barcode) = '' OR barcode ~ '[[:cntrl:]]')
         AS malformed_or_blank_active_values
FROM public.product_barcodes
WHERE is_active;

SELECT count(*) AS duplicate_cross_product_barcode_values,
       coalesce(sum(product_count), 0) AS products_in_cross_product_duplicates
FROM (
  SELECT barcode, count(DISTINCT product_id) AS product_count
  FROM public.product_barcodes
  WHERE is_active
  GROUP BY barcode
  HAVING count(DISTINCT product_id) > 1
) AS duplicate_values;

-- Inventory/history triggers and their function security configuration.
SELECT r.relname AS relation, t.tgname, t.tgenabled,
       pg_catalog.pg_get_triggerdef(t.oid) AS trigger_definition,
       p.proname AS trigger_function, p.prosecdef AS security_definer,
       p.proconfig AS function_settings
FROM pg_catalog.pg_trigger t
JOIN pg_catalog.pg_class r ON r.oid = t.tgrelid
JOIN pg_catalog.pg_namespace n ON n.oid = r.relnamespace
JOIN pg_catalog.pg_proc p ON p.oid = t.tgfoid
WHERE n.nspname = 'public'
  AND r.relname IN ('product_inventory','product_inventory_history')
  AND NOT t.tgisinternal
ORDER BY r.relname, t.tgname;

-- Existing RLS and direct table privileges for the product/import foundation.
WITH expected(schemaname, relname) AS (
  VALUES
    ('public','product_inventory'), ('public','product_inventory_history'),
    ('public','product_field_overrides'), ('public','product_barcodes'),
    ('public','product_field_correction_intents'),
    ('public','product_field_correction_requests'),
    ('public','product_field_audit_reviews'),
    ('public','product_field_reconciliation_events'),
    ('public','ipos_normalization_commits'),
    ('public','ipos_normalization_commit_rows')
)
SELECT e.schemaname, e.relname,
       c.oid::regclass AS relation,
       c.relrowsecurity AS rls_enabled,
       c.relforcerowsecurity AS rls_forced,
       has_table_privilege('anon', c.oid, 'SELECT') AS anon_select,
       has_table_privilege('anon', c.oid, 'INSERT') AS anon_insert,
       has_table_privilege('anon', c.oid, 'UPDATE') AS anon_update,
       has_table_privilege('anon', c.oid, 'DELETE') AS anon_delete,
       has_table_privilege('authenticated', c.oid, 'SELECT') AS authenticated_select,
       has_table_privilege('authenticated', c.oid, 'INSERT') AS authenticated_insert,
       has_table_privilege('authenticated', c.oid, 'UPDATE') AS authenticated_update,
       has_table_privilege('authenticated', c.oid, 'DELETE') AS authenticated_delete,
       has_table_privilege('service_role', c.oid, 'SELECT') AS service_role_select,
       has_table_privilege('service_role', c.oid, 'INSERT') AS service_role_insert,
       has_table_privilege('service_role', c.oid, 'UPDATE') AS service_role_update,
       has_table_privilege('service_role', c.oid, 'DELETE') AS service_role_delete
FROM expected e
LEFT JOIN pg_catalog.pg_namespace n ON n.nspname = e.schemaname
LEFT JOIN pg_catalog.pg_class c ON c.relnamespace = n.oid AND c.relname = e.relname
ORDER BY e.schemaname, e.relname;

-- Existing policies for the protected product/import relations.
SELECT n.nspname AS schema_name, r.relname AS relation, p.polname,
       p.polcmd, p.polpermissive,
       pg_catalog.pg_get_expr(p.polqual, p.polrelid) AS using_expression,
       pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid) AS check_expression
FROM pg_catalog.pg_policy p
JOIN pg_catalog.pg_class r ON r.oid = p.polrelid
JOIN pg_catalog.pg_namespace n ON n.oid = r.relnamespace
WHERE n.nspname = 'public'
  AND r.relname IN (
    'product_inventory','product_inventory_history','product_field_overrides',
    'product_barcodes','product_field_correction_intents',
    'product_field_correction_requests','product_field_audit_reviews',
    'product_field_reconciliation_events','ipos_normalization_commits',
    'ipos_normalization_commit_rows'
  )
ORDER BY r.relname, p.polname;

-- Role labels required by the existing authorization model.
SELECT e.enumlabel AS role_label
FROM pg_catalog.pg_enum e
JOIN pg_catalog.pg_type t ON t.oid = e.enumtypid
JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'public' AND t.typname = 'user_role'
ORDER BY e.enumsortorder;

-- No mutation or migration statement follows this final inspection query.
