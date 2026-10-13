-- Daily iPos sales ingestion. Uploaded workbooks remain staged until an
-- OWNER/ADMIN explicitly commits a fully reconciled and resolvable batch.
BEGIN;

-- Imported sales use a separate costing operation identity. Their internal
-- inventory valuation depletion is deliberately not a SALE_COGS event.
ALTER TABLE public.inventory_cost_operation_requests
  DROP CONSTRAINT inventory_cost_operation_requests_operation_key_check,
  ADD CONSTRAINT inventory_cost_operation_requests_operation_key_check
    CHECK (operation_key IN ('BOOTSTRAP_OUTLET','PURCHASE_RECEIPT','OPNAME_ADJUSTMENT',
      'REVERSAL','STOCK_CORRECTION','SUPPLIER_RETURN','POS_SALE','IPOS_SALES_IMPORT'));

CREATE TABLE public.ipos_sales_import_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  upload_request_id uuid NOT NULL UNIQUE,
  source text NOT NULL DEFAULT 'IPOS_IMPORT' CHECK (source='IPOS_IMPORT'),
  original_filename text NOT NULL CHECK (length(original_filename) BETWEEN 1 AND 240),
  file_sha256 text NOT NULL CHECK (file_sha256 ~ '^[0-9a-f]{64}$'),
  report_from date NOT NULL,
  report_to date NOT NULL CHECK (report_to>=report_from),
  transaction_count integer NOT NULL CHECK (transaction_count BETWEEN 1 AND 10000),
  sale_line_count integer NOT NULL CHECK (sale_line_count BETWEEN 1 AND 100000),
  total_quantity numeric(32,3) NOT NULL CHECK (total_quantity>0),
  total_amount numeric(32,2) NOT NULL CHECK (total_amount>=0),
  footer_totals jsonb NOT NULL CHECK (jsonb_typeof(footer_totals)='object'),
  reconciliation jsonb NOT NULL CHECK (jsonb_typeof(reconciliation)='object'),
  preflight_result jsonb,
  status text NOT NULL DEFAULT 'UPLOADED' CHECK (status IN ('UPLOADED','PREFLIGHT_BLOCKED','READY','COMMITTED','CANCELLED')),
  revision integer NOT NULL DEFAULT 1 CHECK (revision>0),
  uploaded_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  uploaded_at timestamptz NOT NULL DEFAULT now(),
  committed_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  committed_at timestamptz,
  commit_request_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ipos_sales_import_batch_commit_state CHECK (
    (status='COMMITTED' AND committed_by IS NOT NULL AND committed_at IS NOT NULL AND commit_request_id IS NOT NULL)
    OR (status<>'COMMITTED' AND committed_by IS NULL AND committed_at IS NULL AND commit_request_id IS NULL)
  ),
  CONSTRAINT ipos_sales_import_batch_hash_unique UNIQUE(outlet_id,file_sha256),
  CONSTRAINT ipos_sales_import_batch_identity UNIQUE(id,outlet_id)
);
CREATE INDEX ipos_sales_import_batch_outlet_time_idx ON public.ipos_sales_import_batches(outlet_id,uploaded_at DESC,id DESC);

CREATE TABLE public.ipos_sales_import_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.ipos_sales_import_batches(id) ON DELETE RESTRICT,
  source_row_number integer NOT NULL CHECK (source_row_number>0),
  source_transaction_number text NOT NULL CHECK (length(btrim(source_transaction_number)) BETWEEN 1 AND 80),
  source_occurred_at timestamptz NOT NULL,
  raw_transaction_total numeric(32,2) NOT NULL CHECK (raw_transaction_total>=0),
  raw_discount_total numeric(32,2) NOT NULL DEFAULT 0 CHECK (raw_discount_total>=0),
  raw_tax_total numeric(32,2) NOT NULL DEFAULT 0 CHECK (raw_tax_total>=0),
  raw_fee_total numeric(32,2) NOT NULL DEFAULT 0 CHECK (raw_fee_total>=0),
  raw_data jsonb NOT NULL CHECK (jsonb_typeof(raw_data)='object'),
  duplicate boolean NOT NULL DEFAULT false,
  sale_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ipos_sales_import_transaction_id_batch_unique UNIQUE(id,batch_id)
);
CREATE INDEX ipos_sales_import_transaction_time_idx ON public.ipos_sales_import_transactions(batch_id,source_occurred_at,source_transaction_number);

CREATE TABLE public.ipos_sales_import_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL,
  transaction_id uuid NOT NULL,
  source_row_number integer NOT NULL CHECK (source_row_number>0),
  raw_sku text NOT NULL CHECK (length(btrim(raw_sku)) BETWEEN 1 AND 128),
  raw_item_name text NOT NULL CHECK (length(btrim(raw_item_name)) BETWEEN 1 AND 500),
  raw_quantity numeric(32,3) NOT NULL CHECK (raw_quantity>0),
  raw_unit text,
  raw_unit_price numeric(32,2) NOT NULL CHECK (raw_unit_price>=0),
  raw_discount_percent numeric(8,4) NOT NULL CHECK (raw_discount_percent BETWEEN 0 AND 100),
  raw_line_total numeric(32,2) NOT NULL CHECK (raw_line_total>=0),
  raw_data jsonb NOT NULL CHECK (jsonb_typeof(raw_data)='object'),
  resolution text NOT NULL DEFAULT 'PENDING' CHECK (resolution IN ('PENDING','MATCHED','MISSING','INVALID')),
  product_id uuid REFERENCES public.products(id) ON DELETE RESTRICT,
  sale_item_id uuid,
  CONSTRAINT ipos_sales_import_line_transaction_fk FOREIGN KEY(transaction_id,batch_id)
    REFERENCES public.ipos_sales_import_transactions(id,batch_id) ON DELETE RESTRICT,
  CONSTRAINT ipos_sales_import_line_identity UNIQUE(id,batch_id,transaction_id),
  CONSTRAINT ipos_sales_import_line_product_resolution CHECK (
    (resolution='MATCHED' AND product_id IS NOT NULL) OR (resolution<>'MATCHED' AND product_id IS NULL)
  )
);
CREATE INDEX ipos_sales_import_line_sku_idx ON public.ipos_sales_import_lines(batch_id,raw_sku);
CREATE INDEX ipos_sales_import_line_product_idx ON public.ipos_sales_import_lines(batch_id,product_id) WHERE product_id IS NOT NULL;

CREATE TABLE public.ipos_sales_import_commit_requests (
  request_id uuid PRIMARY KEY,
  batch_id uuid NOT NULL REFERENCES public.ipos_sales_import_batches(id) ON DELETE RESTRICT,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  expected_revision integer NOT NULL,
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{32}$'),
  result jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  CONSTRAINT ipos_sales_import_commit_terminal CHECK ((result IS NULL)=(completed_at IS NULL))
);

ALTER TABLE public.sales
  ALTER COLUMN cashier_id DROP NOT NULL,
  ALTER COLUMN completed_by DROP NOT NULL,
  ALTER COLUMN pos_cart_id DROP NOT NULL,
  ALTER COLUMN checkout_request_id DROP NOT NULL,
  DROP CONSTRAINT sales_cashier_completed_by_same,
  DROP CONSTRAINT sales_sale_number_check,
  DROP CONSTRAINT sales_cart_outlet_fk,
  DROP CONSTRAINT sales_checkout_request_fk,
  ADD COLUMN source_import_batch_id uuid,
  ADD COLUMN source_import_transaction_id uuid,
  ADD COLUMN source_transaction_number text,
  ADD COLUMN source_cashier_label text,
  ADD COLUMN imported_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  ADD COLUMN imported_at timestamptz,
  ADD CONSTRAINT sales_number_format_check CHECK (
    (source_system='QUENA_POS' AND sale_number ~ '^QPOS-[0-9]{8}-[0-9]{8,}$')
    OR (source_system='IPOS_IMPORT' AND sale_number ~ '^[0-9]{6}/[^/[:cntrl:]]+/[^/[:cntrl:]]+/[0-9]{4}$')
  ),
  ADD CONSTRAINT sales_source_identity_check CHECK (
    (source_system='QUENA_POS' AND cashier_id IS NOT NULL AND completed_by=cashier_id
      AND pos_cart_id IS NOT NULL AND checkout_request_id IS NOT NULL
      AND source_import_batch_id IS NULL AND source_import_transaction_id IS NULL
      AND source_transaction_number IS NULL AND imported_by IS NULL AND imported_at IS NULL)
    OR (source_system='IPOS_IMPORT' AND cashier_id IS NULL AND completed_by IS NULL
      AND pos_cart_id IS NULL AND checkout_request_id IS NULL
      AND source_import_batch_id IS NOT NULL AND source_import_transaction_id IS NOT NULL
      AND source_transaction_number IS NOT NULL AND imported_by IS NOT NULL AND imported_at IS NOT NULL)
  ),
  ADD CONSTRAINT sales_import_batch_fk FOREIGN KEY(source_import_batch_id,outlet_id)
    REFERENCES public.ipos_sales_import_batches(id,outlet_id) ON DELETE RESTRICT,
  ADD CONSTRAINT sales_import_actor_profile_fk FOREIGN KEY(imported_by)
    REFERENCES public.profiles(id) ON DELETE RESTRICT;
