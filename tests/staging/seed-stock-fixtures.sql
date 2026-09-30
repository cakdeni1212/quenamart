-- Synthetic iPos fixture built by the actual Phase 2B normalization RPC.
-- This file mutates only the guarded local staging database.
DO $guard$
BEGIN
  IF current_database() <> 'quena_stock_staging'
     OR coalesce(host(inet_server_addr()), '') NOT IN ('127.0.0.1', '::1')
     OR inet_server_port() <> 5432
     OR current_setting('server_version_num')::integer / 10000 <> 15
     OR current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'Refusing fixture seed outside local UTF8 PostgreSQL 15 quena_stock_staging';
  END IF;
  IF EXISTS (SELECT 1 FROM quena_staging.fixture_runs WHERE fixture_key = 'stock_foundation_v1') THEN
    RAISE EXCEPTION 'Stock fixtures already seeded; refusing to duplicate them';
  END IF;
  IF EXISTS (SELECT 1 FROM public.products)
     OR EXISTS (SELECT 1 FROM public.ipos_import_batches)
     OR EXISTS (SELECT 1 FROM public.product_inventory)
     OR EXISTS (SELECT 1 FROM public.product_barcodes) THEN
    RAISE EXCEPTION 'Stock fixture seed requires the clean staging catalog';
  END IF;
END;
$guard$;

BEGIN;
INSERT INTO storage.objects(id, bucket_id, name)
VALUES (
  'b0000000-0000-4000-8000-000000000003',
  'quena-ipos-imports',
  'incoming/a0000000-0000-4000-8000-000000000001/b0000000-0000-4000-8000-000000000004.xlsx'
);

SELECT id AS outlet_id FROM public.outlets
WHERE code = 'QUENA-MART-1' AND is_active \gset
SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true);
SET LOCAL ROLE authenticated;
SELECT public.request_ipos_import(
  :'outlet_id'::uuid,
  'incoming/a0000000-0000-4000-8000-000000000001/b0000000-0000-4000-8000-000000000004.xlsx',
  'stock-foundation-v1.xlsx'
) AS request_id \gset
RESET ROLE;

SET LOCAL ROLE service_role;
SELECT public.claim_ipos_import_request(:'request_id'::uuid) AS claim_result \gset
SELECT (:'claim_result'::jsonb ->> 'batch_id') AS batch_id \gset
SELECT set_config('quena.stock_fixture_request_id', :'request_id', true);
SELECT set_config('quena.stock_fixture_batch_id', :'batch_id', true);
SELECT set_config('quena.stock_fixture_outlet_id', :'outlet_id', true);

DO $fixtures$
DECLARE
  v_outlet uuid;
  v_request uuid;
  v_batch uuid;
  v_rows jsonb := '[]'::jsonb;
  v_payload jsonb;
  v_result jsonb;
  r record;
