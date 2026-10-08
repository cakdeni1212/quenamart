\set ON_ERROR_STOP on
\timing on
DO $guard$
BEGIN
  IF current_database()<>'quena_stock_staging'
    OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
    OR inet_server_port()<>5432 OR current_setting('server_version_num')::integer/10000<>15
    OR current_setting('server_encoding')<>'UTF8'
    OR NOT EXISTS(SELECT 1 FROM quena_staging.environment WHERE name='quena_stock_staging') THEN
    RAISE EXCEPTION 'Refusing HPP acceptance runtime matrix outside guarded local staging';
  END IF;
END $guard$;

BEGIN;
SET LOCAL statement_timeout='180s';
SET LOCAL lock_timeout='10s';
SELECT id outlet_id FROM public.outlets WHERE code='QUENA-MART-1' AND is_active \gset
SELECT id product_candidate FROM public.products p JOIN public.product_costs c ON c.product_id=p.id
  JOIN public.stock_balance_projection s ON s.product_id=p.id AND s.outlet_id=c.outlet_id
  WHERE c.outlet_id=:'outlet_id'::uuid AND s.effective_quantity>0 AND c.hpp>0
    AND NOT EXISTS(SELECT 1 FROM public.product_field_overrides o WHERE o.product_id=p.id
      AND o.outlet_id=c.outlet_id AND o.field_key='hpp' AND o.is_active)
  ORDER BY p.sku LIMIT 1 \gset

CREATE TEMP TABLE hpp_acceptance_stock_before AS
  SELECT md5(coalesce(string_agg(product_id::text||':'||outlet_id::text||':'||
    coalesce(effective_quantity::text,'NULL')||':'||balance_version::text,E'\n' ORDER BY outlet_id,product_id),'')) AS fingerprint
  FROM public.stock_balance_projection WHERE outlet_id=:'outlet_id'::uuid;
CREATE TEMP TABLE hpp_acceptance_hpp_before AS
  SELECT md5(coalesce(string_agg(c.product_id::text||':'||coalesce(c.hpp::text,'NULL')||':'||
    coalesce(c.source_import_row_id::text,'')||':'||coalesce(h.id::text,'')||':'||coalesce(h.hpp::text,'NULL'),
    E'\n' ORDER BY c.product_id),'')) AS fingerprint
  FROM public.product_costs c LEFT JOIN LATERAL (SELECT id,hpp FROM public.product_cost_history x
    WHERE x.product_id=c.product_id AND x.outlet_id=c.outlet_id ORDER BY effective_at DESC,created_at DESC,id DESC LIMIT 1) h ON true
  WHERE c.outlet_id=:'outlet_id'::uuid;
CREATE TEMP TABLE hpp_acceptance_cost_state_before AS
  SELECT (SELECT count(*) FROM public.inventory_cost_projections WHERE outlet_id=:'outlet_id'::uuid) projections,
    (SELECT count(*) FROM public.inventory_cost_events WHERE outlet_id=:'outlet_id'::uuid) events,
    (SELECT count(*) FROM public.inventory_cost_event_batches WHERE outlet_id=:'outlet_id'::uuid) batches,
    (SELECT count(*) FROM public.inventory_costing_outlet_authority WHERE outlet_id=:'outlet_id'::uuid) authorities;

-- OWNER and ADMIN may read the bounded live preview; KASIR/GUDANG receive no financial payload.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT set_config('quena.hpp_accept.owner_preview',
  public.inventory_cost_initial_hpp_acceptance_preview(:'outlet_id'::uuid,'EXCEPTIONS',NULL,1,100)::text,true);
SELECT set_config('quena.hpp_accept.owner_batch_rows',
  (SELECT count(*)::text FROM public.inventory_cost_hpp_acceptance_batches),true);
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
SET LOCAL ROLE authenticated;
SELECT set_config('quena.hpp_accept.admin_preview',
  public.inventory_cost_initial_hpp_acceptance_preview(:'outlet_id'::uuid,'ALL',NULL,1,100)::text,true);
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',true);
SET LOCAL ROLE authenticated;
SELECT set_config('quena.hpp_accept.gudang_preview',
  public.inventory_cost_initial_hpp_acceptance_preview(:'outlet_id'::uuid,'ALL',NULL,1,100)::text,true);
