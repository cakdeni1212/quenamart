-- P1D-A: additive native POS sale/payment/cost evidence schema only.
-- No sale writer, checkout operation, stock movement, COGS writer, or WAC change.
BEGIN;

ALTER TYPE public.pos_cart_status ADD VALUE 'COMPLETED';
ALTER TYPE public.pos_cart_event_type ADD VALUE 'COMPLETED';

CREATE TYPE public.pos_sale_source AS ENUM ('QUENA_POS');
CREATE TYPE public.pos_sale_status AS ENUM ('COMPLETED');
CREATE TYPE public.pos_sale_payment_method AS ENUM ('CASH','QRIS','CARD','E_WALLET');
CREATE TYPE public.pos_checkout_request_state AS ENUM ('PENDING','COMPLETED','STALE','REJECTED');
CREATE TYPE public.pos_sale_item_cogs_status AS ENUM (
  'RESOLVED','PROVISIONAL','PARTIALLY_UNRESOLVED','UNRESOLVED'
);
CREATE TYPE public.pos_sale_cost_allocation_bucket AS ENUM ('VALUED','UNVALUED');

CREATE SEQUENCE public.pos_sale_number_seq AS bigint START WITH 1 INCREMENT BY 1 NO CYCLE;
REVOKE ALL ON SEQUENCE public.pos_sale_number_seq FROM PUBLIC,anon,authenticated,service_role;

