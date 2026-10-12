BEGIN;

ALTER TABLE public.native_product_creation_requests
  ADD COLUMN reference_hpp numeric,
  ADD CONSTRAINT native_product_creation_reference_hpp_valid CHECK (
    reference_hpp IS NULL OR (reference_hpp >= 0 AND reference_hpp < 1000000000000
      AND reference_hpp = trunc(reference_hpp,2))
  );

-- Replace the v1 contract so every new native product records required
-- product-reference HPP in product_costs and its append-only history.
DROP FUNCTION public.native_product_create(uuid,text,text,text,text,text,text,text,numeric);

CREATE FUNCTION public.native_product_create(
  p_request_id uuid,
  p_sku text,
  p_name text,
  p_category_label text,
  p_unit_label text,
  p_brand_label text,
  p_rack_label text,
  p_barcode text,
  p_reference_hpp numeric,
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
  IF p_reference_hpp IS NULL OR p_reference_hpp<0 OR p_reference_hpp>=1000000000000
    OR p_reference_hpp<>trunc(p_reference_hpp,2) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='NATIVE_PRODUCT_HPP_INVALID';
  END IF;
  IF p_selling_price IS NULL OR p_selling_price<=0 OR p_selling_price>=1000000000000
    OR p_selling_price<>trunc(p_selling_price,2) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='NATIVE_PRODUCT_PRICE_INVALID';
  END IF;

  v_payload:=jsonb_build_object(
    'sku',v_sku,'name',v_name,'category_label',v_category,'unit_label',v_unit,
    'brand_label',v_brand,'rack_label',v_rack,'barcode',v_barcode,
    'reference_hpp',p_reference_hpp,'selling_price',p_selling_price);
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
    INSERT INTO public.product_costs(product_id,outlet_id,hpp,source_import_row_id,created_by,updated_by)
    VALUES(v_product,v_outlet,p_reference_hpp,NULL,v_actor,v_actor);
    IF v_barcode IS NOT NULL THEN
      INSERT INTO public.product_barcodes(product_id,barcode,source_import_row_id,created_by,updated_by)
      VALUES(v_product,v_barcode,NULL,v_actor,v_actor);
    END IF;

    v_result:=jsonb_build_object('ok',true,'product_id',v_product,'sku',v_sku,'source_system','QUENA_NATIVE');
    INSERT INTO public.native_product_creation_requests(request_id,actor_id,outlet_id,product_id,reference_hpp,
      payload_hash,resolved_sku,barcode,result)
    VALUES(p_request_id,v_actor,v_outlet,v_product,p_reference_hpp,v_hash,v_sku,v_barcode,v_result);
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
ALTER FUNCTION public.native_product_create(uuid,text,text,text,text,text,text,text,numeric,numeric) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.native_product_create(uuid,text,text,text,text,text,text,text,numeric,numeric)
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.native_product_create(uuid,text,text,text,text,text,text,text,numeric,numeric) TO authenticated;


COMMIT;