SELECT set_config('quena.hpp_accept.gudang_batch_rows',(SELECT count(*)::text FROM public.inventory_cost_hpp_acceptance_batches),true);
SELECT set_config('quena.hpp_accept.gudang_item_rows',(SELECT count(*)::text FROM public.inventory_cost_hpp_acceptance_items),true);
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000004',true);
SET LOCAL ROLE authenticated;
SELECT set_config('quena.hpp_accept.kasir_preview',
  public.inventory_cost_initial_hpp_acceptance_preview(:'outlet_id'::uuid,'ALL',NULL,1,100)::text,true);
RESET ROLE;
DO $read_assertions$
DECLARE owner_page jsonb:=current_setting('quena.hpp_accept.owner_preview')::jsonb;
  admin_page jsonb:=current_setting('quena.hpp_accept.admin_preview')::jsonb;
BEGIN
  IF owner_page->>'ok'<>'true' OR (owner_page->'summary'->>'positiveStockProducts')::integer<=0
    OR (owner_page->'summary'->>'autoCandidates')::integer<=0
    OR owner_page->>'pageSize'<>'100' THEN RAISE EXCEPTION 'OWNER preview contract failed'; END IF;
  IF admin_page->>'ok'<>'true' THEN RAISE EXCEPTION 'ADMIN preview contract failed'; END IF;
  IF current_setting('quena.hpp_accept.gudang_preview')::jsonb->>'code'<>'FORBIDDEN'
    OR current_setting('quena.hpp_accept.kasir_preview')::jsonb->>'code'<>'FORBIDDEN'
    OR current_setting('quena.hpp_accept.gudang_batch_rows')<>'0'
    OR current_setting('quena.hpp_accept.gudang_item_rows')<>'0' THEN
    RAISE EXCEPTION 'GUDANG/KASIR acceptance financial data was exposed';
  END IF;
END $read_assertions$;

-- Direct authenticated DML is denied even to OWNER.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
DO $direct_write_denied$
DECLARE v_blocked boolean:=false;
BEGIN
  BEGIN INSERT INTO public.inventory_cost_hpp_acceptance_batches(outlet_id,rule_version,status,source_snapshot_hash,prepared_by,prepare_request_id)
    VALUES(gen_random_uuid(),'INITIAL_HPP_V1','PREPARED',repeat('0',32),auth.uid(),gen_random_uuid());
  EXCEPTION WHEN insufficient_privilege THEN v_blocked:=true; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'Authenticated direct acceptance write was not denied'; END IF;
END $direct_write_denied$;
RESET ROLE;

-- ADMIN prepares; exact request replay returns the original batch without duplicates.
SELECT gen_random_uuid()::text prep_request \gset
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
SET LOCAL ROLE authenticated;
SELECT set_config('quena.hpp_accept.prepared',public.prepare_initial_hpp_acceptance(:'outlet_id'::uuid,:'prep_request'::uuid)::text,true);
SELECT set_config('quena.hpp_accept.prepare_replay',public.prepare_initial_hpp_acceptance(:'outlet_id'::uuid,:'prep_request'::uuid)::text,true);
RESET ROLE;
SELECT current_setting('quena.hpp_accept.prepared')::jsonb->>'batchId' batch_id \gset
SELECT set_config('quena.test_outlet',:'outlet_id',true);
DO $prepare_assertions$
DECLARE a jsonb:=current_setting('quena.hpp_accept.prepared')::jsonb;
  b jsonb:=current_setting('quena.hpp_accept.prepare_replay')::jsonb;
BEGIN
  IF a->>'code'<>'PREPARED' OR a<>b THEN RAISE EXCEPTION 'Prepare replay is not exact/idempotent'; END IF;
  IF (SELECT count(*) FROM public.inventory_cost_hpp_acceptance_batches WHERE status='PREPARED')<>1
    OR (SELECT count(*) FROM public.inventory_cost_hpp_acceptance_items WHERE batch_id=(a->>'batchId')::uuid)
       <> (SELECT positive_stock_products FROM (SELECT count(*) positive_stock_products FROM public.stock_balance_projection
          WHERE outlet_id=current_setting('quena.test_outlet')::uuid AND effective_quantity>0) q) THEN
    RAISE EXCEPTION 'Prepared evidence does not cover each positive-stock product exactly once';
  END IF;
END $prepare_assertions$;
SELECT gen_random_uuid()::text duplicate_prepare_request \gset
SELECT set_config('quena.hpp_accept.duplicate_prepare_request',:'duplicate_prepare_request',true);
DO $duplicate_active_batch$
DECLARE v_blocked boolean:=false;
BEGIN
  BEGIN PERFORM public.prepare_initial_hpp_acceptance(current_setting('quena.test_outlet')::uuid,
    current_setting('quena.hpp_accept.duplicate_prepare_request')::uuid);
  EXCEPTION WHEN SQLSTATE '55000' THEN v_blocked:=true; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'A second active batch for the outlet was allowed'; END IF;