CREATE TABLE public.pos_checkout_requests (
  request_id uuid PRIMARY KEY,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  cart_id uuid NOT NULL,
  expected_cart_revision bigint NOT NULL CHECK (expected_cart_revision>0),
  payment_payload_hash text NOT NULL CHECK (payment_payload_hash ~ '^[0-9a-f]{32}$'),
  state public.pos_checkout_request_state NOT NULL DEFAULT 'PENDING',
  sale_id uuid UNIQUE,
  result jsonb CHECK (result IS NULL OR jsonb_typeof(result)='object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  CONSTRAINT pos_checkout_request_cart_fk FOREIGN KEY(cart_id,outlet_id)
    REFERENCES public.pos_carts(id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT pos_checkout_request_identity UNIQUE(request_id,outlet_id,cart_id,actor_id),
  CONSTRAINT pos_checkout_request_terminal CHECK (
    (state='PENDING' AND sale_id IS NULL AND result IS NULL AND completed_at IS NULL)
    OR (state='COMPLETED' AND sale_id IS NOT NULL AND result IS NOT NULL AND completed_at IS NOT NULL)
    OR (state IN ('STALE','REJECTED') AND sale_id IS NULL AND result IS NOT NULL AND completed_at IS NOT NULL)
  )
);
CREATE INDEX pos_checkout_requests_cart_time_idx ON public.pos_checkout_requests(outlet_id,cart_id,created_at DESC);
CREATE INDEX pos_checkout_requests_actor_time_idx ON public.pos_checkout_requests(actor_id,created_at DESC);

CREATE TABLE public.sales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  cashier_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  completed_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  pos_cart_id uuid NOT NULL,
  checkout_request_id uuid NOT NULL UNIQUE,
  sale_number text NOT NULL CHECK (sale_number ~ '^QPOS-[0-9]{8}-[0-9]{8,}$'),
  source_system public.pos_sale_source NOT NULL DEFAULT 'QUENA_POS',
  status public.pos_sale_status NOT NULL DEFAULT 'COMPLETED',
  currency text NOT NULL DEFAULT 'IDR' CHECK (currency='IDR'),
  subtotal numeric(32,2) NOT NULL CHECK (subtotal>=0),
  discount_total numeric(32,2) NOT NULL DEFAULT 0 CHECK (discount_total=0),
  grand_total numeric(32,2) NOT NULL CHECK (grand_total>=0 AND grand_total=subtotal-discount_total),
  completed_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sales_cashier_completed_by_same CHECK (cashier_id=completed_by),
  CONSTRAINT sales_cart_outlet_fk FOREIGN KEY(pos_cart_id,outlet_id)
    REFERENCES public.pos_carts(id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT sales_checkout_request_fk FOREIGN KEY(checkout_request_id,outlet_id,pos_cart_id,cashier_id)
    REFERENCES public.pos_checkout_requests(request_id,outlet_id,cart_id,actor_id) ON DELETE RESTRICT,
  CONSTRAINT sales_id_outlet_unique UNIQUE(id,outlet_id),
  CONSTRAINT sales_id_cart_outlet_unique UNIQUE(id,pos_cart_id,outlet_id),
  CONSTRAINT sales_id_outlet_request_unique UNIQUE(id,outlet_id,checkout_request_id),
  CONSTRAINT sales_number_outlet_unique UNIQUE(outlet_id,sale_number),
  CONSTRAINT sales_native_cart_once UNIQUE(pos_cart_id)
);
CREATE INDEX sales_outlet_completed_idx ON public.sales(outlet_id,completed_at DESC,id DESC);
CREATE INDEX sales_cashier_completed_idx ON public.sales(cashier_id,completed_at DESC,id DESC);

ALTER TABLE public.pos_cart_items
  ADD CONSTRAINT pos_cart_item_id_cart_outlet_product_unique UNIQUE(id,cart_id,outlet_id,product_id);

ALTER TABLE public.pos_checkout_requests
  ADD CONSTRAINT pos_checkout_request_sale_fk FOREIGN KEY(sale_id)
    REFERENCES public.sales(id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE public.product_selling_price_history
  ADD CONSTRAINT selling_price_history_id_product_outlet_unique UNIQUE(id,product_id,outlet_id);

ALTER TABLE public.inventory_cost_events
  ADD CONSTRAINT inventory_cost_event_sale_movement_identity
  UNIQUE(id,source_stock_movement_id,outlet_id,product_id);

CREATE TABLE public.sale_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_id uuid NOT NULL,
  pos_cart_id uuid NOT NULL,
  pos_cart_item_id uuid NOT NULL,
  outlet_id uuid NOT NULL,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  line_number integer NOT NULL CHECK (line_number>0),
  product_name_snapshot text NOT NULL CHECK (btrim(product_name_snapshot)<>''),
  sku_snapshot text NOT NULL CHECK (btrim(sku_snapshot)<>''),
  unit_snapshot text,
  quantity numeric NOT NULL CHECK (quantity>0 AND quantity<100000000000 AND quantity=trunc(quantity,3)),
  unit_selling_price numeric(20,2) NOT NULL CHECK (unit_selling_price>=0 AND unit_selling_price<1000000000000),
  line_subtotal numeric(32,2) GENERATED ALWAYS AS (round(quantity*unit_selling_price,2)) STORED,
  selling_price_history_id uuid,
  price_checked_at timestamptz NOT NULL,
  CONSTRAINT sale_item_sale_outlet_fk FOREIGN KEY(sale_id,outlet_id)
    REFERENCES public.sales(id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT sale_item_sale_cart_fk FOREIGN KEY(sale_id,pos_cart_id,outlet_id)
    REFERENCES public.sales(id,pos_cart_id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT sale_item_cart_line_fk FOREIGN KEY(pos_cart_item_id,pos_cart_id,outlet_id,product_id)
    REFERENCES public.pos_cart_items(id,cart_id,outlet_id,product_id) ON DELETE RESTRICT,
  CONSTRAINT sale_item_price_history_fk FOREIGN KEY(selling_price_history_id,product_id,outlet_id)
    REFERENCES public.product_selling_price_history(id,product_id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT sale_item_line_once UNIQUE(sale_id,line_number),
  CONSTRAINT sale_item_product_once UNIQUE(sale_id,product_id),
  CONSTRAINT sale_item_id_sale_outlet_unique UNIQUE(id,sale_id,outlet_id),
  CONSTRAINT sale_item_identity_unique UNIQUE(id,sale_id,outlet_id,product_id)
);
CREATE INDEX sale_items_outlet_product_idx ON public.sale_items(outlet_id,product_id,sale_id);
CREATE INDEX sale_items_sale_line_idx ON public.sale_items(sale_id,line_number);

CREATE TABLE public.sale_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_id uuid NOT NULL,
  outlet_id uuid NOT NULL,
  method public.pos_sale_payment_method NOT NULL,
  applied_amount numeric(32,2) NOT NULL CHECK (applied_amount>0),
  received_amount numeric(32,2),
  change_amount numeric(32,2),
  reference_text text CHECK (reference_text IS NULL OR (length(reference_text)<=160 AND btrim(reference_text)<>'')),
  status text NOT NULL DEFAULT 'RECORDED' CHECK (status='RECORDED'),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  recorded_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  CONSTRAINT sale_payment_sale_outlet_fk FOREIGN KEY(sale_id,outlet_id)
    REFERENCES public.sales(id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT sale_payment_method_fields CHECK (
    (method='CASH' AND received_amount IS NOT NULL AND change_amount IS NOT NULL
      AND received_amount>=applied_amount AND change_amount=received_amount-applied_amount)
    OR (method<>'CASH' AND received_amount IS NULL AND change_amount IS NULL)
  ),
  CONSTRAINT sale_payment_id_sale_outlet_unique UNIQUE(id,sale_id,outlet_id)
);
CREATE INDEX sale_payments_sale_idx ON public.sale_payments(sale_id);
CREATE INDEX sale_payments_outlet_method_time_idx ON public.sale_payments(outlet_id,method,recorded_at DESC);

CREATE TABLE public.sale_item_cost_evidence (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_item_id uuid NOT NULL,
  sale_id uuid NOT NULL,
  outlet_id uuid NOT NULL,
  product_id uuid NOT NULL,
  checkout_request_id uuid NOT NULL,
  stock_movement_id uuid,
  cost_event_id uuid,
  quantity numeric NOT NULL CHECK (quantity>0 AND quantity<100000000000 AND quantity=trunc(quantity,3)),
  valued_quantity numeric NOT NULL CHECK (valued_quantity>=0 AND valued_quantity=trunc(valued_quantity,3)),
  provisional_quantity numeric NOT NULL CHECK (provisional_quantity>=0 AND provisional_quantity=trunc(provisional_quantity,3)),
  unvalued_quantity numeric NOT NULL CHECK (unvalued_quantity>=0 AND unvalued_quantity=trunc(unvalued_quantity,3)),
  resolved_cogs_amount numeric(32,8),
  provisional_cogs_amount numeric(32,8),
  status public.pos_sale_item_cogs_status NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sale_item_cost_quantities CHECK (
    valued_quantity+unvalued_quantity=quantity AND provisional_quantity<=valued_quantity
  ),
  CONSTRAINT sale_item_cost_event_movement_pair CHECK (
    (cost_event_id IS NULL AND stock_movement_id IS NULL)
    OR (cost_event_id IS NOT NULL AND stock_movement_id IS NOT NULL)
  ),
  CONSTRAINT sale_item_cost_amounts CHECK (
    (resolved_cogs_amount IS NULL OR resolved_cogs_amount>=0)
    AND (provisional_cogs_amount IS NULL OR provisional_cogs_amount>=0)
    AND ((valued_quantity>provisional_quantity)=(resolved_cogs_amount IS NOT NULL))
    AND ((provisional_quantity>0)=(provisional_cogs_amount IS NOT NULL))
  ),
  CONSTRAINT sale_item_cost_status_shape CHECK (
    (status='RESOLVED' AND unvalued_quantity=0 AND provisional_quantity=0 AND valued_quantity>0)
    OR (status='PROVISIONAL' AND unvalued_quantity=0 AND provisional_quantity>0)
    OR (status='PARTIALLY_UNRESOLVED' AND unvalued_quantity>0 AND valued_quantity>0)
    OR (status='UNRESOLVED' AND unvalued_quantity>0 AND valued_quantity=0
      AND resolved_cogs_amount IS NULL AND provisional_cogs_amount IS NULL)
  ),
  CONSTRAINT sale_item_cost_item_fk FOREIGN KEY(sale_item_id,sale_id,outlet_id,product_id)
    REFERENCES public.sale_items(id,sale_id,outlet_id,product_id) ON DELETE RESTRICT,
  CONSTRAINT sale_item_cost_sale_request_fk FOREIGN KEY(sale_id,outlet_id,checkout_request_id)
    REFERENCES public.sales(id,outlet_id,checkout_request_id) ON DELETE RESTRICT,
  CONSTRAINT sale_item_cost_event_movement_fk FOREIGN KEY(cost_event_id,stock_movement_id,outlet_id,product_id)
    REFERENCES public.inventory_cost_events(id,source_stock_movement_id,outlet_id,product_id) ON DELETE RESTRICT,
  CONSTRAINT sale_item_cost_checkout_identity UNIQUE(sale_item_id,sale_id,outlet_id,product_id,cost_event_id,stock_movement_id),
  CONSTRAINT sale_item_cost_once UNIQUE(sale_item_id)
);
CREATE INDEX sale_item_cost_event_idx ON public.sale_item_cost_evidence(outlet_id,cost_event_id);
CREATE INDEX sale_item_cost_checkout_idx ON public.sale_item_cost_evidence(checkout_request_id);

ALTER TABLE public.inventory_cost_layer_allocations
  ADD CONSTRAINT inventory_cost_layer_allocation_sale_link_identity
  UNIQUE(id,cost_event_id,source_layer_id,outlet_id,product_id,stock_movement_id);

CREATE TABLE public.sale_item_cost_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_item_id uuid NOT NULL,
  sale_id uuid NOT NULL,
  outlet_id uuid NOT NULL,
  product_id uuid NOT NULL,
  cost_event_id uuid NOT NULL,
  stock_movement_id uuid NOT NULL,
  source_layer_allocation_id uuid NOT NULL,
  source_layer_id uuid NOT NULL,
  bucket public.pos_sale_cost_allocation_bucket NOT NULL,
  physical_quantity numeric NOT NULL CHECK (physical_quantity>0 AND physical_quantity=trunc(physical_quantity,3)),
  valued_quantity numeric NOT NULL CHECK (valued_quantity>=0 AND valued_quantity=trunc(valued_quantity,3)),
  provisional_quantity numeric NOT NULL CHECK (provisional_quantity>=0 AND provisional_quantity=trunc(provisional_quantity,3)),
  unvalued_quantity numeric NOT NULL CHECK (unvalued_quantity>=0 AND unvalued_quantity=trunc(unvalued_quantity,3)),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sale_item_cost_allocation_shape CHECK (
    physical_quantity=valued_quantity+unvalued_quantity AND provisional_quantity<=valued_quantity
    AND ((bucket='VALUED' AND valued_quantity>0 AND unvalued_quantity=0)
      OR (bucket='UNVALUED' AND unvalued_quantity>0 AND valued_quantity=0 AND provisional_quantity=0))
  ),
  CONSTRAINT sale_item_cost_allocation_evidence_fk FOREIGN KEY(
    sale_item_id,sale_id,outlet_id,product_id,cost_event_id,stock_movement_id
  ) REFERENCES public.sale_item_cost_evidence(
    sale_item_id,sale_id,outlet_id,product_id,cost_event_id,stock_movement_id
  ) ON DELETE RESTRICT,
  CONSTRAINT sale_item_cost_allocation_source_fk FOREIGN KEY(
    source_layer_allocation_id,cost_event_id,source_layer_id,outlet_id,product_id,stock_movement_id
  ) REFERENCES public.inventory_cost_layer_allocations(
    id,cost_event_id,source_layer_id,outlet_id,product_id,stock_movement_id
  ) ON DELETE RESTRICT,
  CONSTRAINT sale_item_cost_allocation_once UNIQUE(sale_item_id,source_layer_allocation_id),
  CONSTRAINT sale_item_cost_allocation_resolution_identity UNIQUE(
    sale_item_id,sale_id,outlet_id,product_id,cost_event_id,stock_movement_id,source_layer_allocation_id,source_layer_id
  )
);
CREATE INDEX sale_item_cost_allocations_layer_idx ON public.sale_item_cost_allocations(source_layer_id,created_at);
CREATE INDEX sale_item_cost_allocations_evidence_idx ON public.sale_item_cost_allocations(sale_item_id);

CREATE FUNCTION public.guard_pos_sale_cost_allocation_link()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE a public.inventory_cost_layer_allocations%ROWTYPE;
BEGIN
  SELECT * INTO a FROM public.inventory_cost_layer_allocations WHERE id=NEW.source_layer_allocation_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='23503',MESSAGE='POS source-layer allocation is unavailable'; END IF;
  IF NEW.bucket='UNVALUED' THEN
    IF a.allocation_kind<>'OUTFLOW_UNVALUED' OR NEW.physical_quantity<>-a.physical_quantity_delta
      OR NEW.unvalued_quantity<>-a.unvalued_quantity_delta OR NEW.valued_quantity<>0 OR NEW.provisional_quantity<>0 THEN
      RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='POS unvalued sale allocation does not match source evidence';
    END IF;
  ELSIF a.allocation_kind<>'OUTFLOW_VALUED' OR NEW.physical_quantity<>-a.physical_quantity_delta
    OR NEW.valued_quantity<>-a.valued_quantity_delta OR NEW.provisional_quantity<>-a.provisional_quantity_delta
    OR NEW.unvalued_quantity<>0 THEN
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='POS valued sale allocation does not match source evidence';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.guard_pos_sale_cost_allocation_link() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_pos_sale_cost_allocation_link() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER sale_item_cost_allocation_source_guard BEFORE INSERT ON public.sale_item_cost_allocations
  FOR EACH ROW EXECUTE FUNCTION public.guard_pos_sale_cost_allocation_link();

-- Future valuation of sold UNVALUED quantity is append-only evidence; it must
-- not reopen the inventory source-layer balance or edit original COGS rows.
CREATE TABLE public.sale_item_cost_resolutions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_item_id uuid NOT NULL,
  sale_id uuid NOT NULL,
  outlet_id uuid NOT NULL,
  product_id uuid NOT NULL,
  cost_event_id uuid NOT NULL,
  stock_movement_id uuid NOT NULL,
  source_layer_allocation_id uuid NOT NULL,
  source_layer_id uuid NOT NULL,
  resolution_cost_event_id uuid NOT NULL,
  resolved_quantity numeric NOT NULL CHECK (resolved_quantity>0 AND resolved_quantity=trunc(resolved_quantity,3)),
  resolved_cogs_amount numeric(32,8) NOT NULL CHECK (resolved_cogs_amount>=0),
  resolution_request_id uuid NOT NULL REFERENCES public.inventory_cost_operation_requests(request_id) ON DELETE RESTRICT,
  recorded_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sale_item_cost_resolution_item_fk FOREIGN KEY(sale_item_id,sale_id,outlet_id,product_id)
    REFERENCES public.sale_items(id,sale_id,outlet_id,product_id) ON DELETE RESTRICT,
  CONSTRAINT sale_item_cost_resolution_source_fk FOREIGN KEY(
    sale_item_id,sale_id,outlet_id,product_id,cost_event_id,stock_movement_id,source_layer_allocation_id,source_layer_id
  ) REFERENCES public.sale_item_cost_allocations(
    sale_item_id,sale_id,outlet_id,product_id,cost_event_id,stock_movement_id,source_layer_allocation_id,source_layer_id
  ) ON DELETE RESTRICT,
  CONSTRAINT sale_item_cost_resolution_event_fk FOREIGN KEY(resolution_cost_event_id,outlet_id,product_id)
    REFERENCES public.inventory_cost_events(id,outlet_id,product_id) ON DELETE RESTRICT,
  CONSTRAINT sale_item_cost_resolution_once UNIQUE(source_layer_allocation_id,resolution_cost_event_id)
);
CREATE INDEX sale_item_cost_resolutions_item_idx ON public.sale_item_cost_resolutions(sale_item_id,recorded_at,id);
CREATE INDEX sale_item_cost_resolutions_request_idx ON public.sale_item_cost_resolutions(resolution_request_id);

CREATE FUNCTION public.guard_pos_sale_cost_resolution_link()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE a public.sale_item_cost_allocations%ROWTYPE; already_resolved numeric;
BEGIN
  SELECT * INTO a FROM public.sale_item_cost_allocations
   WHERE sale_item_id=NEW.sale_item_id AND source_layer_allocation_id=NEW.source_layer_allocation_id
   FOR UPDATE;
  IF NOT FOUND OR a.bucket<>'UNVALUED' THEN
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='POS cost resolution requires an unvalued sale allocation';
  END IF;
  SELECT coalesce(sum(r.resolved_quantity),0) INTO already_resolved
    FROM public.sale_item_cost_resolutions r WHERE r.source_layer_allocation_id=NEW.source_layer_allocation_id;
  IF already_resolved+NEW.resolved_quantity>a.unvalued_quantity THEN
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='POS resolved quantity exceeds sold unvalued quantity';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.guard_pos_sale_cost_resolution_link() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_pos_sale_cost_resolution_link() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER sale_item_cost_resolution_source_guard BEFORE INSERT ON public.sale_item_cost_resolutions
  FOR EACH ROW EXECUTE FUNCTION public.guard_pos_sale_cost_resolution_link();

-- P1B event identity continues to serve cart mutations; P1D-B completion uses
-- a separate checkout request identity and still has no writer in this migration.
ALTER TABLE public.pos_cart_events ALTER COLUMN request_id DROP NOT NULL;
ALTER TABLE public.pos_cart_events ADD COLUMN checkout_request_id uuid;
ALTER TABLE public.pos_cart_events
  ADD CONSTRAINT pos_cart_event_checkout_request_fk FOREIGN KEY(checkout_request_id)
    REFERENCES public.pos_checkout_requests(request_id) ON DELETE RESTRICT,
  ADD CONSTRAINT pos_cart_event_exactly_one_request CHECK (
    (request_id IS NOT NULL AND checkout_request_id IS NULL)
    OR (request_id IS NULL AND checkout_request_id IS NOT NULL)
  );
CREATE UNIQUE INDEX pos_cart_events_checkout_request_once
  ON public.pos_cart_events(checkout_request_id) WHERE checkout_request_id IS NOT NULL;

CREATE FUNCTION public.guard_pos_sale_evidence_immutable()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Completed POS sale evidence is immutable';
END;
$$;
ALTER FUNCTION public.guard_pos_sale_evidence_immutable() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_pos_sale_evidence_immutable() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER sales_immutable BEFORE UPDATE OR DELETE ON public.sales
  FOR EACH ROW EXECUTE FUNCTION public.guard_pos_sale_evidence_immutable();
CREATE TRIGGER sale_items_immutable BEFORE UPDATE OR DELETE ON public.sale_items
  FOR EACH ROW EXECUTE FUNCTION public.guard_pos_sale_evidence_immutable();
CREATE TRIGGER sale_payments_immutable BEFORE UPDATE OR DELETE ON public.sale_payments
  FOR EACH ROW EXECUTE FUNCTION public.guard_pos_sale_evidence_immutable();
CREATE TRIGGER sale_item_cost_evidence_immutable BEFORE UPDATE OR DELETE ON public.sale_item_cost_evidence
  FOR EACH ROW EXECUTE FUNCTION public.guard_pos_sale_evidence_immutable();
CREATE TRIGGER sale_item_cost_allocations_immutable BEFORE UPDATE OR DELETE ON public.sale_item_cost_allocations
  FOR EACH ROW EXECUTE FUNCTION public.guard_pos_sale_evidence_immutable();
CREATE TRIGGER sale_item_cost_resolutions_immutable BEFORE UPDATE OR DELETE ON public.sale_item_cost_resolutions
  FOR EACH ROW EXECUTE FUNCTION public.guard_pos_sale_evidence_immutable();

ALTER TABLE public.pos_checkout_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_checkout_requests FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sale_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_items FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sale_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_payments FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sale_item_cost_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_item_cost_evidence FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sale_item_cost_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_item_cost_allocations FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sale_item_cost_resolutions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_item_cost_resolutions FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.pos_checkout_requests,public.sales,public.sale_items,public.sale_payments,
  public.sale_item_cost_evidence,public.sale_item_cost_allocations,public.sale_item_cost_resolutions
  FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.sale_item_cost_evidence,public.sale_item_cost_allocations,public.sale_item_cost_resolutions TO authenticated;
CREATE POLICY sale_item_cost_evidence_manager_read ON public.sale_item_cost_evidence
  FOR SELECT TO authenticated USING (
    public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role)
    AND (SELECT count(*)=1 FROM public.stock_authority_periods ap
      JOIN public.outlets o ON o.id=ap.outlet_id
      WHERE ap.ended_at IS NULL AND o.is_active)
    AND EXISTS(SELECT 1 FROM public.stock_authority_periods ap
      JOIN public.outlets o ON o.id=ap.outlet_id
      WHERE ap.outlet_id=sale_item_cost_evidence.outlet_id AND ap.ended_at IS NULL AND o.is_active)
  );
CREATE POLICY sale_item_cost_allocations_manager_read ON public.sale_item_cost_allocations
  FOR SELECT TO authenticated USING (
    public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role)
    AND (SELECT count(*)=1 FROM public.stock_authority_periods ap
      JOIN public.outlets o ON o.id=ap.outlet_id
      WHERE ap.ended_at IS NULL AND o.is_active)
    AND EXISTS(SELECT 1 FROM public.stock_authority_periods ap
      JOIN public.outlets o ON o.id=ap.outlet_id
      WHERE ap.outlet_id=sale_item_cost_allocations.outlet_id AND ap.ended_at IS NULL AND o.is_active)
  );
CREATE POLICY sale_item_cost_resolutions_manager_read ON public.sale_item_cost_resolutions
  FOR SELECT TO authenticated USING (
    public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role)
    AND (SELECT count(*)=1 FROM public.stock_authority_periods ap
      JOIN public.outlets o ON o.id=ap.outlet_id
      WHERE ap.ended_at IS NULL AND o.is_active)
    AND EXISTS(SELECT 1 FROM public.stock_authority_periods ap
      JOIN public.outlets o ON o.id=ap.outlet_id
      WHERE ap.outlet_id=sale_item_cost_resolutions.outlet_id AND ap.ended_at IS NULL AND o.is_active)
  );

REVOKE ALL ON TYPE public.pos_sale_source,public.pos_sale_status,public.pos_sale_payment_method,
  public.pos_checkout_request_state,public.pos_sale_item_cogs_status,public.pos_sale_cost_allocation_bucket
  FROM PUBLIC,anon,authenticated,service_role;
GRANT USAGE ON TYPE public.pos_sale_source,public.pos_sale_status,public.pos_sale_payment_method,
  public.pos_checkout_request_state,public.pos_sale_item_cogs_status,public.pos_sale_cost_allocation_bucket
  TO authenticated;

COMMIT;
