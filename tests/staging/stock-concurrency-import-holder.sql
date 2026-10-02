\set ON_ERROR_STOP on
DO $guard$
BEGIN
  IF current_database() <> 'quena_stock_staging'
     OR coalesce(host(inet_server_addr()), '') NOT IN ('127.0.0.1', '::1')
     OR inet_server_port() <> 5432
     OR current_setting('server_version_num')::integer / 10000 <> 15
     OR NOT EXISTS (SELECT 1 FROM quena_staging.environment WHERE name = 'quena_stock_staging')
     OR NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929171000')
     OR NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929180000') THEN
    RAISE EXCEPTION 'Refusing import holder outside verified local stock staging';
  END IF;
END;
$guard$;
BEGIN;
SET LOCAL statement_timeout = '35s';
SET LOCAL lock_timeout = '25s';
SET LOCAL ROLE service_role;
SELECT public.commit_ipos_normalization(
  :'batch_id'::uuid,
  'ipos-v1-preflight',
  jsonb_build_object(
    'normalizationVersion', 'ipos-v1-preflight',
    'batchId', :'batch_id',
    'outletId', :'outlet_id',
    'expectedState', (
      WITH proposed AS (
        SELECT :'sku'::text AS sku, :'barcode'::text AS barcode
      ), candidate_products AS (
        SELECT p.id FROM public.products p JOIN proposed x ON x.sku = p.sku
      )
      SELECT jsonb_build_object(
        'products', coalesce((
          SELECT jsonb_agg(jsonb_build_object('id', p.id, 'sku', p.sku, 'name', p.name) ORDER BY p.id)
          FROM public.products p
        ), '[]'::jsonb),
        'barcodes', coalesce((
          SELECT jsonb_agg(jsonb_build_object('id', b.id, 'product_id', b.product_id,
            'barcode', b.barcode, 'source_import_row_id', b.source_import_row_id) ORDER BY b.id)
          FROM public.product_barcodes b
          WHERE b.is_active AND (b.product_id IN (SELECT cp.id FROM candidate_products cp)
            OR b.barcode = :'barcode')
        ), '[]'::jsonb),
        'overrides', coalesce((
          SELECT jsonb_agg(jsonb_build_object('id', o.id, 'product_id', o.product_id,
            'barcode_id', o.barcode_id, 'outlet_id', o.outlet_id, 'field_key', o.field_key,
            'corrected_value', o.corrected_value) ORDER BY o.id)
          FROM public.product_field_overrides o
          WHERE o.is_active AND o.product_id IN (SELECT cp.id FROM candidate_products cp)
        ), '[]'::jsonb)
      )
    ),
    'rows', jsonb_build_array(jsonb_build_object(
      'source_row_id', :'source_row_id', 'source_row', 3, 'action', 'UPDATE',
      'sku', :'sku', 'expected_product_id', :'product_id',
      'normalized_data', :'normalized_data'::jsonb,
      'audit_findings', '[]'::jsonb, 'issues', '[]'::jsonb,
      'blocked_override_fields', '[]'::jsonb
    ))
  )
);
\echo CONCURRENCY_IMPORT_APPLIED
\! while [ ! -f "$STOCK_BARRIER_RELEASE" ]; do sleep 0.05; done; if [ ! -f "$STOCK_BARRIER_COMMIT" ]; then kill -TERM "$PPID"; fi
COMMIT;