END $duplicate_active_batch$;

-- Add a new unresolved review after preparation. It changes a stale-sensitive fact;
-- approval must invalidate this batch. This synthetic evidence is rolled back below.
INSERT INTO public.product_field_audit_reviews(product_id,outlet_id,field_key,status,source_import_row_id,reviewer_id,evidence_notes,request_id)
SELECT c.product_id, c.outlet_id,'hpp','SEDANG_DICEK',c.source_import_row_id,
  'a0000000-0000-4000-8000-000000000002','Rollback-only stale review fixture',gen_random_uuid()
FROM public.product_costs c JOIN public.stock_balance_projection s USING(product_id,outlet_id)
WHERE c.product_id=:'product_candidate'::uuid AND s.effective_quantity>0;
SELECT gen_random_uuid()::text stale_request \gset
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT set_config('quena.hpp_accept.stale_result',public.approve_initial_hpp_acceptance(:'batch_id'::uuid,:'stale_request'::uuid)::text,true);
RESET ROLE;
DO $stale_assertion$
BEGIN
  IF current_setting('quena.hpp_accept.stale_result')::jsonb->>'code'<>'STALE_BATCH'
    OR (SELECT status FROM public.inventory_cost_hpp_acceptance_batches WHERE id=(current_setting('quena.hpp_accept.prepared')::jsonb->>'batchId')::uuid)<>'INVALIDATED' THEN
    RAISE EXCEPTION 'Changed HPP review did not invalidate the prepared batch';
  END IF;
END $stale_assertion$;

-- Each cost-trust input change invalidates a fresh batch. These writes are
-- transactional fixtures and disappear at the final ROLLBACK.
DO $stale_cost_facts$
DECLARE v_prepared jsonb;v_result jsonb;v_batch uuid;v_product uuid;v_source_row uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
  v_prepared:=public.prepare_initial_hpp_acceptance(current_setting('quena.test_outlet')::uuid,gen_random_uuid());
  v_batch:=(v_prepared->>'batchId')::uuid;
  SELECT i.product_id INTO v_product FROM public.inventory_cost_hpp_acceptance_items i
    JOIN public.products p ON p.id=i.product_id WHERE i.batch_id=v_batch AND p.sku='STG-FULL-A';
  UPDATE public.product_costs SET hpp=hpp+0.01,updated_by='a0000000-0000-4000-8000-000000000002',updated_at=now()
    WHERE product_id=v_product AND outlet_id=current_setting('quena.test_outlet')::uuid;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
  v_result:=public.approve_initial_hpp_acceptance(v_batch,gen_random_uuid());
  IF v_result->>'code'<>'STALE_BATCH' THEN RAISE EXCEPTION 'HPP change did not stale acceptance: %',v_result; END IF;

  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
  v_prepared:=public.prepare_initial_hpp_acceptance(current_setting('quena.test_outlet')::uuid,gen_random_uuid());
  v_batch:=(v_prepared->>'batchId')::uuid;
  SELECT i.product_id,i.source_import_row_id INTO v_product,v_source_row
    FROM public.inventory_cost_hpp_acceptance_items i JOIN public.products p ON p.id=i.product_id
    WHERE i.batch_id=v_batch AND p.sku='STG-FULL-A';
  UPDATE public.product_costs SET source_import_row_id=NULL,updated_by='a0000000-0000-4000-8000-000000000002',updated_at=now()
    WHERE product_id=v_product AND outlet_id=current_setting('quena.test_outlet')::uuid
      AND source_import_row_id=v_source_row;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
  v_result:=public.approve_initial_hpp_acceptance(v_batch,gen_random_uuid());
  IF v_result->>'code'<>'STALE_BATCH' THEN RAISE EXCEPTION 'Source validity change did not stale acceptance: %',v_result; END IF;

  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
  v_prepared:=public.prepare_initial_hpp_acceptance(current_setting('quena.test_outlet')::uuid,gen_random_uuid());
  v_batch:=(v_prepared->>'batchId')::uuid;
  SELECT i.product_id INTO v_product FROM public.inventory_cost_hpp_acceptance_items i
    JOIN public.products p ON p.id=i.product_id WHERE i.batch_id=v_batch AND p.sku='STG-FULL-A';
  UPDATE public.product_selling_prices SET amount=amount+0.01,updated_by='a0000000-0000-4000-8000-000000000002',updated_at=now()
    WHERE product_id=v_product AND outlet_id=current_setting('quena.test_outlet')::uuid;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
  v_result:=public.approve_initial_hpp_acceptance(v_batch,gen_random_uuid());
  IF v_result->>'code'<>'STALE_BATCH' THEN RAISE EXCEPTION 'Selling-price change did not stale acceptance: %',v_result; END IF;