BEGIN
  v_outlet := current_setting('quena.stock_fixture_outlet_id')::uuid;
  v_request := current_setting('quena.stock_fixture_request_id')::uuid;
  v_batch := current_setting('quena.stock_fixture_batch_id')::uuid;

  FOR r IN
    SELECT * FROM (VALUES
      ('c0000000-0000-4000-8000-000000000001'::uuid, 3, 'STG-BASE20', 'Staging Baseline 20', '000000000020', 20::numeric, 'Rak S1', '[]'::jsonb),
      ('c0000000-0000-4000-8000-000000000002'::uuid, 4, 'STG-STALE', 'Staging Stale Baseline', 'STG-STALE-BC', 10::numeric, 'Rak S2', '[]'::jsonb),
      ('c0000000-0000-4000-8000-000000000003'::uuid, 5, 'STG-RECON', 'Staging Reconciliation', 'STG-RECON-BC', 20::numeric, 'Rak S3', '[]'::jsonb),
      ('c0000000-0000-4000-8000-000000000004'::uuid, 6, 'STG-CONCURRENT', 'Staging Concurrent', 'STG-CONCURRENT-BC', 20::numeric, 'Rak S4', '[]'::jsonb),
      ('c0000000-0000-4000-8000-000000000005'::uuid, 7, 'STG-FULL-A', 'Staging Full A', 'STG-FULL-A-BC', 5::numeric, 'Rak S5', '[]'::jsonb),
      ('c0000000-0000-4000-8000-000000000006'::uuid, 8, 'STG-FULL-B', 'Staging Full B', 'STG-FULL-B-BC', 7::numeric, 'Rak S6', '[]'::jsonb),
      ('c0000000-0000-4000-8000-000000000007'::uuid, 9, 'STG-AMBIG-A', 'Staging Ambiguous A', 'STG-DUP-AMBIG', 9::numeric, 'Rak S7', '["DUPLICATE_BARCODE"]'::jsonb),
      ('c0000000-0000-4000-8000-000000000008'::uuid, 10, 'STG-AMBIG-B', 'Staging Ambiguous B', 'STG-DUP-AMBIG', 11::numeric, 'Rak S8', '["DUPLICATE_BARCODE"]'::jsonb)
    ) AS seed(source_row_id, source_row_number, sku, product_name, barcode,
              quantity, rack_label, findings)
    ORDER BY source_row_number
  LOOP
    INSERT INTO public.ipos_import_rows(
      id, batch_id, outlet_id, source_row_number, raw_data, status
    ) VALUES (
      r.source_row_id, v_batch, v_outlet, r.source_row_number,
      jsonb_build_object('SKU', r.sku, 'NAMA', r.product_name,
        'BARCODE', r.barcode, 'STOK', r.quantity, 'RAK', r.rack_label),
      'RAW_ONLY'
    );

    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'source_row_id', r.source_row_id::text,
      'source_row', r.source_row_number,
      'action', 'CREATE',
      'sku', r.sku,
      'expected_product_id', null,
      'normalized_data', jsonb_build_object(
        'sku', r.sku,
        'name', r.product_name,
        'categoryLabel', 'Staging',
        'brandLabel', 'Synthetic',
        'unitLabel', 'pcs',
        'departmentLabel', 'Staging',
        'sourceDescription', 'Synthetic stock foundation fixture',
        'sourceReferenceCode', r.sku,
        'barcode', r.barcode,
        'barcodeState', 'VALID',
        'rackLabel', r.rack_label,
        'quantity', r.quantity::text,
        'minimumQuantity', '0',
        'sellingPrice', '1000',
        'hpp', '500'
      ),
      'audit_findings', r.findings,
      'issues', '[]'::jsonb,
      'blocked_override_fields', '[]'::jsonb
    ));
  END LOOP;

  IF public.complete_ipos_import_request(v_request, v_batch, 8) <> 8 THEN
    RAISE EXCEPTION 'Synthetic worker did not complete exactly eight raw rows';
  END IF;

  v_payload := jsonb_build_object(
    'normalizationVersion', 'ipos-v1-preflight',
    'batchId', v_batch::text,
    'outletId', v_outlet::text,
    'expectedState', jsonb_build_object(
      'products', '[]'::jsonb,
      'barcodes', '[]'::jsonb,
      'overrides', '[]'::jsonb
    ),
    'rows', v_rows
  );
  v_result := public.commit_ipos_normalization(v_batch, 'ipos-v1-preflight', v_payload);
  IF v_result->>'linkedRows' <> '8' OR v_result->>'invalidRows' <> '0' THEN
    RAISE EXCEPTION 'Synthetic Phase 2B commit did not link all fixture rows';
  END IF;

END;
$fixtures$;

RESET ROLE;
COMMIT;

-- Seed same-product aliases through the deployed authenticated review and
-- correction-intent RPCs. This exercises the real ADD_ALIAS permissions and
-- keeps application table grants/RLS unchanged. Each RPC runs in its own
-- transaction, matching separate PostgREST calls. A short gap ensures the
-- deployed reviewed_at/created_at ordering is strictly chronological instead
-- of tying every event to one transaction_timestamp() value.
SELECT p.id AS alias_product_id, p.last_import_row_id AS alias_source_row_id
FROM public.products p
WHERE p.sku = 'STG-BASE20' \gset

SELECT pg_catalog.pg_sleep(0.01);
BEGIN;
SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true);
SET LOCAL ROLE authenticated;
SELECT public.issue_product_field_review_intent(
  :'alias_product_id'::uuid, NULL, 'barcode',
  'SEDANG_DICEK'::public.product_field_audit_status,
  :'alias_source_row_id'::uuid, 'Staging alias setup'
) AS review_request_id \gset
COMMIT;

SELECT pg_catalog.pg_sleep(0.01);
BEGIN;
SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true);
SET LOCAL ROLE authenticated;
SELECT public.record_product_field_review(
  :'review_request_id'::uuid, :'alias_product_id'::uuid, NULL, 'barcode',
  'SEDANG_DICEK'::public.product_field_audit_status,
  :'alias_source_row_id'::uuid, 'Staging alias setup'
);
COMMIT;

