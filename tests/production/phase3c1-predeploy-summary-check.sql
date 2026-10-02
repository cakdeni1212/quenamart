-- Phase 3C.1A production pre-deployment summary check.
-- Before running, independently verify in Supabase Dashboard that the active
-- project ref is giwuzemjmimuvhtvjfhq. PostgreSQL SQL cannot prove that ref.
-- This statement is read-only. Review FAIL and REVIEW rows before proceeding.

WITH
expected_migrations(version) AS (
  VALUES ('20260928'), ('20260928115000'), ('20260928143000'),
         ('20260929100000'), ('20260929130000'), ('20260929150000'),
         ('20260929160000'), ('20260929170000')
),
actual_migrations AS (
  SELECT version::text AS version FROM supabase_migrations.schema_migrations
),
migration_diff AS (
  SELECT
    count(*) FILTER (WHERE e.version IS NOT NULL AND a.version IS NULL) AS missing_expected,
    count(*) FILTER (WHERE e.version IS NULL AND a.version IS NOT NULL) AS unexpected_actual,
    coalesce(string_agg('missing:' || e.version, ', ')
      FILTER (WHERE e.version IS NOT NULL AND a.version IS NULL), '') AS missing_list,
    coalesce(string_agg('unexpected:' || a.version, ', ')
      FILTER (WHERE e.version IS NULL AND a.version IS NOT NULL), '') AS unexpected_list
  FROM expected_migrations e
  FULL JOIN actual_migrations a ON a.version = e.version
),
required_relations(schemaname, relname) AS (
  VALUES
    ('public','profiles'), ('public','outlets'), ('public','products'),
    ('public','product_inventory'), ('public','product_inventory_history'),
    ('public','product_field_overrides'), ('public','product_barcodes'),
    ('public','product_field_audit_reviews'),
    ('public','product_field_correction_requests'),
    ('public','product_field_correction_intents'),
    ('public','ipos_import_batches'), ('public','ipos_import_rows'),
    ('public','ipos_normalization_commits'),
    ('public','ipos_normalization_commit_rows'), ('auth','users')
),
relation_state AS (
  SELECT e.schemaname, e.relname, c.oid, c.relkind
  FROM required_relations e
  LEFT JOIN pg_catalog.pg_namespace n ON n.nspname = e.schemaname
  LEFT JOIN pg_catalog.pg_class c ON c.relnamespace = n.oid AND c.relname = e.relname
),
required_columns(schemaname, relname, attname) AS (
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
),
column_state AS (
  SELECT e.schemaname, e.relname, e.attname, a.attnum IS NOT NULL AS present
  FROM required_columns e
  LEFT JOIN pg_catalog.pg_namespace n ON n.nspname = e.schemaname
  LEFT JOIN pg_catalog.pg_class c ON c.relnamespace = n.oid AND c.relname = e.relname
  LEFT JOIN pg_catalog.pg_attribute a
    ON a.attrelid = c.oid AND a.attname = e.attname
   AND a.attnum > 0 AND NOT a.attisdropped
),
required_functions(signature) AS (
  VALUES
    ('auth.uid()'),
    ('public.current_active_user_role()'),
    ('public.commit_ipos_normalization(uuid,text,jsonb)'),
    ('public.apply_product_field_correction(uuid,uuid,uuid,text,jsonb,text,uuid,text)'),
    ('public.issue_product_field_correction_intent(uuid,uuid,text,uuid,jsonb,text,text)'),
    ('public.apply_product_field_correction_payload(uuid,uuid,uuid,text,jsonb,text,uuid,text)'),
    ('public.apply_product_field_correction_intent(uuid)')
),
function_state AS (
  SELECT signature, to_regprocedure(signature) IS NOT NULL AS present
  FROM required_functions
),
required_constraints(relname, conname, expected_columns) AS (
  VALUES
    ('ipos_import_batches','ipos_batches_id_outlet_unique',ARRAY['id','outlet_id']::text[]),
    ('ipos_import_rows','ipos_rows_id_product_outlet_unique',ARRAY['id','product_id','outlet_id']::text[]),
    ('ipos_import_rows','ipos_rows_full_provenance_unique',ARRAY['id','batch_id','outlet_id','product_id']::text[]),
    ('product_barcodes','product_barcodes_id_product_unique',ARRAY['id','product_id']::text[]),
    ('ipos_normalization_commits','ipos_normalization_commits_id_outlet_unique',ARRAY['id','outlet_id']::text[])
),
candidate_unique_keys AS (
  SELECT idx.indrelid,
         index_relation.relname::text AS index_name,
         key_constraint.conname::text AS constraint_name,
         array_agg(attribute.attname::text ORDER BY key_column.ordinality) AS key_columns
  FROM pg_catalog.pg_index idx
  JOIN pg_catalog.pg_class index_relation ON index_relation.oid = idx.indexrelid
  JOIN LATERAL unnest(idx.indkey) WITH ORDINALITY AS key_column(attnum, ordinality)
    ON key_column.ordinality <= idx.indnkeyatts
  LEFT JOIN pg_catalog.pg_attribute attribute
    ON attribute.attrelid = idx.indrelid AND attribute.attnum = key_column.attnum
  LEFT JOIN pg_catalog.pg_constraint key_constraint
    ON key_constraint.conindid = idx.indexrelid AND key_constraint.contype IN ('p','u')
  WHERE idx.indisunique AND idx.indisvalid AND idx.indisready
    AND idx.indpred IS NULL AND idx.indexprs IS NULL
    AND (key_constraint.oid IS NULL OR
         (key_constraint.contype IN ('p','u') AND NOT key_constraint.condeferrable))
  GROUP BY idx.indrelid, index_relation.relname, key_constraint.conname, idx.indnkeyatts
  HAVING count(*) = idx.indnkeyatts AND bool_and(attribute.attname IS NOT NULL)
),
required_constraint_state AS (
  SELECT e.relname, e.conname, e.expected_columns,
         EXISTS (
           SELECT 1
           FROM candidate_unique_keys k
           WHERE k.indrelid = to_regclass('public.' || e.relname)
             AND k.key_columns = e.expected_columns
         ) AS present,
         EXISTS (
           SELECT 1
           FROM pg_catalog.pg_constraint c
           JOIN candidate_unique_keys k ON k.indrelid = c.conrelid
             AND k.constraint_name = c.conname
             AND k.key_columns = e.expected_columns
           WHERE c.conrelid = to_regclass('public.' || e.relname)
             AND c.conname = e.conname
         ) AS expected_name_present
  FROM required_constraints e
),
required_indexes(indexname) AS (
  VALUES ('product_field_correction_intents_pending_payload_unique')
),
required_index_state AS (
  SELECT e.indexname,
         i.indexrelid IS NOT NULL AND i.indisunique
           AND pg_catalog.pg_get_indexdef(i.indexrelid, 1, true) = 'actor_id'
           AND pg_catalog.pg_get_indexdef(i.indexrelid, 2, true) = 'request_payload'
           AND lower(regexp_replace(coalesce(pg_catalog.pg_get_expr(i.indpred, i.indrelid), ''),
                                    '[[:space:]()]', '', 'g')) = 'completed_atisnull'
           AS present
  FROM required_indexes e
  LEFT JOIN pg_catalog.pg_class c
    ON c.relnamespace = 'public'::regnamespace AND c.relname = e.indexname
   AND c.relkind = 'i'
  LEFT JOIN pg_catalog.pg_index i ON i.indexrelid = c.oid
),
expected_roles(role_name) AS (
  VALUES ('OWNER'), ('ADMIN'), ('KASIR'), ('GUDANG')
),
actual_roles AS (
  SELECT e.enumlabel::text AS role_name
  FROM pg_catalog.pg_enum e
  JOIN pg_catalog.pg_type t ON t.oid = e.enumtypid
  JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public' AND t.typname = 'user_role'
),
role_diff AS (
  SELECT
    count(*) FILTER (WHERE e.role_name IS NOT NULL AND a.role_name IS NULL) AS missing_count,
    count(*) FILTER (WHERE e.role_name IS NULL AND a.role_name IS NOT NULL) AS extra_count,
    coalesce(string_agg('missing:' || e.role_name, ', ')
      FILTER (WHERE e.role_name IS NOT NULL AND a.role_name IS NULL), '') AS missing_list,
    coalesce(string_agg('extra:' || a.role_name, ', ')
      FILTER (WHERE e.role_name IS NULL AND a.role_name IS NOT NULL), '') AS extra_list
  FROM expected_roles e
  FULL JOIN actual_roles a ON a.role_name = e.role_name
),
planned_types(typname) AS (
  VALUES ('stock_authority_mode'), ('stock_movement_type'), ('stock_movement_source'),
         ('stock_opname_scope'), ('stock_opname_status'), ('stock_count_event_type'),
         ('stock_opname_event_type'), ('stock_request_state')
),
type_collisions AS (
  SELECT count(*) AS collision_count,
         coalesce(string_agg(e.typname, ', '), '') AS names
  FROM planned_types e
  JOIN pg_catalog.pg_type t
    ON t.typnamespace = 'public'::regnamespace AND t.typname = e.typname
),
planned_relations(relname) AS (
  VALUES ('stock_authority_periods'), ('stock_balance_projection'),
         ('stock_balance_baseline_events'), ('stock_operation_requests'),
         ('stock_opname_sessions'), ('stock_opname_items'),
         ('stock_opname_count_events'), ('stock_opname_session_events'),
         ('stock_movement_batches'), ('stock_movements'),
         ('stock_movement_source_reconciliations'), ('stock_balance_projection_events')
),
relation_collisions AS (
  SELECT count(*) AS collision_count,
         coalesce(string_agg(e.relname || ':' || c.relkind::text, ', '), '') AS names
  FROM planned_relations e
  JOIN pg_catalog.pg_class c
    ON c.relnamespace = 'public'::regnamespace AND c.relname = e.relname
),
planned_constraints(relname, conname) AS (
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
),
constraint_collisions AS (
  SELECT count(*) AS collision_count,
         coalesce(string_agg(e.relname || '.' || e.conname, ', '), '') AS names
  FROM planned_constraints e
  JOIN pg_catalog.pg_constraint c
    ON c.conrelid = to_regclass('public.' || e.relname) AND c.conname = e.conname
),
planned_indexes(indexname) AS (
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
),
index_collisions AS (
  SELECT count(*) AS collision_count,
         coalesce(string_agg(e.indexname, ', '), '') AS names
  FROM planned_indexes e
  JOIN pg_catalog.pg_class c
    ON c.relnamespace = 'public'::regnamespace AND c.relname = e.indexname
   AND c.relkind = 'i'
),
planned_functions(signature, proname) AS (
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
),
function_collisions AS (
  SELECT
    count(*) FILTER (WHERE to_regprocedure(f.signature) IS NOT NULL) AS exact_count,
    count(*) FILTER (WHERE EXISTS (
      SELECT 1 FROM pg_catalog.pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace AND p.proname = f.proname
    )) AS overload_name_count,
    coalesce(string_agg(f.signature, ', ')
      FILTER (WHERE to_regprocedure(f.signature) IS NOT NULL), '') AS exact_names,
    coalesce(string_agg(f.proname || '[' || coalesce((
      SELECT string_agg(pg_catalog.pg_get_function_identity_arguments(p.oid), '; ')
      FROM pg_catalog.pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace AND p.proname = f.proname
    ), '') || ']', ', ')
      FILTER (WHERE EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc p
        WHERE p.pronamespace = 'public'::regnamespace AND p.proname = f.proname
      )), '') AS overload_names
  FROM planned_functions f
),
planned_triggers(relname, triggername) AS (
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
),
trigger_collisions AS (
  SELECT count(*) AS collision_count,
         coalesce(string_agg(e.relname || '.' || e.triggername, ', '), '') AS names
  FROM planned_triggers e
  JOIN pg_catalog.pg_trigger t
    ON t.tgrelid = to_regclass('public.' || e.relname)
   AND t.tgname = e.triggername AND NOT t.tgisinternal
),
planned_policies(relname, policyname) AS (
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
),
policy_collisions AS (
  SELECT count(*) AS collision_count,
         coalesce(string_agg(e.relname || '.' || e.policyname, ', '), '') AS names
  FROM planned_policies e
  JOIN pg_catalog.pg_policy p
    ON p.polrelid = to_regclass('public.' || e.relname) AND p.polname = e.policyname
),
inventory_metrics AS (
  SELECT count(*) AS row_count,
         count(DISTINCT (i.product_id, i.outlet_id)) AS distinct_product_outlet_count,
         count(*) FILTER (WHERE i.quantity IS NULL) AS null_quantity,
         count(*) FILTER (WHERE i.quantity < 0) AS negative_quantity,
         count(*) FILTER (WHERE i.quantity >= 100000000000) AS out_of_range_quantity,
         count(*) FILTER (WHERE i.quantity <> trunc(i.quantity, 3)) AS excess_precision_quantity,
         count(*) FILTER (WHERE i.source_import_row_id IS NULL) AS null_source_pointer,
         count(*) FILTER (WHERE p.id IS NULL) AS missing_product,
         count(*) FILTER (WHERE o.id IS NULL) AS missing_outlet,
         count(*) - count(DISTINCT (i.product_id, i.outlet_id)) AS duplicate_product_outlet_rows
  FROM public.product_inventory i
  LEFT JOIN public.products p ON p.id = i.product_id
  LEFT JOIN public.outlets o ON o.id = i.outlet_id
),
minimum_metrics AS (
  SELECT count(*) FILTER (WHERE minimum_quantity IS NULL) AS null_minimum,
         count(*) FILTER (WHERE minimum_quantity < 0) AS negative_minimum,
         count(*) FILTER (WHERE minimum_quantity >= 100000000000) AS out_of_range_minimum,
         count(*) FILTER (WHERE minimum_quantity <> trunc(minimum_quantity, 3)) AS excess_precision_minimum
  FROM public.product_inventory
),
bootstrap_metrics AS (
  SELECT count(*) AS inventory_rows,
         count(*) FILTER (WHERE i.quantity IS NOT NULL AND i.source_import_row_id IS NOT NULL
           AND EXISTS (
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
           )) AS eligible_rows,
         count(*) FILTER (WHERE i.quantity IS NOT NULL AND i.source_import_row_id IS NOT NULL
           AND NOT EXISTS (
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
           )) AS rows_without_eligible_provenance,
         count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM public.product_field_overrides o
           WHERE o.product_id = i.product_id AND o.outlet_id = i.outlet_id
             AND o.field_key = 'quantity' AND o.is_active
         )) AS rows_with_active_quantity_override
  FROM public.product_inventory i
),
override_metrics AS (
  SELECT count(*) FILTER (WHERE field_key = 'quantity' AND is_active) AS active_quantity,
         count(*) FILTER (WHERE field_key = 'minimum_quantity' AND is_active) AS active_minimum
  FROM public.product_field_overrides
  WHERE field_key IN ('quantity','minimum_quantity')
),
barcode_metrics AS (
  SELECT count(*) AS active_associations,
         count(DISTINCT barcode) AS distinct_active_values,
         count(*) FILTER (WHERE btrim(barcode) = '' OR barcode ~ '[[:cntrl:]]') AS malformed_values
  FROM public.product_barcodes WHERE is_active
),
barcode_ambiguity AS (
  SELECT count(*) AS duplicate_values,
         coalesce(sum(product_count), 0) AS affected_product_count
  FROM (
    SELECT barcode, count(DISTINCT product_id) AS product_count
    FROM public.product_barcodes WHERE is_active
    GROUP BY barcode HAVING count(DISTINCT product_id) > 1
  ) d
),
security_relations(schemaname, relname, expected_select, expected_private) AS (
  VALUES
    ('public','product_inventory',true,false),
    ('public','product_inventory_history',true,false),
    ('public','product_field_overrides',true,false),
    ('public','product_barcodes',true,false),
    ('public','product_field_correction_intents',false,true),
    ('public','product_field_correction_requests',false,true)
),
security_metrics AS (
  SELECT count(*) FILTER (WHERE c.oid IS NULL OR NOT c.relrowsecurity) AS rls_failures,
         count(*) FILTER (WHERE c.oid IS NOT NULL AND s.expected_select
           AND NOT has_table_privilege('authenticated', c.oid, 'SELECT')) AS select_failures,
         count(*) FILTER (WHERE c.oid IS NOT NULL AND s.expected_private
           AND has_table_privilege('authenticated', c.oid, 'SELECT')) AS private_select_failures,
         count(*) FILTER (WHERE c.oid IS NOT NULL
           AND has_table_privilege('anon', c.oid, 'SELECT')) AS anon_select_failures,
         count(*) FILTER (WHERE c.oid IS NOT NULL AND (
           has_table_privilege('anon', c.oid, 'INSERT') OR
           has_table_privilege('anon', c.oid, 'UPDATE') OR
           has_table_privilege('anon', c.oid, 'DELETE') OR
           has_table_privilege('authenticated', c.oid, 'INSERT') OR
           has_table_privilege('authenticated', c.oid, 'UPDATE') OR
           has_table_privilege('authenticated', c.oid, 'DELETE')
         )) AS direct_dml_failures
  FROM security_relations s
  LEFT JOIN pg_catalog.pg_namespace n ON n.nspname = s.schemaname
  LEFT JOIN pg_catalog.pg_class c ON c.relnamespace = n.oid AND c.relname = s.relname
),
gate_rows AS (
  SELECT 1 AS check_order, 'migration_ledger_expected'::text AS check_name,
         CASE WHEN d.missing_expected = 0 AND d.unexpected_actual = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
         'missing=' || d.missing_expected || '; unexpected=' || d.unexpected_actual AS actual,
         'exactly 8 expected versions through 20260929170000' AS expected,
         concat_ws(' ', nullif(d.missing_list,''), nullif(d.unexpected_list,'')) AS detail,
         true AS blocking
  FROM migration_diff d
  UNION ALL
  SELECT 2, 'migration_171000_absent',
         CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
         count(*)::text, '0', 'Forward-fix migration must not already be applied.', true
  FROM actual_migrations WHERE version = '20260929171000'
  UNION ALL
  SELECT 3, 'migration_180000_absent',
         CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
         count(*)::text, '0', 'Stock foundation migration must not already be applied.', true
  FROM actual_migrations WHERE version = '20260929180000'
  UNION ALL
  SELECT 4, 'required_relations_present',
         CASE WHEN count(*) FILTER (WHERE oid IS NULL) = 0 THEN 'PASS' ELSE 'FAIL' END,
         count(*) FILTER (WHERE oid IS NOT NULL)::text || '/' || count(*)::text,
         count(*)::text || '/' || count(*)::text,
         coalesce(string_agg(schemaname || '.' || relname, ', ') FILTER (WHERE oid IS NULL), 'none missing'), true
  FROM relation_state
  UNION ALL
  SELECT 5, 'required_columns_present',
         CASE WHEN count(*) FILTER (WHERE NOT present) = 0 THEN 'PASS' ELSE 'FAIL' END,
         count(*) FILTER (WHERE present)::text || '/' || count(*)::text,
         count(*)::text || '/' || count(*)::text,
         coalesce(string_agg(schemaname || '.' || relname || '.' || attname, ', ') FILTER (WHERE NOT present), 'none missing'), true
  FROM column_state
  UNION ALL
  SELECT 6, 'required_functions_present',
         CASE WHEN count(*) FILTER (WHERE NOT present) = 0 THEN 'PASS' ELSE 'FAIL' END,
         count(*) FILTER (WHERE present)::text || '/' || count(*)::text,
         count(*)::text || '/' || count(*)::text,
         coalesce(string_agg(signature, ', ') FILTER (WHERE NOT present), 'none missing'), true
  FROM function_state
  UNION ALL
  SELECT 7, 'required_constraints_present',
         CASE WHEN count(*) FILTER (WHERE NOT present) = 0 THEN 'PASS' ELSE 'FAIL' END,
         count(*) FILTER (WHERE present)::text || '/' || count(*)::text,
         count(*)::text || '/' || count(*)::text,
         coalesce(string_agg(relname || '.' || conname, ', ') FILTER (WHERE NOT present), 'none missing structurally') ||
           '; expected_named_constraints=' || count(*) FILTER (WHERE expected_name_present)::text || '/' || count(*)::text,
         true
  FROM required_constraint_state
  UNION ALL
  SELECT 8, 'required_indexes_present',
         CASE WHEN count(*) FILTER (WHERE NOT present) = 0 THEN 'PASS' ELSE 'FAIL' END,
         count(*) FILTER (WHERE present)::text || '/' || count(*)::text,
         count(*)::text || '/' || count(*)::text,
         coalesce(string_agg(indexname, ', ') FILTER (WHERE NOT present), 'none missing'), true
  FROM required_index_state
  UNION ALL
  SELECT 9, 'user_role_values',
         CASE WHEN d.missing_count = 0 AND d.extra_count = 0 THEN 'PASS' ELSE 'FAIL' END,
         'missing=' || d.missing_count || '; extra=' || d.extra_count,
         'OWNER, ADMIN, KASIR, GUDANG exactly',
         concat_ws(' ', nullif(d.missing_list,''), nullif(d.extra_list,'')), true
  FROM role_diff d
  UNION ALL
  SELECT 10, 'stock_enum_collisions',
         CASE WHEN collision_count = 0 THEN 'PASS' ELSE 'FAIL' END,
         collision_count::text, '0', coalesce(nullif(names,''),'none'), true
  FROM type_collisions
  UNION ALL
  SELECT 11, 'stock_relation_collisions',
         CASE WHEN collision_count = 0 THEN 'PASS' ELSE 'FAIL' END,
         collision_count::text, '0', coalesce(nullif(names,''),'none'), true
  FROM relation_collisions
  UNION ALL
  SELECT 12, 'stock_constraint_collisions',
         CASE WHEN collision_count = 0 THEN 'PASS' ELSE 'FAIL' END,
         collision_count::text, '0', coalesce(nullif(names,''),'none'), true
  FROM constraint_collisions
  UNION ALL
  SELECT 13, 'stock_function_collisions',
         CASE WHEN exact_count = 0 AND overload_name_count = 0 THEN 'PASS'
              WHEN exact_count > 0 THEN 'FAIL' ELSE 'REVIEW' END,
         'exact=' || exact_count || '; names_with_overloads=' || overload_name_count,
         'exact=0; overloads=0 unless reviewed',
         concat_ws(' ', nullif(exact_names,''), nullif(overload_names,'')), true
  FROM function_collisions
  UNION ALL
  SELECT 14, 'stock_index_collisions',
         CASE WHEN collision_count = 0 THEN 'PASS' ELSE 'FAIL' END,
         collision_count::text, '0', coalesce(nullif(names,''),'none'), true
  FROM index_collisions
  UNION ALL
  SELECT 15, 'stock_trigger_collisions',
         CASE WHEN collision_count = 0 THEN 'PASS' ELSE 'FAIL' END,
         collision_count::text, '0', coalesce(nullif(names,''),'none'), true
  FROM trigger_collisions
  UNION ALL
  SELECT 16, 'stock_policy_collisions',
         CASE WHEN collision_count = 0 THEN 'PASS' ELSE 'FAIL' END,
         collision_count::text, '0', coalesce(nullif(names,''),'none'), true
  FROM policy_collisions
  UNION ALL
  SELECT 17, 'inventory_row_integrity',
         CASE WHEN null_quantity + negative_quantity + out_of_range_quantity +
                         excess_precision_quantity + null_source_pointer + missing_product +
                         missing_outlet + duplicate_product_outlet_rows = 0
              THEN 'PASS' ELSE 'FAIL' END,
         'rows=' || row_count || '; null_qty=' || null_quantity || '; negative=' || negative_quantity ||
         '; range=' || out_of_range_quantity || '; precision=' || excess_precision_quantity ||
         '; null_source=' || null_source_pointer || '; missing_product=' || missing_product ||
         '; missing_outlet=' || missing_outlet || '; duplicate_pair=' || duplicate_product_outlet_rows,
         'all listed defect counts 0', 'Stock bootstrap requires complete nonnegative inventory with unique product/outlet provenance.', true
  FROM inventory_metrics
  UNION ALL
  SELECT 18, 'inventory_minimum_quantity_integrity',
         CASE WHEN negative_minimum + out_of_range_minimum + excess_precision_minimum = 0
              THEN 'PASS' ELSE 'FAIL' END,
         'null=' || null_minimum || '; negative=' || negative_minimum ||
         '; range=' || out_of_range_minimum || '; precision=' || excess_precision_minimum,
         'null allowed; other defect counts 0',
         'minimum_quantity is nullable in the existing schema and is not used by the 180000 bootstrap.', true
  FROM minimum_metrics
  UNION ALL
  SELECT 19, 'bootstrap_provenance',
         CASE WHEN rows_without_eligible_provenance = 0 AND rows_with_active_quantity_override = 0
              THEN 'PASS' ELSE 'FAIL' END,
         'inventory=' || inventory_rows || '; eligible=' || eligible_rows ||
         '; ineligible=' || rows_without_eligible_provenance ||
         '; active_qty_override_rows=' || rows_with_active_quantity_override,
         'every inventory row eligible; active quantity overrides=0',
         'Requires valid source row, completed batch and commit, CREATE/UPDATE proposal, matching product/outlet, matching normalized quantity, and no invalid STOK validation error.', true
  FROM bootstrap_metrics
  UNION ALL
  SELECT 20, 'active_quantity_overrides',
         CASE WHEN active_quantity = 0 THEN 'PASS' ELSE 'FAIL' END,
         active_quantity::text, '0', '180000 explicitly aborts when an active quantity override exists.', true
  FROM override_metrics
  UNION ALL
  SELECT 21, 'active_minimum_quantity_overrides',
         CASE WHEN active_minimum = 0 THEN 'PASS' ELSE 'REVIEW' END,
         active_minimum::text, 'reported; not a 180000 blocker',
         '180000 does not block bootstrap on minimum_quantity overrides.', false
  FROM override_metrics
  UNION ALL
  SELECT 22, 'barcode_cross_product_ambiguity',
         CASE WHEN duplicate_values = 0 THEN 'PASS' ELSE 'REVIEW' END,
         'duplicate_values=' || duplicate_values || '; affected_products=' || affected_product_count,
         '0 preferred; resolver returns an explicit ambiguous state when greater than 1 product matches',
         'Aggregate only; no barcode values or product identities returned.', false
  FROM barcode_ambiguity
  UNION ALL
  SELECT 23, 'malformed_active_barcodes',
         CASE WHEN malformed_values = 0 THEN 'PASS' ELSE 'REVIEW' END,
         malformed_values::text, '0 preferred',
         'Resolver rejects control characters and trims input; this is reported for manual assessment.', false
  FROM barcode_metrics
  UNION ALL
  SELECT 24, 'existing_rls_grant_assumptions',
         CASE WHEN rls_failures + select_failures + private_select_failures + anon_select_failures + direct_dml_failures = 0
              THEN 'PASS' ELSE 'FAIL' END,
         'rls=' || rls_failures || '; required_select=' || select_failures ||
         '; private_select=' || private_select_failures || '; anon_select=' || anon_select_failures ||
         '; direct_dml=' || direct_dml_failures,
         'RLS enabled; authenticated SELECT on inventory/history/overrides/barcodes; no anon/authenticated DML; correction request tables private',
         'Checks effective table privileges and RLS flags; inspect existing policies separately if results differ from reviewed migration definitions.', true
  FROM security_metrics
  UNION ALL
  SELECT 25, 'bootstrap_projection_expected_rows',
         CASE WHEN eligible_rows = inventory_rows AND rows_without_eligible_provenance = 0
              THEN 'PASS' ELSE 'FAIL' END,
         eligible_rows::text, inventory_rows::text,
         'Expected projection row count equals eligible product_inventory rows; no values are printed.', true
  FROM bootstrap_metrics
),
overall AS (
  SELECT CASE
           WHEN bool_or(status = 'FAIL' AND blocking) THEN 'FAIL'
           WHEN bool_or(status = 'REVIEW') THEN 'REVIEW'
           ELSE 'PASS'
         END AS status,
         count(*) FILTER (WHERE status = 'FAIL' AND blocking) AS blocking_failures,
         count(*) FILTER (WHERE status = 'REVIEW') AS review_count
  FROM gate_rows
)
SELECT check_order, check_name, status, actual, expected, detail
FROM (
  SELECT check_order, check_name, status, actual, expected, detail
  FROM gate_rows
  UNION ALL
  SELECT 999, 'overall_gate', status,
         'blocking_failures=' || blocking_failures || '; review_gates=' || review_count,
         'PASS only with zero blocking failures and zero REVIEW gates',
         'Computed from the component gate rows above.'
  FROM overall
) summary
ORDER BY check_order;