END $stale_cost_facts$;

-- Restore the dedicated low-margin fixture's source/current snapshot after
-- exercising stale changes so its warning-only assertion remains isolated.
UPDATE public.product_costs c SET hpp=(n.normalized_data->>'hpp')::numeric,
  source_import_row_id=ir.id,updated_by='a0000000-0000-4000-8000-000000000002',updated_at=now()
FROM public.products p
JOIN public.ipos_normalization_commit_rows n ON n.product_id=p.id AND n.action='CREATE'
JOIN public.ipos_import_rows ir ON ir.id=n.source_row_id AND ir.product_id=n.product_id AND ir.outlet_id=n.outlet_id
WHERE p.sku='STG-FULL-A' AND c.product_id=p.id AND c.outlet_id=:'outlet_id'::uuid;

-- Rollback-only classification fixtures cover zero/missing HPP, equal/greater
-- selling price, warning-only low/high margin, and active override handling.
UPDATE public.product_costs SET hpp=0,updated_by='a0000000-0000-4000-8000-000000000002',updated_at=now()
WHERE product_id=(SELECT id FROM public.products WHERE sku='STG-FULL-B') AND outlet_id=:'outlet_id'::uuid;
UPDATE public.product_costs SET hpp=NULL,updated_by='a0000000-0000-4000-8000-000000000002',updated_at=now()
WHERE product_id=(SELECT id FROM public.products WHERE sku='STG-STALE') AND outlet_id=:'outlet_id'::uuid;
UPDATE public.product_selling_prices SET amount=500,updated_by='a0000000-0000-4000-8000-000000000002',updated_at=now()
WHERE product_id=(SELECT id FROM public.products WHERE sku='STG-AMBIG-A') AND outlet_id=:'outlet_id'::uuid;
UPDATE public.product_selling_prices SET amount=499,updated_by='a0000000-0000-4000-8000-000000000002',updated_at=now()
WHERE product_id=(SELECT id FROM public.products WHERE sku='STG-AMBIG-B') AND outlet_id=:'outlet_id'::uuid;
UPDATE public.product_selling_prices SET amount=501,updated_by='a0000000-0000-4000-8000-000000000002',updated_at=now()
WHERE product_id=(SELECT id FROM public.products WHERE sku='STG-FULL-A') AND outlet_id=:'outlet_id'::uuid;
UPDATE public.product_selling_prices SET amount=3000,updated_by='a0000000-0000-4000-8000-000000000002',updated_at=now()
WHERE product_id=(SELECT id FROM public.products WHERE sku='STG-BASE20') AND outlet_id=:'outlet_id'::uuid;
INSERT INTO public.product_field_overrides(product_id,outlet_id,field_key,corrected_value,reason,
  source_import_row_id,corrected_by)
SELECT c.product_id,c.outlet_id,'hpp',to_jsonb(c.hpp),'Rollback-only active override fixture',
  c.source_import_row_id,'a0000000-0000-4000-8000-000000000002'
FROM public.product_costs c JOIN public.products p ON p.id=c.product_id
WHERE p.sku='STG-RECON' AND c.outlet_id=:'outlet_id'::uuid AND c.hpp IS NOT NULL
  AND NOT EXISTS(SELECT 1 FROM public.product_field_overrides o WHERE o.product_id=c.product_id
    AND o.outlet_id=c.outlet_id AND o.field_key='hpp' AND o.is_active);
