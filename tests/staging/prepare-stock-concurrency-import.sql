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
    RAISE EXCEPTION 'Refusing import fixture setup outside verified local stock staging';
  END IF;
END;
$guard$;

SELECT gen_random_uuid() AS storage_object_id \gset
INSERT INTO storage.objects(id, bucket_id, name)
VALUES (:'storage_object_id'::uuid, 'quena-ipos-imports', :'object_name');

SELECT id AS outlet_id FROM public.outlets WHERE code = 'QUENA-MART-1' AND is_active \gset
SELECT id AS product_id, sku, last_import_row_id AS previous_source_row_id
FROM public.products WHERE sku = 'STG-CONCURRENT' \gset
SELECT barcode FROM public.product_barcodes
WHERE product_id = :'product_id'::uuid AND is_active AND source_import_row_id IS NOT NULL
ORDER BY id LIMIT 1 \gset
SELECT (quantity + 4)::numeric AS next_source_quantity
FROM public.product_inventory WHERE product_id = :'product_id'::uuid AND outlet_id = :'outlet_id'::uuid \gset
SELECT cr.normalized_data || jsonb_build_object('quantity', :'next_source_quantity') AS normalized_data
FROM public.ipos_normalization_commit_rows cr
WHERE cr.source_row_id = :'previous_source_row_id'::uuid AND cr.product_id = :'product_id'::uuid
ORDER BY cr.created_at DESC, cr.commit_id DESC, cr.source_row_number DESC LIMIT 1 \gset

BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = 'a0000000-0000-4000-8000-000000000001';
SELECT public.request_ipos_import(:'outlet_id'::uuid, :'object_name', 'stock-concurrency.xlsx') AS import_request_id \gset
COMMIT;

BEGIN;
SET LOCAL ROLE service_role;
SELECT public.claim_ipos_import_request(:'import_request_id'::uuid) AS claim_result \gset
SELECT (:'claim_result'::jsonb->>'batch_id') AS batch_id \gset
SELECT gen_random_uuid() AS source_row_id \gset
INSERT INTO public.ipos_import_rows(id, batch_id, outlet_id, source_row_number, raw_data, status)
VALUES (:'source_row_id'::uuid, :'batch_id'::uuid, :'outlet_id'::uuid, 3,
  jsonb_build_object('SKU', :'sku', 'NAMA', (SELECT name FROM public.products WHERE id = :'product_id'::uuid),
    'BARCODE', :'barcode', 'STOK', :'next_source_quantity'::numeric, 'RAK', 'Rak S4'), 'RAW_ONLY');
SELECT public.complete_ipos_import_request(:'import_request_id'::uuid, :'batch_id'::uuid, 1);
COMMIT;

\echo Prepared legitimate completed synthetic import; normalization commit is reserved for the concurrent holder connection.
