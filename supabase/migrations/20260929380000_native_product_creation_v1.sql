-- Native product master creation with an audited zero-stock baseline.
BEGIN;

CREATE SEQUENCE public.native_product_sku_seq AS bigint START WITH 1 INCREMENT BY 1 NO CYCLE;
REVOKE ALL ON SEQUENCE public.native_product_sku_seq FROM PUBLIC,anon,authenticated,service_role;

CREATE TABLE public.native_product_creation_requests (
  request_id uuid PRIMARY KEY,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL UNIQUE REFERENCES public.products(id) ON DELETE RESTRICT,
  source_system text NOT NULL DEFAULT 'QUENA_NATIVE' CHECK (source_system='QUENA_NATIVE'),
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{32}$'),
  resolved_sku text NOT NULL,
  barcode text,
  result jsonb NOT NULL CHECK (jsonb_typeof(result)='object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT native_product_creation_request_product_outlet_unique UNIQUE(request_id,outlet_id,product_id)
);
CREATE INDEX native_product_creation_requests_outlet_time_idx
  ON public.native_product_creation_requests(outlet_id,created_at DESC);
-- Native products have a separate audited zero baseline. They are never
-- represented by synthetic iPos rows and do not establish costing.
CREATE TABLE public.stock_native_zero_baselines (
  request_id uuid NOT NULL,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  authority_period_id uuid NOT NULL,
  source_system text NOT NULL DEFAULT 'QUENA_NATIVE' CHECK (source_system='QUENA_NATIVE'),
  accepted_baseline_quantity numeric NOT NULL DEFAULT 0 CHECK (accepted_baseline_quantity=0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT stock_native_zero_baseline_request_fk
    FOREIGN KEY(request_id,outlet_id,product_id)
    REFERENCES public.native_product_creation_requests(request_id,outlet_id,product_id) ON DELETE RESTRICT,
  CONSTRAINT stock_native_zero_baseline_period_fk
    FOREIGN KEY(authority_period_id,outlet_id)
    REFERENCES public.stock_authority_periods(id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT stock_native_zero_baseline_product_unique UNIQUE(outlet_id,product_id),
  CONSTRAINT stock_native_zero_baseline_identity UNIQUE(request_id,outlet_id,product_id)
);
CREATE INDEX stock_native_zero_baselines_outlet_created_idx
  ON public.stock_native_zero_baselines(outlet_id,created_at DESC);
ALTER TABLE public.stock_native_zero_baselines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.stock_native_zero_baselines FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.stock_native_zero_baselines TO authenticated;
CREATE POLICY stock_native_zero_baselines_manager_read ON public.stock_native_zero_baselines
  FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));

CREATE FUNCTION public.reject_stock_native_zero_baseline_mutation()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Native zero baseline evidence is immutable';
END;
$$;
ALTER FUNCTION public.reject_stock_native_zero_baseline_mutation() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reject_stock_native_zero_baseline_mutation() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER stock_native_zero_baselines_immutable
  BEFORE UPDATE OR DELETE ON public.stock_native_zero_baselines
  FOR EACH ROW EXECUTE FUNCTION public.reject_stock_native_zero_baseline_mutation();

ALTER TABLE public.stock_balance_projection ADD COLUMN native_zero_baseline_request_id uuid;
ALTER TABLE public.stock_balance_projection
  DROP CONSTRAINT stock_balance_baseline_identity_consistent,
  ADD CONSTRAINT stock_balance_native_baseline_fk
    FOREIGN KEY(native_zero_baseline_request_id,outlet_id,product_id)
    REFERENCES public.stock_native_zero_baselines(request_id,outlet_id,product_id) ON DELETE RESTRICT,
  ADD CONSTRAINT stock_balance_baseline_identity_consistent CHECK (
    (baseline_quantity IS NULL AND baseline_source_import_row_id IS NULL
      AND baseline_batch_id IS NULL AND baseline_commit_id IS NULL
      AND native_zero_baseline_request_id IS NULL)
    OR (baseline_quantity IS NOT NULL AND baseline_source_import_row_id IS NOT NULL
      AND baseline_batch_id IS NOT NULL AND baseline_commit_id IS NOT NULL
      AND native_zero_baseline_request_id IS NULL)
    OR (baseline_quantity=0 AND baseline_source_import_row_id IS NULL
      AND baseline_batch_id IS NULL AND baseline_commit_id IS NULL
      AND native_zero_baseline_request_id IS NOT NULL)
  );
CREATE INDEX stock_balance_projection_native_baseline_idx
  ON public.stock_balance_projection(outlet_id,product_id)
  WHERE native_zero_baseline_request_id IS NOT NULL;

ALTER TABLE public.stock_balance_projection_events
  ADD COLUMN native_zero_baseline_request_id uuid,
  DROP CONSTRAINT stock_balance_projection_events_event_type_check,
  ADD CONSTRAINT stock_balance_projection_events_event_type_check CHECK (event_type IN (
    'MOVEMENT_POSTED','MOVEMENT_RECONCILED','AUTHORITY_BASELINE_ACCEPTED',
    'NATIVE_ZERO_BASELINE_ACCEPTED','NATIVE_BASELINE_PERIOD_ADVANCED')),
  ADD CONSTRAINT stock_balance_projection_event_native_baseline_fk
    FOREIGN KEY(native_zero_baseline_request_id,outlet_id,product_id)
    REFERENCES public.stock_native_zero_baselines(request_id,outlet_id,product_id) ON DELETE RESTRICT,
  DROP CONSTRAINT stock_balance_projection_event_request_shape,
  ADD CONSTRAINT stock_balance_projection_event_request_shape CHECK (
    (event_type='AUTHORITY_BASELINE_ACCEPTED' AND request_id IS NULL
      AND opening_cutover_request_id IS NOT NULL AND native_zero_baseline_request_id IS NULL)
    OR (event_type='NATIVE_ZERO_BASELINE_ACCEPTED' AND request_id IS NULL
      AND opening_cutover_request_id IS NULL AND native_zero_baseline_request_id IS NOT NULL)
    OR (event_type='NATIVE_BASELINE_PERIOD_ADVANCED' AND request_id IS NULL
      AND opening_cutover_request_id IS NOT NULL AND native_zero_baseline_request_id IS NOT NULL)
    OR (event_type NOT IN ('AUTHORITY_BASELINE_ACCEPTED','NATIVE_ZERO_BASELINE_ACCEPTED',
      'NATIVE_BASELINE_PERIOD_ADVANCED') AND opening_cutover_request_id IS NULL
      AND native_zero_baseline_request_id IS NULL)
  );

-- Preserve the deployed iPos refresh function verbatim except for a guarded
-- native-only branch placed ahead of its strict iPos provenance check.
DO $native_refresh$
DECLARE v_definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef('public.refresh_stock_balance_from_ipos_inventory()'::regprocedure)
    INTO v_definition;
  IF position('Stock baseline refresh requires an iPos source row' IN v_definition)=0 THEN
    RAISE EXCEPTION 'Unexpected stock refresh function definition; refusing native branch patch';
  END IF;
  v_definition:=replace(v_definition,
$old$  if new.source_import_row_id is null then
    raise exception 'Stock baseline refresh requires an iPos source row';
  end if;$old$,
$new$  IF EXISTS(SELECT 1 FROM public.native_product_creation_requests r
      WHERE r.product_id=NEW.product_id AND r.outlet_id=NEW.outlet_id) THEN
    IF NEW.source_import_row_id IS NOT NULL OR NEW.quantity IS DISTINCT FROM 0
      OR NOT EXISTS(
        SELECT 1 FROM public.stock_native_zero_baselines b
        JOIN public.stock_authority_periods ap ON ap.id=b.authority_period_id AND ap.outlet_id=b.outlet_id
          AND ap.ended_at IS NULL
        JOIN public.stock_balance_projection p ON p.product_id=b.product_id AND p.outlet_id=b.outlet_id
          AND p.native_zero_baseline_request_id=b.request_id AND p.authority_period_id=ap.id
          AND p.baseline_quantity=0 AND p.unreconciled_movement_delta=0 AND p.effective_quantity=0
        WHERE b.product_id=NEW.product_id AND b.outlet_id=NEW.outlet_id
          AND b.source_system='QUENA_NATIVE' AND b.accepted_baseline_quantity=0
      ) THEN
      RAISE EXCEPTION 'Native product stock baseline is unavailable or inconsistent';
    END IF;
    RETURN NEW;
  END IF;
  if new.source_import_row_id is null then
    raise exception 'Stock baseline refresh requires an iPos source row';
  end if;$new$);
  IF v_definition NOT LIKE '%Native product stock baseline is unavailable or inconsistent%' THEN
    RAISE EXCEPTION 'Could not apply the guarded native stock refresh branch';
  END IF;
  EXECUTE v_definition;
END;
$native_refresh$;

-- 370000 is deployed, so add only a forward compatibility patch. iPos
-- completeness remains strict; native zero baselines advance unchanged.
DO $native_cutover$
DECLARE v_definition text; v_old text; v_new text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.stock_opening_cutover(uuid,uuid,uuid,uuid,text)'::regprocedure)
    INTO v_definition;
  v_old:=$old$OR EXISTS(SELECT 1 FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id
      AND NOT EXISTS(SELECT 1 FROM public.ipos_normalization_commit_rows cr$old$;
  v_new:=$new$OR EXISTS(SELECT 1 FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id
      AND p.native_zero_baseline_request_id IS NULL
      AND NOT EXISTS(SELECT 1 FROM public.ipos_normalization_commit_rows cr$new$;
  IF position(v_old IN v_definition)=0 THEN
    RAISE EXCEPTION 'Unexpected stock cutover projection coverage check; refusing native compatibility patch';
  END IF;
  v_definition:=replace(v_definition,v_old,v_new);
  v_old:=$old$v_count integer:=0;
  v_result jsonb;$old$;
  v_new:=$new$v_count integer:=0;
  v_native_count integer:=0;
  v_result jsonb;$new$;
  IF position(v_old IN v_definition)=0 THEN
    RAISE EXCEPTION 'Unexpected stock cutover declaration; refusing native compatibility patch';
  END IF;
  v_definition:=replace(v_definition,v_old,v_new);
  v_old:=$old$  IF v_count=0 THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STOCK_CUTOVER_SNAPSHOT_EMPTY';
  END IF;$old$;
  v_new:=$new$  FOR v_product IN
    SELECT p.product_id,p.native_zero_baseline_request_id,p.baseline_quantity,
      p.unreconciled_movement_delta,p.effective_quantity,p.balance_version,p.authority_period_id
    FROM public.stock_balance_projection p
    WHERE p.outlet_id=p_outlet_id AND p.native_zero_baseline_request_id IS NOT NULL
    ORDER BY p.product_id
  LOOP
    IF v_product.authority_period_id IS DISTINCT FROM v_previous_period.id
      OR v_product.baseline_quantity IS DISTINCT FROM 0
      OR v_product.unreconciled_movement_delta IS DISTINCT FROM 0
      OR v_product.effective_quantity IS DISTINCT FROM 0
      OR NOT EXISTS(SELECT 1 FROM public.stock_native_zero_baselines b
        WHERE b.request_id=v_product.native_zero_baseline_request_id
          AND b.product_id=v_product.product_id AND b.outlet_id=p_outlet_id
          AND b.source_system='QUENA_NATIVE' AND b.accepted_baseline_quantity=0) THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STOCK_CUTOVER_NATIVE_BASELINE_INVALID';
    END IF;
    UPDATE public.stock_balance_projection p SET authority_period_id=v_new_period,
      balance_version=p.balance_version+1,updated_at=v_now
    WHERE p.product_id=v_product.product_id AND p.outlet_id=p_outlet_id
    RETURNING p.balance_version INTO v_new_version;
    INSERT INTO public.stock_balance_projection_events(product_id,outlet_id,authority_period_id,
      event_type,request_id,quantity_delta,balance_before,balance_after,balance_version,actor_id,
      opening_cutover_request_id,native_zero_baseline_request_id)
    VALUES(v_product.product_id,p_outlet_id,v_new_period,'NATIVE_BASELINE_PERIOD_ADVANCED',NULL,
      0,0,0,v_new_version,v_actor,p_request_id,v_product.native_zero_baseline_request_id);
    v_native_count:=v_native_count+1;
  END LOOP;
  IF v_count=0 THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='STOCK_CUTOVER_SNAPSHOT_EMPTY';
  END IF;$new$;
  IF position(v_old IN v_definition)=0 THEN
    RAISE EXCEPTION 'Unexpected stock cutover completion point; refusing native compatibility patch';
  END IF;
  v_definition:=replace(v_definition,v_old,v_new);
  EXECUTE v_definition;
END;
$native_cutover$;



ALTER TABLE public.native_product_creation_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.native_product_creation_requests FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.native_product_creation_requests TO authenticated;
CREATE POLICY native_product_creation_requests_manager_read
  ON public.native_product_creation_requests FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));

CREATE FUNCTION public.reject_native_product_creation_evidence_mutation()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Native product creation evidence is immutable';
END;
$$;
ALTER FUNCTION public.reject_native_product_creation_evidence_mutation() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reject_native_product_creation_evidence_mutation() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER native_product_creation_evidence_immutable
  BEFORE UPDATE OR DELETE ON public.native_product_creation_requests
  FOR EACH ROW EXECUTE FUNCTION public.reject_native_product_creation_evidence_mutation();

CREATE FUNCTION public.native_product_create(
  p_request_id uuid,
  p_sku text,
  p_name text,
  p_category_label text,
  p_unit_label text,
  p_brand_label text,
  p_rack_label text,
  p_barcode text,
  p_selling_price numeric
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE
  v_actor uuid:=auth.uid();
  v_role public.user_role;
  v_outlet uuid;
  v_open_count integer;
  v_period uuid;
  v_name text:=btrim(coalesce(p_name,''));
  v_category text:=nullif(btrim(coalesce(p_category_label,'')),'');
  v_unit text:=nullif(btrim(coalesce(p_unit_label,'')),'');
  v_brand text:=nullif(btrim(coalesce(p_brand_label,'')),'');
  v_rack text:=nullif(btrim(coalesce(p_rack_label,'')),'');
  v_barcode text:=nullif(btrim(coalesce(p_barcode,'')),'');
  v_sku text:=nullif(btrim(coalesce(p_sku,'')),'');
  v_payload jsonb;
  v_hash text;
  v_existing public.native_product_creation_requests%ROWTYPE;
  v_product uuid;
  v_result jsonb;
  v_constraint text;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='NATIVE_PRODUCT_UNAUTHORIZED';
  END IF;
  IF p_request_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='NATIVE_PRODUCT_INVALID_REQUEST';
  END IF;

  SELECT count(*)::integer,(array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1]
    INTO v_open_count,v_outlet
    FROM public.stock_authority_periods ap
    JOIN public.outlets o ON o.id=ap.outlet_id
   WHERE ap.ended_at IS NULL AND o.is_active;
  IF v_open_count<>1 OR v_outlet IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='NATIVE_PRODUCT_OUTLET_UNAVAILABLE';
  END IF;

  IF v_name='' OR length(v_name)>200 OR v_name ~ '[[:cntrl:]]'
    OR v_category IS NULL OR length(v_category)>120 OR v_category ~ '[[:cntrl:]]'
    OR v_unit IS NULL OR length(v_unit)>40 OR v_unit ~ '[[:cntrl:]]'
    OR (v_brand IS NOT NULL AND (length(v_brand)>120 OR v_brand ~ '[[:cntrl:]]'))
    OR (v_rack IS NOT NULL AND (length(v_rack)>120 OR v_rack ~ '[[:cntrl:]]')) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='NATIVE_PRODUCT_REQUIRED_FIELD_INVALID';
  END IF;
  IF v_sku IS NOT NULL AND (length(v_sku)>100 OR v_sku ~ '[[:cntrl:]]') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='NATIVE_PRODUCT_SKU_INVALID';
  END IF;
  IF v_barcode IS NOT NULL AND (length(v_barcode)>128 OR v_barcode ~ '[[:cntrl:]]') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='NATIVE_PRODUCT_BARCODE_INVALID';
  END IF;
  IF p_selling_price IS NULL OR p_selling_price<=0 OR p_selling_price>=1000000000000
    OR p_selling_price<>trunc(p_selling_price,2) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='NATIVE_PRODUCT_PRICE_INVALID';
  END IF;

  v_payload:=jsonb_build_object(
    'sku',v_sku,'name',v_name,'category_label',v_category,'unit_label',v_unit,
    'brand_label',v_brand,'rack_label',v_rack,'barcode',v_barcode,'selling_price',p_selling_price);
  v_hash:=md5(v_payload::text);
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('NATIVE_PRODUCT_REQUEST:'||p_request_id::text,73190411));
  SELECT * INTO v_existing FROM public.native_product_creation_requests r
   WHERE r.request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.outlet_id IS DISTINCT FROM v_outlet
      OR v_existing.payload_hash IS DISTINCT FROM v_hash THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='NATIVE_PRODUCT_REQUEST_CONFLICT';
    END IF;
    RETURN v_existing.result;
  END IF;

  -- Serialize enrollment with the one-time stock-period cutover. Replay is
  -- intentionally resolved first so a successful retry remains stable.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('COST_BOOTSTRAP_OUTLET:'||v_outlet::text,73190411));
  SELECT ap.id INTO v_period FROM public.stock_authority_periods ap
   WHERE ap.outlet_id=v_outlet AND ap.ended_at IS NULL FOR UPDATE;
  IF v_period IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='NATIVE_PRODUCT_OUTLET_UNAVAILABLE';
  END IF;

  IF v_barcode IS NOT NULL THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('NATIVE_PRODUCT_BARCODE:'||v_barcode,73190411));
    LOCK TABLE public.product_barcodes IN SHARE ROW EXCLUSIVE MODE;
    IF EXISTS(SELECT 1 FROM public.product_barcodes b WHERE b.barcode=v_barcode AND b.is_active) THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='NATIVE_PRODUCT_BARCODE_EXISTS';
    END IF;
  END IF;

  IF v_sku IS NULL THEN
    LOOP
      v_sku:='QN-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'||lpad(nextval('public.native_product_sku_seq')::text,8,'0');
      EXIT WHEN NOT EXISTS(SELECT 1 FROM public.products p WHERE p.sku=v_sku);
    END LOOP;
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('NATIVE_PRODUCT_SKU:'||v_sku,73190411));
  IF EXISTS(SELECT 1 FROM public.products p WHERE p.sku=v_sku) THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='NATIVE_PRODUCT_SKU_EXISTS';
  END IF;

  BEGIN
    INSERT INTO public.products(sku,name,category_label,brand_label,unit_label,created_by,updated_by)
    VALUES(v_sku,v_name,v_category,v_brand,v_unit,v_actor,v_actor)
    RETURNING id INTO v_product;

    INSERT INTO public.product_outlet_settings(product_id,outlet_id,rack_label,created_by,updated_by)
    VALUES(v_product,v_outlet,v_rack,v_actor,v_actor);
    INSERT INTO public.product_selling_prices(product_id,outlet_id,amount,created_by,updated_by)
    VALUES(v_product,v_outlet,p_selling_price,v_actor,v_actor);
    IF v_barcode IS NOT NULL THEN
      INSERT INTO public.product_barcodes(product_id,barcode,source_import_row_id,created_by,updated_by)
      VALUES(v_product,v_barcode,NULL,v_actor,v_actor);
    END IF;

    v_result:=jsonb_build_object('ok',true,'product_id',v_product,'sku',v_sku,'source_system','QUENA_NATIVE');
    INSERT INTO public.native_product_creation_requests(request_id,actor_id,outlet_id,product_id,
      payload_hash,resolved_sku,barcode,result)
    VALUES(p_request_id,v_actor,v_outlet,v_product,v_hash,v_sku,v_barcode,v_result);
    INSERT INTO public.stock_native_zero_baselines(request_id,outlet_id,product_id,actor_id,
      authority_period_id,source_system,accepted_baseline_quantity)
    VALUES(p_request_id,v_outlet,v_product,v_actor,v_period,'QUENA_NATIVE',0);
    INSERT INTO public.stock_balance_projection(product_id,outlet_id,authority_period_id,
      baseline_quantity,native_zero_baseline_request_id,unreconciled_movement_delta,balance_version,
      last_observation_status)
    VALUES(v_product,v_outlet,v_period,0,p_request_id,0,1,'BOOTSTRAPPED');
    INSERT INTO public.stock_balance_projection_events(product_id,outlet_id,authority_period_id,
      event_type,request_id,quantity_delta,balance_before,balance_after,balance_version,actor_id,
      native_zero_baseline_request_id)
    VALUES(v_product,v_outlet,v_period,'NATIVE_ZERO_BASELINE_ACCEPTED',NULL,0,0,0,1,v_actor,p_request_id);
    -- Keep the inventory row used by existing product/POS read contracts,
    -- while the stock projection and native evidence remain authoritative.
    INSERT INTO public.product_inventory(product_id,outlet_id,quantity,minimum_quantity,created_by,updated_by)
    VALUES(v_product,v_outlet,0,NULL,v_actor,v_actor);
  EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_constraint=CONSTRAINT_NAME;
    IF v_constraint='products_sku_key' THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='NATIVE_PRODUCT_SKU_EXISTS';
    ELSE
      RAISE;
    END IF;
  END;
  RETURN v_result;
END;
$$;
ALTER FUNCTION public.native_product_create(uuid,text,text,text,text,text,text,text,numeric) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.native_product_create(uuid,text,text,text,text,text,text,text,numeric)
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.native_product_create(uuid,text,text,text,text,text,text,text,numeric) TO authenticated;

COMMIT;