INSERT INTO public.product_audit_findings(product_id,outlet_id,batch_id,import_row_id,finding_code)
SELECT c.product_id,c.outlet_id,ir.batch_id,ir.id,'ZERO_OR_MISSING_HPP'
FROM public.product_costs c JOIN public.products p ON p.id=c.product_id
JOIN public.ipos_import_rows ir ON ir.id=c.source_import_row_id AND ir.product_id=c.product_id AND ir.outlet_id=c.outlet_id
WHERE p.sku='STG-FULL-B' AND c.outlet_id=:'outlet_id'::uuid
ON CONFLICT(import_row_id,finding_code) DO NOTHING;
DO $classification_assertions$
DECLARE e record;
BEGIN
  SELECT * INTO e FROM public.inventory_cost_hpp_acceptance_evaluate(current_setting('quena.test_outlet')::uuid)
    WHERE sku='STG-FULL-B';
  IF NOT e.blocking_reasons @> ARRAY['HPP_ZERO','OPEN_COST_AUDIT_FINDING']::text[] THEN
    RAISE EXCEPTION 'HPP zero/open cost finding was not an exception'; END IF;
  SELECT * INTO e FROM public.inventory_cost_hpp_acceptance_evaluate(current_setting('quena.test_outlet')::uuid)
    WHERE sku='STG-STALE';
  IF e.current_hpp IS NOT NULL OR NOT e.blocking_reasons @> ARRAY['HPP_MISSING']::text[] THEN
    RAISE EXCEPTION 'Missing HPP was not distinct from explicit zero'; END IF;
  SELECT * INTO e FROM public.inventory_cost_hpp_acceptance_evaluate(current_setting('quena.test_outlet')::uuid)
    WHERE sku='STG-AMBIG-A';
  IF NOT e.blocking_reasons @> ARRAY['HPP_NOT_BELOW_SELLING_PRICE']::text[] THEN
    RAISE EXCEPTION 'HPP equal to selling price was auto-accepted'; END IF;
  SELECT * INTO e FROM public.inventory_cost_hpp_acceptance_evaluate(current_setting('quena.test_outlet')::uuid)
    WHERE sku='STG-AMBIG-B';
  IF NOT e.blocking_reasons @> ARRAY['HPP_NOT_BELOW_SELLING_PRICE']::text[] THEN
    RAISE EXCEPTION 'HPP above selling price was auto-accepted'; END IF;
  SELECT * INTO e FROM public.inventory_cost_hpp_acceptance_evaluate(current_setting('quena.test_outlet')::uuid)
    WHERE sku='STG-RECON';
  IF NOT e.blocking_reasons @> ARRAY['ACTIVE_HPP_OVERRIDE']::text[] THEN RAISE EXCEPTION 'Active HPP override was missed'; END IF;
  SELECT * INTO e FROM public.inventory_cost_hpp_acceptance_evaluate(current_setting('quena.test_outlet')::uuid)
    WHERE sku='STG-FULL-A';
  IF e.classification<>'AUTO_CANDIDATE' OR NOT e.warning_codes @> ARRAY['GROSS_MARGIN_AT_OR_BELOW_5_PERCENT']::text[] THEN
    RAISE EXCEPTION 'Low margin warning incorrectly blocked candidate'; END IF;
  SELECT * INTO e FROM public.inventory_cost_hpp_acceptance_evaluate(current_setting('quena.test_outlet')::uuid)
    WHERE sku='STG-BASE20';
  IF e.classification<>'AUTO_CANDIDATE' OR NOT e.warning_codes @> ARRAY['GROSS_MARGIN_ABOVE_80_PERCENT']::text[] THEN
    RAISE EXCEPTION 'High margin warning incorrectly blocked candidate'; END IF;
END $classification_assertions$;
TRUNCATE hpp_acceptance_hpp_before;
INSERT INTO hpp_acceptance_hpp_before
  SELECT md5(coalesce(string_agg(c.product_id::text||':'||coalesce(c.hpp::text,'NULL')||':'||
    coalesce(c.source_import_row_id::text,'')||':'||coalesce(h.id::text,'')||':'||coalesce(h.hpp::text,'NULL'),
    E'\n' ORDER BY c.product_id),''))
  FROM public.product_costs c LEFT JOIN LATERAL (SELECT id,hpp FROM public.product_cost_history x
    WHERE x.product_id=c.product_id AND x.outlet_id=c.outlet_id ORDER BY effective_at DESC,created_at DESC,id DESC LIMIT 1) h ON true
  WHERE c.outlet_id=:'outlet_id'::uuid;

