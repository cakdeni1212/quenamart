SELECT jsonb_build_object(
  'stock', (SELECT md5(coalesce(string_agg(to_jsonb(x)::text,'|' ORDER BY x.outlet_id,x.product_id),'')) FROM public.stock_balance_projection x),
  'movements', (SELECT md5(coalesce(string_agg(to_jsonb(x)::text,'|' ORDER BY x.id),'')) FROM public.stock_movements x),
  'batches', (SELECT md5(coalesce(string_agg(to_jsonb(x)::text,'|' ORDER BY x.id),'')) FROM public.stock_movement_batches x),
  'costBatches', (SELECT md5(coalesce(string_agg(to_jsonb(x)::text,'|' ORDER BY x.id),'')) FROM public.inventory_cost_event_batches x),
  'costEvents', (SELECT md5(coalesce(string_agg(to_jsonb(x)::text,'|' ORDER BY x.id),'')) FROM public.inventory_cost_events x),
  'costProjection', (SELECT md5(coalesce(string_agg(to_jsonb(x)::text,'|' ORDER BY x.outlet_id,x.product_id),'')) FROM public.inventory_cost_projections x),
  'layers', (SELECT md5(coalesce(string_agg(to_jsonb(x)::text,'|' ORDER BY x.id),'')) FROM public.inventory_cost_source_layers x),
  'layerBalances', (SELECT md5(coalesce(string_agg(to_jsonb(x)::text,'|' ORDER BY x.layer_id),'')) FROM public.inventory_cost_source_layer_balances x),
  'allocations', (SELECT md5(coalesce(string_agg(to_jsonb(x)::text,'|' ORDER BY x.id),'')) FROM public.inventory_cost_layer_allocations x),
  'returns', (SELECT md5(coalesce(string_agg(to_jsonb(x)::text,'|' ORDER BY x.id),'')) FROM public.supplier_returns x),
  'returnLines', (SELECT md5(coalesce(string_agg(to_jsonb(x)::text,'|' ORDER BY x.id),'')) FROM public.supplier_return_items x),
  'receipts', (SELECT md5(coalesce(string_agg(to_jsonb(x)::text,'|' ORDER BY x.id),'')) FROM public.purchase_receipts x),
  'receiptLines', (SELECT md5(coalesce(string_agg(to_jsonb(x)::text,'|' ORDER BY x.id),'')) FROM public.purchase_receipt_items x),
  'payables', (SELECT md5(coalesce(string_agg(to_jsonb(x)::text,'|' ORDER BY x.id),'')) FROM public.supplier_payables x),
  'payments', (SELECT md5(coalesce(string_agg(to_jsonb(x)::text,'|' ORDER BY x.id),'')) FROM public.supplier_payments x)
);
