-- Read-only Phase 3C.1A post-deployment verification for migration 180000.
-- REVIEW rows are informational and should be compared with captured
-- pre-deployment values; operational activity can legitimately change counts.
WITH
expected_migrations(version) AS (
  VALUES ('20260928'), ('20260928115000'), ('20260928143000'),
         ('20260929100000'), ('20260929130000'), ('20260929150000'),
         ('20260929160000'), ('20260929170000'), ('20260929171000'),
         ('20260929180000')
),
actual_migrations AS (
  SELECT version::text AS version FROM supabase_migrations.schema_migrations
),
migration_state AS (
  SELECT count(*) FILTER (WHERE e.version IS NOT NULL AND a.version IS NULL) AS missing_count,
         count(*) FILTER (WHERE e.version IS NULL AND a.version IS NOT NULL) AS unexpected_count,
         coalesce(string_agg('missing:' || e.version, ', ')
           FILTER (WHERE e.version IS NOT NULL AND a.version IS NULL), 'none') AS missing_versions,
         coalesce(string_agg('unexpected:' || a.version, ', ')
           FILTER (WHERE e.version IS NULL AND a.version IS NOT NULL), 'none') AS unexpected_versions
  FROM expected_migrations e FULL JOIN actual_migrations a ON a.version = e.version
),
expected_types(typname, labels) AS (
  VALUES
    ('stock_authority_mode', ARRAY['IPOS_SNAPSHOT_PLUS_QUENA_MOVEMENTS','QUENA_MOVEMENT_LEDGER']::text[]),
    ('stock_movement_type', ARRAY['OPENING','PURCHASE_RECEIPT','SALE','SALE_RETURN','SUPPLIER_RETURN','MANUAL_IN','MANUAL_OUT','OPNAME_ADJUSTMENT','TRANSFER_IN','TRANSFER_OUT','REVERSAL']::text[]),
    ('stock_movement_source', ARRAY['IPOS_IMPORT','QUENA_POS','PURCHASING','STOCK_OPNAME','MANUAL','TRANSFER']::text[]),
    ('stock_opname_scope', ARRAY['FULL','PARTIAL']::text[]),
    ('stock_opname_status', ARRAY['COUNTING','REVIEW','POSTED','CANCELLED']::text[]),
    ('stock_count_event_type', ARRAY['COUNTED','RECOUNTED','BASELINE_REFRESHED','STALE_BASELINE','EXCEPTION_REVIEWED']::text[]),
    ('stock_opname_event_type', ARRAY['CREATED','SUBMITTED_FOR_REVIEW','RETURNED_TO_COUNTING','POSTED','CANCELLED','BASELINE_STALE']::text[]),
    ('stock_request_state', ARRAY['PENDING','COMPLETED','STALE','SUPERSEDED']::text[])
),
type_state AS (
  SELECT e.typname, e.labels, t.oid,
         coalesce(array_agg(en.enumlabel::text ORDER BY en.enumsortorder)
           FILTER (WHERE en.enumlabel IS NOT NULL), ARRAY[]::text[]) AS actual_labels
  FROM expected_types e
  LEFT JOIN pg_catalog.pg_type t
    ON t.typnamespace = 'public'::regnamespace AND t.typname = e.typname AND t.typtype = 'e'
  LEFT JOIN pg_catalog.pg_enum en ON en.enumtypid = t.oid
  GROUP BY e.typname, e.labels, t.oid
),
expected_relations(relname) AS (
  VALUES ('stock_authority_periods'), ('stock_balance_projection'),
         ('stock_balance_baseline_events'), ('stock_operation_requests'),
         ('stock_opname_sessions'), ('stock_opname_items'),
         ('stock_opname_count_events'), ('stock_opname_session_events'),
         ('stock_movement_batches'), ('stock_movements'),
         ('stock_movement_source_reconciliations'), ('stock_balance_projection_events')
),
relation_state AS (
  SELECT e.relname, c.oid, c.relkind, c.relrowsecurity
  FROM expected_relations e
  LEFT JOIN pg_catalog.pg_class c
    ON c.relnamespace = 'public'::regnamespace AND c.relname = e.relname
),
expected_columns(relname, attname) AS (
  VALUES
    ('stock_authority_periods','id'), ('stock_authority_periods','outlet_id'), ('stock_authority_periods','mode'), ('stock_authority_periods','started_at'), ('stock_authority_periods','ended_at'), ('stock_authority_periods','created_by'), ('stock_authority_periods','created_reason'), ('stock_authority_periods','created_at'),
    ('stock_balance_projection','product_id'), ('stock_balance_projection','outlet_id'), ('stock_balance_projection','authority_period_id'), ('stock_balance_projection','baseline_quantity'), ('stock_balance_projection','baseline_source_import_row_id'), ('stock_balance_projection','baseline_batch_id'), ('stock_balance_projection','baseline_commit_id'), ('stock_balance_projection','unreconciled_movement_delta'), ('stock_balance_projection','effective_quantity'), ('stock_balance_projection','balance_version'), ('stock_balance_projection','last_observation_source_import_row_id'), ('stock_balance_projection','last_observation_status'), ('stock_balance_projection','updated_at'),
    ('stock_balance_baseline_events','id'), ('stock_balance_baseline_events','product_id'), ('stock_balance_baseline_events','outlet_id'), ('stock_balance_baseline_events','source_import_row_id'), ('stock_balance_baseline_events','batch_id'), ('stock_balance_baseline_events','normalization_commit_id'), ('stock_balance_baseline_events','event_type'), ('stock_balance_baseline_events','recorded_at'),
    ('stock_operation_requests','request_id'), ('stock_operation_requests','actor_id'), ('stock_operation_requests','operation_key'), ('stock_operation_requests','target_key'), ('stock_operation_requests','request_payload'), ('stock_operation_requests','payload_hash'), ('stock_operation_requests','state'), ('stock_operation_requests','result'), ('stock_operation_requests','created_at'), ('stock_operation_requests','completed_at'),
    ('stock_opname_sessions','id'), ('stock_opname_sessions','outlet_id'), ('stock_opname_sessions','scope_type'), ('stock_opname_sessions','status'), ('stock_opname_sessions','note'), ('stock_opname_sessions','created_by'), ('stock_opname_sessions','created_at'), ('stock_opname_sessions','started_at'), ('stock_opname_sessions','submitted_by'), ('stock_opname_sessions','submitted_at'), ('stock_opname_sessions','approved_by'), ('stock_opname_sessions','approved_at'), ('stock_opname_sessions','posted_at'), ('stock_opname_sessions','cancelled_by'), ('stock_opname_sessions','cancelled_at'),
    ('stock_opname_items','id'), ('stock_opname_items','session_id'), ('stock_opname_items','outlet_id'), ('stock_opname_items','product_id'), ('stock_opname_items','baseline_quantity'), ('stock_opname_items','baseline_source_import_row_id'), ('stock_opname_items','baseline_balance_version'), ('stock_opname_items','physical_quantity'), ('stock_opname_items','quantity_variance'), ('stock_opname_items','scanned_barcode_id'), ('stock_opname_items','revision_no'), ('stock_opname_items','requires_recount'), ('stock_opname_items','exception_reason'), ('stock_opname_items','exception_reviewed_by'), ('stock_opname_items','exception_reviewed_at'), ('stock_opname_items','last_counted_by'), ('stock_opname_items','last_counted_at'), ('stock_opname_items','active_scope'), ('stock_opname_items','created_at'), ('stock_opname_items','updated_at'),
    ('stock_opname_count_events','id'), ('stock_opname_count_events','item_id'), ('stock_opname_count_events','request_id'), ('stock_opname_count_events','event_type'), ('stock_opname_count_events','revision_no'), ('stock_opname_count_events','baseline_quantity'), ('stock_opname_count_events','baseline_balance_version'), ('stock_opname_count_events','physical_quantity'), ('stock_opname_count_events','barcode_id'), ('stock_opname_count_events','actor_id'), ('stock_opname_count_events','note'), ('stock_opname_count_events','created_at'),
    ('stock_opname_session_events','id'), ('stock_opname_session_events','session_id'), ('stock_opname_session_events','event_type'), ('stock_opname_session_events','previous_status'), ('stock_opname_session_events','next_status'), ('stock_opname_session_events','actor_id'), ('stock_opname_session_events','request_id'), ('stock_opname_session_events','note'), ('stock_opname_session_events','created_at'),
    ('stock_movement_batches','id'), ('stock_movement_batches','authority_period_id'), ('stock_movement_batches','outlet_id'), ('stock_movement_batches','source_system'), ('stock_movement_batches','operation_request_id'), ('stock_movement_batches','created_by'), ('stock_movement_batches','posted_at'), ('stock_movement_batches','created_at'),
    ('stock_movements','id'), ('stock_movements','batch_id'), ('stock_movements','authority_period_id'), ('stock_movements','outlet_id'), ('stock_movements','product_id'), ('stock_movements','movement_type'), ('stock_movements','source_system'), ('stock_movements','quantity_delta'), ('stock_movements','balance_before'), ('stock_movements','balance_after'), ('stock_movements','source_import_row_id'), ('stock_movements','opname_item_id'), ('stock_movements','source_reference'), ('stock_movements','source_event_key'), ('stock_movements','reverses_movement_id'), ('stock_movements','created_by'), ('stock_movements','created_at'),
    ('stock_movement_source_reconciliations','id'), ('stock_movement_source_reconciliations','movement_id'), ('stock_movement_source_reconciliations','reconciliation_group_id'), ('stock_movement_source_reconciliations','product_id'), ('stock_movement_source_reconciliations','outlet_id'), ('stock_movement_source_reconciliations','source_import_row_id'), ('stock_movement_source_reconciliations','batch_id'), ('stock_movement_source_reconciliations','confirmed_by'), ('stock_movement_source_reconciliations','reason'), ('stock_movement_source_reconciliations','request_id'), ('stock_movement_source_reconciliations','created_at'),
    ('stock_balance_projection_events','id'), ('stock_balance_projection_events','product_id'), ('stock_balance_projection_events','outlet_id'), ('stock_balance_projection_events','authority_period_id'), ('stock_balance_projection_events','event_type'), ('stock_balance_projection_events','request_id'), ('stock_balance_projection_events','quantity_delta'), ('stock_balance_projection_events','balance_before'), ('stock_balance_projection_events','balance_after'), ('stock_balance_projection_events','balance_version'), ('stock_balance_projection_events','actor_id'), ('stock_balance_projection_events','created_at')
),
column_state AS (
  SELECT e.relname, e.attname, a.attnum IS NOT NULL AS present
  FROM expected_columns e
  LEFT JOIN pg_catalog.pg_class c ON c.relnamespace = 'public'::regnamespace AND c.relname = e.relname
  LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attname = e.attname AND a.attnum > 0 AND NOT a.attisdropped
),
expected_constraints(relname, conname, contype) AS (
  VALUES
    ('stock_authority_periods','stock_authority_periods_pkey','p'), ('stock_authority_periods','stock_authority_period_reason_nonblank','c'), ('stock_authority_periods','stock_authority_period_time_valid','c'), ('stock_authority_periods','stock_authority_period_id_outlet_unique','u'),
    ('stock_balance_projection','stock_balance_projection_pkey','p'), ('stock_balance_projection','stock_balance_authority_period_fk','f'), ('stock_balance_projection','stock_balance_baseline_source_fk','f'), ('stock_balance_projection','stock_balance_observation_source_fk','f'), ('stock_balance_projection','stock_balance_baseline_identity_consistent','c'), ('stock_balance_projection','stock_balance_quantity_precision','c'), ('stock_balance_projection','stock_balance_version_positive','c'), ('stock_balance_projection','stock_balance_observation_status_valid','c'),
    ('stock_balance_baseline_events','stock_balance_baseline_events_pkey','p'), ('stock_balance_baseline_events','stock_balance_baseline_event_source_fk','f'), ('stock_balance_baseline_events','stock_balance_baseline_event_once','u'),
    ('stock_operation_requests','stock_operation_requests_pkey','p'), ('stock_operation_requests','stock_operation_request_hash_valid','c'), ('stock_operation_requests','stock_operation_request_state_consistent','c'),
    ('stock_opname_sessions','stock_opname_sessions_pkey','p'), ('stock_opname_sessions','stock_opname_note_nonblank','c'), ('stock_opname_sessions','stock_opname_lifecycle_valid','c'), ('stock_opname_sessions','stock_opname_id_outlet_unique','u'),
    ('stock_opname_items','stock_opname_items_pkey','p'), ('stock_opname_items','stock_opname_item_session_outlet_fk','f'), ('stock_opname_items','stock_opname_item_baseline_fk','f'), ('stock_opname_items','stock_opname_item_barcode_product_fk','f'), ('stock_opname_items','stock_opname_item_unique_product','u'), ('stock_opname_items','stock_opname_item_id_product_outlet_unique','u'), ('stock_opname_items','stock_opname_item_quantity_valid','c'), ('stock_opname_items','stock_opname_item_baseline_pair','c'), ('stock_opname_items','stock_opname_item_exception_consistent','c'), ('stock_opname_items','stock_opname_item_count_actor_consistent','c'), ('stock_opname_items','stock_opname_item_revision_nonnegative','c'),
    ('stock_opname_count_events','stock_opname_count_events_pkey','p'), ('stock_opname_count_events','stock_opname_count_event_revision_positive','c'), ('stock_opname_count_events','stock_opname_count_event_quantity_valid','c'), ('stock_opname_count_events','stock_opname_count_event_barcode_fk','f'), ('stock_opname_count_events','stock_opname_count_event_request_unique','u'),
    ('stock_opname_session_events','stock_opname_session_events_pkey','p'), ('stock_opname_session_events','stock_opname_session_event_request_unique','u'),
    ('stock_movement_batches','stock_movement_batches_pkey','p'), ('stock_movement_batches','stock_movement_batches_operation_request_id_key','u'), ('stock_movement_batches','stock_movement_batch_period_outlet_fk','f'), ('stock_movement_batches','stock_movement_batch_id_outlet_unique','u'), ('stock_movement_batches','stock_movement_batch_source_context_unique','u'),
    ('stock_movements','stock_movements_pkey','p'), ('stock_movements','stock_movement_batch_fk','f'), ('stock_movements','stock_movement_opname_item_fk','f'), ('stock_movements','stock_movement_source_row_fk','f'), ('stock_movements','stock_movement_id_product_outlet_unique','u'), ('stock_movements','stock_movement_delta_signed_nonzero','c'), ('stock_movements','stock_movement_balance_valid','c'), ('stock_movements','stock_movement_source_event_nonblank','c'), ('stock_movements','stock_movement_source_reference_nonblank','c'), ('stock_movements','stock_movement_identity_present','c'), ('stock_movements','stock_movement_manual_reason_required','c'), ('stock_movements','stock_movement_reason_source_valid','c'), ('stock_movements','stock_movement_sign_valid','c'), ('stock_movements','stock_movement_reversal_shape','c'), ('stock_movements','stock_movement_opname_shape','c'),
    ('stock_movement_source_reconciliations','stock_movement_source_reconciliations_pkey','p'), ('stock_movement_source_reconciliations','stock_movement_reconciliation_movement_fk','f'), ('stock_movement_source_reconciliations','stock_movement_reconciliation_source_fk','f'), ('stock_movement_source_reconciliations','stock_movement_reconciliation_reason_nonblank','c'), ('stock_movement_source_reconciliations','stock_movement_reconciled_once','u'), ('stock_movement_source_reconciliations','stock_movement_reconciliation_request_member_unique','u'), ('stock_movement_source_reconciliations','stock_movement_reconciliation_group_member_unique','u'),
    ('stock_balance_projection_events','stock_balance_projection_events_pkey','p'), ('stock_balance_projection_events','stock_balance_projection_event_product_fk','f'), ('stock_balance_projection_events','stock_balance_projection_event_period_fk','f'), ('stock_balance_projection_events','stock_balance_projection_event_quantity_valid','c')
),
constraint_state AS (
  SELECT e.relname, e.conname, e.contype, c.oid IS NOT NULL AS present, coalesce(c.convalidated,false) AS validated
  FROM expected_constraints e
  LEFT JOIN pg_catalog.pg_constraint c ON c.conrelid = to_regclass('public.' || e.relname) AND c.conname = e.conname AND c.contype = e.contype
),
expected_keys(relname, conname, key_columns, ref_relname, ref_columns) AS (
  VALUES
    ('stock_balance_projection','stock_balance_projection_pkey',ARRAY['product_id','outlet_id']::text[],NULL::text,NULL::text[]),
    ('stock_balance_projection','stock_balance_authority_period_fk',ARRAY['authority_period_id','outlet_id']::text[],'stock_authority_periods',ARRAY['id','outlet_id']::text[]),
    ('stock_balance_projection','stock_balance_baseline_source_fk',ARRAY['baseline_source_import_row_id','baseline_batch_id','outlet_id','product_id']::text[],'ipos_import_rows',ARRAY['id','batch_id','outlet_id','product_id']::text[]),
    ('stock_balance_projection','stock_balance_observation_source_fk',ARRAY['last_observation_source_import_row_id','product_id','outlet_id']::text[],'ipos_import_rows',ARRAY['id','product_id','outlet_id']::text[]),
    ('stock_balance_baseline_events','stock_balance_baseline_event_source_fk',ARRAY['source_import_row_id','batch_id','outlet_id','product_id']::text[],'ipos_import_rows',ARRAY['id','batch_id','outlet_id','product_id']::text[]),
    ('stock_opname_items','stock_opname_item_session_outlet_fk',ARRAY['session_id','outlet_id']::text[],'stock_opname_sessions',ARRAY['id','outlet_id']::text[]),
    ('stock_opname_items','stock_opname_item_barcode_product_fk',ARRAY['scanned_barcode_id','product_id']::text[],'product_barcodes',ARRAY['id','product_id']::text[]),
    ('stock_movement_batches','stock_movement_batch_source_context_unique',ARRAY['id','outlet_id','authority_period_id','source_system']::text[],NULL::text,NULL::text[]),
    ('stock_movements','stock_movement_batch_fk',ARRAY['batch_id','outlet_id','authority_period_id','source_system']::text[],'stock_movement_batches',ARRAY['id','outlet_id','authority_period_id','source_system']::text[]),
    ('stock_movements','stock_movement_opname_item_fk',ARRAY['opname_item_id','product_id','outlet_id']::text[],'stock_opname_items',ARRAY['id','product_id','outlet_id']::text[]),
    ('stock_movement_source_reconciliations','stock_movement_reconciliation_movement_fk',ARRAY['movement_id','product_id','outlet_id']::text[],'stock_movements',ARRAY['id','product_id','outlet_id']::text[]),
    ('stock_movement_source_reconciliations','stock_movement_reconciliation_source_fk',ARRAY['source_import_row_id','batch_id','outlet_id','product_id']::text[],'ipos_import_rows',ARRAY['id','batch_id','outlet_id','product_id']::text[])
),
key_state AS (
  SELECT e.relname, e.conname,
         ARRAY(SELECT la.attname::text FROM unnest(c.conkey) WITH ORDINALITY lk(attnum,ordinality)
               JOIN pg_catalog.pg_attribute la ON la.attrelid=c.conrelid AND la.attnum=lk.attnum
               ORDER BY lk.ordinality) = e.key_columns AS local_columns_match,
         CASE WHEN e.ref_relname IS NULL THEN true ELSE c.confrelid = to_regclass('public.' || e.ref_relname)
           AND ARRAY(SELECT ra.attname::text FROM unnest(c.confkey) WITH ORDINALITY rk(attnum,ordinality)
                     JOIN pg_catalog.pg_attribute ra ON ra.attrelid=c.confrelid AND ra.attnum=rk.attnum
                     ORDER BY rk.ordinality) = e.ref_columns END AS referenced_columns_match
  FROM expected_keys e
  JOIN pg_catalog.pg_constraint c ON c.conrelid = to_regclass('public.' || e.relname) AND c.conname = e.conname
),
expected_indexes(indexname,relname,is_unique,is_partial) AS (
  VALUES
    ('stock_authority_one_current_period_per_outlet','stock_authority_periods',true,true), ('stock_authority_periods_pkey','stock_authority_periods',true,false), ('stock_authority_period_id_outlet_unique','stock_authority_periods',true,false),
    ('stock_balance_outlet_product_idx','stock_balance_projection',false,false), ('ipos_normalization_rows_stock_source_lookup_idx','ipos_normalization_commit_rows',false,true), ('stock_balance_projection_pkey','stock_balance_projection',true,false),
    ('stock_balance_baseline_events_product_time_idx','stock_balance_baseline_events',false,false), ('stock_balance_baseline_events_pkey','stock_balance_baseline_events',true,false), ('stock_balance_baseline_event_once','stock_balance_baseline_events',true,false),
    ('stock_operation_one_pending_intent_per_target','stock_operation_requests',true,true), ('stock_operation_request_actor_recent_idx','stock_operation_requests',false,false), ('stock_operation_requests_pkey','stock_operation_requests',true,false),
    ('stock_opname_outlet_status_created_idx','stock_opname_sessions',false,false), ('stock_opname_sessions_pkey','stock_opname_sessions',true,false), ('stock_opname_id_outlet_unique','stock_opname_sessions',true,false),
    ('stock_opname_no_active_overlap','stock_opname_items',true,true), ('stock_opname_items_session_idx','stock_opname_items',false,false), ('stock_opname_items_pkey','stock_opname_items',true,false), ('stock_opname_item_unique_product','stock_opname_items',true,false), ('stock_opname_item_id_product_outlet_unique','stock_opname_items',true,false),
    ('stock_opname_count_events_item_time_idx','stock_opname_count_events',false,false), ('stock_opname_count_events_pkey','stock_opname_count_events',true,false), ('stock_opname_count_event_request_unique','stock_opname_count_events',true,false),
    ('stock_opname_session_events_session_time_idx','stock_opname_session_events',false,false), ('stock_opname_session_events_pkey','stock_opname_session_events',true,false), ('stock_opname_session_event_request_unique','stock_opname_session_events',true,false),
    ('stock_movement_batches_pkey','stock_movement_batches',true,false), ('stock_movement_batches_operation_request_id_key','stock_movement_batches',true,false), ('stock_movement_batch_id_outlet_unique','stock_movement_batches',true,false), ('stock_movement_batch_source_context_unique','stock_movement_batches',true,false),
    ('stock_movements_pkey','stock_movements',true,false), ('stock_movement_id_product_outlet_unique','stock_movements',true,false), ('stock_movement_one_reversal_per_original','stock_movements',true,true), ('stock_movement_source_event_once','stock_movements',true,true), ('stock_movements_product_time_idx','stock_movements',false,false), ('stock_movements_batch_idx','stock_movements',false,false),
    ('stock_movement_reconciliation_snapshot_idx','stock_movement_source_reconciliations',false,false), ('stock_movement_source_reconciliations_pkey','stock_movement_source_reconciliations',true,false), ('stock_movement_reconciled_once','stock_movement_source_reconciliations',true,false), ('stock_movement_reconciliation_request_member_unique','stock_movement_source_reconciliations',true,false), ('stock_movement_reconciliation_group_member_unique','stock_movement_source_reconciliations',true,false),
    ('stock_balance_projection_request_event_once','stock_balance_projection_events',true,true), ('stock_balance_projection_events_product_time_idx','stock_balance_projection_events',false,false), ('stock_balance_projection_events_pkey','stock_balance_projection_events',true,false)
),
index_state AS (
  SELECT e.indexname,e.relname,
         idx.oid IS NOT NULL AND i.indisvalid AND i.indisready AND i.indisunique = e.is_unique
           AND ((i.indpred IS NOT NULL) = e.is_partial) AND tbl.oid IS NOT NULL AS structurally_present
  FROM expected_indexes e
  LEFT JOIN pg_catalog.pg_class idx ON idx.relnamespace = 'public'::regnamespace AND idx.relname = e.indexname AND idx.relkind = 'i'
  LEFT JOIN pg_catalog.pg_index i ON i.indexrelid = idx.oid
  LEFT JOIN pg_catalog.pg_class tbl ON tbl.oid = i.indrelid
    AND tbl.oid = to_regclass('public.' || e.relname)
),
expected_functions(signature,proname,authenticated_execute,expected_prosecdef,expected_search_path) AS (
  VALUES
    ('public.validate_stock_movement_reversal()','validate_stock_movement_reversal',false,true,ARRAY['search_path=pg_catalog']::text[]),
    ('public.refresh_stock_balance_from_ipos_inventory()','refresh_stock_balance_from_ipos_inventory',false,true,ARRAY['search_path=pg_catalog']::text[]),
    ('public.reject_stock_ledger_mutation()','reject_stock_ledger_mutation',false,false,ARRAY['search_path=pg_catalog']::text[]),
    ('public.guard_posted_stock_opname()','guard_posted_stock_opname',false,false,ARRAY['search_path=pg_catalog']::text[]),
    ('public.guard_posted_stock_opname_item()','guard_posted_stock_opname_item',false,false,ARRAY['search_path=pg_catalog']::text[]),
    ('public.stock_apply_balance_delta(uuid,uuid,numeric)','stock_apply_balance_delta',false,true,ARRAY['search_path=pg_catalog']::text[]),
    ('public.stock_opname_content_hash(uuid)','stock_opname_content_hash',false,true,ARRAY['search_path=pg_catalog']::text[]),
    ('public.issue_stock_operation_intent(text,jsonb)','issue_stock_operation_intent',true,true,ARRAY['search_path=pg_catalog']::text[]),
    ('public.read_stock_operation_intent(uuid)','read_stock_operation_intent',true,true,ARRAY['search_path=pg_catalog']::text[]),
    ('public.resolve_stock_barcode(uuid,text)','resolve_stock_barcode',true,false,ARRAY['search_path=pg_catalog, public']::text[]),
    ('public.apply_stock_operation_intent(uuid)','apply_stock_operation_intent',true,true,ARRAY['search_path=pg_catalog']::text[])
),
function_state AS (
  SELECT e.signature,e.proname,e.authenticated_execute,e.expected_prosecdef,e.expected_search_path,
         p.oid,p.prosecdef,p.proconfig,p.proowner,p.proacl,
         coalesce((SELECT count(*) FROM pg_catalog.pg_proc p2 WHERE p2.pronamespace='public'::regnamespace AND p2.proname=e.proname),0) AS same_name_count,
         has_function_privilege('authenticated',p.oid,'EXECUTE') AS auth_exec,
         has_function_privilege('anon',p.oid,'EXECUTE') AS anon_exec,
         has_function_privilege('service_role',p.oid,'EXECUTE') AS service_exec,
         NOT EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a WHERE a.grantee=0 AND a.privilege_type='EXECUTE') AS public_exec_revoked
  FROM expected_functions e LEFT JOIN pg_catalog.pg_proc p ON p.oid=to_regprocedure(e.signature)::oid
),
expected_triggers(relname,triggername,function_name,expected_tgtype) AS (
  VALUES
    ('stock_movements','stock_movement_validate_reversal','validate_stock_movement_reversal',7),
    ('product_inventory','product_inventory_refresh_stock_projection_insert','refresh_stock_balance_from_ipos_inventory',5),
    ('product_inventory','product_inventory_refresh_stock_projection_source_update','refresh_stock_balance_from_ipos_inventory',17),
    ('stock_movement_batches','stock_movement_batches_immutable','reject_stock_ledger_mutation',27),
    ('stock_movements','stock_movements_immutable','reject_stock_ledger_mutation',27),
    ('stock_movement_source_reconciliations','stock_reconciliations_immutable','reject_stock_ledger_mutation',27),
    ('stock_balance_baseline_events','stock_baseline_events_immutable','reject_stock_ledger_mutation',27),
    ('stock_balance_projection_events','stock_projection_events_immutable','reject_stock_ledger_mutation',27),
    ('stock_opname_count_events','stock_count_events_immutable','reject_stock_ledger_mutation',27),
    ('stock_opname_session_events','stock_session_events_immutable','reject_stock_ledger_mutation',27),
    ('stock_opname_sessions','stock_opname_session_guard','guard_posted_stock_opname',19),
    ('stock_opname_items','stock_opname_item_guard','guard_posted_stock_opname_item',27)
),
trigger_state AS (
  SELECT e.relname,e.triggername,e.function_name,e.expected_tgtype,t.oid,t.tgenabled,t.tgtype,
         t.tgfoid = to_regprocedure('public.' || e.function_name || '()')::oid AS function_matches
  FROM expected_triggers e LEFT JOIN pg_catalog.pg_trigger t
    ON t.tgrelid=to_regclass('public.'||e.relname) AND t.tgname=e.triggername AND NOT t.tgisinternal
),
expected_policies(relname,policyname,manager_only) AS (
  VALUES
    ('stock_authority_periods','stock_authority_periods_select_roles',false),
    ('stock_balance_projection','stock_balance_projection_select_roles',false),
    ('stock_balance_baseline_events','stock_balance_baseline_events_select_roles',false),
    ('stock_balance_projection_events','stock_balance_projection_events_select_roles',false),
    ('stock_opname_sessions','stock_opname_sessions_select_roles',false),
    ('stock_opname_items','stock_opname_items_select_roles',false),
    ('stock_opname_count_events','stock_opname_count_events_select_roles',false),
    ('stock_opname_session_events','stock_opname_session_events_select_roles',false),
    ('stock_movement_batches','stock_movement_batches_select_roles',false),
    ('stock_movements','stock_movements_select_roles',false),
    ('stock_movement_source_reconciliations','stock_movement_reconciliations_select_managers',true)
),
policy_state AS (
  SELECT e.relname,e.policyname,e.manager_only,p.oid,p.polcmd,p.polroles,
         lower(coalesce(pg_get_expr(p.polqual,p.polrelid),'')) AS policy_expression
  FROM expected_policies e LEFT JOIN pg_catalog.pg_policy p
    ON p.polrelid=to_regclass('public.'||e.relname) AND p.polname=e.policyname
),
type_privileges AS (
  SELECT count(*) FILTER (WHERE NOT has_type_privilege('authenticated',t.oid,'USAGE')) AS missing_authenticated_usage,
         count(*) FILTER (WHERE has_type_privilege('anon',t.oid,'USAGE')) AS anon_usage,
         count(*) FILTER (WHERE has_type_privilege('service_role',t.oid,'USAGE')) AS service_usage
  FROM type_state t WHERE t.oid IS NOT NULL
),
table_security AS (
  SELECT r.relname,r.oid,r.relrowsecurity,
         has_table_privilege('anon',r.oid,'INSERT') OR has_table_privilege('anon',r.oid,'UPDATE') OR has_table_privilege('anon',r.oid,'DELETE') AS anon_dml,
         has_table_privilege('authenticated',r.oid,'INSERT') OR has_table_privilege('authenticated',r.oid,'UPDATE') OR has_table_privilege('authenticated',r.oid,'DELETE') AS authenticated_dml,
         has_table_privilege('service_role',r.oid,'INSERT') OR has_table_privilege('service_role',r.oid,'UPDATE') OR has_table_privilege('service_role',r.oid,'DELETE') AS service_dml,
         has_table_privilege('authenticated',r.oid,'SELECT') AS authenticated_select,
         has_table_privilege('anon',r.oid,'SELECT') AS anon_select,
         has_table_privilege('service_role',r.oid,'SELECT') AS service_select,
         EXISTS (SELECT 1 FROM aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a
                 WHERE a.grantee=0 AND a.privilege_type='SELECT') AS public_select,
         EXISTS (SELECT 1 FROM aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a
                 WHERE a.grantee=0 AND a.privilege_type IN ('INSERT','UPDATE','DELETE')) AS public_dml,
         CASE WHEN r.relname='stock_operation_requests' THEN has_table_privilege('authenticated',r.oid,'SELECT') ELSE NOT has_table_privilege('authenticated',r.oid,'SELECT') END AS request_select_mismatch
  FROM relation_state r JOIN pg_catalog.pg_class c ON c.oid=r.oid
),
important_index_keys(indexname,expected_columns) AS (
  VALUES
    ('stock_authority_one_current_period_per_outlet',ARRAY['outlet_id']::text[]),
    ('stock_balance_outlet_product_idx',ARRAY['outlet_id','product_id']::text[]),
    ('ipos_normalization_rows_stock_source_lookup_idx',ARRAY['source_row_id','batch_id','product_id']::text[]),
    ('stock_operation_one_pending_intent_per_target',ARRAY['actor_id','operation_key','target_key']::text[]),
    ('stock_opname_no_active_overlap',ARRAY['outlet_id','product_id']::text[]),
    ('stock_opname_items_session_idx',ARRAY['session_id','product_id']::text[]),
    ('stock_movement_one_reversal_per_original',ARRAY['reverses_movement_id']::text[]),
    ('stock_movement_source_event_once',ARRAY['source_system','source_event_key']::text[]),
    ('stock_balance_projection_request_event_once',ARRAY['request_id','event_type','product_id']::text[])
),
important_index_state AS (
  SELECT e.indexname,
         coalesce(array_agg(a.attname::text ORDER BY k.ordinality) FILTER (WHERE a.attname IS NOT NULL),ARRAY[]::text[]) = e.expected_columns AS columns_match
  FROM important_index_keys e
  LEFT JOIN pg_catalog.pg_class idx ON idx.relnamespace='public'::regnamespace AND idx.relname=e.indexname AND idx.relkind='i'
  LEFT JOIN pg_catalog.pg_index i ON i.indexrelid=idx.oid
  LEFT JOIN LATERAL unnest(i.indkey) WITH ORDINALITY k(attnum,ordinality) ON k.ordinality <= i.indnkeyatts
  LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=k.attnum
  GROUP BY e.indexname,e.expected_columns
),
projection_metrics AS (
  SELECT count(*) AS row_count,
         count(DISTINCT (p.product_id,p.outlet_id)) AS distinct_pairs,
         count(*) FILTER (WHERE p.effective_quantity < 0) AS negative_effective,
         count(*) FILTER (WHERE p.baseline_quantity IS NULL OR p.baseline_source_import_row_id IS NULL OR p.baseline_batch_id IS NULL OR p.baseline_commit_id IS NULL) AS missing_baseline_identity,
         count(*) FILTER (WHERE p.effective_quantity >= 100000000000 OR p.effective_quantity <> trunc(p.effective_quantity,3)) AS invalid_effective,
         count(*) FILTER (WHERE p.baseline_quantity < 0 OR p.baseline_quantity >= 100000000000 OR p.baseline_quantity <> trunc(p.baseline_quantity,3)) AS invalid_baseline,
         count(*) FILTER (WHERE p.unreconciled_movement_delta <= -100000000000 OR p.unreconciled_movement_delta >= 100000000000 OR p.unreconciled_movement_delta <> trunc(p.unreconciled_movement_delta,3)) AS invalid_overlay,
         count(*) FILTER (WHERE p.balance_version < 1) AS invalid_version
  FROM public.stock_balance_projection p
),
projection_provenance AS (
  SELECT count(*) AS projection_rows,
         count(*) FILTER (WHERE EXISTS (
           SELECT 1
           FROM public.ipos_import_rows r
           JOIN public.ipos_import_batches b ON b.id=r.batch_id AND b.outlet_id=r.outlet_id AND b.status='COMPLETED'
           JOIN public.ipos_normalization_commit_rows cr ON cr.source_row_id=r.id AND cr.batch_id=r.batch_id AND cr.product_id=p.product_id AND cr.action IN ('CREATE','UPDATE')
           JOIN public.ipos_normalization_commits nc ON nc.id=cr.commit_id AND nc.batch_id=r.batch_id AND nc.outlet_id=r.outlet_id AND nc.status='COMPLETED'
           WHERE r.id=p.baseline_source_import_row_id AND r.batch_id=p.baseline_batch_id
             AND r.product_id=p.product_id AND r.outlet_id=p.outlet_id AND r.status='VALID'
             AND nc.id=p.baseline_commit_id
             AND CASE jsonb_typeof(cr.normalized_data->'quantity')
               WHEN 'number' THEN (cr.normalized_data->>'quantity')::numeric=p.baseline_quantity
               WHEN 'string' THEN CASE WHEN cr.normalized_data->>'quantity' ~ '^-?[0-9]+([.][0-9]+)?$'
                 THEN (cr.normalized_data->>'quantity')::numeric=p.baseline_quantity ELSE false END
               ELSE false END
             AND NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(cr.validation_errors) e(value)
               WHERE e.value->>'code'='INVALID_NUMERIC_VALUE' AND e.value->>'field'='STOK')
         )) AS eligible_baselines
  FROM public.stock_balance_projection p
),
authority_state AS (
  SELECT count(*) FILTER (WHERE ended_at IS NULL) AS current_periods,
         count(*) FILTER (WHERE ended_at IS NULL AND mode='IPOS_SNAPSHOT_PLUS_QUENA_MOVEMENTS') AS transition_periods,
         count(*) FILTER (WHERE started_at IS NULL OR (ended_at IS NOT NULL AND ended_at <= started_at)) AS invalid_periods,
         count(*) FILTER (WHERE ended_at IS NULL AND id NOT IN (SELECT authority_period_id FROM public.stock_balance_projection)) AS current_periods_without_projection
  FROM public.stock_authority_periods
),
inventory_metrics AS (
  SELECT count(*) AS inventory_rows,
         count(*) FILTER (WHERE i.quantity IS NULL OR i.source_import_row_id IS NULL) AS missing_quantity_or_source,
         count(*) FILTER (WHERE i.quantity < 0 OR i.quantity >= 100000000000 OR i.quantity <> trunc(i.quantity,3)) AS invalid_quantity,
         count(*) FILTER (WHERE r.id IS NULL OR r.product_id<>i.product_id OR r.outlet_id<>i.outlet_id) AS bad_current_source_pointer
  FROM public.product_inventory i LEFT JOIN public.ipos_import_rows r ON r.id=i.source_import_row_id
),
activity_metrics AS (
  SELECT
    (SELECT count(*) FROM public.stock_movement_batches) AS movement_batches,
    (SELECT count(*) FROM public.stock_movements) AS movements,
    (SELECT count(*) FROM public.stock_movement_source_reconciliations) AS reconciliations,
    (SELECT count(*) FROM public.stock_balance_baseline_events) AS baseline_events,
    (SELECT count(*) FROM public.stock_balance_baseline_events WHERE event_type='BOOTSTRAP') AS bootstrap_events,
    (SELECT count(*) FROM public.stock_balance_projection_events) AS projection_events,
    (SELECT count(*) FROM public.stock_opname_sessions) AS opname_sessions,
    (SELECT count(*) FROM public.stock_opname_items) AS opname_items,
    (SELECT count(*) FROM public.stock_opname_count_events) AS count_events,
    (SELECT count(*) FROM public.stock_opname_session_events) AS session_events,
    (SELECT count(*) FROM public.stock_operation_requests) AS operation_requests,
    (SELECT count(*) FROM public.product_inventory_history) AS inventory_history_rows,
    (SELECT count(*) FROM public.product_barcodes WHERE is_active) AS active_barcodes,
    (SELECT count(*) FROM public.product_field_correction_requests) AS correction_requests,
    (SELECT count(*) FROM public.product_field_correction_intents) AS correction_intents
),
snapshot_comparison AS (
  SELECT count(*) FILTER (WHERE p.baseline_quantity IS DISTINCT FROM i.quantity
       OR p.baseline_source_import_row_id IS DISTINCT FROM i.source_import_row_id) AS baseline_vs_current_mismatches
  FROM public.stock_balance_projection p
  JOIN public.product_inventory i ON i.product_id=p.product_id AND i.outlet_id=p.outlet_id
),
stock_hpp_state AS (
  SELECT count(*) AS hpp_columns
  FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_class c ON c.oid=a.attrelid
  WHERE c.relnamespace='public'::regnamespace AND c.relname IN (SELECT relname FROM expected_relations)
    AND a.attnum>0 AND NOT a.attisdropped AND a.attname ILIKE '%hpp%'
),
stock_function_hpp_state AS (
  SELECT count(*) AS hpp_or_cost_references
  FROM function_state f JOIN pg_catalog.pg_proc p ON p.oid=f.oid
  WHERE p.prosrc ILIKE '%product_costs%' OR p.prosrc ILIKE '%hpp%'
),
refresh_body AS (
  SELECT lower(regexp_replace(pg_get_functiondef(p.oid),'[[:space:]]+',' ','g')) AS body
  FROM pg_catalog.pg_proc p WHERE p.oid=to_regprocedure('public.refresh_stock_balance_from_ipos_inventory()')::oid
),
gate_rows AS (
  SELECT 1 AS check_order,'migration_ledger_exact'::text AS check_name,
    CASE WHEN missing_count=0 AND unexpected_count=0 THEN 'PASS' ELSE 'FAIL' END AS status,
    'missing='||missing_count::text||'; unexpected='||unexpected_count::text AS actual,
    'exact expected set through 20260929180000, including 171000 and 180000' AS expected,
    missing_versions||'; '||unexpected_versions AS detail,true AS blocking
  FROM migration_state
  UNION ALL
  SELECT 2,'stock_enums_and_labels',CASE WHEN count(*) FILTER (WHERE oid IS NULL OR actual_labels<>labels)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE oid IS NOT NULL AND actual_labels=labels)::text||'/'||count(*)::text,count(*)::text||'/'||count(*)::text,
    coalesce(string_agg(typname,', ') FILTER (WHERE oid IS NULL OR actual_labels<>labels),'all enum labels match'),true FROM type_state
  UNION ALL
  SELECT 3,'stock_relations_present',CASE WHEN count(*) FILTER (WHERE oid IS NULL OR relkind<>'r')=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE oid IS NOT NULL AND relkind='r')::text||'/'||count(*)::text,count(*)::text||'/'||count(*)::text,
    coalesce(string_agg(relname,', ') FILTER (WHERE oid IS NULL OR relkind<>'r'),'all stock tables exist'),true FROM relation_state
  UNION ALL
  SELECT 4,'required_stock_columns',CASE WHEN count(*) FILTER (WHERE NOT present)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE present)::text||'/'||count(*)::text,count(*)::text||'/'||count(*)::text,
    coalesce(string_agg(relname||'.'||attname,', ') FILTER (WHERE NOT present),'none missing'),true FROM column_state
  UNION ALL
  SELECT 5,'required_constraints_present_and_validated',CASE WHEN count(*) FILTER (WHERE NOT present OR NOT validated)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE present AND validated)::text||'/'||count(*)::text,count(*)::text||'/'||count(*)::text,
    coalesce(string_agg(relname||'.'||conname,', ') FILTER (WHERE NOT present OR NOT validated),'all present and validated'),true FROM constraint_state
  UNION ALL
  SELECT 6,'key_and_fk_column_structures',CASE WHEN count(*) FILTER (WHERE NOT local_columns_match OR NOT referenced_columns_match)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE local_columns_match AND referenced_columns_match)::text||'/'||count(*)::text,count(*)::text||'/'||count(*)::text,
    coalesce(string_agg(relname||'.'||conname,', ') FILTER (WHERE NOT local_columns_match OR NOT referenced_columns_match),'ordered key columns match'),true FROM key_state
  UNION ALL
  SELECT 7,'required_indexes_structural',CASE WHEN count(*) FILTER (WHERE NOT structurally_present)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE structurally_present)::text||'/'||count(*)::text,count(*)::text||'/'||count(*)::text,
    coalesce(string_agg(indexname,', ') FILTER (WHERE NOT structurally_present),'valid index, relation, uniqueness and partialness verified'),true FROM index_state
  UNION ALL
  SELECT 8,'important_index_key_columns',CASE WHEN count(*) FILTER (WHERE NOT columns_match)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE columns_match)::text||'/'||count(*)::text,count(*)::text||'/'||count(*)::text,
    coalesce(string_agg(indexname,', ') FILTER (WHERE NOT columns_match),'important ordered index keys match'),true FROM important_index_state
  UNION ALL
  SELECT 9,'stock_function_signatures_and_overloads',CASE WHEN count(*) FILTER (WHERE oid IS NULL OR same_name_count<>1)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE oid IS NOT NULL AND same_name_count=1)::text||'/'||count(*)::text,count(*)::text||'/'||count(*)::text,
    coalesce(string_agg(signature,', ') FILTER (WHERE oid IS NULL OR same_name_count<>1),'exact signatures; no overloads'),true FROM function_state
  UNION ALL
  SELECT 10,'stock_function_security_and_execute',CASE WHEN count(*) FILTER (WHERE oid IS NULL OR same_name_count<>1 OR prosecdef IS DISTINCT FROM expected_prosecdef OR proconfig IS NULL OR NOT (proconfig @> expected_search_path) OR pg_get_userbyid(proowner)<>'postgres' OR NOT public_exec_revoked OR coalesce(anon_exec,true) OR coalesce(service_exec,true) OR coalesce(auth_exec,false)<>authenticated_execute)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE oid IS NOT NULL AND same_name_count=1 AND prosecdef=expected_prosecdef AND proconfig @> expected_search_path AND pg_get_userbyid(proowner)='postgres' AND public_exec_revoked AND NOT anon_exec AND NOT service_exec AND auth_exec=authenticated_execute)::text||'/'||count(*)::text,
    count(*)::text||'/'||count(*)::text,'Exact per-function security mode and search_path; postgres owner; PUBLIC/anon/service_role denied; authenticated EXECUTE matches the explicit contract.',true FROM function_state
  UNION ALL
  SELECT 11,'stock_rls_enabled',CASE WHEN count(*) FILTER (WHERE oid IS NULL OR NOT relrowsecurity)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE relrowsecurity)::text||'/'||count(*)::text,count(*)::text||'/'||count(*)::text,
    coalesce(string_agg(relname,', ') FILTER (WHERE oid IS NULL OR NOT relrowsecurity),'RLS enabled on all stock tables'),true FROM relation_state
  UNION ALL
  SELECT 12,'expected_stock_select_policies',CASE WHEN count(*) FILTER (WHERE oid IS NULL OR polcmd<>'r' OR polroles<>ARRAY['authenticated'::regrole::oid] OR position('current_active_user_role' IN policy_expression)=0 OR position('owner' IN policy_expression)=0 OR position('admin' IN policy_expression)=0 OR position('kasir' IN policy_expression)>0 OR (NOT manager_only AND position('gudang' IN policy_expression)=0) OR (manager_only AND position('gudang' IN policy_expression)>0))=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE oid IS NOT NULL AND polcmd='r' AND polroles=ARRAY['authenticated'::regrole::oid] AND position('current_active_user_role' IN policy_expression)>0 AND position('owner' IN policy_expression)>0 AND position('admin' IN policy_expression)>0 AND position('kasir' IN policy_expression)=0 AND ((manager_only AND position('gudang' IN policy_expression)=0) OR (NOT manager_only AND position('gudang' IN policy_expression)>0)))::text||'/'||count(*)::text,count(*)::text||'/'||count(*)::text,
    coalesce(string_agg(relname||'.'||policyname,', ') FILTER (WHERE oid IS NULL OR polcmd<>'r' OR polroles<>ARRAY['authenticated'::regrole::oid] OR position('current_active_user_role' IN policy_expression)=0 OR position('owner' IN policy_expression)=0 OR position('admin' IN policy_expression)=0 OR position('kasir' IN policy_expression)>0 OR (NOT manager_only AND position('gudang' IN policy_expression)=0) OR (manager_only AND position('gudang' IN policy_expression)>0)),'named role-filtered SELECT policies match OWNER/ADMIN/GUDANG scope'),true FROM policy_state
  UNION ALL
  SELECT 13,'direct_stock_dml_denied',CASE WHEN count(*) FILTER (WHERE oid IS NULL OR NOT relrowsecurity OR coalesce(anon_dml,false) OR coalesce(authenticated_dml,false) OR coalesce(service_dml,false) OR coalesce(public_dml,false) OR request_select_mismatch)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE oid IS NOT NULL AND NOT anon_dml AND NOT authenticated_dml AND NOT service_dml AND NOT request_select_mismatch)::text||'/'||count(*)::text,count(*)::text||'/'||count(*)::text,
    'no PUBLIC/anon/authenticated/service_role DML; request ledger not browser-readable',true FROM table_security
  UNION ALL
  SELECT 14,'stock_table_select_grants',CASE WHEN count(*) FILTER (WHERE oid IS NULL OR authenticated_select<>(relname<>'stock_operation_requests') OR anon_select OR service_select OR public_select)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE oid IS NOT NULL AND authenticated_select=(relname<>'stock_operation_requests') AND NOT anon_select AND NOT service_select AND NOT public_select)::text||'/'||count(*)::text,
    count(*)::text||'/'||count(*)::text,'authenticated SELECT on public stock tables except private operation requests; PUBLIC/anon/service_role SELECT denied',true FROM table_security
  UNION ALL
  SELECT 15,'stock_hpp_isolation',CASE WHEN hpp_columns=0 AND hpp_or_cost_references=0 THEN 'PASS' ELSE 'FAIL' END,
    'stock_columns='||hpp_columns::text||'; stock_function_cost_refs='||hpp_or_cost_references::text,'0/0','No stock table or RPC exposes/references product HPP/cost data.',true FROM stock_hpp_state CROSS JOIN stock_function_hpp_state
  UNION ALL
  SELECT 16,'projection_row_count',CASE WHEN row_count=5103 THEN 'PASS' ELSE 'FAIL' END,row_count::text,'5103','Expected one projection per verified inventory product/outlet.',true FROM projection_metrics
  UNION ALL
  SELECT 17,'projection_product_outlet_uniqueness',CASE WHEN row_count=distinct_pairs AND row_count=5103 THEN 'PASS' ELSE 'FAIL' END,
    'rows='||row_count::text||'; distinct_pairs='||distinct_pairs::text,'5103 rows and distinct pairs','Composite projection primary key prevents duplicates.',true FROM projection_metrics
  UNION ALL
  SELECT 18,'projection_quantity_nonnegative_precision_range',CASE WHEN negative_effective=0 AND invalid_effective=0 AND invalid_baseline=0 AND invalid_overlay=0 AND invalid_version=0 THEN 'PASS' ELSE 'FAIL' END,
    'negative_effective='||negative_effective::text||'; invalid_effective='||invalid_effective::text||'; invalid_baseline='||invalid_baseline::text||'; invalid_overlay='||invalid_overlay::text||'; invalid_version='||invalid_version::text,
    'all zero; quantities nonnegative, below 1e11, 3-decimal precision; version positive','V1 prohibits negative effective stock.',true FROM projection_metrics
  UNION ALL
  SELECT 19,'accepted_baseline_source_provenance',CASE WHEN projection_rows=5103 AND eligible_baselines=projection_rows THEN 'PASS' ELSE 'FAIL' END,
    'projections='||projection_rows::text||'; eligible='||eligible_baselines::text,'5103/5103 valid source-row/batch/commit/proposal provenance and exact proposed quantity',
    'Baseline provenance is checked independently of later current iPos observations.',true FROM projection_provenance
  UNION ALL
  SELECT 20,'initial_authority_mode',CASE WHEN current_periods=1 AND transition_periods=1 AND invalid_periods=0 AND current_periods_without_projection=0 THEN 'PASS' ELSE 'FAIL' END,
    'current='||current_periods::text||'; transition='||transition_periods::text||'; invalid='||invalid_periods::text||'; without_projection='||current_periods_without_projection::text,
    'one current IPOS_SNAPSHOT_PLUS_QUENA_MOVEMENTS period','Initial bootstrap authority for the verified single outlet.',true FROM authority_state
  UNION ALL
  SELECT 21,'ordinary_import_observation_only_body',CASE WHEN EXISTS (SELECT 1 FROM refresh_body WHERE
      position('source_chronology_unverified' IN body)>0 AND position('quena_authority_observation' IN body)>0
      AND position('last_observation_source_import_row_id' IN body)>0
      AND body !~ 'set[[:space:]]+([a-z0-9_]+[.])?baseline_quantity[[:space:]]*='
      AND position('update public.product_inventory' IN body)=0)
    THEN 'PASS' ELSE 'FAIL' END,
    'refresh trigger function classifies unverified chronology and Quena authority observations without baseline assignment',
    'no automatic accepted-baseline advancement or overlay reconciliation','Function-body semantic check normalized for whitespace.',true
  UNION ALL
  SELECT 22,'product_inventory_row_count',CASE WHEN inventory_rows=5103 THEN 'PASS' ELSE 'FAIL' END,inventory_rows::text,'5103','Verified pre-deployment row count; migration contains no UPDATE to product_inventory.',true FROM inventory_metrics
  UNION ALL
  SELECT 23,'product_inventory_integrity_and_source_pointer',CASE WHEN missing_quantity_or_source=0 AND invalid_quantity=0 AND bad_current_source_pointer=0 THEN 'PASS' ELSE 'FAIL' END,
    'missing_qty_or_source='||missing_quantity_or_source::text||'; invalid_qty='||invalid_quantity::text||'; bad_source_pointer='||bad_current_source_pointer::text,
    'all counts 0; source row points to matching product/outlet; quantity nonnegative, range and precision valid',
    'Integrity counts are evaluated against the current inventory and source pointer.',true FROM inventory_metrics
  UNION ALL
  SELECT 24,'product_inventory_history_count',CASE WHEN inventory_history_rows=5103 THEN 'PASS' ELSE 'REVIEW' END,inventory_history_rows::text,'5103 at verified pre-deployment check',
    'History may grow after later imports; compare with pre-deployment result.',false FROM activity_metrics
  UNION ALL
  SELECT 25,'active_barcode_count',CASE WHEN active_barcodes=4527 THEN 'PASS' ELSE 'REVIEW' END,active_barcodes::text,'4527 at verified pre-deployment check',
    'Association changes can be unrelated; no barcode values are returned.',false FROM activity_metrics
  UNION ALL
  SELECT 26,'bootstrap_baseline_event_rows',CASE WHEN baseline_events=5103 AND bootstrap_events=5103 THEN 'PASS' ELSE 'FAIL' END,
    'events='||baseline_events::text||'; bootstrap='||bootstrap_events::text,'5103 baseline events; all BOOTSTRAP',
    'One provenance event is recorded for each projection bootstrap row.',true FROM activity_metrics
  UNION ALL
  SELECT 27,'bootstrap_created_no_movements_or_reconciliation',CASE WHEN movement_batches+movements+reconciliations+projection_events=0 THEN 'PASS' ELSE 'REVIEW' END,
    'batches='||movement_batches::text||'; movements='||movements::text||'; reconciliations='||reconciliations::text||'; projection_events='||projection_events::text,'0 immediately after bootstrap',
    'Nonzero values may be later authorized activity; inspect source/time.',false FROM activity_metrics
  UNION ALL
  SELECT 28,'bootstrap_created_no_opname_activity',CASE WHEN opname_sessions+opname_items+count_events+session_events=0 THEN 'PASS' ELSE 'REVIEW' END,
    'sessions='||opname_sessions::text||'; items='||opname_items::text||'; count_events='||count_events::text||'; session_events='||session_events::text,'0 immediately after bootstrap',
    'Nonzero values may be later use; inspect audit history.',false FROM activity_metrics
  UNION ALL
  SELECT 29,'bootstrap_created_no_operation_requests',CASE WHEN operation_requests=0 THEN 'PASS' ELSE 'REVIEW' END,operation_requests::text,'0 immediately after bootstrap',
    'Nonzero requests may reflect subsequent authorized operations.',false FROM activity_metrics
  UNION ALL
  SELECT 30,'correction_ledger_counts',CASE WHEN correction_requests=0 AND correction_intents=0 THEN 'PASS' ELSE 'REVIEW' END,
    'requests='||correction_requests::text||'; intents='||correction_intents::text,'0 if no unrelated audit activity occurred',
    'Informational; 180000 does not write correction ledgers.',false FROM activity_metrics
  UNION ALL
  SELECT 31,'bootstrap_baseline_vs_current_inventory',CASE WHEN baseline_vs_current_mismatches=0 THEN 'PASS' ELSE 'REVIEW' END,
    baseline_vs_current_mismatches::text,'0 immediately after deployment and before a later import',
    'A difference may be a legitimate later iPos observation; accepted projection baseline must remain unchanged until trusted acceptance.',false FROM snapshot_comparison
  UNION ALL
  SELECT 32,'all_expected_immutability_and_refresh_triggers',CASE WHEN count(*) FILTER (WHERE oid IS NULL OR tgenabled NOT IN ('O','A') OR NOT function_matches OR tgtype<>expected_tgtype)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE oid IS NOT NULL AND tgenabled IN ('O','A') AND function_matches AND tgtype=expected_tgtype)::text||'/'||count(*)::text,count(*)::text||'/'||count(*)::text,
    coalesce(string_agg(relname||'.'||triggername,', ') FILTER (WHERE oid IS NULL OR tgenabled NOT IN ('O','A') OR NOT function_matches OR tgtype<>expected_tgtype),'expected trigger timing/events/functions match'),true FROM trigger_state
  UNION ALL
  SELECT 33,'product_inventory_refresh_triggers',CASE WHEN count(*) FILTER (WHERE oid IS NULL OR tgenabled NOT IN ('O','A') OR NOT function_matches OR tgtype<>expected_tgtype)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE oid IS NOT NULL AND tgenabled IN ('O','A') AND function_matches AND tgtype=expected_tgtype)::text||'/'||count(*)::text,'2/2',
    'AFTER INSERT and source_import_row_id UPDATE observation triggers enabled.',true FROM trigger_state WHERE relname='product_inventory'
  UNION ALL
  SELECT 34,'stock_enum_usage_privileges',CASE WHEN missing_authenticated_usage+anon_usage+service_usage=0 THEN 'PASS' ELSE 'FAIL' END,
    'authenticated_missing='||missing_authenticated_usage::text||'; anon_effective_including_PUBLIC='||anon_usage::text||'; service_role='||service_usage::text,
    'authenticated USAGE on all stock enums; anon/service_role/PUBLIC effective USAGE denied','Effective anon privilege detects PUBLIC USAGE because PUBLIC privileges are inherited by anon.',true FROM type_privileges
),
overall AS (
  SELECT CASE WHEN bool_or(status='FAIL' AND blocking) THEN 'FAIL'
              WHEN bool_or(status='REVIEW') THEN 'REVIEW' ELSE 'PASS' END AS status,
         count(*) FILTER (WHERE status='FAIL' AND blocking) AS blocking_failures,
         count(*) FILTER (WHERE status='REVIEW') AS review_gates
  FROM gate_rows
)
SELECT check_order,check_name,status,actual,expected,detail
FROM (
  SELECT check_order,check_name,status,actual,expected,detail FROM gate_rows
  UNION ALL
  SELECT 999,'overall_gate',status,
    'blocking_failures='||blocking_failures::text||'; review_gates='||review_gates::text,
    'PASS only if blocking failures=0 and review gates=0','Derived from component gates.' FROM overall
) summary
ORDER BY check_order;