-- A fresh batch can be prepared after invalidation. Reasoned decisions are required.
SELECT gen_random_uuid()::text prep_request_2 \gset
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
SET LOCAL ROLE authenticated;
SELECT set_config('quena.hpp_accept.prepared_2',public.prepare_initial_hpp_acceptance(:'outlet_id'::uuid,:'prep_request_2'::uuid)::text,true);
RESET ROLE;
SELECT current_setting('quena.hpp_accept.prepared_2')::jsonb->>'batchId' batch_id_2 \gset
SELECT set_config('quena.hpp_accept.batch2',:'batch_id_2',true);
SELECT set_config('quena.hpp_accept.candidate_product',:'product_candidate',true);
DO $reason_required$
DECLARE v_product uuid;v_blocked boolean:=false;
BEGIN
  SELECT product_id INTO v_product FROM public.inventory_cost_hpp_acceptance_items
    WHERE batch_id=current_setting('quena.hpp_accept.batch2')::uuid AND classification='EXCEPTION' LIMIT 1;
  IF v_product IS NOT NULL THEN
    BEGIN
      PERFORM public.resolve_initial_hpp_acceptance_exception(current_setting('quena.hpp_accept.batch2')::uuid,v_product,
        'LEAVE_UNVALUED',NULL,'  ',gen_random_uuid());
      RAISE EXCEPTION 'Blank exception reason was accepted';
    EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  END IF;
  SELECT product_id INTO v_product FROM public.inventory_cost_hpp_acceptance_items
    WHERE batch_id=current_setting('quena.hpp_accept.batch2')::uuid AND current_hpp IS NULL LIMIT 1;
  IF v_product IS NOT NULL THEN
    BEGIN
      PERFORM public.resolve_initial_hpp_acceptance_exception(current_setting('quena.hpp_accept.batch2')::uuid,v_product,
        'AUTHORITATIVE_ZERO',0,'Cannot invent zero for missing HPP',gen_random_uuid());
      RAISE EXCEPTION 'Missing HPP was accepted as authoritative zero';
    EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.inventory_cost_hpp_acceptance_items
      WHERE batch_id=current_setting('quena.hpp_accept.batch2')::uuid
        AND blocking_reasons @> ARRAY['UNRESOLVED_OR_CONFLICTING_HPP_REVIEW']::text[]) THEN
    RAISE EXCEPTION 'Unresolved HPP review was not represented as a blocking exception';
  END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
  BEGIN
    PERFORM public.approve_initial_hpp_acceptance(current_setting('quena.hpp_accept.batch2')::uuid,gen_random_uuid());
  EXCEPTION WHEN SQLSTATE '55000' THEN v_blocked:=true; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'Approval passed while exceptions were unresolved'; END IF;
  PERFORM set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
END $reason_required$;

-- ADMIN resolves every exception explicitly. This exercises zero-vs-missing,
-- current-value acceptance, opening-only overrides, and leave-unvalued evidence.
DO $resolve_exceptions$
DECLARE r record;v_disposition public.inventory_cost_hpp_acceptance_disposition;
  v_override_used boolean:=false;v_result jsonb;
BEGIN
  FOR r IN SELECT product_id,current_hpp,blocking_reasons FROM public.inventory_cost_hpp_acceptance_items
    WHERE batch_id=current_setting('quena.hpp_accept.batch2')::uuid AND classification='EXCEPTION' ORDER BY product_id
  LOOP
    IF r.current_hpp=0 THEN v_disposition:='AUTHORITATIVE_ZERO';
    ELSIF r.current_hpp IS NULL THEN v_disposition:='LEAVE_UNVALUED';
    ELSIF r.blocking_reasons @> ARRAY['UNRESOLVED_OR_CONFLICTING_HPP_REVIEW']::text[] THEN v_disposition:='ACCEPT_CURRENT_HPP';
    ELSIF r.blocking_reasons @> ARRAY['ACTIVE_HPP_OVERRIDE']::text[] THEN v_disposition:='LEAVE_UNVALUED';
    ELSIF r.blocking_reasons @> ARRAY['HPP_NOT_BELOW_SELLING_PRICE']::text[] AND NOT v_override_used THEN v_disposition:='OPENING_HPP_OVERRIDE';v_override_used:=true;
    ELSIF NOT v_override_used THEN v_disposition:='OPENING_HPP_OVERRIDE';v_override_used:=true;
    ELSE v_disposition:='LEAVE_UNVALUED'; END IF;
    v_result:=public.resolve_initial_hpp_acceptance_exception(current_setting('quena.hpp_accept.batch2')::uuid,r.product_id,v_disposition,
      CASE WHEN v_disposition='OPENING_HPP_OVERRIDE' THEN 123.45::numeric END,
      'Rollback-only acceptance test resolution',gen_random_uuid());
    IF v_result->>'code'<>'EXCEPTION_RESOLVED' THEN RAISE EXCEPTION 'Exception resolution failed: %',v_result; END IF;
  END LOOP;
  IF EXISTS(SELECT 1 FROM public.inventory_cost_hpp_acceptance_items WHERE batch_id=current_setting('quena.hpp_accept.batch2')::uuid
    AND classification='EXCEPTION' AND (disposition IS NULL OR resolved_by IS NULL OR nullif(btrim(resolution_reason),'') IS NULL)) THEN
    RAISE EXCEPTION 'An exception remains unresolved after the staging resolution loop';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.inventory_cost_hpp_acceptance_items WHERE batch_id=current_setting('quena.hpp_accept.batch2')::uuid
      AND disposition='AUTHORITATIVE_ZERO' AND accepted_opening_hpp=0 AND nullif(btrim(resolution_reason),'') IS NOT NULL)
    OR NOT EXISTS(SELECT 1 FROM public.inventory_cost_hpp_acceptance_items WHERE batch_id=current_setting('quena.hpp_accept.batch2')::uuid
      AND disposition='LEAVE_UNVALUED' AND accepted_opening_hpp IS NULL AND nullif(btrim(resolution_reason),'') IS NOT NULL)
    OR NOT EXISTS(SELECT 1 FROM public.inventory_cost_hpp_acceptance_items WHERE batch_id=current_setting('quena.hpp_accept.batch2')::uuid
      AND disposition='OPENING_HPP_OVERRIDE' AND accepted_opening_hpp=123.45) THEN
    RAISE EXCEPTION 'Zero, missing/unvalued, or opening-only override evidence was not distinguished';
  END IF;
