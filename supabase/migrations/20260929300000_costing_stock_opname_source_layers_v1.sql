-- C3B: source quantity provenance and atomic stock-opname/reversal costing.
-- This migration installs capabilities only; it does not bootstrap or activate WAC.
BEGIN;

ALTER TYPE public.inventory_cost_event_type ADD VALUE 'OPNAME_ADJUSTMENT';

CREATE TYPE public.inventory_cost_source_layer_balance_state AS ENUM
  ('ACTIVE','EXHAUSTED');

ALTER TABLE public.inventory_cost_events
  ADD COLUMN source_stock_movement_id uuid REFERENCES public.stock_movements(id) ON DELETE RESTRICT,
  ADD COLUMN opname_session_id uuid REFERENCES public.stock_opname_sessions(id) ON DELETE RESTRICT,
  ADD COLUMN opname_item_id uuid REFERENCES public.stock_opname_items(id) ON DELETE RESTRICT,
  ADD COLUMN reverses_cost_event_id uuid REFERENCES public.inventory_cost_events(id) ON DELETE RESTRICT,
  ADD COLUMN reverses_stock_movement_id uuid REFERENCES public.stock_movements(id) ON DELETE RESTRICT;

ALTER TABLE public.stock_movements
  ADD CONSTRAINT stock_movement_layer_identity UNIQUE(id,outlet_id,product_id);
ALTER TABLE public.stock_opname_items
  ADD CONSTRAINT stock_opname_item_layer_identity UNIQUE(id,session_id,product_id);

ALTER TABLE public.inventory_cost_events
  ADD CONSTRAINT inventory_cost_event_layer_identity UNIQUE(id,outlet_id,product_id),
  ADD CONSTRAINT inventory_cost_event_source_movement_identity_fk
    FOREIGN KEY(source_stock_movement_id,outlet_id,product_id)
    REFERENCES public.stock_movements(id,outlet_id,product_id) ON DELETE RESTRICT,
  ADD CONSTRAINT inventory_cost_event_reversal_movement_identity_fk
    FOREIGN KEY(reverses_stock_movement_id,outlet_id,product_id)
    REFERENCES public.stock_movements(id,outlet_id,product_id) ON DELETE RESTRICT,
  ADD CONSTRAINT inventory_cost_event_reversal_event_identity_fk
    FOREIGN KEY(reverses_cost_event_id,outlet_id,product_id)
    REFERENCES public.inventory_cost_events(id,outlet_id,product_id) ON DELETE RESTRICT,
  ADD CONSTRAINT inventory_cost_event_opname_identity_fk
    FOREIGN KEY(opname_item_id,opname_session_id,product_id)
    REFERENCES public.stock_opname_items(id,session_id,product_id) ON DELETE RESTRICT,
  ADD CONSTRAINT inventory_cost_event_opname_shape CHECK (
    (opname_session_id IS NULL AND opname_item_id IS NULL)
    OR (opname_session_id IS NOT NULL AND opname_item_id IS NOT NULL AND source_stock_movement_id IS NOT NULL)
  ),
  ADD CONSTRAINT inventory_cost_event_reversal_shape CHECK (
    (reverses_cost_event_id IS NULL AND reverses_stock_movement_id IS NULL)
    OR (reverses_cost_event_id IS NOT NULL AND reverses_stock_movement_id IS NOT NULL AND source_stock_movement_id IS NOT NULL)
  );
ALTER TABLE public.inventory_cost_operation_requests
  DROP CONSTRAINT inventory_cost_operation_requests_operation_key_check,
  ADD CONSTRAINT inventory_cost_operation_requests_operation_key_check
    CHECK (operation_key IN ('BOOTSTRAP_OUTLET','PURCHASE_RECEIPT','OPNAME_ADJUSTMENT','REVERSAL'));

