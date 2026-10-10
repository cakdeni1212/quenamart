SELECT jsonb_build_object(
  'stock_projection', (SELECT jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(to_jsonb(x)::text,E'\n' ORDER BY x.outlet_id,x.product_id),''))) FROM public.stock_balance_projection x),
  'stock_movements', (SELECT jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(to_jsonb(x)::text,E'\n' ORDER BY x.id),''))) FROM public.stock_movements x),
  'movement_batches', (SELECT jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(to_jsonb(x)::text,E'\n' ORDER BY x.id),''))) FROM public.stock_movement_batches x),
  'balance_events', (SELECT jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(to_jsonb(x)::text,E'\n' ORDER BY x.id),''))) FROM public.stock_balance_projection_events x),
  'cost_projection', (SELECT jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(to_jsonb(x)::text,E'\n' ORDER BY x.outlet_id,x.product_id),''))) FROM public.inventory_cost_projections x),
  'cost_events', (SELECT jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(to_jsonb(x)::text,E'\n' ORDER BY x.id),''))) FROM public.inventory_cost_events x),
  'source_layers', (SELECT jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(to_jsonb(x)::text,E'\n' ORDER BY x.id),''))) FROM public.inventory_cost_source_layers x),
  'layer_balances', (SELECT jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(to_jsonb(x)::text,E'\n' ORDER BY x.layer_id),''))) FROM public.inventory_cost_source_layer_balances x),
  'layer_allocations', (SELECT jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(to_jsonb(x)::text,E'\n' ORDER BY x.id),''))) FROM public.inventory_cost_layer_allocations x),
  'corrections', (SELECT jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(to_jsonb(x)::text,E'\n' ORDER BY x.id),''))) FROM public.manual_stock_corrections x),
  'correction_items', (SELECT jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(to_jsonb(x)::text,E'\n' ORDER BY x.id),''))) FROM public.manual_stock_correction_items x),
  'correction_events', (SELECT jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(to_jsonb(x)::text,E'\n' ORDER BY x.id),''))) FROM public.manual_stock_correction_events x)
)::text;