SELECT pg_catalog.pg_sleep(0.01);
BEGIN;
SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true);
SET LOCAL ROLE authenticated;
SELECT public.issue_product_field_correction_intent(
  :'alias_product_id'::uuid, NULL, 'barcode', :'alias_source_row_id'::uuid,
  to_jsonb('STG-BASE20-ALIAS-A'::text), 'Synthetic staging alias A', 'ADD_ALIAS'
) AS correction_request_id \gset
COMMIT;

SELECT pg_catalog.pg_sleep(0.01);
BEGIN;
SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true);
SET LOCAL ROLE authenticated;
SELECT (public.apply_product_field_correction_intent(:'correction_request_id'::uuid)->>'ok')::boolean AS alias_a_ok \gset
\if :alias_a_ok
\else
  \echo 'Fixture alias A correction failed; staging preparation is incomplete and requires guarded reset.'
  \quit 1
\endif
COMMIT;
SELECT EXISTS (
  SELECT 1 FROM public.product_barcodes b
  WHERE b.product_id = :'alias_product_id'::uuid
    AND b.barcode = 'STG-BASE20-ALIAS-A'
    AND b.is_active AND b.source_import_row_id IS NULL
) AND EXISTS (
  SELECT 1 FROM public.product_barcodes b
  WHERE b.product_id = :'alias_product_id'::uuid
    AND b.barcode = '000000000020' AND b.is_active
) AS alias_a_present_without_losing_imported_barcode \gset
\if :alias_a_present_without_losing_imported_barcode
\else
  \echo 'Fixture alias A or original imported barcode is missing; staging preparation is incomplete and requires guarded reset.'
  \quit 1
\endif

-- Successful correction automatically verifies the field. Start a new review
-- cycle before creating a second independent alias.
SELECT pg_catalog.pg_sleep(0.01);
BEGIN;
SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true);
SET LOCAL ROLE authenticated;
SELECT public.issue_product_field_review_intent(
  :'alias_product_id'::uuid, NULL, 'barcode',
  'SEDANG_DICEK'::public.product_field_audit_status,
  :'alias_source_row_id'::uuid, 'Staging alias setup'
) AS review_request_id \gset
COMMIT;

SELECT pg_catalog.pg_sleep(0.01);
BEGIN;
SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true);
SET LOCAL ROLE authenticated;
SELECT public.record_product_field_review(
  :'review_request_id'::uuid, :'alias_product_id'::uuid, NULL, 'barcode',
  'SEDANG_DICEK'::public.product_field_audit_status,
  :'alias_source_row_id'::uuid, 'Staging alias setup'
);
COMMIT;

SELECT pg_catalog.pg_sleep(0.01);
BEGIN;
SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true);
SET LOCAL ROLE authenticated;
SELECT public.issue_product_field_correction_intent(
  :'alias_product_id'::uuid, NULL, 'barcode', :'alias_source_row_id'::uuid,
  to_jsonb('STG-BASE20-ALIAS-B'::text), 'Synthetic staging alias B', 'ADD_ALIAS'
) AS correction_request_id \gset
COMMIT;

SELECT pg_catalog.pg_sleep(0.01);
BEGIN;
SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true);
SET LOCAL ROLE authenticated;
SELECT (public.apply_product_field_correction_intent(:'correction_request_id'::uuid)->>'ok')::boolean AS alias_b_ok \gset
\if :alias_b_ok
\else
  \echo 'Fixture alias B correction failed; staging preparation is incomplete and requires guarded reset.'
  \quit 1
\endif
COMMIT;
SELECT (
  SELECT count(*) = 2 FROM public.product_barcodes b
  WHERE b.product_id = :'alias_product_id'::uuid
    AND b.barcode IN ('STG-BASE20-ALIAS-A', 'STG-BASE20-ALIAS-B')
    AND b.is_active AND b.source_import_row_id IS NULL
) AND EXISTS (
  SELECT 1 FROM public.product_barcodes b
  WHERE b.product_id = :'alias_product_id'::uuid
    AND b.barcode = '000000000020' AND b.is_active
) AS both_aliases_and_imported_barcode_present \gset
\if :both_aliases_and_imported_barcode_present
\else
  \echo 'Fixture did not retain both aliases and imported barcode; staging preparation is incomplete and requires guarded reset.'
  \quit 1
\endif

BEGIN;
INSERT INTO quena_staging.fixture_runs(fixture_key)
VALUES ('stock_foundation_v1');
COMMIT;