CREATE TABLE public.inventory_cost_source_layers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  opening_cost_event_id uuid NOT NULL UNIQUE
    REFERENCES public.inventory_cost_events(id) ON DELETE RESTRICT,
  source_event_type public.inventory_cost_event_type NOT NULL,
  source_entity_type text NOT NULL CHECK (btrim(source_entity_type)<>''),
  source_entity_id uuid NOT NULL,
  source_stock_movement_id uuid REFERENCES public.stock_movements(id) ON DELETE RESTRICT,
  receipt_id uuid REFERENCES public.purchase_receipts(id) ON DELETE RESTRICT,
  receipt_item_id uuid REFERENCES public.purchase_receipt_items(id) ON DELETE RESTRICT,
  opname_session_id uuid REFERENCES public.stock_opname_sessions(id) ON DELETE RESTRICT,
  opname_item_id uuid REFERENCES public.stock_opname_items(id) ON DELETE RESTRICT,
  original_physical_quantity numeric NOT NULL,
  original_valued_quantity numeric NOT NULL,
  original_provisional_quantity numeric NOT NULL,
  original_unvalued_quantity numeric NOT NULL,
  original_source_amount numeric(32,8),
  source_unit_cost numeric(20,8),
  valuation_basis public.inventory_cost_acquisition_basis,
  source_evidence_revision integer,
  created_cost_version bigint NOT NULL,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_cost_source_layer_source_shape CHECK (
    (receipt_id IS NULL AND receipt_item_id IS NULL) OR
    (receipt_id IS NOT NULL AND receipt_item_id IS NOT NULL)
  ),
  CONSTRAINT inventory_cost_source_layer_opname_shape CHECK (
    (opname_session_id IS NULL AND opname_item_id IS NULL) OR
    (opname_session_id IS NOT NULL AND opname_item_id IS NOT NULL AND source_stock_movement_id IS NOT NULL)
  ),
  CONSTRAINT inventory_cost_source_layer_quantities CHECK (
    original_physical_quantity>=0 AND original_physical_quantity=trunc(original_physical_quantity,3)
    AND original_valued_quantity>=0 AND original_valued_quantity=trunc(original_valued_quantity,3)
    AND original_provisional_quantity>=0 AND original_provisional_quantity<=original_valued_quantity
      AND original_provisional_quantity=trunc(original_provisional_quantity,3)
    AND original_unvalued_quantity>=0 AND original_unvalued_quantity=trunc(original_unvalued_quantity,3)
    AND original_physical_quantity=original_valued_quantity+original_unvalued_quantity
    AND (original_source_amount IS NULL OR original_source_amount>=0)
    AND (source_unit_cost IS NULL OR source_unit_cost>=0)
    AND (source_evidence_revision IS NULL OR source_evidence_revision>0)
    AND created_cost_version>0
  ),
  CONSTRAINT inventory_cost_source_layer_event_identity_fk FOREIGN KEY
    (opening_cost_event_id,outlet_id,product_id)
    REFERENCES public.inventory_cost_events(id,outlet_id,product_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_source_layer_identity UNIQUE(id,outlet_id,product_id),
  CONSTRAINT inventory_cost_source_layer_receipt_identity_fk FOREIGN KEY
    (receipt_item_id,receipt_id,product_id)
    REFERENCES public.purchase_receipt_items(id,receipt_id,product_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_source_layer_opname_identity_fk FOREIGN KEY
    (opname_item_id,opname_session_id,product_id)
    REFERENCES public.stock_opname_items(id,session_id,product_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_source_layer_movement_identity_fk FOREIGN KEY
    (source_stock_movement_id,outlet_id,product_id)
    REFERENCES public.stock_movements(id,outlet_id,product_id) ON DELETE RESTRICT
);
CREATE INDEX inventory_cost_source_layers_product_idx
  ON public.inventory_cost_source_layers(outlet_id,product_id,id);
CREATE INDEX inventory_cost_source_layers_opname_idx
  ON public.inventory_cost_source_layers(opname_session_id,opname_item_id)
  WHERE opname_session_id IS NOT NULL;

CREATE TABLE public.inventory_cost_source_layer_balances (
  layer_id uuid PRIMARY KEY REFERENCES public.inventory_cost_source_layers(id) ON DELETE RESTRICT,
  outlet_id uuid NOT NULL,
  product_id uuid NOT NULL,
  remaining_valued_quantity numeric NOT NULL,
  remaining_provisional_quantity numeric NOT NULL,
  remaining_unvalued_quantity numeric NOT NULL,
  remaining_physical_quantity numeric GENERATED ALWAYS AS
    (remaining_valued_quantity+remaining_unvalued_quantity) STORED,
  state public.inventory_cost_source_layer_balance_state NOT NULL DEFAULT 'ACTIVE',
  last_cost_version bigint NOT NULL,
  last_cost_event_id uuid NOT NULL REFERENCES public.inventory_cost_events(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  exhausted_at timestamptz,
  CONSTRAINT inventory_cost_source_layer_balance_layer_fk FOREIGN KEY(layer_id,outlet_id,product_id)
    REFERENCES public.inventory_cost_source_layers(id,outlet_id,product_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_source_layer_balance_last_event_fk FOREIGN KEY(last_cost_event_id,outlet_id,product_id)
    REFERENCES public.inventory_cost_events(id,outlet_id,product_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_source_layer_balance_quantities CHECK (
    remaining_valued_quantity>=0 AND remaining_valued_quantity=trunc(remaining_valued_quantity,3)
    AND remaining_provisional_quantity>=0 AND remaining_provisional_quantity<=remaining_valued_quantity
      AND remaining_provisional_quantity=trunc(remaining_provisional_quantity,3)
    AND remaining_unvalued_quantity>=0 AND remaining_unvalued_quantity=trunc(remaining_unvalued_quantity,3)
    AND last_cost_version>0
    AND ((remaining_physical_quantity=0 AND state='EXHAUSTED' AND exhausted_at IS NOT NULL)
      OR (remaining_physical_quantity>0 AND state='ACTIVE' AND exhausted_at IS NULL))
  )
);
CREATE INDEX inventory_cost_source_layer_balances_product_idx
  ON public.inventory_cost_source_layer_balances(outlet_id,product_id,layer_id);

CREATE TABLE public.inventory_cost_layer_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cost_event_id uuid NOT NULL REFERENCES public.inventory_cost_events(id) ON DELETE RESTRICT,
  source_layer_id uuid NOT NULL REFERENCES public.inventory_cost_source_layers(id) ON DELETE RESTRICT,
  outlet_id uuid NOT NULL,
  product_id uuid NOT NULL,
  stock_movement_id uuid REFERENCES public.stock_movements(id) ON DELETE RESTRICT,
  allocation_kind text NOT NULL CHECK (allocation_kind IN (
    'OPENING','PURCHASE_RECEIPT','OPNAME_GAIN','OUTFLOW_UNVALUED','OUTFLOW_VALUED',
    'VALUATION_RESOLUTION','REVERSAL')),
  physical_quantity_delta numeric NOT NULL,
  valued_quantity_delta numeric NOT NULL,
  provisional_quantity_delta numeric NOT NULL,
  unvalued_quantity_delta numeric NOT NULL,
  reverses_allocation_id uuid UNIQUE REFERENCES public.inventory_cost_layer_allocations(id) ON DELETE RESTRICT,
  allocation_sequence integer NOT NULL DEFAULT 0 CHECK (allocation_sequence>=0),
  cost_version bigint NOT NULL CHECK (cost_version>0),
  request_id uuid NOT NULL REFERENCES public.inventory_cost_operation_requests(request_id) ON DELETE RESTRICT,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_cost_layer_allocation_quantity_precision CHECK (
    physical_quantity_delta=trunc(physical_quantity_delta,3)
    AND valued_quantity_delta=trunc(valued_quantity_delta,3)
    AND provisional_quantity_delta=trunc(provisional_quantity_delta,3)
    AND unvalued_quantity_delta=trunc(unvalued_quantity_delta,3)
    AND physical_quantity_delta=valued_quantity_delta+unvalued_quantity_delta
    AND (provisional_quantity_delta=0 OR sign(provisional_quantity_delta)=sign(valued_quantity_delta))
    AND abs(provisional_quantity_delta)<=abs(valued_quantity_delta)
    AND ((allocation_kind='REVERSAL' AND reverses_allocation_id IS NOT NULL)
      OR (allocation_kind<>'REVERSAL' AND reverses_allocation_id IS NULL))
  ),
  CONSTRAINT inventory_cost_layer_allocation_event_identity_fk FOREIGN KEY(cost_event_id,outlet_id,product_id)
    REFERENCES public.inventory_cost_events(id,outlet_id,product_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_layer_allocation_layer_identity_fk FOREIGN KEY(source_layer_id,outlet_id,product_id)
    REFERENCES public.inventory_cost_source_layers(id,outlet_id,product_id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX inventory_cost_layer_allocation_event_layer_kind_once
  ON public.inventory_cost_layer_allocations(cost_event_id,source_layer_id,allocation_kind,allocation_sequence);
CREATE INDEX inventory_cost_layer_allocations_source_idx
  ON public.inventory_cost_layer_allocations(source_layer_id,created_at,id);

CREATE UNIQUE INDEX inventory_cost_event_source_stock_movement_once
  ON public.inventory_cost_events(source_stock_movement_id)
  WHERE source_stock_movement_id IS NOT NULL;
CREATE UNIQUE INDEX inventory_cost_event_reversal_once
  ON public.inventory_cost_events(reverses_cost_event_id)
  WHERE reverses_cost_event_id IS NOT NULL;

ALTER TABLE public.inventory_cost_source_layers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_cost_source_layer_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_cost_layer_allocations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_cost_source_layers,public.inventory_cost_source_layer_balances,
  public.inventory_cost_layer_allocations FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.inventory_cost_source_layers,public.inventory_cost_source_layer_balances,
  public.inventory_cost_layer_allocations TO authenticated;
CREATE POLICY inventory_cost_source_layers_manager_read ON public.inventory_cost_source_layers
  FOR SELECT TO authenticated USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY inventory_cost_source_layer_balances_manager_read ON public.inventory_cost_source_layer_balances
  FOR SELECT TO authenticated USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY inventory_cost_layer_allocations_manager_read ON public.inventory_cost_layer_allocations
  FOR SELECT TO authenticated USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
REVOKE ALL ON TYPE public.inventory_cost_source_layer_balance_state FROM PUBLIC,anon,authenticated,service_role;
GRANT USAGE ON TYPE public.inventory_cost_source_layer_balance_state TO authenticated;

CREATE FUNCTION public.guard_inventory_cost_source_layer_immutable()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Cost source-layer evidence is immutable';
END;
$$;
ALTER FUNCTION public.guard_inventory_cost_source_layer_immutable() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_inventory_cost_source_layer_immutable() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER inventory_cost_source_layers_immutable
  BEFORE UPDATE OR DELETE ON public.inventory_cost_source_layers
  FOR EACH ROW EXECUTE FUNCTION public.guard_inventory_cost_source_layer_immutable();
CREATE TRIGGER inventory_cost_layer_allocations_immutable
  BEFORE UPDATE OR DELETE ON public.inventory_cost_layer_allocations
  FOR EACH ROW EXECUTE FUNCTION public.guard_inventory_cost_source_layer_immutable();

CREATE FUNCTION public.guard_inventory_cost_c3b_event_links()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_movement public.stock_movements%rowtype; v_original public.inventory_cost_events%rowtype;
  v_item public.stock_opname_items%rowtype; v_batch_request uuid;
BEGIN
  IF NEW.event_type::text='OPNAME_ADJUSTMENT' THEN
    SELECT * INTO v_movement FROM public.stock_movements m WHERE m.id=NEW.source_stock_movement_id;
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Opname cost movement is unavailable'; END IF;
    SELECT * INTO v_item FROM public.stock_opname_items i WHERE i.id=NEW.opname_item_id;
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Opname cost item is unavailable'; END IF;
    SELECT b.operation_request_id INTO v_batch_request FROM public.stock_movement_batches b WHERE b.id=v_movement.batch_id;
    IF v_movement.movement_type<>'OPNAME_ADJUSTMENT'::public.stock_movement_type
      OR v_movement.source_system<>'STOCK_OPNAME' OR v_movement.opname_item_id IS DISTINCT FROM NEW.opname_item_id
      OR v_item.session_id IS DISTINCT FROM NEW.opname_session_id OR v_item.product_id IS DISTINCT FROM NEW.product_id
      OR v_movement.quantity_delta IS DISTINCT FROM NEW.physical_quantity_delta
      OR v_movement.outlet_id IS DISTINCT FROM NEW.outlet_id OR v_batch_request IS DISTINCT FROM NEW.operation_request_id
      OR v_movement.created_by IS DISTINCT FROM NEW.actor_id OR NEW.source_event_id IS DISTINCT FROM v_movement.id
      OR NEW.source_entity_type IS DISTINCT FROM 'STOCK_OPNAME_ITEM'
      OR NEW.source_entity_id IS DISTINCT FROM NEW.opname_item_id
      OR NEW.stock_authority_period_id IS DISTINCT FROM v_movement.authority_period_id
      OR NEW.physical_quantity_before IS DISTINCT FROM v_movement.balance_before
      OR NEW.physical_quantity_after IS DISTINCT FROM v_movement.balance_after THEN
      RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Opname cost event source does not match its stock movement';
    END IF;
  ELSIF NEW.event_type::text='REVERSAL' AND NEW.reverses_cost_event_id IS NOT NULL THEN
    SELECT * INTO v_movement FROM public.stock_movements m WHERE m.id=NEW.source_stock_movement_id;
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Reversal cost movement is unavailable'; END IF;
    SELECT * INTO v_original FROM public.inventory_cost_events e WHERE e.id=NEW.reverses_cost_event_id;
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Original cost event is unavailable'; END IF;
    IF v_movement.movement_type IS DISTINCT FROM 'REVERSAL'::public.stock_movement_type
      OR v_movement.reverses_movement_id IS DISTINCT FROM NEW.reverses_stock_movement_id
      OR v_original.outlet_id IS DISTINCT FROM NEW.outlet_id OR v_original.product_id IS DISTINCT FROM NEW.product_id
      OR NEW.source_event_id IS DISTINCT FROM v_original.id
      OR NEW.source_entity_type IS DISTINCT FROM 'STOCK_MOVEMENT_REVERSAL'
      OR NEW.source_entity_id IS DISTINCT FROM v_movement.id
      OR NEW.stock_authority_period_id IS DISTINCT FROM v_movement.authority_period_id
      OR NEW.physical_quantity_before IS DISTINCT FROM v_movement.balance_before
      OR NEW.physical_quantity_after IS DISTINCT FROM v_movement.balance_after
      OR v_original.physical_quantity_delta IS DISTINCT FROM -NEW.physical_quantity_delta
      OR v_original.valued_quantity_delta IS DISTINCT FROM -NEW.valued_quantity_delta
      OR v_original.provisional_quantity_delta IS DISTINCT FROM -NEW.provisional_quantity_delta
      OR v_original.unvalued_quantity_delta IS DISTINCT FROM -NEW.unvalued_quantity_delta
      OR v_original.inventory_value_delta IS DISTINCT FROM -NEW.inventory_value_delta THEN
      RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Reversal cost event does not exactly invert its original event';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.guard_inventory_cost_c3b_event_links() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_inventory_cost_c3b_event_links() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER inventory_cost_c3b_event_links
  BEFORE INSERT ON public.inventory_cost_events
  FOR EACH ROW EXECUTE FUNCTION public.guard_inventory_cost_c3b_event_links();

CREATE FUNCTION public.guard_inventory_cost_layer_allocation_links()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_event public.inventory_cost_events%rowtype; v_layer public.inventory_cost_source_layers%rowtype;
  v_original public.inventory_cost_layer_allocations%rowtype;
BEGIN
  SELECT * INTO v_event FROM public.inventory_cost_events e WHERE e.id=NEW.cost_event_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='23503',MESSAGE='Layer allocation cost event is unavailable'; END IF;
  SELECT * INTO v_layer FROM public.inventory_cost_source_layers l WHERE l.id=NEW.source_layer_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='23503',MESSAGE='Layer allocation source is unavailable'; END IF;
  IF v_event.outlet_id IS DISTINCT FROM v_layer.outlet_id OR v_event.product_id IS DISTINCT FROM v_layer.product_id
    OR NEW.request_id IS DISTINCT FROM v_event.operation_request_id OR NEW.actor_id IS DISTINCT FROM v_event.actor_id
    OR NEW.stock_movement_id IS DISTINCT FROM coalesce(v_event.source_stock_movement_id,v_event.stock_movement_id) THEN
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Layer allocation source identity does not match its cost event';
  END IF;
  IF NEW.reverses_allocation_id IS NOT NULL THEN
    SELECT * INTO v_original FROM public.inventory_cost_layer_allocations a WHERE a.id=NEW.reverses_allocation_id;
    IF NOT FOUND OR NEW.source_layer_id IS DISTINCT FROM v_original.source_layer_id
      OR NEW.physical_quantity_delta IS DISTINCT FROM -v_original.physical_quantity_delta
      OR NEW.valued_quantity_delta IS DISTINCT FROM -v_original.valued_quantity_delta
      OR NEW.provisional_quantity_delta IS DISTINCT FROM -v_original.provisional_quantity_delta
      OR NEW.unvalued_quantity_delta IS DISTINCT FROM -v_original.unvalued_quantity_delta
      OR v_event.reverses_cost_event_id IS DISTINCT FROM v_original.cost_event_id THEN
      RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Layer reversal allocation does not invert its original allocation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.guard_inventory_cost_layer_allocation_links() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_inventory_cost_layer_allocation_links() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER inventory_cost_layer_allocation_links
  BEFORE INSERT ON public.inventory_cost_layer_allocations
  FOR EACH ROW EXECUTE FUNCTION public.guard_inventory_cost_layer_allocation_links();

CREATE FUNCTION public.inventory_cost_assert_event_layer_allocation(p_cost_event_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_event public.inventory_cost_events%rowtype; v_count bigint;
  v_physical numeric; v_valued numeric; v_provisional numeric; v_unvalued numeric;
BEGIN
  SELECT * INTO STRICT v_event FROM public.inventory_cost_events e WHERE e.id=p_cost_event_id;
  IF v_event.event_type::text NOT IN ('OPENING','PURCHASE_RECEIPT','OPNAME_ADJUSTMENT','REVERSAL') THEN RETURN; END IF;
  SELECT count(*),coalesce(sum(a.physical_quantity_delta),0),coalesce(sum(a.valued_quantity_delta),0),
    coalesce(sum(a.provisional_quantity_delta),0),coalesce(sum(a.unvalued_quantity_delta),0)
  INTO v_count,v_physical,v_valued,v_provisional,v_unvalued
  FROM public.inventory_cost_layer_allocations a WHERE a.cost_event_id=p_cost_event_id;
  IF v_count=0 OR v_physical IS DISTINCT FROM coalesce(v_event.physical_quantity_delta,v_event.quantity_delta,0)
    OR v_valued IS DISTINCT FROM coalesce(v_event.valued_quantity_delta,0)
    OR v_provisional IS DISTINCT FROM coalesce(v_event.provisional_quantity_delta,0)
    OR v_unvalued IS DISTINCT FROM coalesce(v_event.unvalued_quantity_delta,0) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Cost event and source-layer allocations do not reconcile';
  END IF;
END;
$$;
ALTER FUNCTION public.inventory_cost_assert_event_layer_allocation(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_assert_event_layer_allocation(uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.inventory_cost_check_event_layer_allocation_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  PERFORM public.inventory_cost_assert_event_layer_allocation(NEW.id);
  RETURN NULL;
END;
$$;
ALTER FUNCTION public.inventory_cost_check_event_layer_allocation_trigger() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_check_event_layer_allocation_trigger() FROM PUBLIC,anon,authenticated,service_role;
CREATE CONSTRAINT TRIGGER inventory_cost_event_layer_allocation_consistent
  AFTER INSERT ON public.inventory_cost_events DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.inventory_cost_check_event_layer_allocation_trigger();

CREATE FUNCTION public.inventory_cost_assert_layer_balance_ledger(p_layer uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_layer public.inventory_cost_source_layers%rowtype; v_balance public.inventory_cost_source_layer_balances%rowtype;
  v_valued numeric; v_provisional numeric; v_unvalued numeric;
BEGIN
  SELECT * INTO STRICT v_layer FROM public.inventory_cost_source_layers l WHERE l.id=p_layer;
  SELECT * INTO STRICT v_balance FROM public.inventory_cost_source_layer_balances b WHERE b.layer_id=p_layer;
  SELECT coalesce(sum(a.valued_quantity_delta),0),coalesce(sum(a.provisional_quantity_delta),0),
    coalesce(sum(a.unvalued_quantity_delta),0) INTO v_valued,v_provisional,v_unvalued
  FROM public.inventory_cost_layer_allocations a WHERE a.source_layer_id=p_layer;
  IF v_balance.remaining_valued_quantity IS DISTINCT FROM v_valued
    OR v_balance.remaining_provisional_quantity IS DISTINCT FROM v_provisional
    OR v_balance.remaining_unvalued_quantity IS DISTINCT FROM v_unvalued
    OR v_balance.remaining_valued_quantity+v_balance.remaining_unvalued_quantity>v_layer.original_physical_quantity
    OR v_balance.remaining_valued_quantity>v_layer.original_physical_quantity
    OR v_balance.remaining_unvalued_quantity>v_layer.original_physical_quantity THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Source-layer balance does not reconcile to its immutable allocation ledger';
  END IF;
END;
$$;
ALTER FUNCTION public.inventory_cost_assert_layer_balance_ledger(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_assert_layer_balance_ledger(uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.inventory_cost_check_layer_balance_ledger_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  PERFORM public.inventory_cost_assert_layer_balance_ledger(NEW.layer_id);
  RETURN NULL;
END;
$$;
ALTER FUNCTION public.inventory_cost_check_layer_balance_ledger_trigger() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_check_layer_balance_ledger_trigger() FROM PUBLIC,anon,authenticated,service_role;
CREATE CONSTRAINT TRIGGER inventory_cost_layer_balance_ledger_consistent
  AFTER INSERT OR UPDATE ON public.inventory_cost_source_layer_balances DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.inventory_cost_check_layer_balance_ledger_trigger();

CREATE FUNCTION public.inventory_cost_open_source_layer(p_cost_event_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_event public.inventory_cost_events%rowtype; v_layer uuid;
  v_physical numeric; v_valued numeric; v_provisional numeric; v_unvalued numeric; v_kind text; v_movement uuid;
BEGIN
  SELECT * INTO STRICT v_event FROM public.inventory_cost_events e WHERE e.id=p_cost_event_id;
  IF v_event.event_type::text NOT IN ('OPENING','PURCHASE_RECEIPT','OPNAME_ADJUSTMENT') THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Cost event type cannot open a source layer';
  END IF;
  v_movement:=coalesce(v_event.source_stock_movement_id,v_event.stock_movement_id);
  v_physical:=greatest(coalesce(v_event.physical_quantity_delta,v_event.quantity_delta,
    v_event.physical_quantity_after-v_event.physical_quantity_before,0),0);
  v_valued:=greatest(coalesce(v_event.valued_quantity_delta,
    v_event.valued_quantity_after-v_event.valued_quantity_before,0),0);
  v_provisional:=greatest(coalesce(v_event.provisional_quantity_delta,
    CASE WHEN v_event.valuation_status_after='PROVISIONAL'::public.inventory_cost_projection_status THEN v_valued ELSE 0 END),0);
  v_unvalued:=greatest(coalesce(v_event.unvalued_quantity_delta,v_physical-v_valued),0);
  IF coalesce(v_event.physical_quantity_delta,v_event.quantity_delta,
      v_event.physical_quantity_after-v_event.physical_quantity_before,0)<0
    OR (v_physical=0 AND v_event.event_type::text<>'OPENING') THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Only opening or positive source quantity can open a source layer';
  END IF;
  IF v_physical<>v_valued+v_unvalued THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Cost event cannot open a balanced source layer';
  END IF;
  v_kind:=CASE v_event.event_type::text WHEN 'OPENING' THEN 'OPENING'
    WHEN 'PURCHASE_RECEIPT' THEN 'PURCHASE_RECEIPT' ELSE 'OPNAME_GAIN' END;
  INSERT INTO public.inventory_cost_source_layers(
    outlet_id,product_id,opening_cost_event_id,source_event_type,source_entity_type,source_entity_id,
    source_stock_movement_id,receipt_id,receipt_item_id,opname_session_id,opname_item_id,
    original_physical_quantity,original_valued_quantity,original_provisional_quantity,original_unvalued_quantity,
    original_source_amount,source_unit_cost,valuation_basis,source_evidence_revision,created_cost_version,created_by)
  VALUES(v_event.outlet_id,v_event.product_id,v_event.id,v_event.event_type,v_event.source_entity_type,
    v_event.source_entity_id,v_movement,v_event.receipt_id,v_event.receipt_item_id,
    v_event.opname_session_id,v_event.opname_item_id,v_physical,v_valued,v_provisional,v_unvalued,
    CASE WHEN v_event.valuation_basis IN ('AUTHORITATIVE_ZERO','VERIFIED_IPOS_HPP','MANAGER_ESTIMATE','CURRENT_WAC')
      THEN coalesce(v_event.inventory_value_delta,v_event.inventory_value_after-v_event.inventory_value_before,0)
      WHEN coalesce(v_event.inventory_value_delta,v_event.inventory_value_after-v_event.inventory_value_before,0)>0
      THEN coalesce(v_event.inventory_value_delta,v_event.inventory_value_after-v_event.inventory_value_before) ELSE NULL END,
    coalesce(v_event.frozen_unit_cost,v_event.source_hpp_value),v_event.valuation_basis,
    v_event.acquisition_evidence_revision,v_event.cost_version_after,v_event.actor_id)
  ON CONFLICT(opening_cost_event_id) DO NOTHING RETURNING id INTO v_layer;
  IF v_layer IS NULL THEN
    SELECT id INTO STRICT v_layer FROM public.inventory_cost_source_layers WHERE opening_cost_event_id=v_event.id;
    RETURN v_layer;
  END IF;
  INSERT INTO public.inventory_cost_source_layer_balances(
    layer_id,outlet_id,product_id,remaining_valued_quantity,remaining_provisional_quantity,
    remaining_unvalued_quantity,state,last_cost_version,last_cost_event_id,exhausted_at)
  VALUES(v_layer,v_event.outlet_id,v_event.product_id,v_valued,v_provisional,v_unvalued,
    CASE WHEN v_physical=0 THEN 'EXHAUSTED'::public.inventory_cost_source_layer_balance_state
      ELSE 'ACTIVE'::public.inventory_cost_source_layer_balance_state END,
    v_event.cost_version_after,v_event.id,CASE WHEN v_physical=0 THEN now() ELSE NULL END);
  INSERT INTO public.inventory_cost_layer_allocations(
    cost_event_id,source_layer_id,outlet_id,product_id,stock_movement_id,allocation_kind,physical_quantity_delta,
    valued_quantity_delta,provisional_quantity_delta,unvalued_quantity_delta,cost_version,request_id,actor_id)
  VALUES(v_event.id,v_layer,v_event.outlet_id,v_event.product_id,v_movement,v_kind,v_physical,v_valued,v_provisional,v_unvalued,
    v_event.cost_version_after,v_event.operation_request_id,v_event.actor_id);
  RETURN v_layer;
END;
$$;
ALTER FUNCTION public.inventory_cost_open_source_layer(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_open_source_layer(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.inventory_cost_assert_layer_invariants(p_outlet uuid,p_product uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_authority public.inventory_cost_authority_status; v_cost public.inventory_cost_projections%rowtype;
  v_stock numeric; v_layer_physical numeric; v_layer_valued numeric; v_layer_provisional numeric; v_layer_unvalued numeric;
BEGIN
  SELECT a.status INTO v_authority FROM public.inventory_costing_outlet_authority a WHERE a.outlet_id=p_outlet;
  IF v_authority IS DISTINCT FROM 'WAC_ACTIVE'::public.inventory_cost_authority_status THEN RETURN; END IF;
  SELECT * INTO v_cost FROM public.inventory_cost_projections cp
    WHERE cp.outlet_id=p_outlet AND cp.product_id=p_product;
  SELECT p.effective_quantity INTO v_stock FROM public.stock_balance_projection p
    WHERE p.outlet_id=p_outlet AND p.product_id=p_product;
  IF NOT FOUND OR v_cost.product_id IS NULL OR v_cost.physical_quantity IS DISTINCT FROM v_stock THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Active costing and stock quantities are out of sync';
  END IF;
  SELECT coalesce(sum(b.remaining_physical_quantity),0),coalesce(sum(b.remaining_valued_quantity),0),
    coalesce(sum(b.remaining_provisional_quantity),0),coalesce(sum(b.remaining_unvalued_quantity),0)
    INTO v_layer_physical,v_layer_valued,v_layer_provisional,v_layer_unvalued
  FROM public.inventory_cost_source_layer_balances b
  WHERE b.outlet_id=p_outlet AND b.product_id=p_product;
  IF v_layer_physical IS DISTINCT FROM v_cost.physical_quantity
    OR v_layer_valued IS DISTINCT FROM v_cost.valued_quantity
    OR v_layer_provisional IS DISTINCT FROM v_cost.provisional_quantity
    OR v_layer_unvalued IS DISTINCT FROM v_cost.unvalued_quantity THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Active source layers and aggregate costing projection are out of sync';
  END IF;
END;
$$;
ALTER FUNCTION public.inventory_cost_assert_layer_invariants(uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_assert_layer_invariants(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.inventory_cost_check_layer_invariants_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_outlet uuid; v_product uuid;
BEGIN
  IF TG_TABLE_NAME='inventory_costing_outlet_authority' THEN
    v_outlet:=coalesce(NEW.outlet_id,OLD.outlet_id);
    IF coalesce(NEW.status,OLD.status)='WAC_ACTIVE'::public.inventory_cost_authority_status THEN
      IF EXISTS(SELECT 1 FROM public.stock_balance_projection p WHERE p.outlet_id=v_outlet
        AND NOT EXISTS(SELECT 1 FROM public.inventory_cost_projections cp
          WHERE cp.outlet_id=p.outlet_id AND cp.product_id=p.product_id)) THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='WAC activation requires a costing projection for every stock product';
      END IF;
      FOR v_product IN SELECT p.product_id FROM public.stock_balance_projection p
        WHERE p.outlet_id=v_outlet ORDER BY p.product_id LOOP
        PERFORM public.inventory_cost_assert_layer_invariants(v_outlet,v_product);
      END LOOP;
    END IF;
    RETURN NULL;
  END IF;
  v_outlet:=coalesce(NEW.outlet_id,OLD.outlet_id); v_product:=coalesce(NEW.product_id,OLD.product_id);
  PERFORM public.inventory_cost_assert_layer_invariants(v_outlet,v_product);
  RETURN NULL;
END;
$$;
ALTER FUNCTION public.inventory_cost_check_layer_invariants_trigger() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_check_layer_invariants_trigger() FROM PUBLIC,anon,authenticated,service_role;
CREATE CONSTRAINT TRIGGER inventory_cost_projection_layer_invariant
  AFTER INSERT OR UPDATE ON public.inventory_cost_projections DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.inventory_cost_check_layer_invariants_trigger();
CREATE CONSTRAINT TRIGGER inventory_cost_layer_balance_invariant
  AFTER INSERT OR UPDATE OR DELETE ON public.inventory_cost_source_layer_balances DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.inventory_cost_check_layer_invariants_trigger();
CREATE CONSTRAINT TRIGGER stock_projection_cost_layer_invariant
  AFTER INSERT OR UPDATE ON public.stock_balance_projection DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.inventory_cost_check_layer_invariants_trigger();
CREATE CONSTRAINT TRIGGER costing_authority_layer_invariant
  AFTER INSERT OR UPDATE ON public.inventory_costing_outlet_authority
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
  EXECUTE FUNCTION public.inventory_cost_check_layer_invariants_trigger();

CREATE FUNCTION public.inventory_cost_build_layer_outflow_plan(
  p_outlet uuid,p_product uuid,p_quantity numeric,p_bucket text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_quantity_mills numeric; v_available_mills numeric; v_plan jsonb;
BEGIN
  IF p_quantity IS NULL OR p_quantity<=0 OR p_quantity<>trunc(p_quantity,3)
    OR p_bucket NOT IN ('VALUED','UNVALUED') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid source-layer outflow quantity';
  END IF;
  v_quantity_mills:=p_quantity*1000;
  WITH eligible AS (
    SELECT b.layer_id,'UNVALUED'::text AS bucket,b.remaining_unvalued_quantity*1000 AS available_mills
    FROM public.inventory_cost_source_layer_balances b
    WHERE p_bucket='UNVALUED' AND b.outlet_id=p_outlet AND b.product_id=p_product AND b.remaining_unvalued_quantity>0
    UNION ALL
    SELECT b.layer_id,'FINAL'::text,(b.remaining_valued_quantity-b.remaining_provisional_quantity)*1000
    FROM public.inventory_cost_source_layer_balances b
    WHERE p_bucket='VALUED' AND b.outlet_id=p_outlet AND b.product_id=p_product
      AND b.remaining_valued_quantity>b.remaining_provisional_quantity
    UNION ALL
    SELECT b.layer_id,'PROVISIONAL'::text,b.remaining_provisional_quantity*1000
    FROM public.inventory_cost_source_layer_balances b
    WHERE p_bucket='VALUED' AND b.outlet_id=p_outlet AND b.product_id=p_product AND b.remaining_provisional_quantity>0
  ) SELECT coalesce(sum(available_mills),0) INTO v_available_mills FROM eligible;
  IF v_available_mills<v_quantity_mills OR v_available_mills=0 THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Source-layer quantity is insufficient for stock outflow';
  END IF;
  WITH eligible AS (
    SELECT b.layer_id,'UNVALUED'::text AS bucket,b.remaining_unvalued_quantity*1000 AS available_mills
    FROM public.inventory_cost_source_layer_balances b
    WHERE p_bucket='UNVALUED' AND b.outlet_id=p_outlet AND b.product_id=p_product AND b.remaining_unvalued_quantity>0
    UNION ALL
    SELECT b.layer_id,'FINAL'::text,(b.remaining_valued_quantity-b.remaining_provisional_quantity)*1000
    FROM public.inventory_cost_source_layer_balances b
    WHERE p_bucket='VALUED' AND b.outlet_id=p_outlet AND b.product_id=p_product
      AND b.remaining_valued_quantity>b.remaining_provisional_quantity
    UNION ALL
    SELECT b.layer_id,'PROVISIONAL'::text,b.remaining_provisional_quantity*1000
    FROM public.inventory_cost_source_layer_balances b
    WHERE p_bucket='VALUED' AND b.outlet_id=p_outlet AND b.product_id=p_product AND b.remaining_provisional_quantity>0
  ), raw AS (
    SELECT e.*,floor(v_quantity_mills*e.available_mills/v_available_mills) AS base_mills,
      mod(v_quantity_mills*e.available_mills,v_available_mills) AS remainder_numerator
    FROM eligible e
  ), ranked AS (
    SELECT r.*,row_number() OVER (ORDER BY remainder_numerator DESC,layer_id,bucket) AS remainder_rank,
      v_quantity_mills-sum(base_mills) OVER () AS remaining_mills
    FROM raw r
  ), apportioned AS (
    SELECT layer_id,bucket,base_mills+CASE WHEN remainder_rank<=remaining_mills THEN 1 ELSE 0 END AS allocated_mills
    FROM ranked
  ), combined AS (
    SELECT layer_id,
      sum(CASE WHEN bucket IN ('FINAL','PROVISIONAL') THEN allocated_mills ELSE 0 END)/1000 AS valued_quantity,
      sum(CASE WHEN bucket='PROVISIONAL' THEN allocated_mills ELSE 0 END)/1000 AS provisional_quantity,
      sum(CASE WHEN bucket='UNVALUED' THEN allocated_mills ELSE 0 END)/1000 AS unvalued_quantity
    FROM apportioned GROUP BY layer_id
  ) SELECT coalesce(jsonb_agg(jsonb_build_object('layerId',layer_id,'valued',valued_quantity,
      'provisional',provisional_quantity,'unvalued',unvalued_quantity) ORDER BY layer_id),'[]'::jsonb)
    INTO v_plan FROM combined WHERE valued_quantity<>0 OR unvalued_quantity<>0;
  RETURN v_plan;
END;
$$;
ALTER FUNCTION public.inventory_cost_build_layer_outflow_plan(uuid,uuid,numeric,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_build_layer_outflow_plan(uuid,uuid,numeric,text) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.inventory_cost_apply_layer_plan(
  p_cost_event uuid,p_stock_movement uuid,p_request uuid,p_actor uuid,p_cost_version bigint,
  p_allocation_kind text,p_plan jsonb
) RETURNS TABLE(valued_delta numeric,provisional_delta numeric,unvalued_delta numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_row record; v_physical numeric; v_valued numeric; v_provisional numeric; v_unvalued numeric;
BEGIN
  valued_delta:=0;provisional_delta:=0;unvalued_delta:=0;
  FOR v_row IN SELECT x.* FROM jsonb_to_recordset(p_plan) AS x(
      "layerId" uuid,valued numeric,provisional numeric,unvalued numeric)
    ORDER BY x."layerId" LOOP
    v_valued:=-v_row.valued;v_provisional:=-v_row.provisional;v_unvalued:=-v_row.unvalued;
    v_physical:=v_valued+v_unvalued;
    INSERT INTO public.inventory_cost_layer_allocations(
      cost_event_id,source_layer_id,outlet_id,product_id,stock_movement_id,allocation_kind,physical_quantity_delta,
      valued_quantity_delta,provisional_quantity_delta,unvalued_quantity_delta,cost_version,request_id,actor_id)
    VALUES(p_cost_event,v_row."layerId",
      (SELECT e.outlet_id FROM public.inventory_cost_events e WHERE e.id=p_cost_event),
      (SELECT e.product_id FROM public.inventory_cost_events e WHERE e.id=p_cost_event),
      p_stock_movement,p_allocation_kind,v_physical,v_valued,v_provisional,v_unvalued,
      p_cost_version,p_request,p_actor);
    UPDATE public.inventory_cost_source_layer_balances b SET
      remaining_valued_quantity=b.remaining_valued_quantity+v_valued,
      remaining_provisional_quantity=b.remaining_provisional_quantity+v_provisional,
      remaining_unvalued_quantity=b.remaining_unvalued_quantity+v_unvalued,
      state=CASE WHEN b.remaining_valued_quantity+v_valued+b.remaining_unvalued_quantity+v_unvalued=0
        THEN 'EXHAUSTED'::public.inventory_cost_source_layer_balance_state
        ELSE 'ACTIVE'::public.inventory_cost_source_layer_balance_state END,
      last_cost_version=p_cost_version,last_cost_event_id=p_cost_event,updated_at=now(),
      exhausted_at=CASE WHEN b.remaining_valued_quantity+v_valued+b.remaining_unvalued_quantity+v_unvalued=0
        THEN now() ELSE NULL END
    WHERE b.layer_id=v_row."layerId";
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Source-layer balance is unavailable'; END IF;
    valued_delta:=valued_delta+v_valued;provisional_delta:=provisional_delta+v_provisional;
    unvalued_delta:=unvalued_delta+v_unvalued;
  END LOOP;
  IF p_plan='[]'::jsonb THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Source-layer outflow plan is empty'; END IF;
  RETURN NEXT;
END;
$$;
ALTER FUNCTION public.inventory_cost_apply_layer_plan(uuid,uuid,uuid,uuid,bigint,text,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_apply_layer_plan(uuid,uuid,uuid,uuid,bigint,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;

-- Backfill only already-applied quantity-introducing events. This creates no
-- events and never changes an outlet's costing authority.
DO $$
DECLARE v_event record;
BEGIN
  FOR v_event IN SELECT e.id FROM public.inventory_cost_events e
    WHERE e.event_type::text IN ('OPENING','PURCHASE_RECEIPT')
      AND coalesce(e.physical_quantity_delta,e.quantity_delta,e.physical_quantity_after-e.physical_quantity_before)>=0
      AND NOT EXISTS(SELECT 1 FROM public.inventory_cost_source_layers l WHERE l.opening_cost_event_id=e.id)
    ORDER BY e.outlet_id,e.product_id,e.cost_version_after LOOP
    PERFORM public.inventory_cost_open_source_layer(v_event.id);
  END LOOP;
END;
$$;

DO $validate_backfilled_layers$
DECLARE v_event record;
BEGIN
  FOR v_event IN SELECT l.opening_cost_event_id FROM public.inventory_cost_source_layers l LOOP
    PERFORM public.inventory_cost_assert_event_layer_allocation(v_event.opening_cost_event_id);
  END LOOP;
END;
$validate_backfilled_layers$;

ALTER FUNCTION public.apply_stock_operation_intent(uuid) RENAME TO apply_stock_operation_intent_pre_c3b;
REVOKE ALL ON FUNCTION public.apply_stock_operation_intent_pre_c3b(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.inventory_cost_apply_stock_movement_operation(
  p_request_id uuid,p_operation_key text,p_outlet_id uuid
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_status public.inventory_cost_authority_status;
  v_req public.inventory_cost_operation_requests%rowtype; v_batch uuid; v_result jsonb;
  v_m record; v_cost public.inventory_cost_projections%rowtype; v_orig public.inventory_cost_events%rowtype;
  v_event uuid; v_event_type public.inventory_cost_event_type; v_batch_type public.inventory_cost_event_type;
  v_source_type text; v_source_id uuid; v_physical numeric; v_valued numeric; v_provisional numeric;
  v_unvalued numeric; v_value_delta numeric(32,8); v_value_after numeric(32,8); v_wac_after numeric(20,8);
  v_basis public.inventory_cost_acquisition_basis; v_frozen_unit_cost numeric(20,8); v_basis_event uuid;
  v_status_after public.inventory_cost_projection_status; v_remove_unvalued numeric; v_remove_valued numeric;
  v_plan_unvalued jsonb; v_plan_valued jsonb; v_plan jsonb; v_plan_provisional numeric;
  v_layer record; v_alloc public.inventory_cost_layer_allocations%rowtype; v_sequence integer;
  v_count integer:=0; v_hash text; v_cost_count integer;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Costing actor unavailable'; END IF;
  v_role:=public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Costing access denied';
  END IF;
  IF p_operation_key NOT IN ('POST_SESSION','REVERSE_MOVEMENT') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Unsupported stock costing operation';
  END IF;
  SELECT a.status INTO v_status FROM public.inventory_costing_outlet_authority a WHERE a.outlet_id=p_outlet_id;
  IF v_status IS DISTINCT FROM 'WAC_ACTIVE'::public.inventory_cost_authority_status THEN RETURN 0; END IF;

  IF p_operation_key='POST_SESSION' THEN
    v_event_type:='OPNAME_ADJUSTMENT'; v_batch_type:='OPNAME_ADJUSTMENT';
    v_source_type:='STOCK_OPNAME_SESSION';
    SELECT i.session_id INTO v_source_id FROM public.stock_movement_batches b
      JOIN public.stock_movements m ON m.batch_id=b.id
      JOIN public.stock_opname_items i ON i.id=m.opname_item_id
      WHERE b.operation_request_id=p_request_id LIMIT 1;
    IF NOT FOUND THEN RETURN 0; END IF;
  ELSE
    v_event_type:='REVERSAL'; v_batch_type:='REVERSAL'; v_source_type:='STOCK_MOVEMENT_REVERSAL';
    SELECT m.reverses_movement_id INTO v_source_id FROM public.stock_movement_batches b
      JOIN public.stock_movements m ON m.batch_id=b.id
      WHERE b.operation_request_id=p_request_id AND m.movement_type='REVERSAL' LIMIT 1;
    IF NOT FOUND THEN RETURN 0; END IF;
  END IF;
  SELECT * INTO v_req FROM public.inventory_cost_operation_requests r WHERE r.request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF v_req.actor_id<>v_actor OR v_req.operation_key<>(CASE WHEN p_operation_key='POST_SESSION' THEN 'OPNAME_ADJUSTMENT' ELSE 'REVERSAL' END)
      OR v_req.target_key<>v_source_id::text THEN
      RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Cost operation request identity mismatch';
    END IF;
    IF v_req.result IS NOT NULL THEN RETURN coalesce((v_req.result->>'eventCount')::integer,0); END IF;
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Cost operation request is incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_cost_event_batches b WHERE b.operation_request_id=p_request_id) THEN
    RAISE EXCEPTION USING ERRCODE='23505',MESSAGE='Cost operation request already has a batch';
  END IF;
  v_hash:=md5(jsonb_build_object('operation',p_operation_key,'request',p_request_id,'actor',v_actor,
    'outlet',p_outlet_id,'source',v_source_id)::text);
  INSERT INTO public.inventory_cost_operation_requests(request_id,actor_id,operation_key,target_key,payload_hash)
  VALUES(p_request_id,v_actor,CASE WHEN p_operation_key='POST_SESSION' THEN 'OPNAME_ADJUSTMENT' ELSE 'REVERSAL' END,
    v_source_id::text,v_hash);

  -- Lock every aggregate projection first, then all source-layer balances,
  -- each in deterministic product/layer order.
  FOR v_layer IN
    SELECT DISTINCT m.product_id FROM public.stock_movement_batches b
    JOIN public.stock_movements m ON m.batch_id=b.id
    WHERE b.operation_request_id=p_request_id ORDER BY m.product_id
  LOOP
    SELECT * INTO v_cost FROM public.inventory_cost_projections cp
      WHERE cp.outlet_id=p_outlet_id AND cp.product_id=v_layer.product_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Active costing projection is missing'; END IF;
  END LOOP;
  FOR v_layer IN
    SELECT DISTINCT m.product_id,b.layer_id FROM public.stock_movement_batches mb
    JOIN public.stock_movements m ON m.batch_id=mb.id
    JOIN public.inventory_cost_source_layer_balances b ON b.outlet_id=p_outlet_id AND b.product_id=m.product_id
    WHERE mb.operation_request_id=p_request_id ORDER BY m.product_id,b.layer_id
  LOOP
    PERFORM 1 FROM public.inventory_cost_source_layer_balances b WHERE b.layer_id=v_layer.layer_id FOR UPDATE;
  END LOOP;

  INSERT INTO public.inventory_cost_event_batches(outlet_id,batch_type,source_entity_type,source_entity_id,
    operation_request_id,allocation_method,created_by)
  VALUES(p_outlet_id,v_batch_type,v_source_type,v_source_id,p_request_id,
    'UNVALUED_FIRST_THEN_PROPORTIONAL_SOURCE_QUANTITY',v_actor) RETURNING id INTO v_batch;

  FOR v_m IN SELECT m.*,i.session_id,i.id AS opname_item
    FROM public.stock_movement_batches b JOIN public.stock_movements m ON m.batch_id=b.id
    LEFT JOIN public.stock_opname_items i ON i.id=m.opname_item_id
    WHERE b.operation_request_id=p_request_id
      AND ((p_operation_key='POST_SESSION' AND m.movement_type='OPNAME_ADJUSTMENT')
        OR (p_operation_key='REVERSE_MOVEMENT' AND m.movement_type='REVERSAL'))
    ORDER BY m.product_id LOOP
  SELECT * INTO STRICT v_cost FROM public.inventory_cost_projections cp
      WHERE cp.outlet_id=p_outlet_id AND cp.product_id=v_m.product_id;
    IF v_cost.physical_quantity IS DISTINCT FROM v_m.balance_before
      OR v_cost.stock_authority_period_id IS DISTINCT FROM v_m.authority_period_id THEN
      RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='Costing and stock projections are out of sync';
    END IF;
    v_event:=gen_random_uuid(); v_plan_unvalued:='[]'::jsonb;v_plan_valued:='[]'::jsonb;
    IF p_operation_key='POST_SESSION' THEN
      v_physical:=v_m.quantity_delta;v_valued:=0;v_unvalued:=0;v_provisional:=0;
      v_value_delta:=CASE WHEN v_cost.valued_quantity>0 THEN 0 ELSE NULL END;
      IF v_m.quantity_delta>0 THEN
        v_unvalued:=v_m.quantity_delta;
      ELSE
        v_remove_unvalued:=least(abs(v_m.quantity_delta),v_cost.unvalued_quantity);
        v_remove_valued:=abs(v_m.quantity_delta)-v_remove_unvalued;
        IF v_remove_valued>v_cost.valued_quantity THEN
          RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Opname shortage exceeds valued and unvalued costing quantity';
        END IF;
        IF v_remove_unvalued>0 THEN
          v_plan_unvalued:=public.inventory_cost_build_layer_outflow_plan(p_outlet_id,v_m.product_id,v_remove_unvalued,'UNVALUED');
          v_unvalued:=-v_remove_unvalued;
        END IF;
        IF v_remove_valued>0 THEN
          v_plan_valued:=public.inventory_cost_build_layer_outflow_plan(p_outlet_id,v_m.product_id,v_remove_valued,'VALUED');
          SELECT -coalesce(sum((x->>'provisional')::numeric),0) INTO v_provisional
          FROM jsonb_array_elements(v_plan_valued) x;
          v_valued:=-v_remove_valued;
          IF v_remove_valued=v_cost.valued_quantity THEN
            v_value_delta:=-coalesce(v_cost.inventory_value,0);
          ELSE
            v_value_delta:=-round(v_remove_valued*v_cost.current_wac,8);
          END IF;
        END IF;
      END IF;
      v_basis:=CASE WHEN v_valued<0 THEN 'CURRENT_WAC'::public.inventory_cost_acquisition_basis
        ELSE 'UNVALUED'::public.inventory_cost_acquisition_basis END;
      v_frozen_unit_cost:=CASE WHEN v_valued<0 THEN v_cost.current_wac ELSE NULL END;
      v_basis_event:=CASE WHEN v_valued<0 THEN v_cost.last_cost_event_id ELSE NULL END;
      v_value_after:=CASE WHEN v_cost.valued_quantity+v_valued=0
        THEN CASE WHEN v_m.balance_after=0 THEN 0 ELSE NULL END
        ELSE coalesce(v_cost.inventory_value,0)+v_value_delta END;
      v_wac_after:=CASE WHEN v_cost.valued_quantity+v_valued>0
        THEN round(v_value_after/(v_cost.valued_quantity+v_valued),8)::numeric(20,8) ELSE NULL END;
      v_status_after:=CASE WHEN v_m.balance_after=0 THEN 'VALUED'::public.inventory_cost_projection_status
        WHEN v_cost.valued_quantity+v_valued=0 THEN 'UNVALUED'::public.inventory_cost_projection_status
        WHEN v_cost.unvalued_quantity+v_unvalued>0 THEN 'PARTIALLY_UNVALUED'::public.inventory_cost_projection_status
        WHEN v_cost.provisional_quantity+v_provisional>0 THEN 'PROVISIONAL'::public.inventory_cost_projection_status
        ELSE 'VALUED'::public.inventory_cost_projection_status END;
      INSERT INTO public.inventory_cost_events(id,batch_id,outlet_id,product_id,event_type,source_entity_type,
        source_entity_id,source_event_id,quantity_delta,valued_quantity_before,valued_quantity_delta,
        valued_quantity_after,inventory_value_delta,inventory_value_before,inventory_value_after,wac_before,wac_after,
        valuation_status_before,valuation_status_after,cost_version_before,cost_version_after,stock_balance_version,
        stock_authority_period_id,actor_id,operation_request_id,physical_quantity_delta,physical_quantity_before,
        physical_quantity_after,provisional_quantity_delta,provisional_quantity_before,provisional_quantity_after,
        unvalued_quantity_delta,unvalued_quantity_before,unvalued_quantity_after,source_stock_movement_id,
        opname_session_id,opname_item_id,valuation_basis,frozen_unit_cost,basis_cost_event_id,metadata)
      VALUES(v_event,v_batch,p_outlet_id,v_m.product_id,v_event_type,'STOCK_OPNAME_ITEM',v_m.opname_item,
        v_m.id,v_m.quantity_delta,v_cost.valued_quantity,v_valued,v_cost.valued_quantity+v_valued,
        v_value_delta,v_cost.inventory_value,v_value_after,v_cost.current_wac,v_wac_after,v_cost.valuation_status,
        v_status_after,v_cost.cost_version,v_cost.cost_version+1,
        (SELECT p.balance_version FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id AND p.product_id=v_m.product_id),
        v_m.authority_period_id,v_actor,p_request_id,v_m.quantity_delta,v_m.balance_before,v_m.balance_after,
        v_provisional,v_cost.provisional_quantity,v_cost.provisional_quantity+v_provisional,
        v_unvalued,v_cost.unvalued_quantity,v_cost.unvalued_quantity+v_unvalued,
        v_m.id,v_m.session_id,v_m.opname_item,v_basis,v_frozen_unit_cost,v_basis_event,
        jsonb_build_object('allocationMethod','UNVALUED_FIRST_THEN_PROPORTIONAL','sourceValuesAreNotCarryingValues',true));
      IF v_m.quantity_delta>0 THEN
        PERFORM public.inventory_cost_open_source_layer(v_event);
      ELSE
        IF v_plan_unvalued<>'[]'::jsonb THEN
          PERFORM * FROM public.inventory_cost_apply_layer_plan(v_event,v_m.id,p_request_id,v_actor,
            v_cost.cost_version+1,'OUTFLOW_UNVALUED',v_plan_unvalued);
        END IF;
        IF v_plan_valued<>'[]'::jsonb THEN
          PERFORM * FROM public.inventory_cost_apply_layer_plan(v_event,v_m.id,p_request_id,v_actor,
            v_cost.cost_version+1,'OUTFLOW_VALUED',v_plan_valued);
        END IF;
      END IF;
      UPDATE public.inventory_cost_projections SET physical_quantity=v_m.balance_after,
        valued_quantity=v_cost.valued_quantity+v_valued,
        provisional_quantity=v_cost.provisional_quantity+v_provisional,
        unvalued_quantity=v_cost.unvalued_quantity+v_unvalued,
        inventory_value=v_value_after,current_wac=v_wac_after,valuation_status=v_status_after,
        cost_version=v_cost.cost_version+1,
        stock_balance_version=(SELECT p.balance_version FROM public.stock_balance_projection p
          WHERE p.outlet_id=p_outlet_id AND p.product_id=v_m.product_id),
        stock_authority_period_id=v_m.authority_period_id,last_cost_event_id=v_event,updated_at=now()
      WHERE outlet_id=p_outlet_id AND product_id=v_m.product_id;
    ELSE
      SELECT e.* INTO v_orig FROM public.inventory_cost_events e
      WHERE (e.source_stock_movement_id=v_m.reverses_movement_id OR e.stock_movement_id=v_m.reverses_movement_id)
        AND e.reverses_cost_event_id IS NULL;
      IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Original movement has no matching costing evidence; use a compensating stock correction';
      END IF;
      IF EXISTS(SELECT 1 FROM public.inventory_cost_layer_allocations later
        JOIN public.inventory_cost_layer_allocations original ON original.cost_event_id=v_orig.id
          AND original.source_layer_id=later.source_layer_id
        WHERE later.cost_version>v_orig.cost_version_after) THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Later source-layer activity prevents exact reversal; use a compensating stock correction';
      END IF;
      IF v_m.quantity_delta<>-coalesce(v_orig.physical_quantity_delta,0) THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Reversal movement does not invert its costing source';
      END IF;
      v_physical:=-coalesce(v_orig.physical_quantity_delta,0);
      v_valued:=-coalesce(v_orig.valued_quantity_delta,0);
      v_provisional:=-coalesce(v_orig.provisional_quantity_delta,0);
      v_unvalued:=-coalesce(v_orig.unvalued_quantity_delta,0);
      v_value_delta:=CASE WHEN v_orig.inventory_value_delta IS NULL THEN NULL ELSE -v_orig.inventory_value_delta END;
      v_basis:=v_orig.valuation_basis;v_frozen_unit_cost:=v_orig.frozen_unit_cost;v_basis_event:=v_orig.basis_cost_event_id;
      IF v_cost.valued_quantity+v_valued<0 OR v_cost.unvalued_quantity+v_unvalued<0
        OR v_cost.provisional_quantity+v_provisional<0
        OR v_cost.provisional_quantity+v_provisional>v_cost.valued_quantity+v_valued THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Exact cost reversal is invalid for the current costing balance';
      END IF;
      IF v_cost.valued_quantity+v_valued=0 THEN
        v_value_after:=CASE WHEN v_m.balance_after=0 THEN 0 ELSE NULL END;
      ELSE
        v_value_after:=coalesce(v_cost.inventory_value,0)+coalesce(v_value_delta,0);
        IF v_value_after<0 THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Exact cost reversal would create negative inventory value'; END IF;
      END IF;
      v_wac_after:=CASE WHEN v_cost.valued_quantity+v_valued>0
        THEN round(v_value_after/(v_cost.valued_quantity+v_valued),8)::numeric(20,8) ELSE NULL END;
      v_status_after:=CASE WHEN v_m.balance_after=0 THEN 'VALUED'::public.inventory_cost_projection_status
        WHEN v_cost.valued_quantity+v_valued=0 THEN 'UNVALUED'::public.inventory_cost_projection_status
        WHEN v_cost.unvalued_quantity+v_unvalued>0 THEN 'PARTIALLY_UNVALUED'::public.inventory_cost_projection_status
        WHEN v_cost.provisional_quantity+v_provisional>0 THEN 'PROVISIONAL'::public.inventory_cost_projection_status
        ELSE 'VALUED'::public.inventory_cost_projection_status END;
      INSERT INTO public.inventory_cost_events(id,batch_id,outlet_id,product_id,event_type,source_entity_type,
        source_entity_id,source_event_id,quantity_delta,valued_quantity_before,valued_quantity_delta,
        valued_quantity_after,inventory_value_delta,inventory_value_before,inventory_value_after,wac_before,wac_after,
        valuation_status_before,valuation_status_after,cost_version_before,cost_version_after,stock_balance_version,
        stock_authority_period_id,actor_id,operation_request_id,physical_quantity_delta,physical_quantity_before,
        physical_quantity_after,provisional_quantity_delta,provisional_quantity_before,provisional_quantity_after,
        unvalued_quantity_delta,unvalued_quantity_before,unvalued_quantity_after,source_stock_movement_id,
        reverses_cost_event_id,reverses_stock_movement_id,valuation_basis,frozen_unit_cost,basis_cost_event_id,metadata)
      VALUES(v_event,v_batch,p_outlet_id,v_m.product_id,'REVERSAL','STOCK_MOVEMENT_REVERSAL',v_m.id,
        v_orig.id,v_m.quantity_delta,v_cost.valued_quantity,v_valued,v_cost.valued_quantity+v_valued,
        v_value_delta,v_cost.inventory_value,v_value_after,v_cost.current_wac,v_wac_after,v_cost.valuation_status,
        v_status_after,v_cost.cost_version,v_cost.cost_version+1,
        (SELECT p.balance_version FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id AND p.product_id=v_m.product_id),
        v_m.authority_period_id,v_actor,p_request_id,v_m.quantity_delta,v_m.balance_before,v_m.balance_after,
        v_provisional,v_cost.provisional_quantity,v_cost.provisional_quantity+v_provisional,
        v_unvalued,v_cost.unvalued_quantity,v_cost.unvalued_quantity+v_unvalued,
        v_m.id,v_orig.id,v_m.reverses_movement_id,v_basis,v_frozen_unit_cost,v_basis_event,
        jsonb_build_object('reversesCostEventId',v_orig.id,'valueInvertedFromOriginalEvent',true));
      v_sequence:=0;
      FOR v_alloc IN SELECT a.* FROM public.inventory_cost_layer_allocations a
        WHERE a.cost_event_id=v_orig.id ORDER BY a.source_layer_id,a.id FOR UPDATE LOOP
        IF EXISTS(SELECT 1 FROM public.inventory_cost_layer_allocations x WHERE x.reverses_allocation_id=v_alloc.id) THEN
          RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Original source allocation is already reversed';
        END IF;
        INSERT INTO public.inventory_cost_layer_allocations(cost_event_id,source_layer_id,outlet_id,product_id,stock_movement_id,
          allocation_kind,physical_quantity_delta,valued_quantity_delta,provisional_quantity_delta,
          unvalued_quantity_delta,reverses_allocation_id,allocation_sequence,cost_version,request_id,actor_id)
        VALUES(v_event,v_alloc.source_layer_id,p_outlet_id,v_m.product_id,v_m.id,'REVERSAL',-v_alloc.physical_quantity_delta,
          -v_alloc.valued_quantity_delta,-v_alloc.provisional_quantity_delta,-v_alloc.unvalued_quantity_delta,
          v_alloc.id,v_sequence,v_cost.cost_version+1,p_request_id,v_actor);
        UPDATE public.inventory_cost_source_layer_balances b SET
          remaining_valued_quantity=b.remaining_valued_quantity-v_alloc.valued_quantity_delta,
          remaining_provisional_quantity=b.remaining_provisional_quantity-v_alloc.provisional_quantity_delta,
          remaining_unvalued_quantity=b.remaining_unvalued_quantity-v_alloc.unvalued_quantity_delta,
          state=CASE WHEN b.remaining_valued_quantity-v_alloc.valued_quantity_delta
            +b.remaining_unvalued_quantity-v_alloc.unvalued_quantity_delta=0
            THEN 'EXHAUSTED'::public.inventory_cost_source_layer_balance_state
            ELSE 'ACTIVE'::public.inventory_cost_source_layer_balance_state END,
          last_cost_version=v_cost.cost_version+1,last_cost_event_id=v_event,updated_at=now(),
          exhausted_at=CASE WHEN b.remaining_valued_quantity-v_alloc.valued_quantity_delta
            +b.remaining_unvalued_quantity-v_alloc.unvalued_quantity_delta=0 THEN now() ELSE NULL END
        WHERE b.layer_id=v_alloc.source_layer_id;
        IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Original source layer is unavailable for reversal'; END IF;
        v_sequence:=v_sequence+1;
      END LOOP;
      UPDATE public.inventory_cost_projections SET physical_quantity=v_m.balance_after,
        valued_quantity=v_cost.valued_quantity+v_valued,
        provisional_quantity=v_cost.provisional_quantity+v_provisional,
        unvalued_quantity=v_cost.unvalued_quantity+v_unvalued,
        inventory_value=v_value_after,current_wac=v_wac_after,valuation_status=v_status_after,
        cost_version=v_cost.cost_version+1,
        stock_balance_version=(SELECT p.balance_version FROM public.stock_balance_projection p
          WHERE p.outlet_id=p_outlet_id AND p.product_id=v_m.product_id),
        stock_authority_period_id=v_m.authority_period_id,last_cost_event_id=v_event,updated_at=now()
      WHERE outlet_id=p_outlet_id AND product_id=v_m.product_id;
    END IF;
    v_count:=v_count+1;
  END LOOP;
  IF v_count=0 THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Stock operation batch has no eligible costing movement';
  END IF;
  v_result:=jsonb_build_object('ok',true,'eventCount',v_count,'operation',p_operation_key);
  UPDATE public.inventory_cost_operation_requests SET result=v_result,completed_at=now() WHERE request_id=p_request_id;
  RETURN v_count;
END;
$$;
ALTER FUNCTION public.inventory_cost_apply_stock_movement_operation(uuid,text,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_apply_stock_movement_operation(uuid,text,uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.apply_stock_operation_intent(p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_req public.stock_operation_requests%rowtype; v_outlet uuid;
  v_operation text; v_authority public.inventory_cost_authority_status; v_result jsonb;
BEGIN
  IF v_actor IS NULL THEN RETURN public.apply_stock_operation_intent_pre_c3b(p_request_id); END IF;
  SELECT * INTO v_req FROM public.stock_operation_requests r
    WHERE r.request_id=p_request_id AND r.actor_id=v_actor;
  IF NOT FOUND OR v_req.operation_key NOT IN ('POST_SESSION','REVERSE_MOVEMENT') THEN
    RETURN public.apply_stock_operation_intent_pre_c3b(p_request_id);
  END IF;
  v_operation:=v_req.operation_key;
  IF v_operation='POST_SESSION' THEN
    SELECT s.outlet_id INTO v_outlet FROM public.stock_opname_sessions s
      WHERE s.id=(v_req.request_payload->>'session_id')::uuid;
  ELSE
    SELECT m.outlet_id INTO v_outlet FROM public.stock_movements m
      WHERE m.id=(v_req.request_payload->>'movement_id')::uuid;
  END IF;
  IF v_outlet IS NULL THEN RETURN public.apply_stock_operation_intent_pre_c3b(p_request_id); END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_BOOTSTRAP_OUTLET:'||v_outlet::text,73190411));
  SELECT * INTO v_req FROM public.stock_operation_requests r
    WHERE r.request_id=p_request_id AND r.actor_id=v_actor FOR UPDATE;
  IF NOT FOUND OR v_req.operation_key<>v_operation THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Stock operation unavailable';
  END IF;
  IF v_req.state<>'PENDING' THEN RETURN public.apply_stock_operation_intent_pre_c3b(p_request_id); END IF;
  -- The advisory lock serializes this state read with bootstrap and receipt posting.
  SELECT a.status INTO v_authority FROM public.inventory_costing_outlet_authority a WHERE a.outlet_id=v_outlet;
  IF v_authority='BOOTSTRAP_READY' THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Perubahan stok ditahan selama persiapan awal costing berlangsung';
  END IF;
  v_result:=public.apply_stock_operation_intent_pre_c3b(p_request_id);
  IF v_authority='WAC_ACTIVE' AND coalesce((v_result->>'ok')::boolean,false) THEN
    PERFORM public.inventory_cost_apply_stock_movement_operation(p_request_id,v_operation,v_outlet);
  END IF;
  RETURN v_result;
END;
$$;
ALTER FUNCTION public.apply_stock_operation_intent(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.apply_stock_operation_intent(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.apply_stock_operation_intent(uuid) TO authenticated;

ALTER FUNCTION public.inventory_cost_apply_purchase_receipt(uuid,uuid,uuid,uuid)
  RENAME TO inventory_cost_apply_purchase_receipt_pre_c3b;
REVOKE ALL ON FUNCTION public.inventory_cost_apply_purchase_receipt_pre_c3b(uuid,uuid,uuid,uuid)
  FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.inventory_cost_apply_purchase_receipt(
  p_request_id uuid,p_receipt_id uuid,p_movement_batch_id uuid,p_period_id uuid
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_count integer; v_event record;
BEGIN
  v_count:=public.inventory_cost_apply_purchase_receipt_pre_c3b(p_request_id,p_receipt_id,p_movement_batch_id,p_period_id);
  FOR v_event IN SELECT e.id FROM public.inventory_cost_events e
    WHERE e.operation_request_id=p_request_id AND e.event_type='PURCHASE_RECEIPT'::public.inventory_cost_event_type
    ORDER BY e.product_id LOOP
    PERFORM public.inventory_cost_open_source_layer(v_event.id);
  END LOOP;
  RETURN v_count;
END;
$$;
ALTER FUNCTION public.inventory_cost_apply_purchase_receipt(uuid,uuid,uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_apply_purchase_receipt(uuid,uuid,uuid,uuid)
  FROM PUBLIC,anon,authenticated,service_role;

ALTER FUNCTION public.inventory_cost_bootstrap_outlet(uuid,uuid)
  RENAME TO inventory_cost_bootstrap_outlet_pre_c3b;
REVOKE ALL ON FUNCTION public.inventory_cost_bootstrap_outlet_pre_c3b(uuid,uuid)
  FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.inventory_cost_bootstrap_outlet(p_outlet_id uuid,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_result jsonb; v_event record;
BEGIN
  v_result:=public.inventory_cost_bootstrap_outlet_pre_c3b(p_outlet_id,p_request_id);
  IF coalesce(v_result->>'code','')='BOOTSTRAP_READY' THEN
    FOR v_event IN SELECT e.id FROM public.inventory_cost_events e
      JOIN public.inventory_cost_event_batches b ON b.id=e.batch_id
      WHERE b.id=(v_result->>'batchId')::uuid AND e.event_type='OPENING'::public.inventory_cost_event_type
      ORDER BY e.product_id LOOP
      PERFORM public.inventory_cost_open_source_layer(v_event.id);
    END LOOP;
  END IF;
  RETURN v_result;
END;
$$;
ALTER FUNCTION public.inventory_cost_bootstrap_outlet(uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_bootstrap_outlet(uuid,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.inventory_cost_bootstrap_outlet(uuid,uuid) TO authenticated;

COMMIT;
