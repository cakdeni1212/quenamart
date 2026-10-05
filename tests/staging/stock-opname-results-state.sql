BEGIN READ ONLY;
SELECT jsonb_build_object(
  'target', current_database() || '|' || coalesce(host(inet_server_addr()), '') || '|' || inet_server_port()::text,
  'outlets', (SELECT md5(coalesce(string_agg(o.id::text || ':' || o.name, E'\n' ORDER BY o.id), '')) FROM public.outlets o),
  'products', (SELECT md5(coalesce(string_agg(p.id::text || ':' || p.sku || ':' || p.name || ':' || coalesce(p.unit_label, '<null>'), E'\n' ORDER BY p.id), '')) FROM public.products p),
  'racks', (SELECT md5(coalesce(string_agg(s.product_id::text || ':' || s.outlet_id::text || ':' || coalesce(s.rack_label, '<null>'), E'\n' ORDER BY s.outlet_id, s.product_id), '')) FROM public.product_outlet_settings s),
  'barcodes', (SELECT md5(coalesce(string_agg(b.id::text || ':' || b.product_id::text || ':' || b.barcode || ':' || b.is_active::text, E'\n' ORDER BY b.id), '')) FROM public.product_barcodes b),
  'session_snapshots', (SELECT md5(coalesce(string_agg(s.id::text || ':' || coalesce(s.posted_outlet_name_snapshot, '<null>') || ':' || coalesce(s.posted_metadata_captured_at::text, '<null>'), E'\n' ORDER BY s.id), '')) FROM public.stock_opname_sessions s),
  'item_snapshots', (SELECT md5(coalesce(string_agg(i.id::text || ':' || coalesce(i.posted_product_name_snapshot, '<null>') || ':' || coalesce(i.posted_sku_snapshot, '<null>') || ':' || coalesce(i.posted_rack_label_snapshot, '<null>') || ':' || coalesce(i.posted_unit_label_snapshot, '<null>') || ':' || coalesce(i.posted_display_barcode_snapshot, '<null>') || ':' || coalesce(i.posted_metadata_captured_at::text, '<null>'), E'\n' ORDER BY i.id), '')) FROM public.stock_opname_items i),
  'session_snapshot_rows', (SELECT count(*) FROM public.stock_opname_sessions s WHERE s.posted_metadata_captured_at IS NOT NULL),
  'item_snapshot_rows', (SELECT count(*) FROM public.stock_opname_items i WHERE i.posted_metadata_captured_at IS NOT NULL)
);
ROLLBACK;
