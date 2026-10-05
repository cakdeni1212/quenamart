SELECT md5(
  (SELECT count(*)::text || ':' || coalesce(string_agg(id::text || ':' || status || ':' || draft_revision::text, E'\n' ORDER BY id), '') FROM public.purchase_receipts)
  || (SELECT count(*)::text || ':' || coalesce(string_agg(id::text || ':' || receipt_id::text || ':' || product_id::text || ':' || accepted_quantity::text || ':' || bonus_quantity::text || ':' || rejected_quantity::text || ':' || coalesce(short_quantity::text,''), E'\n' ORDER BY id), '') FROM public.purchase_receipt_items)
  || (SELECT count(*)::text || ':' || coalesce(string_agg(id::text || ':' || operation_request_id::text, E'\n' ORDER BY id), '') FROM public.stock_movement_batches WHERE source_system='PURCHASING')
  || (SELECT count(*)::text || ':' || coalesce(string_agg(id::text || ':' || product_id::text || ':' || quantity_delta::text || ':' || balance_before::text || ':' || balance_after::text, E'\n' ORDER BY id), '') FROM public.stock_movements WHERE source_system='PURCHASING')
  || (SELECT count(*)::text || ':' || coalesce(string_agg(product_id::text || ':' || outlet_id::text || ':' || effective_quantity::text || ':' || balance_version::text, E'\n' ORDER BY outlet_id,product_id), '') FROM public.stock_balance_projection)
  || (SELECT count(*)::text || ':' || coalesce(string_agg(product_id::text || ':' || outlet_id::text || ':' || quantity::text, E'\n' ORDER BY outlet_id,product_id), '') FROM public.product_inventory)
) AS purchasing_runtime_fingerprint;
