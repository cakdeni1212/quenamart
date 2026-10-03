-- Read-only durable-state fingerprint for before/after rollback verification.
BEGIN READ ONLY;
SELECT jsonb_build_object(
  'target', current_database() || '|' || coalesce(host(inet_server_addr()), '') || '|' || inet_server_port()::text,
  'product_inventory', jsonb_build_object(
    'rows', (SELECT count(*) FROM public.product_inventory i),
    'fingerprint', (SELECT md5(coalesce(string_agg(
      i.product_id::text || ':' || i.outlet_id::text || ':' || coalesce(i.quantity::text, '<null>') || ':' ||
      coalesce(i.minimum_quantity::text, '<null>') || ':' || coalesce(i.source_import_row_id::text, '<null>'),
      E'\n' ORDER BY i.outlet_id, i.product_id), '')) FROM public.product_inventory i)
  ),
  'product_inventory_history', jsonb_build_object(
    'rows', (SELECT count(*) FROM public.product_inventory_history h),
    'fingerprint', (SELECT md5(coalesce(string_agg(
      h.id::text || ':' || h.product_id::text || ':' || h.outlet_id::text || ':' ||
      coalesce(h.quantity::text, '<null>') || ':' || coalesce(h.minimum_quantity::text, '<null>') || ':' ||
      h.effective_at::text || ':' || coalesce(h.source_import_row_id::text, '<null>'),
      E'\n' ORDER BY h.id), '')) FROM public.product_inventory_history h)
  ),
  'stock_balance_projection', jsonb_build_object(
    'rows', (SELECT count(*) FROM public.stock_balance_projection p),
    'fingerprint', (SELECT md5(coalesce(string_agg(
      p.product_id::text || ':' || p.outlet_id::text || ':' || coalesce(p.baseline_quantity::text, '<null>') || ':' ||
      coalesce(p.unreconciled_movement_delta::text, '<null>') || ':' || coalesce(p.effective_quantity::text, '<null>') || ':' ||
      coalesce(p.balance_version::text, '<null>') || ':' || coalesce(p.baseline_source_import_row_id::text, '<null>'),
      E'\n' ORDER BY p.outlet_id, p.product_id), '')) FROM public.stock_balance_projection p)
  ),
  'stock_balance_projection_events', jsonb_build_object(
    'rows', (SELECT count(*) FROM public.stock_balance_projection_events),
    'fingerprint', (SELECT md5(coalesce(string_agg(
      e.id::text || ':' || e.product_id::text || ':' || e.outlet_id::text || ':' ||
      e.event_type || ':' || coalesce(e.request_id::text, '<null>') || ':' ||
      e.quantity_delta::text || ':' || e.balance_before::text || ':' || e.balance_after::text || ':' ||
      e.balance_version::text,
      E'\n' ORDER BY e.id), '')) FROM public.stock_balance_projection_events e)
  ),
  'stock_balance_baseline_events', jsonb_build_object(
    'rows', (SELECT count(*) FROM public.stock_balance_baseline_events),
    'fingerprint', (SELECT md5(coalesce(string_agg(
      e.id::text || ':' || e.product_id::text || ':' || e.outlet_id::text || ':' ||
      e.event_type::text || ':' || e.source_import_row_id::text || ':' || e.batch_id::text,
      E'\n' ORDER BY e.id), '')) FROM public.stock_balance_baseline_events e)
  ),
  'stock_opname_sessions', jsonb_build_object(
    'rows', (SELECT count(*) FROM public.stock_opname_sessions s),
    'fingerprint', (SELECT md5(coalesce(string_agg(
      s.id::text || ':' || s.outlet_id::text || ':' || s.scope_type::text || ':' || s.status::text || ':' ||
      s.created_by::text || ':' || s.created_at::text || ':' || coalesce(s.note, '<null>'),
      E'\n' ORDER BY s.id), '')) FROM public.stock_opname_sessions s)
  ),
  'stock_opname_items', jsonb_build_object(
    'rows', (SELECT count(*) FROM public.stock_opname_items i),
    'fingerprint', (SELECT md5(coalesce(string_agg(
      i.id::text || ':' || i.session_id::text || ':' || i.outlet_id::text || ':' || i.product_id::text || ':' ||
      coalesce(i.baseline_quantity::text, '<null>') || ':' || coalesce(i.baseline_source_import_row_id::text, '<null>') || ':' ||
      coalesce(i.baseline_balance_version::text, '<null>') || ':' || coalesce(i.physical_quantity::text, '<null>') || ':' ||
      i.revision_no::text || ':' || i.active_scope::text,
      E'\n' ORDER BY i.id), '')) FROM public.stock_opname_items i)
  ),
  'stock_opname_session_events', jsonb_build_object(
    'rows', (SELECT count(*) FROM public.stock_opname_session_events e),
    'fingerprint', (SELECT md5(coalesce(string_agg(
      e.id::text || ':' || e.session_id::text || ':' || e.event_type::text || ':' || e.actor_id::text || ':' ||
      coalesce(e.request_id::text, '<null>') || ':' || e.created_at::text,
      E'\n' ORDER BY e.id), '')) FROM public.stock_opname_session_events e)
  ),
  'stock_opname_count_events', jsonb_build_object(
    'rows', (SELECT count(*) FROM public.stock_opname_count_events),
    'fingerprint', (SELECT md5(coalesce(string_agg(
      e.id::text || ':' || e.item_id::text || ':' || coalesce(e.request_id::text, '<null>') || ':' ||
      e.event_type::text || ':' || e.revision_no::text || ':' || e.actor_id::text,
      E'\n' ORDER BY e.id), '')) FROM public.stock_opname_count_events e)
  ),
  'stock_operation_requests', jsonb_build_object(
    'rows', (SELECT count(*) FROM public.stock_operation_requests r),
    'fingerprint', (SELECT md5(coalesce(string_agg(
      r.request_id::text || ':' || r.actor_id::text || ':' || r.operation_key || ':' || r.target_key || ':' ||
      r.payload_hash || ':' || r.state::text || ':' || coalesce(md5(r.result::text), '<null>') || ':' ||
      r.created_at::text || ':' || coalesce(r.completed_at::text, '<null>'),
      E'\n' ORDER BY r.request_id), '')) FROM public.stock_operation_requests r)
  ),
  'stock_movements', jsonb_build_object(
    'rows', (SELECT count(*) FROM public.stock_movements m),
    'fingerprint', (SELECT md5(coalesce(string_agg(
      m.id::text || ':' || m.batch_id::text || ':' || m.outlet_id::text || ':' || m.product_id::text || ':' ||
      m.movement_type::text || ':' || m.quantity_delta::text || ':' || m.balance_before::text || ':' || m.balance_after::text || ':' ||
      coalesce(m.opname_item_id::text, '<null>') || ':' || coalesce(m.reverses_movement_id::text, '<null>'),
      E'\n' ORDER BY m.id), '')) FROM public.stock_movements m)
  ),
  'stock_movement_batches', jsonb_build_object(
    'rows', (SELECT count(*) FROM public.stock_movement_batches b),
    'fingerprint', (SELECT md5(coalesce(string_agg(
      b.id::text || ':' || b.authority_period_id::text || ':' || b.outlet_id::text || ':' ||
      b.source_system::text || ':' || b.operation_request_id::text || ':' || b.created_by::text,
      E'\n' ORDER BY b.id), '')) FROM public.stock_movement_batches b)
  ),
  'product_costs', jsonb_build_object(
    'rows', (SELECT count(*) FROM public.product_costs c),
    'fingerprint', (SELECT md5(coalesce(string_agg(
      c.product_id::text || ':' || c.outlet_id::text || ':' || coalesce(c.hpp::text, '<null>') || ':' ||
      coalesce(c.source_import_row_id::text, '<null>'),
      E'\n' ORDER BY c.outlet_id, c.product_id), '')) FROM public.product_costs c)
  ),
  'product_selling_prices', jsonb_build_object(
    'rows', (SELECT count(*) FROM public.product_selling_prices s),
    'fingerprint', (SELECT md5(coalesce(string_agg(
      s.product_id::text || ':' || s.outlet_id::text || ':' || coalesce(s.amount::text, '<null>') || ':' ||
      coalesce(s.source_import_row_id::text, '<null>'),
      E'\n' ORDER BY s.outlet_id, s.product_id), '')) FROM public.product_selling_prices s)
  ),
  'owned_sequences', (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'name', n.nspname || '.' || c.relname,
      'last_value', s.last_value,
      'start_value', s.start_value,
      'increment_by', s.increment_by,
      'cache_size', s.cache_size
    ) ORDER BY n.nspname, c.relname), '[]'::jsonb)
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_catalog.pg_sequences s ON s.schemaname = n.nspname AND s.sequencename = c.relname
    WHERE c.relkind = 'S'
      AND EXISTS (
        SELECT 1 FROM pg_catalog.pg_depend d
        WHERE d.classid = 'pg_catalog.pg_class'::regclass
          AND d.objid = c.oid
          AND d.refclassid = 'pg_catalog.pg_class'::regclass
          AND d.refobjid IN (
            'public.stock_operation_requests'::regclass,
            'public.stock_opname_sessions'::regclass,
            'public.stock_opname_items'::regclass,
            'public.stock_opname_session_events'::regclass,
            'public.stock_opname_count_events'::regclass,
            'public.stock_movement_batches'::regclass,
            'public.stock_movements'::regclass,
            'public.stock_balance_projection_events'::regclass,
            'public.stock_balance_baseline_events'::regclass,
            'public.stock_balance_projection'::regclass,
            'public.product_inventory'::regclass,
            'public.product_inventory_history'::regclass,
            'public.product_costs'::regclass,
            'public.product_selling_prices'::regclass
          )
          AND d.deptype IN ('a', 'i')
      )
  )
)::text AS durable_state;
COMMIT;