CREATE UNIQUE INDEX sales_ipos_source_transaction_once ON public.sales(outlet_id,source_transaction_number)
  WHERE source_system='IPOS_IMPORT';
CREATE UNIQUE INDEX sales_ipos_import_transaction_once ON public.sales(source_import_transaction_id)
  WHERE source_import_transaction_id IS NOT NULL;
CREATE INDEX sales_ipos_batch_idx ON public.sales(source_import_batch_id,completed_at DESC) WHERE source_system='IPOS_IMPORT';

ALTER TABLE public.ipos_sales_import_transactions
  ADD CONSTRAINT ipos_sales_import_transaction_sale_fk FOREIGN KEY(sale_id)
    REFERENCES public.sales(id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE public.sales
  ADD CONSTRAINT sales_import_transaction_fk FOREIGN KEY(source_import_transaction_id)
    REFERENCES public.ipos_sales_import_transactions(id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  ADD CONSTRAINT sales_pos_checkout_request_fk FOREIGN KEY(checkout_request_id)
    REFERENCES public.pos_checkout_requests(request_id) ON DELETE RESTRICT;
ALTER TABLE public.ipos_sales_import_batches
  ADD CONSTRAINT ipos_sales_import_batch_commit_request_fk FOREIGN KEY(commit_request_id)
    REFERENCES public.ipos_sales_import_commit_requests(request_id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE public.sale_items
  ALTER COLUMN pos_cart_id DROP NOT NULL,
  ALTER COLUMN pos_cart_item_id DROP NOT NULL,
  ALTER COLUMN price_checked_at DROP NOT NULL,
  DROP CONSTRAINT sale_item_sale_cart_fk,
  DROP CONSTRAINT sale_item_cart_line_fk,
  DROP CONSTRAINT sale_item_product_once,
  ADD COLUMN source_line_total numeric(32,2),
  ADD COLUMN source_import_line_id uuid,
  ADD CONSTRAINT sale_item_cart_context_check CHECK ((pos_cart_id IS NULL)=(pos_cart_item_id IS NULL)),
  ADD CONSTRAINT sale_item_import_line_fk FOREIGN KEY(source_import_line_id)
    REFERENCES public.ipos_sales_import_lines(id) ON DELETE RESTRICT,
  ADD CONSTRAINT sale_item_source_line_total_check CHECK (source_line_total IS NULL OR source_line_total>=0),
  ADD CONSTRAINT sale_item_import_context_check CHECK (
    (pos_cart_id IS NOT NULL AND source_import_line_id IS NULL)
    OR (pos_cart_id IS NULL AND source_import_line_id IS NOT NULL)
  );
CREATE UNIQUE INDEX sale_item_product_once_native ON public.sale_items(sale_id,product_id) WHERE pos_cart_id IS NOT NULL;
CREATE UNIQUE INDEX sale_item_source_line_once ON public.sale_items(source_import_line_id) WHERE source_import_line_id IS NOT NULL;
ALTER TABLE public.ipos_sales_import_lines
  ADD CONSTRAINT ipos_sales_import_line_sale_item_fk FOREIGN KEY(sale_item_id)
    REFERENCES public.sale_items(id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE public.stock_movement_batches ADD COLUMN ipos_sales_import_batch_id uuid,
  ADD CONSTRAINT stock_movement_batch_ipos_sales_fk FOREIGN KEY(ipos_sales_import_batch_id,outlet_id)
    REFERENCES public.ipos_sales_import_batches(id,outlet_id) ON DELETE RESTRICT,
  ADD CONSTRAINT stock_movement_batch_ipos_source_check CHECK (
    ipos_sales_import_batch_id IS NULL OR source_system='IPOS_IMPORT');
ALTER TABLE public.stock_movements
  ADD COLUMN source_occurred_at timestamptz,
  ADD COLUMN imported_at timestamptz,
  ADD COLUMN ipos_sales_import_transaction_id uuid,
  ADD COLUMN ipos_sales_import_line_id uuid,
  DROP CONSTRAINT stock_movement_reason_source_valid,
  ADD CONSTRAINT stock_movement_reason_source_valid CHECK (
    (movement_type='OPENING' AND source_system='IPOS_IMPORT' AND source_import_row_id IS NOT NULL)
    OR (movement_type='PURCHASE_RECEIPT' AND source_system='PURCHASING')
    OR (movement_type='SALE' AND source_system='QUENA_POS' AND pos_sale_id IS NOT NULL)
    OR (movement_type='SALE' AND source_system='IPOS_IMPORT' AND ipos_sales_import_transaction_id IS NOT NULL
      AND ipos_sales_import_line_id IS NOT NULL AND source_occurred_at IS NOT NULL AND imported_at IS NOT NULL)
    OR (movement_type='SALE_RETURN' AND source_system='QUENA_POS')
    OR (movement_type='SUPPLIER_RETURN' AND source_system='PURCHASING')
    OR (movement_type IN ('MANUAL_IN','MANUAL_OUT') AND source_system='MANUAL')
    OR (movement_type='OPNAME_ADJUSTMENT' AND source_system='STOCK_OPNAME' AND opname_item_id IS NOT NULL)
    OR (movement_type IN ('TRANSFER_IN','TRANSFER_OUT') AND source_system='TRANSFER')
    OR (movement_type='REVERSAL' AND reverses_movement_id IS NOT NULL)
  ),
  ADD CONSTRAINT stock_movement_ipos_import_context_check CHECK (
    (ipos_sales_import_transaction_id IS NULL AND ipos_sales_import_line_id IS NULL)
    OR (source_system='IPOS_IMPORT' AND movement_type='SALE'
      AND ipos_sales_import_transaction_id IS NOT NULL AND ipos_sales_import_line_id IS NOT NULL)
  ),
  ADD CONSTRAINT stock_movement_ipos_transaction_fk FOREIGN KEY(ipos_sales_import_transaction_id)
    REFERENCES public.ipos_sales_import_transactions(id) ON DELETE RESTRICT,
  ADD CONSTRAINT stock_movement_ipos_line_fk FOREIGN KEY(ipos_sales_import_line_id)
    REFERENCES public.ipos_sales_import_lines(id) ON DELETE RESTRICT;
CREATE UNIQUE INDEX stock_movement_ipos_line_once ON public.stock_movements(ipos_sales_import_line_id)
  WHERE ipos_sales_import_line_id IS NOT NULL;
CREATE INDEX stock_movement_ipos_source_time_idx ON public.stock_movements(outlet_id,source_occurred_at,product_id)
  WHERE ipos_sales_import_transaction_id IS NOT NULL;

CREATE FUNCTION public.inventory_cost_apply_ipos_sale_depletion(
  p_import_line_id uuid,p_stock_movement_id uuid,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE
  v_actor uuid:=auth.uid(); v_role public.user_role; v_line public.ipos_sales_import_lines%rowtype;
  v_tx public.ipos_sales_import_transactions%rowtype; v_sale public.sales%rowtype;
  v_m public.stock_movements%rowtype; v_cost public.inventory_cost_projections%rowtype;
  v_request uuid; v_hash text; v_existing public.inventory_cost_operation_requests%rowtype;
  v_batch uuid; v_event uuid; v_unvalued numeric; v_valued numeric; v_provisional numeric;
  v_value_delta numeric(32,8); v_value_after numeric(32,8); v_wac_after numeric(20,8);
  v_status public.inventory_cost_projection_status; v_plan_u jsonb:='[]'::jsonb; v_plan_v jsonb:='[]'::jsonb;
  v_plan_provisional numeric; v_result jsonb; v_layer record; v_period uuid;
BEGIN
  IF v_actor IS NULL OR p_actor_id IS DISTINCT FROM v_actor THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='IPOS_SALES_IMPORT_UNAUTHORIZED';
  END IF;
  v_role:=public.current_active_user_role();
  IF v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='IPOS_SALES_IMPORT_UNAUTHORIZED';
  END IF;
  SELECT * INTO STRICT v_line FROM public.ipos_sales_import_lines WHERE id=p_import_line_id AND resolution='MATCHED';
  SELECT * INTO STRICT v_tx FROM public.ipos_sales_import_transactions WHERE id=v_line.transaction_id AND batch_id=v_line.batch_id;
  SELECT * INTO STRICT v_sale FROM public.sales WHERE id=v_tx.sale_id AND source_system='IPOS_IMPORT'::public.pos_sale_source
    AND source_import_batch_id=v_line.batch_id AND source_import_transaction_id=v_tx.id;
  SELECT * INTO STRICT v_m FROM public.stock_movements WHERE id=p_stock_movement_id
    AND ipos_sales_import_line_id=v_line.id AND ipos_sales_import_transaction_id=v_tx.id
    AND source_system='IPOS_IMPORT'::public.stock_movement_source AND movement_type='SALE'::public.stock_movement_type;
  IF v_m.product_id IS DISTINCT FROM v_line.product_id OR v_m.quantity_delta IS DISTINCT FROM -v_line.raw_quantity
    OR v_m.source_occurred_at IS DISTINCT FROM v_tx.source_occurred_at OR v_m.imported_at IS DISTINCT FROM v_sale.imported_at THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='IPOS_SALES_IMPORT_COST_CONTEXT_MISMATCH';
  END IF;
  v_request:=md5('IPOS_IMPORT_COST:'||v_line.id::text)::uuid;
  v_hash:=md5(jsonb_build_object('line',v_line.id,'movement',v_m.id,'sale',v_sale.id,'quantity',v_line.raw_quantity)::text);
  SELECT * INTO v_existing FROM public.inventory_cost_operation_requests WHERE request_id=v_request FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id<>v_actor OR v_existing.operation_key<>'IPOS_SALES_IMPORT'
      OR v_existing.target_key<>v_line.id::text OR v_existing.payload_hash<>v_hash THEN
      RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='IPOS_SALES_IMPORT_COST_REQUEST_REUSED';
    END IF;
    IF v_existing.result IS NOT NULL THEN RETURN v_existing.result; END IF;
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='IPOS_SALES_IMPORT_COST_REQUEST_INCOMPLETE';
  END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_cost_event_batches WHERE operation_request_id=v_request) THEN
    RAISE EXCEPTION USING ERRCODE='23505',MESSAGE='IPOS_SALES_IMPORT_COST_REQUEST_ALREADY_APPLIED';
  END IF;
  SELECT * INTO STRICT v_cost FROM public.inventory_cost_projections
    WHERE outlet_id=v_m.outlet_id AND product_id=v_m.product_id FOR UPDATE;
  IF v_cost.physical_quantity IS DISTINCT FROM v_m.balance_before
    OR v_cost.stock_authority_period_id IS DISTINCT FROM v_m.authority_period_id THEN
    RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='IPOS_SALES_IMPORT_COST_PROJECTION_STALE';
  END IF;
  v_period:=v_m.authority_period_id;
  IF v_line.raw_quantity>v_cost.unvalued_quantity+v_cost.valued_quantity THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='IPOS_SALES_IMPORT_COST_LAYER_QUANTITY_INSUFFICIENT';
  END IF;
  v_unvalued:=least(v_line.raw_quantity,v_cost.unvalued_quantity);
  v_valued:=v_line.raw_quantity-v_unvalued;
  IF v_unvalued>0 THEN
    v_plan_u:=public.inventory_cost_build_layer_outflow_plan(v_m.outlet_id,v_m.product_id,v_unvalued,'UNVALUED');
  END IF;
  IF v_valued>0 THEN
    v_plan_v:=public.inventory_cost_build_layer_outflow_plan(v_m.outlet_id,v_m.product_id,v_valued,'VALUED');
    SELECT coalesce(sum((x->>'provisional')::numeric),0) INTO v_plan_provisional FROM jsonb_array_elements(v_plan_v) x;
    IF v_plan_provisional>v_cost.provisional_quantity THEN
      RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='IPOS_SALES_IMPORT_COST_PROVISIONAL_QUANTITY_MISMATCH';
    END IF;
  ELSE
    v_plan_provisional:=0;
  END IF;
  v_value_delta:=CASE WHEN v_valued=0 THEN CASE WHEN v_cost.valued_quantity>0 THEN 0 ELSE NULL END
    WHEN v_valued=v_cost.valued_quantity THEN -coalesce(v_cost.inventory_value,0)
    ELSE -round(v_valued*v_cost.current_wac,8) END;
  v_value_after:=CASE WHEN v_cost.valued_quantity-v_valued=0
    THEN CASE WHEN v_m.balance_after=0 THEN 0 ELSE NULL END
    ELSE coalesce(v_cost.inventory_value,0)+coalesce(v_value_delta,0) END;
  IF v_value_after IS NOT NULL AND v_value_after<0 THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='IPOS_SALES_IMPORT_NEGATIVE_INVENTORY_VALUE';
  END IF;
  v_wac_after:=CASE WHEN v_cost.valued_quantity-v_valued>0
    THEN round(v_value_after/(v_cost.valued_quantity-v_valued),8)::numeric(20,8) ELSE NULL END;
  v_status:=CASE WHEN v_m.balance_after=0 THEN 'VALUED'::public.inventory_cost_projection_status
    WHEN v_cost.valued_quantity-v_valued=0 THEN 'UNVALUED'::public.inventory_cost_projection_status
    WHEN v_cost.unvalued_quantity-v_unvalued>0 THEN 'PARTIALLY_UNVALUED'::public.inventory_cost_projection_status
    WHEN v_cost.provisional_quantity-v_plan_provisional>0 THEN 'PROVISIONAL'::public.inventory_cost_projection_status
    ELSE 'VALUED'::public.inventory_cost_projection_status END;

  INSERT INTO public.inventory_cost_operation_requests(request_id,actor_id,operation_key,target_key,payload_hash)
    VALUES(v_request,v_actor,'IPOS_SALES_IMPORT',v_line.id::text,v_hash);
  INSERT INTO public.inventory_cost_event_batches(outlet_id,batch_type,source_entity_type,source_entity_id,
    operation_request_id,allocation_method,created_by)
    VALUES(v_m.outlet_id,'CORRECTION'::public.inventory_cost_event_type,'IPOS_IMPORT_INVENTORY_DEPLETION',v_line.id,
      v_request,'UNVALUED_FIRST_THEN_PROPORTIONAL_SOURCE_QUANTITY',v_actor) RETURNING id INTO v_batch;
  v_event:=gen_random_uuid();
  INSERT INTO public.inventory_cost_events(id,batch_id,outlet_id,product_id,event_type,source_entity_type,
    source_entity_id,source_event_id,quantity_delta,valued_quantity_before,valued_quantity_delta,valued_quantity_after,
    inventory_value_delta,inventory_value_before,inventory_value_after,wac_before,wac_after,valuation_status_before,
    valuation_status_after,cost_version_before,cost_version_after,stock_balance_version,stock_authority_period_id,
    actor_id,operation_request_id,physical_quantity_delta,physical_quantity_before,physical_quantity_after,
    provisional_quantity_delta,provisional_quantity_before,provisional_quantity_after,unvalued_quantity_delta,
    unvalued_quantity_before,unvalued_quantity_after,source_stock_movement_id,valuation_basis,frozen_unit_cost,
    basis_cost_event_id,metadata)
  VALUES(v_event,v_batch,v_m.outlet_id,v_m.product_id,'CORRECTION'::public.inventory_cost_event_type,
    'IPOS_IMPORT_INVENTORY_DEPLETION',v_line.id,v_m.id,-v_line.raw_quantity,v_cost.valued_quantity,-v_valued,
    v_cost.valued_quantity-v_valued,v_value_delta,v_cost.inventory_value,v_value_after,v_cost.current_wac,v_wac_after,
    v_cost.valuation_status,v_status,v_cost.cost_version,v_cost.cost_version+1,
    (SELECT balance_version FROM public.stock_balance_projection WHERE outlet_id=v_m.outlet_id AND product_id=v_m.product_id),
    v_period,v_actor,v_request,-v_line.raw_quantity,v_m.balance_before,v_m.balance_after,-v_plan_provisional,
    v_cost.provisional_quantity,v_cost.provisional_quantity-v_plan_provisional,-v_unvalued,v_cost.unvalued_quantity,
    v_cost.unvalued_quantity-v_unvalued,v_m.id,
    CASE WHEN v_valued>0 THEN 'CURRENT_WAC'::public.inventory_cost_acquisition_basis ELSE 'UNVALUED'::public.inventory_cost_acquisition_basis END,
    CASE WHEN v_valued>0 THEN v_cost.current_wac END,CASE WHEN v_valued>0 THEN v_cost.last_cost_event_id END,
    jsonb_build_object('source','IPOS_IMPORT','importBatchId',v_line.batch_id,'sourceTransactionId',v_tx.id,
      'sourceTransactionNumber',v_tx.source_transaction_number,'importLineId',v_line.id,'productId',v_line.product_id,
      'sourceOccurredAt',v_tx.source_occurred_at,'importedAt',v_sale.imported_at,
      'inventoryValuationOnly',true,'historicalSaleCogsResolved',false,
      'allocationMethod','UNVALUED_FIRST_THEN_PROPORTIONAL_SOURCE_QUANTITY'))
  RETURNING id INTO v_event;
  IF v_plan_u<>'[]'::jsonb THEN
    PERFORM * FROM public.inventory_cost_apply_layer_plan(v_event,v_m.id,v_request,v_actor,v_cost.cost_version+1,'OUTFLOW_UNVALUED',v_plan_u);
  END IF;
  IF v_plan_v<>'[]'::jsonb THEN
    PERFORM * FROM public.inventory_cost_apply_layer_plan(v_event,v_m.id,v_request,v_actor,v_cost.cost_version+1,'OUTFLOW_VALUED',v_plan_v);
  END IF;
  PERFORM public.inventory_cost_assert_event_layer_allocation(v_event);
  FOR v_layer IN SELECT DISTINCT source_layer_id FROM public.inventory_cost_layer_allocations WHERE cost_event_id=v_event LOOP
    PERFORM public.inventory_cost_assert_layer_balance_ledger(v_layer.source_layer_id);
  END LOOP;
  UPDATE public.inventory_cost_projections SET physical_quantity=v_m.balance_after,
    valued_quantity=v_cost.valued_quantity-v_valued,provisional_quantity=v_cost.provisional_quantity-v_plan_provisional,
    unvalued_quantity=v_cost.unvalued_quantity-v_unvalued,inventory_value=v_value_after,current_wac=v_wac_after,
    valuation_status=v_status,cost_version=v_cost.cost_version+1,
    stock_balance_version=(SELECT balance_version FROM public.stock_balance_projection WHERE outlet_id=v_m.outlet_id AND product_id=v_m.product_id),
    stock_authority_period_id=v_period,last_cost_event_id=v_event,updated_at=now()
    WHERE outlet_id=v_m.outlet_id AND product_id=v_m.product_id;
  v_result:=jsonb_build_object('ok',true,'eventId',v_event,'eventType','INVENTORY_VALUATION_DEPLETION',
    'quantity',v_line.raw_quantity,'inventoryValueDelta',v_value_delta,'valuedQuantityDelta',-v_valued,
    'unvaluedQuantityDelta',-v_unvalued,'saleCogsResolved',false);
  UPDATE public.inventory_cost_operation_requests SET result=v_result,completed_at=now() WHERE request_id=v_request;
  RETURN v_result;
END; $$;
ALTER FUNCTION public.inventory_cost_apply_ipos_sale_depletion(uuid,uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_apply_ipos_sale_depletion(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;

ALTER TABLE public.ipos_sales_import_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ipos_sales_import_batches FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ipos_sales_import_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ipos_sales_import_transactions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ipos_sales_import_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ipos_sales_import_lines FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ipos_sales_import_commit_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ipos_sales_import_commit_requests FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.ipos_sales_import_batches,public.ipos_sales_import_transactions,
  public.ipos_sales_import_lines,public.ipos_sales_import_commit_requests FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.ipos_sales_import_upload(p_actor_id uuid,p_upload_request_id uuid,p_original_filename text,
  p_file_sha256 text,p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=p_actor_id; v_role public.user_role; v_outlet uuid; v_outlet_count integer;
  v_batch uuid; v_tx jsonb; v_line jsonb; v_tx_id uuid; v_summary jsonb; v_recon jsonb; v_footer jsonb;
BEGIN
  SELECT p.role INTO v_role FROM public.profiles p WHERE p.id=v_actor AND p.is_active;
  IF v_actor IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role)
    THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='IPOS_SALES_IMPORT_UNAUTHORIZED'; END IF;
  IF p_upload_request_id IS NULL OR p_original_filename IS NULL OR length(p_original_filename)>240
    OR p_original_filename ~ '[[:cntrl:]]' OR p_file_sha256 !~ '^[0-9a-f]{64}$'
    OR jsonb_typeof(p_payload)<>'object' OR jsonb_typeof(p_payload->'transactions')<>'array'
    THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='IPOS_SALES_IMPORT_UPLOAD_INVALID'; END IF;
  SELECT count(*)::integer,(array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1] INTO v_outlet_count,v_outlet
  FROM public.stock_authority_periods ap JOIN public.outlets o ON o.id=ap.outlet_id
  WHERE ap.ended_at IS NULL AND o.is_active;
  IF v_outlet_count<>1 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='IPOS_SALES_IMPORT_OUTLET_UNAVAILABLE'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('IPOS_SALES_IMPORT:'||v_outlet::text,0));
  SELECT b.id INTO v_batch FROM public.ipos_sales_import_batches b
    WHERE b.outlet_id=v_outlet AND b.file_sha256=p_file_sha256;
  IF FOUND THEN RETURN jsonb_build_object('ok',false,'code','IPOS_SALES_DUPLICATE_FILE','batchId',v_batch); END IF;
  IF EXISTS(SELECT 1 FROM public.ipos_sales_import_batches WHERE upload_request_id=p_upload_request_id) THEN
    RAISE EXCEPTION USING ERRCODE='23505',MESSAGE='IPOS_SALES_UPLOAD_REQUEST_REUSED'; END IF;
  v_summary:=p_payload->'summary';v_recon:=p_payload->'reconciliation';v_footer:=p_payload->'footer';
  IF (p_payload->>'reportFrom')::date IS NULL OR (p_payload->>'reportTo')::date IS NULL
    OR coalesce((v_summary->>'transactionCount')::integer,0) NOT BETWEEN 1 AND 10000
    OR coalesce((v_summary->>'saleLineCount')::integer,0) NOT BETWEEN 1 AND 100000
    OR jsonb_array_length(p_payload->'transactions')<>(v_summary->>'transactionCount')::integer
    THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='IPOS_SALES_IMPORT_PAYLOAD_INVALID'; END IF;
  INSERT INTO public.ipos_sales_import_batches(id,outlet_id,upload_request_id,original_filename,file_sha256,
    report_from,report_to,transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,reconciliation,uploaded_by)
  VALUES(gen_random_uuid(),v_outlet,p_upload_request_id,p_original_filename,p_file_sha256,
    (p_payload->>'reportFrom')::date,(p_payload->>'reportTo')::date,
    (v_summary->>'transactionCount')::integer,(v_summary->>'saleLineCount')::integer,
    (v_summary->>'totalQuantity')::numeric,(v_summary->>'totalAmount')::numeric,v_footer,v_recon,v_actor)
  RETURNING id INTO v_batch;
  FOR v_tx IN SELECT value FROM jsonb_array_elements(p_payload->'transactions') LOOP
    INSERT INTO public.ipos_sales_import_transactions(batch_id,source_row_number,source_transaction_number,
      source_occurred_at,raw_transaction_total,raw_discount_total,raw_tax_total,raw_fee_total,raw_data)
    VALUES(v_batch,(v_tx->>'sourceRowNumber')::integer,v_tx->>'sourceTransactionNumber',
      (v_tx->>'sourceOccurredAt')::timestamptz,(v_tx->>'sourceTransactionTotal')::numeric,
      (v_tx->>'sourceDiscountTotal')::numeric,(v_tx->>'sourceTaxTotal')::numeric,(v_tx->>'sourceFeeTotal')::numeric,v_tx)
    RETURNING id INTO v_tx_id;
    FOR v_line IN SELECT value FROM jsonb_array_elements(v_tx->'lines') LOOP
      INSERT INTO public.ipos_sales_import_lines(batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,
        raw_quantity,raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data)
      VALUES(v_batch,v_tx_id,(v_line->>'sourceRowNumber')::integer,v_line->>'rawSku',v_line->>'rawItemName',
        (v_line->>'rawQuantity')::numeric,v_line->>'rawUnit',(v_line->>'rawUnitPrice')::numeric,
        (v_line->>'rawDiscountPercent')::numeric,(v_line->>'rawLineTotal')::numeric,v_line);
    END LOOP;
  END LOOP;
  RETURN jsonb_build_object('ok',true,'batchId',v_batch,'status','UPLOADED','transactionCount',(v_summary->>'transactionCount')::integer);
END; $$;
ALTER FUNCTION public.ipos_sales_import_upload(uuid,uuid,text,text,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.ipos_sales_import_upload(uuid,uuid,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ipos_sales_import_upload(uuid,uuid,text,text,jsonb) TO service_role;

CREATE FUNCTION public.ipos_sales_import_recheck(p_batch_id uuid,p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid();v_role public.user_role;v_batch public.ipos_sales_import_batches%rowtype;
  v_outlet_count integer;v_outlet uuid;v_missing integer;v_ambiguous integer;v_duplicates integer;
  v_negative integer;v_posted_conflicts integer;v_recon_ok boolean;v_status text;v_result jsonb;
  v_cost_status public.inventory_cost_authority_status;v_stock_mode public.stock_authority_mode;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role)
    THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='IPOS_SALES_IMPORT_UNAUTHORIZED'; END IF;
  SELECT count(*)::integer,(array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1] INTO v_outlet_count,v_outlet
    FROM public.stock_authority_periods ap JOIN public.outlets o ON o.id=ap.outlet_id WHERE ap.ended_at IS NULL AND o.is_active;
  IF v_outlet_count<>1 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='IPOS_SALES_IMPORT_OUTLET_UNAVAILABLE'; END IF;
  SELECT a.status INTO v_cost_status FROM public.inventory_costing_outlet_authority a WHERE a.outlet_id=v_outlet;
  SELECT ap.mode INTO v_stock_mode FROM public.stock_authority_periods ap WHERE ap.outlet_id=v_outlet AND ap.ended_at IS NULL;
  PERFORM pg_advisory_xact_lock(hashtextextended('IPOS_SALES_IMPORT:'||v_outlet::text,0));
  SELECT * INTO v_batch FROM public.ipos_sales_import_batches WHERE id=p_batch_id AND outlet_id=v_outlet FOR UPDATE;
  IF NOT FOUND OR v_batch.status='COMMITTED' OR v_batch.status='CANCELLED' THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='IPOS_SALES_IMPORT_BATCH_NOT_RECHECKABLE'; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='IPOS_SALES_IMPORT_REQUEST_INVALID'; END IF;
  WITH resolved AS (
    SELECT l.id,count(p.id)::integer AS product_count,(array_agg(p.id ORDER BY p.id))[1] AS product_id
    FROM public.ipos_sales_import_lines l LEFT JOIN public.products p ON p.sku=l.raw_sku
    WHERE l.batch_id=p_batch_id GROUP BY l.id
  )
  UPDATE public.ipos_sales_import_lines l SET
    product_id=CASE WHEN r.product_count=1 THEN r.product_id ELSE NULL END,
    resolution=CASE WHEN r.product_count=1 THEN 'MATCHED' WHEN r.product_count=0 THEN 'MISSING' ELSE 'INVALID' END
  FROM resolved r WHERE l.id=r.id;
  UPDATE public.ipos_sales_import_transactions t SET duplicate=(
    EXISTS(SELECT 1 FROM public.sales s WHERE s.outlet_id=v_outlet AND s.source_system='IPOS_IMPORT'::public.pos_sale_source
      AND s.source_transaction_number=t.source_transaction_number)
    OR (SELECT count(*) FROM public.ipos_sales_import_transactions same_batch
      WHERE same_batch.batch_id=p_batch_id
        AND same_batch.source_transaction_number=t.source_transaction_number)>1)
  WHERE t.batch_id=p_batch_id;
  SELECT count(DISTINCT raw_sku) FILTER (WHERE resolution='MISSING'),
    count(DISTINCT raw_sku) FILTER (WHERE resolution='INVALID'),
    (SELECT count(DISTINCT t.source_transaction_number) FROM public.ipos_sales_import_transactions t
      WHERE t.batch_id=p_batch_id AND t.duplicate),
    coalesce((v_batch.reconciliation->>'isReconciled')::boolean,false)
  INTO v_missing,v_ambiguous,v_duplicates,v_recon_ok FROM public.ipos_sales_import_lines WHERE batch_id=p_batch_id;
  SELECT count(DISTINCT l.product_id) INTO v_negative
  FROM (SELECT product_id,sum(raw_quantity) q FROM public.ipos_sales_import_lines
    WHERE batch_id=p_batch_id AND product_id IS NOT NULL GROUP BY product_id) l
  LEFT JOIN public.stock_balance_projection p ON p.product_id=l.product_id AND p.outlet_id=v_outlet
  WHERE p.product_id IS NULL OR p.effective_quantity IS NULL OR p.effective_quantity<l.q;
  SELECT count(*) INTO v_posted_conflicts
  FROM public.ipos_sales_import_lines l JOIN public.ipos_sales_import_transactions t ON t.id=l.transaction_id
  JOIN public.stock_opname_items i ON i.product_id=l.product_id AND i.outlet_id=v_outlet
  JOIN public.stock_opname_sessions s ON s.id=i.session_id
  WHERE l.batch_id=p_batch_id AND s.status='POSTED'::public.stock_opname_status
    -- last_counted_at is captured when the latest accepted physical count/recount is recorded.
    -- posted_at is only the later approval boundary and would incorrectly block safe post-count sales.
    AND t.source_occurred_at<=coalesce(i.last_counted_at,s.posted_at);
  v_status:=CASE WHEN v_missing=0 AND v_ambiguous=0 AND v_duplicates=0 AND v_negative=0
    AND v_posted_conflicts=0 AND (
      v_cost_status IS NULL
      OR v_cost_status='REFERENCE_ONLY'::public.inventory_cost_authority_status
      OR (v_cost_status='WAC_ACTIVE'::public.inventory_cost_authority_status
        AND v_stock_mode='QUENA_MOVEMENT_LEDGER'::public.stock_authority_mode))
    THEN CASE WHEN v_recon_ok THEN 'READY' ELSE 'PREFLIGHT_BLOCKED' END ELSE 'PREFLIGHT_BLOCKED' END;
  v_result:=jsonb_build_object('batchId',p_batch_id,'status',v_status,'missingSkuCount',v_missing,
    'ambiguousSkuCount',v_ambiguous,'duplicateTransactionCount',v_duplicates,
    'stockBlockerCount',v_negative,'postedOpnameConflictCount',v_posted_conflicts,
    'costingBlockerCount',CASE WHEN v_cost_status IS NULL
      OR v_cost_status='REFERENCE_ONLY'::public.inventory_cost_authority_status
      OR (v_cost_status='WAC_ACTIVE'::public.inventory_cost_authority_status
        AND v_stock_mode='QUENA_MOVEMENT_LEDGER'::public.stock_authority_mode) THEN 0 ELSE 1 END,
    'reconciliation',v_batch.reconciliation,'ready',v_status='READY');
  UPDATE public.ipos_sales_import_batches SET status=v_status,revision=revision+1,preflight_result=v_result
    WHERE id=p_batch_id;
  RETURN v_result;
END; $$;
ALTER FUNCTION public.ipos_sales_import_recheck(uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.ipos_sales_import_recheck(uuid,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.ipos_sales_import_recheck(uuid,uuid) TO authenticated;

CREATE FUNCTION public.ipos_sales_import_batch_read(p_batch_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid();v_role public.user_role;v_outlet uuid;v_count integer;v_result jsonb;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role)
    THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='IPOS_SALES_IMPORT_UNAUTHORIZED'; END IF;
  SELECT count(*)::integer,(array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1] INTO v_count,v_outlet
    FROM public.stock_authority_periods ap JOIN public.outlets o ON o.id=ap.outlet_id WHERE ap.ended_at IS NULL AND o.is_active;
  IF v_count<>1 THEN RETURN NULL; END IF;
  SELECT jsonb_build_object('batch',to_jsonb(b),'transactions',coalesce((
    SELECT jsonb_agg(jsonb_build_object('id',t.id,'sourceRowNumber',t.source_row_number,
      'sourceTransactionNumber',t.source_transaction_number,'sourceOccurredAt',t.source_occurred_at,
      'total',t.raw_transaction_total,'duplicate',t.duplicate,
      'lines',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',l.id,'sourceRowNumber',l.source_row_number,
        'sku',l.raw_sku,'name',l.raw_item_name,'quantity',l.raw_quantity,'unit',l.raw_unit,
        'unitPrice',l.raw_unit_price,'discount',l.raw_discount_percent,'lineTotal',l.raw_line_total,
        'resolution',l.resolution) ORDER BY l.source_row_number),'[]'::jsonb)
        FROM public.ipos_sales_import_lines l WHERE l.transaction_id=t.id)) ORDER BY t.source_occurred_at,t.source_transaction_number)
    FROM public.ipos_sales_import_transactions t WHERE t.batch_id=b.id),'[]'::jsonb)) INTO v_result
  FROM public.ipos_sales_import_batches b WHERE b.id=p_batch_id AND b.outlet_id=v_outlet;
  RETURN v_result;
END; $$;
ALTER FUNCTION public.ipos_sales_import_batch_read(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.ipos_sales_import_batch_read(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.ipos_sales_import_batch_read(uuid) TO authenticated;

CREATE FUNCTION public.ipos_sales_import_batches_read(p_limit integer DEFAULT 20) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid();v_role public.user_role;v_outlet uuid;v_count integer;v_result jsonb;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role)
    THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='IPOS_SALES_IMPORT_UNAUTHORIZED'; END IF;
  IF p_limit IS NULL OR p_limit<1 OR p_limit>50 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='IPOS_SALES_IMPORT_FILTER_INVALID'; END IF;
  SELECT count(*)::integer,(array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1] INTO v_count,v_outlet
    FROM public.stock_authority_periods ap JOIN public.outlets o ON o.id=ap.outlet_id WHERE ap.ended_at IS NULL AND o.is_active;
  IF v_count<>1 THEN RETURN '[]'::jsonb; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('id',x.id,'reportFrom',x.report_from,'reportTo',x.report_to,
    'filename',x.original_filename,'transactions',x.transaction_count,'lines',x.sale_line_count,
    'amount',x.total_amount::text,'status',x.status,'uploadedAt',x.uploaded_at,
    'committedAt',x.committed_at,'preflight',x.preflight_result)
    ORDER BY x.uploaded_at DESC,x.id DESC),'[]'::jsonb) INTO v_result
  FROM (SELECT * FROM public.ipos_sales_import_batches WHERE outlet_id=v_outlet
    ORDER BY uploaded_at DESC,id DESC LIMIT p_limit) x;
  RETURN v_result;
END; $$;
ALTER FUNCTION public.ipos_sales_import_batches_read(integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.ipos_sales_import_batches_read(integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.ipos_sales_import_batches_read(integer) TO authenticated;

-- Reuse the established sales/receipt evidence for imported sales while keeping
-- missing payments explicit and keeping imported cashier identity distinct.
DO $$
DECLARE v_def text; v_old text; v_new text;
BEGIN
  v_def:=pg_get_functiondef('public.pos_sale_receipt_read(uuid)'::regprocedure);
  v_old:='JOIN public.pos_checkout_requests cr ON cr.request_id=s.checkout_request_id AND cr.outlet_id=s.outlet_id';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Receipt RPC checkout join changed; review source-aware replacement'; END IF;
  v_def:=replace(v_def,v_old,'LEFT JOIN public.pos_checkout_requests cr ON cr.request_id=s.checkout_request_id AND cr.outlet_id=s.outlet_id');
  v_old:='s.source_system=''QUENA_POS''::public.pos_sale_source';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Receipt RPC source predicate changed'; END IF;
  v_def:=replace(v_def,v_old,'s.source_system IN (''QUENA_POS''::public.pos_sale_source,''IPOS_IMPORT''::public.pos_sale_source)');
  v_old:='coalesce(nullif(btrim(cr.result->>''cashier_label''),''''),''Kasir'')';
  v_new:='CASE WHEN s.source_system=''IPOS_IMPORT''::public.pos_sale_source THEN ''Kasir iPos'' ELSE coalesce(nullif(btrim(cr.result->>''cashier_label''),''''),''Kasir'') END';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Receipt RPC cashier projection changed'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  v_old:='''line_subtotal'',si.line_subtotal';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Receipt RPC item total projection changed'; END IF;
  v_def:=replace(v_def,v_old,'''line_subtotal'',coalesce(si.source_line_total,si.line_subtotal)');
  v_old:='(v_role IN (''OWNER''::public.user_role,''ADMIN''::public.user_role) OR s.cashier_id=v_actor)';
  v_new:='(v_role IN (''OWNER''::public.user_role,''ADMIN''::public.user_role) OR s.source_system=''IPOS_IMPORT''::public.pos_sale_source OR s.cashier_id=v_actor)';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Receipt RPC role scope changed'; END IF;
  EXECUTE v_def;

  v_def:=pg_get_functiondef('public.pos_sales_history_read(date,date,text,text,integer)'::regprocedure);
  v_old:='s.source_system=''QUENA_POS''::public.pos_sale_source';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'History RPC source predicate changed'; END IF;
  v_def:=replace(v_def,v_old,'s.source_system IN (''QUENA_POS''::public.pos_sale_source,''IPOS_IMPORT''::public.pos_sale_source)');
  v_old:='JOIN public.pos_checkout_requests cr ON cr.request_id=s.checkout_request_id AND cr.outlet_id=s.outlet_id';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'History RPC checkout join changed'; END IF;
  v_def:=replace(v_def,v_old,'LEFT JOIN public.pos_checkout_requests cr ON cr.request_id=s.checkout_request_id AND cr.outlet_id=s.outlet_id');
  v_old:='coalesce(nullif(btrim(cr.result->>''cashier_label''),''''),nullif(btrim(p.full_name),''''),''Kasir'') AS cashier_label';
  v_new:='CASE WHEN s.source_system=''IPOS_IMPORT''::public.pos_sale_source THEN ''Kasir iPos'' ELSE coalesce(nullif(btrim(cr.result->>''cashier_label''),''''),nullif(btrim(p.full_name),''''),''Kasir'') END AS cashier_label';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'History RPC cashier projection changed'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  v_old:='(v_role<>''KASIR''::public.user_role OR s.cashier_id=v_actor)';
  v_new:='(v_role<>''KASIR''::public.user_role OR s.source_system=''IPOS_IMPORT''::public.pos_sale_source OR s.cashier_id=v_actor)';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'History RPC cashier scope changed'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  v_old:='SELECT s.id,s.sale_number,s.completed_at,s.grand_total,s.cashier_id,';
  v_new:='SELECT s.id,s.sale_number,s.completed_at,s.grand_total,s.cashier_id,s.source_system::text AS source_system,';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'History RPC filtered projection changed'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  v_old:='SELECT id,sale_number,completed_at,cashier_label,item_count,grand_total::text AS grand_total,payment_method';
  v_new:='SELECT id,sale_number,completed_at,cashier_label,item_count,grand_total::text AS grand_total,payment_method,source_system';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'History RPC page projection changed'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  v_old:='''payment_method'',payment_method';
  v_new:='''payment_method'',payment_method,''source_system'',source_system';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'History RPC JSON projection changed'; END IF;
  EXECUTE v_def;

  v_def:=pg_get_functiondef('public.owner_dashboard_read(integer)'::regprocedure);
  v_old:='s.source_system = ''QUENA_POS''::public.pos_sale_source';
  IF (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old)<3 THEN RAISE EXCEPTION 'Dashboard source predicates changed'; END IF;
  v_def:=replace(v_def,v_old,'s.source_system IN (''QUENA_POS''::public.pos_sale_source,''IPOS_IMPORT''::public.pos_sale_source)');
  EXECUTE v_def;

  v_def:=pg_get_functiondef('public.owner_reports_read(date,date,date,date)'::regprocedure);
  v_old:='sum(si.line_subtotal)';
  IF (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old)<2 THEN RAISE EXCEPTION 'Reports top-product expressions changed'; END IF;
  v_def:=replace(v_def,v_old,'sum(coalesce(si.source_line_total,si.line_subtotal))');
  EXECUTE v_def;
END $$;


CREATE FUNCTION public.ipos_sales_import_commit(p_batch_id uuid,p_expected_revision integer,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid();v_role public.user_role;v_batch public.ipos_sales_import_batches%rowtype;
  v_outlet uuid;v_outlet_count integer;v_period public.stock_authority_periods%rowtype;v_cost_status public.inventory_cost_authority_status;
  v_result jsonb;v_existing public.ipos_sales_import_commit_requests%rowtype;v_tx public.ipos_sales_import_transactions%rowtype;
  v_sale uuid;v_item record;v_movement_batch uuid;v_stock_movement uuid;v_line_request uuid;v_before numeric;v_after numeric;v_version bigint;v_imported_at timestamptz:=now();
  v_movement_count integer:=0;v_hash text;v_stale_sessions record;v_stale_item record;v_new_revision integer;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role)
    THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='IPOS_SALES_IMPORT_UNAUTHORIZED'; END IF;
  IF p_request_id IS NULL OR p_expected_revision IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='IPOS_SALES_IMPORT_REQUEST_INVALID'; END IF;
  SELECT count(*)::integer,(array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1] INTO v_outlet_count,v_outlet
    FROM public.stock_authority_periods ap JOIN public.outlets o ON o.id=ap.outlet_id WHERE ap.ended_at IS NULL AND o.is_active;
  IF v_outlet_count<>1 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='IPOS_SALES_IMPORT_OUTLET_UNAVAILABLE'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('COST_BOOTSTRAP_OUTLET:'||v_outlet::text,73190411));
  PERFORM pg_advisory_xact_lock(hashtextextended('IPOS_SALES_IMPORT:'||v_outlet::text,0));
  SELECT * INTO v_batch FROM public.ipos_sales_import_batches WHERE id=p_batch_id AND outlet_id=v_outlet FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='IPOS_SALES_IMPORT_BATCH_NOT_FOUND'; END IF;
  v_hash:=md5(jsonb_build_object('batch',p_batch_id,'revision',p_expected_revision,'actor',v_actor)::text);
  SELECT * INTO v_existing FROM public.ipos_sales_import_commit_requests WHERE request_id=p_request_id;
  IF FOUND THEN
    IF v_existing.actor_id<>v_actor OR v_existing.batch_id<>p_batch_id OR v_existing.expected_revision<>p_expected_revision OR v_existing.payload_hash<>v_hash
      THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='IPOS_SALES_IMPORT_REQUEST_REUSED'; END IF;
    IF v_existing.result IS NOT NULL THEN RETURN v_existing.result; END IF;
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='IPOS_SALES_IMPORT_REQUEST_INCOMPLETE';
  END IF;
  -- An import before the latest physical count is already represented by that
  -- count and cannot be applied through immutable POSTED evidence. Later sales
  -- remain ordinary movements even if import time is after the opname post.
  IF EXISTS(SELECT 1 FROM public.ipos_sales_import_lines l JOIN public.ipos_sales_import_transactions t ON t.id=l.transaction_id
    JOIN public.stock_opname_items i ON i.product_id=l.product_id AND i.outlet_id=v_outlet
    JOIN public.stock_opname_sessions s ON s.id=i.session_id
    WHERE l.batch_id=p_batch_id AND s.status='POSTED'::public.stock_opname_status
      AND t.source_occurred_at<=coalesce(i.last_counted_at,s.posted_at))
    THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='IPOS_SALES_IMPORT_POSTED_OPNAME_CONFLICT'; END IF;
  IF v_batch.status<>'READY' OR v_batch.revision<>p_expected_revision OR coalesce((v_batch.reconciliation->>'isReconciled')::boolean,false)=false
    THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='IPOS_SALES_IMPORT_NOT_READY'; END IF;
  IF EXISTS(SELECT 1 FROM public.ipos_sales_import_lines WHERE batch_id=p_batch_id AND resolution<>'MATCHED')
    THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='IPOS_SALES_IMPORT_SKU_UNRESOLVED'; END IF;
  IF EXISTS(SELECT 1 FROM public.ipos_sales_import_transactions WHERE batch_id=p_batch_id AND duplicate)
    OR EXISTS(SELECT 1 FROM public.sales s JOIN public.ipos_sales_import_transactions t
      ON t.source_transaction_number=s.source_transaction_number
      WHERE t.batch_id=p_batch_id AND s.outlet_id=v_outlet AND s.source_system='IPOS_IMPORT'::public.pos_sale_source)
    THEN RAISE EXCEPTION USING ERRCODE='23505',MESSAGE='IPOS_SALES_DUPLICATE_TRANSACTION'; END IF;
  SELECT * INTO v_period FROM public.stock_authority_periods WHERE outlet_id=v_outlet AND ended_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='IPOS_SALES_IMPORT_STOCK_AUTHORITY_UNAVAILABLE'; END IF;
  SELECT status INTO v_cost_status FROM public.inventory_costing_outlet_authority WHERE outlet_id=v_outlet;
  IF v_cost_status='BOOTSTRAP_READY'::public.inventory_cost_authority_status
    THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='IPOS_SALES_IMPORT_COSTING_BOOTSTRAP_IN_PROGRESS'; END IF;
  IF v_cost_status='WAC_ACTIVE'::public.inventory_cost_authority_status
    AND v_period.mode<>'QUENA_MOVEMENT_LEDGER'::public.stock_authority_mode
    THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='IPOS_SALES_IMPORT_STOCK_AUTHORITY_NOT_READY'; END IF;
  IF v_cost_status IS NULL OR v_cost_status='REFERENCE_ONLY'::public.inventory_cost_authority_status
    THEN IF v_period.mode NOT IN ('IPOS_SNAPSHOT_PLUS_QUENA_MOVEMENTS'::public.stock_authority_mode,
      'QUENA_MOVEMENT_LEDGER'::public.stock_authority_mode) THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='IPOS_SALES_IMPORT_STOCK_AUTHORITY_NOT_READY'; END IF;
  END IF;
  IF EXISTS(SELECT 1 FROM (SELECT product_id,sum(raw_quantity) q FROM public.ipos_sales_import_lines
      WHERE batch_id=p_batch_id GROUP BY product_id) x LEFT JOIN public.stock_balance_projection p
      ON p.product_id=x.product_id AND p.outlet_id=v_outlet
      WHERE p.product_id IS NULL OR p.effective_quantity IS NULL OR p.effective_quantity<x.q)
    THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='IPOS_SALES_STOCK_INSUFFICIENT'; END IF;

  INSERT INTO public.ipos_sales_import_commit_requests(request_id,batch_id,actor_id,expected_revision,payload_hash)
  VALUES(p_request_id,p_batch_id,v_actor,p_expected_revision,v_hash);
  INSERT INTO public.stock_operation_requests(request_id,actor_id,operation_key,target_key,request_payload,payload_hash)
  VALUES(p_request_id,v_actor,'IPOS_SALES_IMPORT',p_batch_id::text,
    jsonb_build_object('batch_id',p_batch_id,'expected_revision',p_expected_revision),v_hash);

  INSERT INTO public.stock_movement_batches(authority_period_id,outlet_id,source_system,operation_request_id,created_by,ipos_sales_import_batch_id)
  VALUES(v_period.id,v_outlet,'IPOS_IMPORT',p_request_id,v_actor,p_batch_id) RETURNING id INTO v_movement_batch;
  FOR v_tx IN SELECT * FROM public.ipos_sales_import_transactions WHERE batch_id=p_batch_id ORDER BY source_occurred_at,source_transaction_number FOR UPDATE LOOP
    v_sale:=gen_random_uuid();
    INSERT INTO public.sales(id,outlet_id,cashier_id,completed_by,pos_cart_id,checkout_request_id,sale_number,source_system,
      status,subtotal,discount_total,grand_total,completed_at,source_import_batch_id,source_import_transaction_id,
      source_transaction_number,source_cashier_label,imported_by,imported_at)
    VALUES(v_sale,v_outlet,NULL,NULL,NULL,NULL,v_tx.source_transaction_number,'IPOS_IMPORT','COMPLETED',
      v_tx.raw_transaction_total,0,v_tx.raw_transaction_total,v_tx.source_occurred_at,p_batch_id,v_tx.id,
      v_tx.source_transaction_number,'Kasir iPos',v_actor,v_imported_at);
    UPDATE public.ipos_sales_import_transactions SET sale_id=v_sale WHERE id=v_tx.id;
    FOR v_item IN SELECT l.*,p.name AS current_name,p.sku AS current_sku,p.unit_label
      FROM public.ipos_sales_import_lines l JOIN public.products p ON p.id=l.product_id
      WHERE l.transaction_id=v_tx.id ORDER BY l.source_row_number FOR UPDATE OF l LOOP
      INSERT INTO public.sale_items(sale_id,pos_cart_id,pos_cart_item_id,outlet_id,product_id,line_number,
        product_name_snapshot,sku_snapshot,unit_snapshot,quantity,unit_selling_price,price_checked_at,
        source_line_total,source_import_line_id)
      VALUES(v_sale,NULL,NULL,v_outlet,v_item.product_id,v_item.source_row_number,v_item.raw_item_name,
        v_item.raw_sku,v_item.raw_unit,v_item.raw_quantity,v_item.raw_unit_price,NULL,
        v_item.raw_line_total,v_item.id) RETURNING id INTO v_item.sale_item_id;
      UPDATE public.ipos_sales_import_lines SET sale_item_id=v_item.sale_item_id WHERE id=v_item.id;
      SELECT d.balance_before,d.balance_after,d.new_balance_version INTO v_before,v_after,v_version
        FROM public.stock_apply_balance_delta(v_item.product_id,v_outlet,-v_item.raw_quantity) d;
      INSERT INTO public.stock_movements(batch_id,authority_period_id,outlet_id,product_id,movement_type,source_system,
        quantity_delta,balance_before,balance_after,source_event_key,source_reference,source_occurred_at,imported_at,
        ipos_sales_import_transaction_id,ipos_sales_import_line_id,created_by)
      VALUES(v_movement_batch,v_period.id,v_outlet,v_item.product_id,'SALE','IPOS_IMPORT',-v_item.raw_quantity,
        v_before,v_after,'IPOS_SALE:'||v_item.id::text,v_tx.source_transaction_number,v_tx.source_occurred_at,
        v_imported_at,v_tx.id,v_item.id,v_actor) RETURNING id INTO v_stock_movement;
      -- A daily batch may contain several sale lines for one product. The
      -- projection-event idempotency key is per product, so each line receives
      -- its own deterministic child request while the batch keeps its parent request.
      v_line_request:=md5('IPOS_SALES_STOCK:'||v_item.id::text)::uuid;
      INSERT INTO public.stock_operation_requests(request_id,actor_id,operation_key,target_key,request_payload,
        payload_hash,state,result,completed_at)
      VALUES(v_line_request,v_actor,'IPOS_SALES_IMPORT',v_item.id::text,
        jsonb_build_object('batch_id',p_batch_id,'line_id',v_item.id,'parent_request_id',p_request_id,
          'movement_id',v_stock_movement),
        md5(jsonb_build_object('batch_id',p_batch_id,'line_id',v_item.id,'movement_id',v_stock_movement)::text),
        'COMPLETED',jsonb_build_object('ok',true,'movementId',v_stock_movement,'sourceLineId',v_item.id),v_imported_at);
      INSERT INTO public.stock_balance_projection_events(product_id,outlet_id,authority_period_id,event_type,request_id,
        quantity_delta,balance_before,balance_after,balance_version,actor_id)
      VALUES(v_item.product_id,v_outlet,v_period.id,'MOVEMENT_POSTED',v_line_request,-v_item.raw_quantity,
        v_before,v_after,v_version,v_actor);
      IF v_cost_status='WAC_ACTIVE'::public.inventory_cost_authority_status THEN
        PERFORM public.inventory_cost_apply_ipos_sale_depletion(v_item.id,v_stock_movement,v_actor);
      END IF;
      v_movement_count:=v_movement_count+1;
    END LOOP;
  END LOOP;

  -- A movement after a count changes the projection version. Make the affected
  -- open/review opname lines explicitly require recount; posted sessions are
  -- immutable and source sales predating them are blocked above.
  FOR v_stale_item IN
    SELECT DISTINCT i.id,i.session_id,i.product_id,i.outlet_id,i.revision_no,p.effective_quantity,p.balance_version
    FROM public.stock_opname_items i JOIN public.stock_opname_sessions s ON s.id=i.session_id
    JOIN public.ipos_sales_import_lines l ON l.product_id=i.product_id AND l.batch_id=p_batch_id
    JOIN public.stock_balance_projection p ON p.product_id=i.product_id AND p.outlet_id=i.outlet_id
    WHERE i.active_scope AND s.status IN ('COUNTING'::public.stock_opname_status,'REVIEW'::public.stock_opname_status)
      AND s.outlet_id=v_outlet AND i.active_scope ORDER BY i.product_id
  LOOP
    v_new_revision:=v_stale_item.revision_no+1;
    UPDATE public.stock_opname_items SET requires_recount=true,revision_no=v_new_revision,updated_at=now()
      WHERE id=v_stale_item.id;
    INSERT INTO public.stock_opname_count_events(item_id,event_type,revision_no,baseline_quantity,
      baseline_balance_version,physical_quantity,actor_id,note)
    SELECT v_stale_item.id,'STALE_BASELINE',v_new_revision,v_stale_item.effective_quantity,
      v_stale_item.balance_version,i.physical_quantity,v_actor,'Penjualan iPos diimpor setelah hitung; hitung ulang diperlukan'
    FROM public.stock_opname_items i WHERE i.id=v_stale_item.id;
    SELECT s.id INTO v_stale_sessions FROM public.stock_opname_sessions s WHERE s.id=v_stale_item.session_id AND s.status='REVIEW';
    IF FOUND THEN
      UPDATE public.stock_opname_sessions SET status='COUNTING',submitted_by=NULL,submitted_at=NULL WHERE id=v_stale_sessions.id;
      INSERT INTO public.stock_opname_session_events(session_id,event_type,previous_status,next_status,actor_id,note)
        VALUES(v_stale_sessions.id,'BASELINE_STALE','REVIEW','COUNTING',v_actor,'Penjualan iPos diimpor setelah hitung; sesi memerlukan review ulang');
    END IF;
  END LOOP;

  v_result:=jsonb_build_object('ok',true,'batchId',p_batch_id,'status','COMMITTED',
    'transactionCount',v_batch.transaction_count,'saleLineCount',v_batch.sale_line_count,
    'movementCount',v_movement_count,'importedAt',v_imported_at);
  UPDATE public.ipos_sales_import_batches SET status='COMMITTED',revision=revision+1,
    committed_by=v_actor,committed_at=v_imported_at,commit_request_id=p_request_id WHERE id=p_batch_id;
  UPDATE public.ipos_sales_import_commit_requests SET result=v_result,completed_at=v_imported_at WHERE request_id=p_request_id;
  UPDATE public.stock_operation_requests SET state='COMPLETED',result=v_result,completed_at=v_imported_at WHERE request_id=p_request_id;
  RETURN v_result;
END; $$;
ALTER FUNCTION public.ipos_sales_import_commit(uuid,integer,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.ipos_sales_import_commit(uuid,integer,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.ipos_sales_import_commit(uuid,integer,uuid) TO authenticated;

COMMIT;
