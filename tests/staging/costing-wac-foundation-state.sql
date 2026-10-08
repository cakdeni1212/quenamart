SELECT md5(
  (SELECT count(*)::text||':'||coalesce(string_agg(product_id::text||':'||outlet_id::text||':'||
    coalesce(baseline_quantity::text,'')||':'||coalesce(unreconciled_movement_delta::text,'')||':'||
    coalesce(effective_quantity::text,'')||':'||balance_version::text||':'||authority_period_id::text,
    E'\n' ORDER BY outlet_id,product_id),'') FROM public.stock_balance_projection)
  ||(SELECT count(*)::text||':'||coalesce(string_agg(product_id::text||':'||outlet_id::text||':'||
    coalesce(quantity::text,'')||':'||coalesce(minimum_quantity::text,'')||':'||
    coalesce(source_import_row_id::text,''),E'\n' ORDER BY outlet_id,product_id),'') FROM public.product_inventory)
  ||(SELECT count(*)::text||':'||coalesce(string_agg(product_id::text||':'||outlet_id::text||':'||
    coalesce(hpp::text,'')||':'||coalesce(source_import_row_id::text,''),E'\n' ORDER BY outlet_id,product_id),'') FROM public.product_costs)
  ||(SELECT count(*)::text||':'||coalesce(string_agg(id::text||':'||product_id::text||':'||outlet_id::text||':'||
    coalesce(hpp::text,'')||':'||coalesce(source_import_row_id::text,''),E'\n' ORDER BY id),'') FROM public.product_cost_history)
  ||(SELECT count(*)::text||':'||coalesce(string_agg(id::text||':'||batch_id::text||':'||source_row_number::text||':'||
    md5(raw_data::text),E'\n' ORDER BY id),'') FROM public.ipos_import_rows)
  ||(SELECT count(*)::text||':'||coalesce(string_agg(id::text||':'||product_id::text||':'||outlet_id::text||':'||
    field_key||':'||status::text||':'||coalesce(source_import_row_id::text,''),E'\n' ORDER BY id),'') FROM public.product_field_audit_reviews)
  ||(SELECT count(*)::text||':'||coalesce(string_agg(id::text||':'||quantity_delta::text||':'||balance_version::text,
    E'\n' ORDER BY id),'') FROM public.stock_balance_projection_events)
) AS costing_wac_durable_fingerprint;
