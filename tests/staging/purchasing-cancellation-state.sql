SELECT md5(
  (SELECT count(*)::text||':'||coalesce(string_agg(id::text||':'||status||':'||draft_revision::text||':'||coalesce(cancelled_by::text,'')||':'||coalesce(cancelled_at::text,''),E'\n' ORDER BY id),'') FROM public.purchase_receipts)
  ||(SELECT count(*)::text||':'||coalesce(string_agg(id::text||':'||status||':'||coalesce(cancelled_by::text,'')||':'||coalesce(cancelled_at::text,''),E'\n' ORDER BY id),'') FROM public.purchase_invoices)
  ||(SELECT count(*)::text||':'||coalesce(string_agg(id::text||':'||invoice_id::text||':'||cleanup_status||':'||cleanup_attempts::text,E'\n' ORDER BY id),'') FROM public.purchase_invoice_documents)
  ||(SELECT count(*)::text||':'||coalesce(string_agg(id::text||':'||receipt_id::text||':'||event_type||':'||actor_id::text,E'\n' ORDER BY id),'') FROM public.purchase_receipt_events)
  ||(SELECT count(*)::text||':'||coalesce(string_agg(id::text||':'||invoice_id::text||':'||event_type||':'||actor_id::text,E'\n' ORDER BY id),'') FROM public.purchase_invoice_events)
  ||(SELECT count(*)::text||':'||coalesce(string_agg(id::text||':'||operation_request_id::text,E'\n' ORDER BY id),'') FROM public.stock_movement_batches WHERE source_system='PURCHASING')
  ||(SELECT count(*)::text||':'||coalesce(string_agg(id::text||':'||product_id::text||':'||quantity_delta::text||':'||balance_before::text||':'||balance_after::text,E'\n' ORDER BY id),'') FROM public.stock_movements WHERE source_system='PURCHASING')
  ||(SELECT count(*)::text||':'||coalesce(string_agg(product_id::text||':'||outlet_id::text||':'||effective_quantity::text||':'||balance_version::text,E'\n' ORDER BY outlet_id,product_id),'') FROM public.stock_balance_projection)
  ||(SELECT count(*)::text||':'||coalesce(string_agg(product_id::text||':'||outlet_id::text||':'||quantity::text,E'\n' ORDER BY outlet_id,product_id),'') FROM public.product_inventory)
  ||(SELECT count(*)::text||':'||coalesce(string_agg(product_id::text||':'||outlet_id::text||':'||hpp::text,E'\n' ORDER BY outlet_id,product_id),'') FROM public.product_costs)
) AS purchasing_cancellation_fingerprint;