END $resolve_exceptions$;

-- ADMIN cannot approve. A stock-quantity-only change is not in the cost-trust
-- fingerprint and approval records the then-current quantity snapshot.
SELECT product_id quantity_product FROM public.inventory_cost_hpp_acceptance_items
  WHERE batch_id=:'batch_id_2'::uuid ORDER BY product_id LIMIT 1 \gset
UPDATE public.stock_balance_projection SET unreconciled_movement_delta=unreconciled_movement_delta+0.001,
  balance_version=balance_version+1,updated_at=now()
WHERE product_id=:'quantity_product'::uuid AND outlet_id=:'outlet_id'::uuid;
SELECT gen_random_uuid()::text admin_approve_request \gset
SELECT set_config('quena.hpp_accept.admin_approve_request',:'admin_approve_request',true);
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
SET LOCAL ROLE authenticated;
DO $admin_cannot_approve$
DECLARE v_blocked boolean:=false;
BEGIN
  BEGIN PERFORM public.approve_initial_hpp_acceptance(current_setting('quena.hpp_accept.batch2')::uuid,
    current_setting('quena.hpp_accept.admin_approve_request')::uuid);
  EXCEPTION WHEN insufficient_privilege THEN v_blocked:=true; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'ADMIN final approval was not denied'; END IF;
END $admin_cannot_approve$;
RESET ROLE;

CREATE TEMP TABLE hpp_acceptance_before_approve AS
  SELECT md5(coalesce(string_agg(product_id::text||':'||outlet_id::text||':'||coalesce(effective_quantity::text,'NULL')||':'||balance_version::text,
    E'\n' ORDER BY outlet_id,product_id),'')) AS fingerprint FROM public.stock_balance_projection WHERE outlet_id=:'outlet_id'::uuid;
SELECT gen_random_uuid()::text approve_request \gset
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT set_config('quena.hpp_accept.approved',public.approve_initial_hpp_acceptance(:'batch_id_2'::uuid,:'approve_request'::uuid)::text,true);
SELECT set_config('quena.hpp_accept.approval_replay',public.approve_initial_hpp_acceptance(:'batch_id_2'::uuid,:'approve_request'::uuid)::text,true);
RESET ROLE;
DO $approval_assertions$
DECLARE v_result jsonb:=current_setting('quena.hpp_accept.approved')::jsonb;
BEGIN
  IF v_result->>'code'<>'APPROVED' OR v_result<>current_setting('quena.hpp_accept.approval_replay')::jsonb THEN
    RAISE EXCEPTION 'OWNER approval or exact replay failed';
  END IF;
  IF (SELECT status FROM public.inventory_cost_hpp_acceptance_batches WHERE id=(v_result->>'batchId')::uuid)<>'APPROVED'
    OR (SELECT count(*) FROM public.inventory_cost_hpp_acceptance_items WHERE batch_id=(v_result->>'batchId')::uuid AND approved_by IS NOT NULL)
      <>(SELECT count(*) FROM public.inventory_cost_hpp_acceptance_items WHERE batch_id=(v_result->>'batchId')::uuid) THEN
    RAISE EXCEPTION 'Approved immutable item evidence is incomplete';
  END IF;
  IF (SELECT fingerprint FROM hpp_acceptance_before_approve)<>
    (SELECT md5(coalesce(string_agg(product_id::text||':'||outlet_id::text||':'||coalesce(effective_quantity::text,'NULL')||':'||balance_version::text,
      E'\n' ORDER BY outlet_id,product_id),'')) FROM public.stock_balance_projection WHERE outlet_id=current_setting('quena.test_outlet')::uuid) THEN
    RAISE EXCEPTION 'Approval unexpectedly changed stock projection';
  END IF;
  IF (SELECT count(*) FROM public.inventory_cost_projections WHERE outlet_id=current_setting('quena.test_outlet')::uuid)<>0
    OR (SELECT count(*) FROM public.inventory_cost_events WHERE outlet_id=current_setting('quena.test_outlet')::uuid)<>0
    OR (SELECT count(*) FROM public.inventory_cost_event_batches WHERE outlet_id=current_setting('quena.test_outlet')::uuid)<>0
    OR (SELECT count(*) FROM public.inventory_costing_outlet_authority WHERE outlet_id=current_setting('quena.test_outlet')::uuid)<>0 THEN
    RAISE EXCEPTION 'HPP approval bootstrapped or activated WAC';
  END IF;
