SELECT concat_ws('|',
  (SELECT count(*)::text FROM public.inventory_costing_outlet_authority),
  (SELECT count(*)::text FROM public.inventory_cost_event_batches),
  (SELECT count(*)::text FROM public.inventory_cost_events),
  (SELECT count(*)::text FROM public.inventory_cost_projections),
  (SELECT count(*)::text FROM public.inventory_cost_source_layers),
  (SELECT count(*)::text FROM public.inventory_cost_source_layer_balances),
  (SELECT count(*)::text FROM public.inventory_cost_layer_allocations),
  (SELECT md5(coalesce(string_agg(concat_ws(':',product_id,outlet_id,coalesce(effective_quantity::text,'NULL'),balance_version),E'\n' ORDER BY outlet_id,product_id),''))
    FROM public.stock_balance_projection),
  (SELECT md5(coalesce(string_agg(concat_ws(':',id,product_id,outlet_id,quantity_delta),E'\n' ORDER BY id),''))
    FROM public.stock_movements),
  (SELECT md5(coalesce(string_agg(concat_ws(':',id,operation_request_id),E'\n' ORDER BY id),''))
    FROM public.stock_movement_batches));
