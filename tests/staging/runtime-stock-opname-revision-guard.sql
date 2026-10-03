-- Local-only forward-contract matrix for REBASE_ITEM, REVIEW_EXCEPTION, and progress.
-- All business mutations use stock intent/apply RPCs in a transaction that rolls back.
\set ON_ERROR_STOP on
\timing on

DO $guard$
BEGIN
  IF current_database() <> 'quena_stock_staging'
     OR coalesce(host(inet_server_addr()), '') NOT IN ('127.0.0.1', '::1')
     OR inet_server_port() <> 5432
     OR current_setting('server_version_num')::integer / 10000 <> 15
     OR current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'Refusing opname revision runtime checks outside local UTF8 PostgreSQL 15 quena_stock_staging';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929180000')
     OR NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929190000')
     OR NOT EXISTS (SELECT 1 FROM quena_staging.applied_migrations WHERE version = '20260929200000') THEN
    RAISE EXCEPTION 'Required local stock migrations 180000, 190000, and 200000 are not ledgered';
  END IF;
END;
$guard$;

BEGIN;
SET LOCAL statement_timeout = '90s';
SET LOCAL lock_timeout = '8s';
SET LOCAL ROLE authenticated;

DO $matrix$
DECLARE
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_admin uuid := 'a0000000-0000-4000-8000-000000000002';
  v_gudang uuid := 'a0000000-0000-4000-8000-000000000003';
  v_kasir uuid := 'a0000000-0000-4000-8000-000000000004';
  v_outlet uuid;
  v_a uuid; v_b uuid; v_c uuid; v_d uuid; v_e uuid; v_f uuid; v_g uuid; v_h uuid;
  v_setup uuid; v_session uuid;
  v_setup_request uuid; v_request uuid; v_retry uuid; v_old_rebase uuid; v_old_exception uuid;
  v_e_movement uuid; v_f_movement uuid;
  v_result jsonb; v_replay jsonb; v_progress jsonb;
  v_base numeric; v_current numeric;
  v_revision integer;
  v_reason text; v_physical numeric;
  v_inventory_before text; v_inventory_after text;
  v_projection_before text; v_projection_after text;
  v_event_count bigint;
  v_denied boolean;
  v_legacy_rebase uuid := 'd0000000-0000-4000-8000-000000000001';
  v_legacy_exception uuid := 'd0000000-0000-4000-8000-000000000002';
  v_acl_ok boolean;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  IF public.current_active_user_role() IS DISTINCT FROM 'OWNER'::public.user_role THEN RAISE EXCEPTION 'OWNER fixture profile unavailable'; END IF;
  SELECT o.id INTO STRICT v_outlet FROM public.outlets o WHERE o.code = 'QUENA-MART-1' AND o.is_active;
  SELECT id INTO STRICT v_a FROM public.products WHERE sku = 'STG-FULL-A';
  SELECT id INTO STRICT v_b FROM public.products WHERE sku = 'STG-FULL-B';
  SELECT id INTO STRICT v_c FROM public.products WHERE sku = 'STG-STALE';
  SELECT id INTO STRICT v_d FROM public.products WHERE sku = 'STG-BASE20';
  SELECT id INTO STRICT v_e FROM public.products WHERE sku = 'STG-RECON';
  SELECT id INTO STRICT v_f FROM public.products WHERE sku = 'STG-CONCURRENT';
  SELECT id INTO STRICT v_g FROM public.products WHERE sku = 'STG-AMBIG-A';
  SELECT id INTO STRICT v_h FROM public.products WHERE sku = 'STG-AMBIG-B';

  IF EXISTS (SELECT 1 FROM public.stock_opname_items i WHERE i.outlet_id = v_outlet AND i.active_scope
    AND i.product_id IN (v_a,v_b,v_c,v_d,v_e,v_f,v_g,v_h)) THEN
    RAISE EXCEPTION 'Precondition failed: a revision-matrix product already has active opname coverage';
  END IF;

  -- Prepare two real posted opname movements so the main session can observe a later baseline change.
  v_setup_request := public.issue_stock_operation_intent('CREATE_SESSION', jsonb_build_object(
    'outlet_id', v_outlet, 'scope_type', 'PARTIAL', 'product_ids', jsonb_build_array(v_e,v_f),
    'note', 'RG:setup-posted-baselines'));
  v_result := public.apply_stock_operation_intent(v_setup_request);
  IF v_result->>'ok' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Could not create setup opname'; END IF;
  v_setup := (v_result->>'sessionId')::uuid;
  SELECT effective_quantity INTO STRICT v_base FROM public.stock_balance_projection WHERE outlet_id=v_outlet AND product_id=v_e;
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object('session_id',v_setup,'product_id',v_e,'physical_quantity',v_base+1,'expected_revision',0,'barcode_id',null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'ok' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Setup count for STG-RECON failed'; END IF;
  SELECT effective_quantity INTO STRICT v_base FROM public.stock_balance_projection WHERE outlet_id=v_outlet AND product_id=v_f;
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object('session_id',v_setup,'product_id',v_f,'physical_quantity',v_base+1,'expected_revision',0,'barcode_id',null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'ok' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Setup count for STG-CONCURRENT failed'; END IF;
  v_request := public.issue_stock_operation_intent('SUBMIT_REVIEW', jsonb_build_object('session_id',v_setup));
  PERFORM public.apply_stock_operation_intent(v_request);
  v_request := public.issue_stock_operation_intent('POST_SESSION', jsonb_build_object('session_id',v_setup));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'status' IS DISTINCT FROM 'POSTED' THEN RAISE EXCEPTION 'Setup stock movement post failed'; END IF;
  SELECT m.id INTO STRICT v_e_movement FROM public.stock_movements m JOIN public.stock_opname_items i ON i.id=m.opname_item_id WHERE i.session_id=v_setup AND i.product_id=v_e AND m.movement_type='OPNAME_ADJUSTMENT';
  SELECT m.id INTO STRICT v_f_movement FROM public.stock_movements m JOIN public.stock_opname_items i ON i.id=m.opname_item_id WHERE i.session_id=v_setup AND i.product_id=v_f AND m.movement_type='OPNAME_ADJUSTMENT';

  v_request := public.issue_stock_operation_intent('CREATE_SESSION', jsonb_build_object('outlet_id',v_outlet,'scope_type','FULL','product_ids','[]'::jsonb,'note','RG:main-session'));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'ok' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Could not create full revision-matrix session'; END IF;
  v_session := (v_result->>'sessionId')::uuid;
  IF (SELECT count(*) FROM public.stock_opname_items WHERE session_id=v_session) <> 8 THEN RAISE EXCEPTION 'FULL fixture scope did not materialize eight projection products'; END IF;

  -- KASIR cannot issue either item-level operation.
  PERFORM set_config('request.jwt.claim.sub',v_kasir::text,true);
  v_denied := false;
  BEGIN
    PERFORM public.issue_stock_operation_intent('REBASE_ITEM',jsonb_build_object('session_id',v_session,'product_id',v_a,'expected_revision',0));
  EXCEPTION WHEN insufficient_privilege THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'KASIR was allowed to issue REBASE_ITEM'; END IF;
  v_denied := false;
  BEGIN
    PERFORM public.issue_stock_operation_intent('REVIEW_EXCEPTION',jsonb_build_object('session_id',v_session,'product_id',v_a,'expected_revision',0,'reason','not allowed'));
  EXCEPTION WHEN insufficient_privilege THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'KASIR was allowed to issue REVIEW_EXCEPTION'; END IF;
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  v_denied := false;
  BEGIN
    PERFORM public.issue_stock_operation_intent('REBASE_ITEM',jsonb_build_object('session_id',v_session,'product_id',v_a,'expected_revision',-1));
  EXCEPTION WHEN invalid_parameter_value THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Negative expected_revision was accepted'; END IF;
  v_denied := false;
  BEGIN
    PERFORM public.issue_stock_operation_intent('REVIEW_EXCEPTION',jsonb_build_object('session_id',v_session,'product_id',v_a,'expected_revision',1.5,'reason','must fail'));
  EXCEPTION WHEN invalid_parameter_value THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Fractional expected_revision was accepted'; END IF;
  v_denied := false;
  BEGIN
    PERFORM public.issue_stock_operation_intent('REBASE_ITEM',jsonb_build_object('session_id',v_session,'product_id',v_a,'expected_revision',2147483648));
  EXCEPTION WHEN invalid_parameter_value THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Out-of-range expected_revision was accepted'; END IF;
  v_denied := false;
  BEGIN
    PERFORM public.issue_stock_operation_intent('REBASE_ITEM',jsonb_build_object('session_id',v_session,'product_id',v_a));
  EXCEPTION WHEN invalid_parameter_value THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Missing expected_revision was accepted'; END IF;

  -- Count E and review an exception on F before reversing their setup movements.
  SELECT effective_quantity INTO STRICT v_base FROM public.stock_balance_projection WHERE outlet_id=v_outlet AND product_id=v_e;
  v_request := public.issue_stock_operation_intent('RECORD_COUNT', jsonb_build_object('session_id',v_session,'product_id',v_e,'physical_quantity',v_base,'expected_revision',0,'barcode_id',null));
  PERFORM public.apply_stock_operation_intent(v_request);
  PERFORM set_config('request.jwt.claim.sub', v_gudang::text, true);
  v_request := public.issue_stock_operation_intent('REVIEW_EXCEPTION', jsonb_build_object('session_id',v_session,'product_id',v_f,'expected_revision',0,'reason','Inspect package'));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'exceptionReviewed' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'GUDANG exception setup failed'; END IF;

  -- Only these explicit setup reversal RPCs create the baseline-stale fixture.
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  v_request := public.issue_stock_operation_intent('REVERSE_MOVEMENT', jsonb_build_object('movement_id',v_e_movement,'reason','RG baseline fixture'));
  PERFORM public.apply_stock_operation_intent(v_request);
  v_request := public.issue_stock_operation_intent('REVERSE_MOVEMENT', jsonb_build_object('movement_id',v_f_movement,'reason','RG baseline fixture'));
  PERFORM public.apply_stock_operation_intent(v_request);

  SELECT md5(coalesce(string_agg(i.product_id::text||':'||coalesce(i.quantity::text,'<null>')||':'||coalesce(i.minimum_quantity::text,'<null>')||':'||coalesce(i.source_import_row_id::text,'<null>'),E'\n' ORDER BY i.product_id),''))
  INTO v_inventory_before FROM public.product_inventory i WHERE i.outlet_id=v_outlet AND i.product_id IN (v_a,v_b,v_c,v_d,v_e,v_f,v_g,v_h);
  SELECT md5(coalesce(string_agg(p.product_id::text||':'||coalesce(p.effective_quantity::text,'<null>')||':'||p.balance_version::text||':'||coalesce(p.unreconciled_movement_delta::text,'<null>'),E'\n' ORDER BY p.product_id),''))
  INTO v_projection_before FROM public.stock_balance_projection p WHERE p.outlet_id=v_outlet AND p.product_id IN (v_a,v_b,v_c,v_d,v_e,v_f,v_g,v_h);

  -- A: competing stale rebases cannot clear a newer physical count or exception.
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  v_request := public.issue_stock_operation_intent('RECORD_COUNT',jsonb_build_object('session_id',v_session,'product_id',v_a,'physical_quantity',0,'expected_revision',0,'barcode_id',null));
  PERFORM public.apply_stock_operation_intent(v_request);
  v_old_rebase := public.issue_stock_operation_intent('REBASE_ITEM',jsonb_build_object('session_id',v_session,'product_id',v_a,'expected_revision',0));
  PERFORM set_config('request.jwt.claim.sub',v_admin::text,true);
  v_request := public.issue_stock_operation_intent('RECORD_COUNT',jsonb_build_object('session_id',v_session,'product_id',v_a,'physical_quantity',3.5,'expected_revision',1,'barcode_id',null));
  PERFORM public.apply_stock_operation_intent(v_request);
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  v_result := public.apply_stock_operation_intent(v_old_rebase);
  IF v_result->>'reason' IS DISTINCT FROM 'ITEM_REVISION_MISMATCH' OR v_result->>'expectedRevision' IS DISTINCT FROM '0' OR v_result->>'currentRevision' IS DISTINCT FROM '2'
     OR v_result->>'refreshRequired' IS DISTINCT FROM 'true' OR v_result ? 'recountRequired' THEN RAISE EXCEPTION 'Stale REBASE_ITEM result contract mismatch'; END IF;
  IF (SELECT physical_quantity FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_a) IS DISTINCT FROM 3.5
     OR (SELECT revision_no FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_a) <> 2
     OR EXISTS (SELECT 1 FROM public.stock_opname_count_events WHERE request_id=v_old_rebase) THEN RAISE EXCEPTION 'Stale rebase changed newer physical count/event'; END IF;
  v_replay := public.apply_stock_operation_intent(v_old_rebase);
  IF v_replay IS DISTINCT FROM v_result THEN RAISE EXCEPTION 'Stale REBASE_ITEM replay changed its result'; END IF;

  -- Re-issuing after the newer count completed produces a new request identity;
  -- its stale expected_revision still cannot mutate the current item.
  v_request := public.issue_stock_operation_intent('REBASE_ITEM',jsonb_build_object('session_id',v_session,'product_id',v_a,'expected_revision',1));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'reason' IS DISTINCT FROM 'ITEM_REVISION_MISMATCH'
     OR v_result->>'currentRevision' IS DISTINCT FROM '2'
     OR EXISTS (SELECT 1 FROM public.stock_opname_count_events WHERE request_id=v_request)
     OR (SELECT physical_quantity FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_a) IS DISTINCT FROM 3.5 THEN
    RAISE EXCEPTION 'New post-completion stale REBASE_ITEM request changed newer count';
  END IF;

  v_old_rebase := public.issue_stock_operation_intent('REBASE_ITEM',jsonb_build_object('session_id',v_session,'product_id',v_a,'expected_revision',1));
  v_retry := public.issue_stock_operation_intent('REBASE_ITEM',jsonb_build_object('session_id',v_session,'product_id',v_a,'expected_revision',1));
  IF v_retry IS DISTINCT FROM v_old_rebase THEN RAISE EXCEPTION 'Same pending canonical REBASE_ITEM did not reuse request UUID'; END IF;
  PERFORM set_config('request.jwt.claim.sub',v_gudang::text,true);
  v_request := public.issue_stock_operation_intent('REVIEW_EXCEPTION',jsonb_build_object('session_id',v_session,'product_id',v_a,'expected_revision',2,'reason','  New exception  '));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'exceptionReviewed' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Newer exception setup failed'; END IF;
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  v_result := public.apply_stock_operation_intent(v_old_rebase);
  IF v_result->>'reason' IS DISTINCT FROM 'ITEM_REVISION_MISMATCH'
     OR (SELECT exception_reason FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_a) IS DISTINCT FROM 'New exception'
     OR (SELECT revision_no FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_a) <> 3 THEN RAISE EXCEPTION 'Stale rebase replaced newer exception'; END IF;
  PERFORM set_config('request.jwt.claim.sub',v_gudang::text,true);
  v_request := public.issue_stock_operation_intent('REBASE_ITEM',jsonb_build_object('session_id',v_session,'product_id',v_a,'expected_revision',3));
  v_result := public.apply_stock_operation_intent(v_request);
  SELECT effective_quantity INTO STRICT v_current FROM public.stock_balance_projection WHERE outlet_id=v_outlet AND product_id=v_a;
  IF v_result->>'ok' IS DISTINCT FROM 'true' OR (SELECT baseline_quantity FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_a) IS DISTINCT FROM v_current
     OR (SELECT physical_quantity FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_a) IS NOT NULL
     OR (SELECT exception_reason FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_a) IS NOT NULL
     OR (SELECT revision_no FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_a) <> 4
     OR NOT EXISTS (SELECT 1 FROM public.stock_opname_count_events WHERE request_id=v_request AND event_type='BASELINE_REFRESHED' AND revision_no=4) THEN RAISE EXCEPTION 'Matching GUDANG rebase failed to refresh/clear/event/revise'; END IF;
  v_replay := public.apply_stock_operation_intent(v_request);
  IF v_replay IS DISTINCT FROM v_result OR (SELECT count(*) FROM public.stock_opname_count_events WHERE request_id=v_request) <> 1 THEN RAISE EXCEPTION 'Exact REBASE_ITEM retry duplicated event'; END IF;
  RAISE NOTICE 'PASS: OWNER/GUDANG REBASE_ITEM, stale count/exception protection, exact replay';

  -- B: ADMIN rebase, canonical pending UUID reuse, then decimal recount.
  PERFORM set_config('request.jwt.claim.sub',v_admin::text,true);
  v_request := public.issue_stock_operation_intent('REBASE_ITEM',jsonb_build_object('session_id',v_session,'product_id',v_b,'expected_revision',0));
  v_retry := public.issue_stock_operation_intent('REBASE_ITEM',jsonb_build_object('session_id',v_session,'product_id',v_b,'expected_revision',0));
  IF v_retry IS DISTINCT FROM v_request THEN RAISE EXCEPTION 'ADMIN pending REBASE_ITEM did not reuse UUID'; END IF;
  v_result := public.apply_stock_operation_intent(v_request);
  v_replay := public.apply_stock_operation_intent(v_request);
  IF v_replay IS DISTINCT FROM v_result OR (SELECT count(*) FROM public.stock_opname_count_events WHERE request_id=v_request AND event_type='BASELINE_REFRESHED') <> 1 THEN RAISE EXCEPTION 'ADMIN REBASE_ITEM exact retry failed'; END IF;
  v_request := public.issue_stock_operation_intent('RECORD_COUNT',jsonb_build_object('session_id',v_session,'product_id',v_b,'physical_quantity',7.125,'expected_revision',1,'barcode_id',null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'ok' IS DISTINCT FROM 'true' OR (SELECT physical_quantity FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_b) IS DISTINCT FROM 7.125 THEN RAISE EXCEPTION 'Post-rebase decimal RECORD_COUNT did not use new baseline/revision'; END IF;

  -- C: OWNER rebase; stale exception cannot overwrite a newer count; fresh rebase clears it.
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  v_request := public.issue_stock_operation_intent('REBASE_ITEM',jsonb_build_object('session_id',v_session,'product_id',v_c,'expected_revision',0));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'ok' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'OWNER matching REBASE_ITEM failed'; END IF;
  v_old_exception := public.issue_stock_operation_intent('REVIEW_EXCEPTION',jsonb_build_object('session_id',v_session,'product_id',v_c,'expected_revision',1,'reason','old exception request'));
  PERFORM set_config('request.jwt.claim.sub',v_gudang::text,true);
  v_request := public.issue_stock_operation_intent('RECORD_COUNT',jsonb_build_object('session_id',v_session,'product_id',v_c,'physical_quantity',8.75,'expected_revision',1,'barcode_id',null));
  PERFORM public.apply_stock_operation_intent(v_request);
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  v_result := public.apply_stock_operation_intent(v_old_exception);
  IF v_result->>'reason' IS DISTINCT FROM 'ITEM_REVISION_MISMATCH'
     OR (SELECT physical_quantity FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_c) IS DISTINCT FROM 8.75
     OR (SELECT exception_reason FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_c) IS NOT NULL THEN RAISE EXCEPTION 'Stale REVIEW_EXCEPTION cleared newer physical count'; END IF;
  v_replay := public.apply_stock_operation_intent(v_old_exception);
  IF v_replay IS DISTINCT FROM v_result OR (SELECT count(*) FROM public.stock_opname_count_events WHERE request_id=v_old_exception) <> 0 THEN RAISE EXCEPTION 'Stale REVIEW_EXCEPTION retry/event behavior invalid'; END IF;
  PERFORM set_config('request.jwt.claim.sub',v_gudang::text,true);
  v_request := public.issue_stock_operation_intent('REBASE_ITEM',jsonb_build_object('session_id',v_session,'product_id',v_c,'expected_revision',2));
  PERFORM public.apply_stock_operation_intent(v_request);
  -- A stale exception cannot replace a newer reviewed exception either.
  -- Keep the stale request OWNER-bound and let GUDANG commit the newer revision,
  -- so actor-scoped pending-request supersession cannot replace the stale request.
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  v_old_exception := public.issue_stock_operation_intent('REVIEW_EXCEPTION',jsonb_build_object('session_id',v_session,'product_id',v_c,'expected_revision',3,'reason','older exception'));
  PERFORM set_config('request.jwt.claim.sub',v_gudang::text,true);
  v_request := public.issue_stock_operation_intent('REVIEW_EXCEPTION',jsonb_build_object('session_id',v_session,'product_id',v_c,'expected_revision',3,'reason','newer exception'));
  PERFORM public.apply_stock_operation_intent(v_request);
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  v_result := public.apply_stock_operation_intent(v_old_exception);
  IF v_result->>'reason' IS DISTINCT FROM 'ITEM_REVISION_MISMATCH'
     OR (SELECT exception_reason FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_c) IS DISTINCT FROM 'newer exception' THEN RAISE EXCEPTION 'Stale exception replaced newer exception'; END IF;
  PERFORM set_config('request.jwt.claim.sub',v_gudang::text,true);
  v_request := public.issue_stock_operation_intent('REBASE_ITEM',jsonb_build_object('session_id',v_session,'product_id',v_c,'expected_revision',4));
  PERFORM public.apply_stock_operation_intent(v_request);
  IF (SELECT physical_quantity FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_c) IS NOT NULL THEN RAISE EXCEPTION 'Matching rebase did not clear old physical count'; END IF;

  -- D: OWNER exception clears a prior zero count; whitespace-normalized requests share identity.
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  v_request := public.issue_stock_operation_intent('RECORD_COUNT',jsonb_build_object('session_id',v_session,'product_id',v_d,'physical_quantity',0,'expected_revision',0,'barcode_id',null));
  PERFORM public.apply_stock_operation_intent(v_request);
  v_request := public.issue_stock_operation_intent('REVIEW_EXCEPTION',jsonb_build_object('session_id',v_session,'product_id',v_d,'expected_revision',1,'reason','  Barang belum dapat dipastikan  '));
  v_retry := public.issue_stock_operation_intent('REVIEW_EXCEPTION',jsonb_build_object('session_id',v_session,'product_id',v_d,'expected_revision',1,'reason','Barang belum dapat dipastikan'));
  IF v_retry IS DISTINCT FROM v_request THEN RAISE EXCEPTION 'Trim-equivalent REVIEW_EXCEPTION did not reuse pending UUID'; END IF;
  v_result := public.apply_stock_operation_intent(v_request);
  v_replay := public.apply_stock_operation_intent(v_request);
  IF v_replay IS DISTINCT FROM v_result OR v_result->>'exceptionReviewed' IS DISTINCT FROM 'true'
     OR (SELECT physical_quantity FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_d) IS NOT NULL
     OR (SELECT exception_reason FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_d) IS DISTINCT FROM 'Barang belum dapat dipastikan'
     OR (SELECT revision_no FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_d) <> 2
     OR (SELECT count(*) FROM public.stock_opname_count_events WHERE request_id=v_request AND event_type='EXCEPTION_REVIEWED' AND revision_no=2) <> 1 THEN RAISE EXCEPTION 'OWNER exception trim/clear/revision/event/replay failed'; END IF;
  v_denied := false;
  BEGIN
    PERFORM public.issue_stock_operation_intent('REVIEW_EXCEPTION',jsonb_build_object('session_id',v_session,'product_id',v_d,'expected_revision',2,'reason','   '));
  EXCEPTION WHEN invalid_parameter_value THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Whitespace-only exception reason was accepted'; END IF;
  v_denied := false;
  BEGIN
    PERFORM public.issue_stock_operation_intent('REVIEW_EXCEPTION',jsonb_build_object('session_id',v_session,'product_id',v_d,'expected_revision',2,'reason',''));
  EXCEPTION WHEN invalid_parameter_value THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Blank exception reason was accepted'; END IF;

  -- G: ADMIN exception role, reason trim, and append-only event.
  PERFORM set_config('request.jwt.claim.sub',v_admin::text,true);
  v_request := public.issue_stock_operation_intent('REVIEW_EXCEPTION',jsonb_build_object('session_id',v_session,'product_id',v_g,'expected_revision',0,'reason','  Check kondisi  '));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'exceptionReviewed' IS DISTINCT FROM 'true'
     OR (SELECT exception_reason FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_g) IS DISTINCT FROM 'Check kondisi'
     OR (SELECT physical_quantity FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_g) IS NOT NULL THEN RAISE EXCEPTION 'ADMIN reviewed exception semantics invalid'; END IF;

  -- H: zero is a real counted quantity, never an exception.
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  v_request := public.issue_stock_operation_intent('RECORD_COUNT',jsonb_build_object('session_id',v_session,'product_id',v_h,'physical_quantity',0,'expected_revision',0,'barcode_id',null));
  PERFORM public.apply_stock_operation_intent(v_request);

  -- Projection-stale operations preserve the prior count/exception fields,
  -- mark recount required, and append STALE_BASELINE rather than success.
  v_request := public.issue_stock_operation_intent('RECORD_COUNT',jsonb_build_object('session_id',v_session,'product_id',v_e,'physical_quantity',99,'expected_revision',1,'barcode_id',null));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'reason' IS DISTINCT FROM 'PROJECTION_BASELINE_CHANGED'
     OR NOT (SELECT requires_recount FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_e)
     OR (SELECT physical_quantity FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_e) IS NULL THEN RAISE EXCEPTION 'Projection-stale count did not preserve old count and require recount'; END IF;
  PERFORM set_config('request.jwt.claim.sub',v_gudang::text,true);
  v_request := public.issue_stock_operation_intent('REVIEW_EXCEPTION',jsonb_build_object('session_id',v_session,'product_id',v_f,'expected_revision',1,'reason','Changed reason'));
  v_result := public.apply_stock_operation_intent(v_request);
  IF v_result->>'code' IS DISTINCT FROM 'STALE_BASELINE'
     OR v_result->>'recountRequired' IS DISTINCT FROM 'true'
     OR NOT (SELECT requires_recount FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_f)
     OR (SELECT exception_reason FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_f) IS DISTINCT FROM 'Inspect package'
     OR (SELECT exception_reviewed_by FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_f) IS DISTINCT FROM v_gudang
     OR (SELECT exception_reviewed_at FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_f) IS NULL
     OR (SELECT physical_quantity FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_f) IS NOT NULL
     OR (SELECT count(*) FROM public.stock_opname_count_events WHERE request_id=v_request AND event_type='STALE_BASELINE') <> 1
     OR (SELECT revision_no FROM public.stock_opname_items WHERE session_id=v_session AND product_id=v_f) <> 2
     OR NOT EXISTS (SELECT 1 FROM public.stock_opname_count_events WHERE request_id=v_request AND event_type='STALE_BASELINE' AND revision_no=2)
     OR EXISTS (SELECT 1 FROM public.stock_opname_count_events WHERE request_id=v_request AND event_type='EXCEPTION_REVIEWED') THEN
    RAISE EXCEPTION 'Projection-stale exception result/event/recount behavior invalid';
  END IF;

  -- Matching progress read is one aggregate snapshot; stale rows are neither counted nor exceptions.
  v_progress := public.stock_opname_progress_counts(v_session);
  IF v_progress IS DISTINCT FROM jsonb_build_object('total',8,'counted',2,'exception',2,'accounted',4,'remaining',4,'recount_required',2) THEN
    RAISE EXCEPTION 'Progress aggregate mismatch: %', v_progress;
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_admin::text,true);
  IF public.stock_opname_progress_counts(v_session) IS DISTINCT FROM v_progress THEN RAISE EXCEPTION 'ADMIN could not read RLS-protected session progress'; END IF;
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  IF public.stock_opname_progress_counts(v_session) IS DISTINCT FROM v_progress THEN RAISE EXCEPTION 'OWNER could not read session progress'; END IF;
  PERFORM set_config('request.jwt.claim.sub',v_kasir::text,true);
  IF public.stock_opname_progress_counts(v_session) IS DISTINCT FROM jsonb_build_object('total',0,'counted',0,'exception',0,'accounted',0,'remaining',0,'recount_required',0) THEN RAISE EXCEPTION 'KASIR observed opname progress outside existing RLS'; END IF;

  -- The before fingerprint was captured as OWNER. Restore that same RLS
  -- identity before comparing the after fingerprint; KASIR cannot see stock
  -- projections, so comparing under KASIR would look like rows disappeared.
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  SELECT md5(coalesce(string_agg(i.product_id::text||':'||coalesce(i.quantity::text,'<null>')||':'||coalesce(i.minimum_quantity::text,'<null>')||':'||coalesce(i.source_import_row_id::text,'<null>'),E'\n' ORDER BY i.product_id),''))
  INTO v_inventory_after FROM public.product_inventory i WHERE i.outlet_id=v_outlet AND i.product_id IN (v_a,v_b,v_c,v_d,v_e,v_f,v_g,v_h);
  SELECT md5(coalesce(string_agg(p.product_id::text||':'||coalesce(p.effective_quantity::text,'<null>')||':'||p.balance_version::text||':'||coalesce(p.unreconciled_movement_delta::text,'<null>'),E'\n' ORDER BY p.product_id),''))
  INTO v_projection_after FROM public.stock_balance_projection p WHERE p.outlet_id=v_outlet AND p.product_id IN (v_a,v_b,v_c,v_d,v_e,v_f,v_g,v_h);
  IF v_inventory_after IS DISTINCT FROM v_inventory_before OR v_projection_after IS DISTINCT FROM v_projection_before THEN RAISE EXCEPTION 'Rebase/exception/count operations changed inventory or projection quantities'; END IF;

  -- Role/ACL assertions include PUBLIC through anon's effective privilege.
  SELECT p.proowner = 'postgres'::regrole AND NOT p.prosecdef
    AND p.proconfig @> ARRAY['search_path=pg_catalog']
    AND has_function_privilege('authenticated','public.stock_opname_progress_counts(uuid)','EXECUTE')
    AND NOT has_function_privilege('anon','public.stock_opname_progress_counts(uuid)','EXECUTE')
    AND NOT has_function_privilege('service_role','public.stock_opname_progress_counts(uuid)','EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a WHERE a.grantee=0 AND a.privilege_type='EXECUTE')
  INTO v_acl_ok FROM pg_catalog.pg_proc p WHERE p.oid='public.stock_opname_progress_counts(uuid)'::regprocedure;
  IF NOT coalesce(v_acl_ok,false) THEN RAISE EXCEPTION 'Progress RPC owner/security/search_path/grants are incorrect'; END IF;

  PERFORM set_config('quena.revision_guard.session_id',v_session::text,true);
  PERFORM set_config('quena.revision_guard.product_id',v_a::text,true);
  PERFORM set_config('quena.revision_guard.owner_id',v_owner::text,true);
  PERFORM set_config('quena.revision_guard.admin_id',v_admin::text,true);
  RAISE NOTICE 'PASS: OWNER/ADMIN/GUDANG rebase and exception, stale revision protection, progress snapshot, no stock quantity mutation';
END;
$matrix$;

-- Simulate legacy PENDING rows that could only predate the new canonical contract.
-- This is private request-ledger fixture setup, never a stock item/domain mutation.
SET LOCAL ROLE postgres;
INSERT INTO public.stock_operation_requests(request_id,actor_id,operation_key,target_key,request_payload,payload_hash)
VALUES
 ('d0000000-0000-4000-8000-000000000001',current_setting('quena.revision_guard.owner_id')::uuid,'REBASE_ITEM',current_setting('quena.revision_guard.session_id')||':'||current_setting('quena.revision_guard.product_id'),jsonb_build_object('session_id',current_setting('quena.revision_guard.session_id')::uuid,'product_id',current_setting('quena.revision_guard.product_id')::uuid),md5(jsonb_build_object('session_id',current_setting('quena.revision_guard.session_id')::uuid,'product_id',current_setting('quena.revision_guard.product_id')::uuid)::text)),
 ('d0000000-0000-4000-8000-000000000002',current_setting('quena.revision_guard.admin_id')::uuid,'REVIEW_EXCEPTION',current_setting('quena.revision_guard.session_id')||':'||current_setting('quena.revision_guard.product_id'),jsonb_build_object('session_id',current_setting('quena.revision_guard.session_id')::uuid,'product_id',current_setting('quena.revision_guard.product_id')::uuid,'reason','Legacy reason'),md5(jsonb_build_object('session_id',current_setting('quena.revision_guard.session_id')::uuid,'product_id',current_setting('quena.revision_guard.product_id')::uuid,'reason','Legacy reason')::text));
SET LOCAL ROLE authenticated;
DO $legacy$
DECLARE
  v_session uuid := current_setting('quena.revision_guard.session_id')::uuid;
  v_product uuid := current_setting('quena.revision_guard.product_id')::uuid;
  v_owner uuid := current_setting('quena.revision_guard.owner_id')::uuid;
  v_admin uuid := current_setting('quena.revision_guard.admin_id')::uuid;
  v_before text; v_after text; v_result jsonb; v_replay jsonb;
BEGIN
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  SELECT md5(i.revision_no::text||':'||coalesce(i.physical_quantity::text,'<null>')||':'||coalesce(i.exception_reason,'<null>')||':'||i.requires_recount::text)
  INTO v_before FROM public.stock_opname_items i WHERE i.session_id=v_session AND i.product_id=v_product;
  v_result := public.apply_stock_operation_intent('d0000000-0000-4000-8000-000000000001');
  v_replay := public.apply_stock_operation_intent('d0000000-0000-4000-8000-000000000001');
  IF v_result->>'reason' IS DISTINCT FROM 'EXPECTED_REVISION_REQUIRED' OR v_replay IS DISTINCT FROM v_result THEN RAISE EXCEPTION 'Legacy pending REBASE_ITEM did not fail closed/replay'; END IF;
  PERFORM set_config('request.jwt.claim.sub',v_admin::text,true);
  v_result := public.apply_stock_operation_intent('d0000000-0000-4000-8000-000000000002');
  v_replay := public.apply_stock_operation_intent('d0000000-0000-4000-8000-000000000002');
  IF v_result->>'reason' IS DISTINCT FROM 'EXPECTED_REVISION_REQUIRED' OR v_replay IS DISTINCT FROM v_result THEN RAISE EXCEPTION 'Legacy pending REVIEW_EXCEPTION did not fail closed/replay'; END IF;
  SELECT md5(i.revision_no::text||':'||coalesce(i.physical_quantity::text,'<null>')||':'||coalesce(i.exception_reason,'<null>')||':'||i.requires_recount::text)
  INTO v_after FROM public.stock_opname_items i WHERE i.session_id=v_session AND i.product_id=v_product;
  IF v_after IS DISTINCT FROM v_before OR EXISTS (SELECT 1 FROM public.stock_opname_count_events WHERE request_id IN ('d0000000-0000-4000-8000-000000000001','d0000000-0000-4000-8000-000000000002')) THEN
    RAISE EXCEPTION 'Legacy pending intents changed an item or appended count events';
  END IF;
  RAISE NOTICE 'PASS: legacy pending requests without expected_revision fail closed without item mutation';
END;
$legacy$;

ROLLBACK;
\echo 'PASS: revision guard matrix completed; outer transaction rolled back.'