END $approval_assertions$;

-- Approved acceptance evidence and audit history reject edits/deletes.
DO $immutability$
DECLARE v_batch uuid:=(current_setting('quena.hpp_accept.approved')::jsonb->>'batchId')::uuid;
  v_product uuid;v_event uuid;v_update_blocked boolean:=false;v_delete_blocked boolean:=false;
BEGIN
  SELECT product_id INTO v_product FROM public.inventory_cost_hpp_acceptance_items WHERE batch_id=v_batch LIMIT 1;
  BEGIN UPDATE public.inventory_cost_hpp_acceptance_items SET current_hpp=current_hpp WHERE batch_id=v_batch AND product_id=v_product;
  EXCEPTION WHEN SQLSTATE '55000' THEN v_update_blocked:=true; END;
  SELECT id INTO v_event FROM public.inventory_cost_hpp_acceptance_events WHERE batch_id=v_batch LIMIT 1;
  BEGIN DELETE FROM public.inventory_cost_hpp_acceptance_events WHERE id=v_event;
  EXCEPTION WHEN SQLSTATE '55000' THEN v_delete_blocked:=true; END;
  IF NOT v_update_blocked OR NOT v_delete_blocked THEN RAISE EXCEPTION 'Approved evidence/audit immutability failed'; END IF;
END $immutability$;

-- Batch prepare replay did not mutate source HPP/history or the WAC foundation.
DO $no_financial_or_cost_mutation$
BEGIN
  IF (SELECT fingerprint FROM hpp_acceptance_hpp_before)<>
    (SELECT md5(coalesce(string_agg(c.product_id::text||':'||coalesce(c.hpp::text,'NULL')||':'||
      coalesce(c.source_import_row_id::text,'')||':'||coalesce(h.id::text,'')||':'||coalesce(h.hpp::text,'NULL'),
      E'\n' ORDER BY c.product_id),'')) FROM public.product_costs c LEFT JOIN LATERAL
      (SELECT id,hpp FROM public.product_cost_history x WHERE x.product_id=c.product_id AND x.outlet_id=c.outlet_id
        ORDER BY effective_at DESC,created_at DESC,id DESC LIMIT 1) h ON true WHERE c.outlet_id=current_setting('quena.test_outlet')::uuid) THEN
    RAISE EXCEPTION 'Acceptance changed legacy current/history HPP';
  END IF;
  IF (SELECT projections::text||':'||events::text||':'||batches::text||':'||authorities::text FROM hpp_acceptance_cost_state_before)<>
    ((SELECT count(*)::text FROM public.inventory_cost_projections WHERE outlet_id=current_setting('quena.test_outlet')::uuid)
      ||':'||(SELECT count(*)::text FROM public.inventory_cost_events WHERE outlet_id=current_setting('quena.test_outlet')::uuid)
      ||':'||(SELECT count(*)::text FROM public.inventory_cost_event_batches WHERE outlet_id=current_setting('quena.test_outlet')::uuid)
      ||':'||(SELECT count(*)::text FROM public.inventory_costing_outlet_authority WHERE outlet_id=current_setting('quena.test_outlet')::uuid)) THEN
    RAISE EXCEPTION 'Acceptance changed WAC foundation state';
  END IF;
END $no_financial_or_cost_mutation$;

ROLLBACK;
