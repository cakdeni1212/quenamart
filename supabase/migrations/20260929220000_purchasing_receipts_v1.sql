-- Purchasing Phase 1: operational suppliers and physical goods receipts.
-- No prices, payables, or costing fields are introduced in this phase.
BEGIN;

CREATE TABLE public.suppliers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_code text NOT NULL UNIQUE DEFAULT ('SUP-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))),
  display_name text NOT NULL,
  legal_name text,
  phone text,
  contact_name text,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  updated_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT suppliers_code_nonblank CHECK (btrim(supplier_code) <> ''),
  CONSTRAINT suppliers_name_nonblank CHECK (btrim(display_name) <> ''),
  CONSTRAINT suppliers_legal_name_nonblank CHECK (legal_name IS NULL OR btrim(legal_name) <> ''),
  CONSTRAINT suppliers_phone_nonblank CHECK (phone IS NULL OR btrim(phone) <> '')
);

CREATE TABLE public.purchase_receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_reference text NOT NULL UNIQUE DEFAULT ('BR-' || to_char(clock_timestamp(), 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))),
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  supplier_id uuid NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  received_at timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT', 'POSTED')),
  operational_note text,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  updated_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  posted_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  posted_at timestamptz,
  draft_revision integer NOT NULL DEFAULT 1,
  CONSTRAINT purchase_receipt_note_nonblank CHECK (operational_note IS NULL OR btrim(operational_note) <> ''),
  CONSTRAINT purchase_receipt_revision_positive CHECK (draft_revision > 0),
  CONSTRAINT purchase_receipt_posting_consistent CHECK (
    (status = 'DRAFT' AND posted_by IS NULL AND posted_at IS NULL)
    OR (status = 'POSTED' AND posted_by IS NOT NULL AND posted_at IS NOT NULL)
  ),
  CONSTRAINT purchase_receipt_id_outlet_unique UNIQUE (id, outlet_id)
);
CREATE INDEX purchase_receipts_outlet_created_idx
  ON public.purchase_receipts(outlet_id, created_at DESC, id DESC);
CREATE INDEX purchase_receipts_supplier_created_idx
  ON public.purchase_receipts(supplier_id, created_at DESC, id DESC);

CREATE TABLE public.purchase_receipt_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id uuid NOT NULL REFERENCES public.purchase_receipts(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  accepted_quantity numeric NOT NULL DEFAULT 0,
  bonus_quantity numeric NOT NULL DEFAULT 0,
  rejected_quantity numeric NOT NULL DEFAULT 0,
  short_quantity numeric,
  operational_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT purchase_receipt_item_product_unique UNIQUE (receipt_id, product_id),
  CONSTRAINT purchase_receipt_item_quantity_valid CHECK (
    accepted_quantity >= 0 AND accepted_quantity < 100000000000 AND accepted_quantity = trunc(accepted_quantity, 3)
    AND bonus_quantity >= 0 AND bonus_quantity < 100000000000 AND bonus_quantity = trunc(bonus_quantity, 3)
    AND rejected_quantity >= 0 AND rejected_quantity < 100000000000 AND rejected_quantity = trunc(rejected_quantity, 3)
    AND (short_quantity IS NULL OR (short_quantity >= 0 AND short_quantity < 100000000000 AND short_quantity = trunc(short_quantity, 3)))
    AND (accepted_quantity + bonus_quantity + rejected_quantity + coalesce(short_quantity, 0)) > 0
  ),
  CONSTRAINT purchase_receipt_item_note_nonblank CHECK (operational_note IS NULL OR btrim(operational_note) <> ''),
  CONSTRAINT purchase_receipt_item_id_product_unique UNIQUE (id, product_id)
);
CREATE INDEX purchase_receipt_items_receipt_idx ON public.purchase_receipt_items(receipt_id, product_id);

CREATE TABLE public.purchase_receipt_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id uuid NOT NULL REFERENCES public.purchase_receipts(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type IN ('CREATED', 'DRAFT_UPDATED', 'POSTED')),
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  request_id uuid REFERENCES public.stock_operation_requests(request_id) ON DELETE RESTRICT,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT purchase_receipt_event_request_unique UNIQUE (request_id)
);
CREATE INDEX purchase_receipt_events_receipt_time_idx
  ON public.purchase_receipt_events(receipt_id, created_at, id);

ALTER TABLE public.stock_movements
  ADD COLUMN purchase_receipt_item_id uuid;
ALTER TABLE public.stock_movements
  ADD CONSTRAINT stock_movement_purchase_receipt_item_fk
    FOREIGN KEY (purchase_receipt_item_id, product_id)
    REFERENCES public.purchase_receipt_items(id, product_id) ON DELETE RESTRICT,
  ADD CONSTRAINT stock_movement_purchase_receipt_shape CHECK (
    (movement_type = 'PURCHASE_RECEIPT' AND purchase_receipt_item_id IS NOT NULL)
    OR (movement_type <> 'PURCHASE_RECEIPT' AND purchase_receipt_item_id IS NULL)
  );

ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_receipt_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_receipt_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.suppliers, public.purchase_receipts, public.purchase_receipt_items,
  public.purchase_receipt_events FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.suppliers, public.purchase_receipts, public.purchase_receipt_items,
  public.purchase_receipt_events TO authenticated;
CREATE POLICY suppliers_read_authorized ON public.suppliers FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role)
    AND (public.current_active_user_role() <> 'GUDANG'::public.user_role OR is_active
      OR EXISTS (SELECT 1 FROM public.purchase_receipts r WHERE r.supplier_id = suppliers.id)));
CREATE POLICY purchase_receipts_read_authorized ON public.purchase_receipts FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role));
CREATE POLICY purchase_receipt_items_read_authorized ON public.purchase_receipt_items FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role));
CREATE POLICY purchase_receipt_events_read_authorized ON public.purchase_receipt_events FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role));

CREATE FUNCTION public.guard_purchase_receipt_immutability()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Purchase receipt history cannot be deleted';
  END IF;
  IF OLD.status = 'POSTED' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Posted purchase receipts are immutable';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_purchase_receipt_immutability() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER purchase_receipt_immutable_guard BEFORE UPDATE OR DELETE ON public.purchase_receipts
  FOR EACH ROW EXECUTE FUNCTION public.guard_purchase_receipt_immutability();

CREATE FUNCTION public.guard_purchase_receipt_item_draft()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE v_receipt_id uuid;
BEGIN
  v_receipt_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.receipt_id ELSE NEW.receipt_id END;
  IF TG_OP = 'UPDATE' AND NEW.receipt_id <> OLD.receipt_id THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Receipt item cannot move between receipts';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.purchase_receipts r WHERE r.id = v_receipt_id AND r.status = 'DRAFT' FOR KEY SHARE) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Receipt items are editable only while draft';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_purchase_receipt_item_draft() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER purchase_receipt_item_draft_guard BEFORE INSERT OR UPDATE OR DELETE ON public.purchase_receipt_items
  FOR EACH ROW EXECUTE FUNCTION public.guard_purchase_receipt_item_draft();

CREATE FUNCTION public.purchase_supplier_upsert(p_supplier_id uuid, p_display_name text, p_legal_name text,
  p_phone text, p_contact_name text, p_is_active boolean)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_actor uuid := auth.uid(); v_id uuid;
BEGIN
  IF v_actor IS NULL OR public.current_active_user_role() IS NULL
    OR public.current_active_user_role() NOT IN ('OWNER'::public.user_role, 'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Supplier management permission denied';
  END IF;
  IF p_display_name IS NULL OR btrim(p_display_name) = '' OR length(btrim(p_display_name)) > 160
    OR (p_legal_name IS NOT NULL AND (btrim(p_legal_name) = '' OR length(btrim(p_legal_name)) > 200))
    OR (p_phone IS NOT NULL AND (btrim(p_phone) = '' OR length(btrim(p_phone)) > 40))
    OR (p_contact_name IS NOT NULL AND (btrim(p_contact_name) = '' OR length(btrim(p_contact_name)) > 120)) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supplier fields are invalid';
  END IF;
  IF p_supplier_id IS NULL THEN
    INSERT INTO public.suppliers(display_name, legal_name, phone, contact_name, is_active, created_by, updated_by)
    VALUES (btrim(p_display_name), nullif(btrim(p_legal_name), ''), nullif(btrim(p_phone), ''),
      nullif(btrim(p_contact_name), ''), coalesce(p_is_active, true), v_actor, v_actor)
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.suppliers SET display_name = btrim(p_display_name), legal_name = nullif(btrim(p_legal_name), ''),
      phone = nullif(btrim(p_phone), ''), contact_name = nullif(btrim(p_contact_name), ''),
      is_active = coalesce(p_is_active, is_active), updated_by = v_actor, updated_at = now()
    WHERE id = p_supplier_id RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Supplier not found'; END IF;
  END IF;
  RETURN v_id;
END;
$$;
ALTER FUNCTION public.purchase_supplier_upsert(uuid,text,text,text,text,boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_supplier_upsert(uuid,text,text,text,text,boolean) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.purchase_supplier_upsert(uuid,text,text,text,text,boolean) TO authenticated;

CREATE FUNCTION public.purchase_receipt_create_draft(p_outlet_id uuid, p_supplier_id uuid, p_received_at timestamptz, p_note text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_actor uuid := auth.uid(); v_role public.user_role; v_id uuid;
BEGIN
  v_role := public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Goods receipt access denied';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.outlets WHERE id = p_outlet_id AND is_active)
    OR NOT EXISTS (SELECT 1 FROM public.suppliers WHERE id = p_supplier_id AND is_active)
    OR p_received_at IS NULL OR (p_note IS NOT NULL AND (btrim(p_note) = '' OR length(p_note) > 1000)) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Receipt header is invalid';
  END IF;
  INSERT INTO public.purchase_receipts(outlet_id, supplier_id, received_at, operational_note, created_by, updated_by)
  VALUES (p_outlet_id, p_supplier_id, p_received_at, nullif(btrim(p_note), ''), v_actor, v_actor) RETURNING id INTO v_id;
  INSERT INTO public.purchase_receipt_events(receipt_id, event_type, actor_id) VALUES (v_id, 'CREATED', v_actor);
  RETURN v_id;
END;
$$;
ALTER FUNCTION public.purchase_receipt_create_draft(uuid,uuid,timestamptz,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_receipt_create_draft(uuid,uuid,timestamptz,text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.purchase_receipt_create_draft(uuid,uuid,timestamptz,text) TO authenticated;

CREATE FUNCTION public.purchase_receipt_save_draft(p_receipt_id uuid, p_expected_revision integer,
  p_received_at timestamptz, p_note text, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_actor uuid := auth.uid(); v_role public.user_role; v_receipt public.purchase_receipts%rowtype; v_row jsonb; v_product uuid; v_count integer := 0;
BEGIN
  v_role := public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Goods receipt access denied';
  END IF;
  IF p_receipt_id IS NULL OR p_expected_revision IS NULL OR p_expected_revision < 1
    OR p_received_at IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) > 500
    OR (p_note IS NOT NULL AND (btrim(p_note) = '' OR length(p_note) > 1000)) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Receipt draft is invalid';
  END IF;
  SELECT * INTO v_receipt FROM public.purchase_receipts WHERE id = p_receipt_id FOR UPDATE;
  IF NOT FOUND OR v_receipt.status <> 'DRAFT' THEN RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Receipt is not editable'; END IF;
  IF v_receipt.draft_revision <> p_expected_revision THEN RETURN jsonb_build_object('ok',false,'code','DRAFT_CHANGED','revision',v_receipt.draft_revision); END IF;
  IF jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'At least one receipt item is required'; END IF;
  IF (SELECT count(DISTINCT x.product_id) FROM jsonb_to_recordset(p_items) AS x(product_id uuid)) <> jsonb_array_length(p_items) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A product may appear only once on a receipt';
  END IF;
  UPDATE public.purchase_receipts SET received_at = p_received_at, operational_note = nullif(btrim(p_note), ''),
    updated_by = v_actor, updated_at = now(), draft_revision = draft_revision + 1 WHERE id = p_receipt_id;
  DELETE FROM public.purchase_receipt_items WHERE receipt_id = p_receipt_id;
  FOR v_row IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    v_product := (v_row->>'product_id')::uuid;
    IF v_product IS NULL OR NOT EXISTS (SELECT 1 FROM public.products p WHERE p.id = v_product) THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Receipt product is unavailable';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_object_keys(v_row) AS keys(key) WHERE key NOT IN
      ('product_id','accepted_quantity','bonus_quantity','rejected_quantity','short_quantity','operational_note')) THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Unsupported receipt item field';
    END IF;
    IF v_row ? 'operational_note' AND jsonb_typeof(v_row->'operational_note') NOT IN ('string','null') THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Receipt item note must be text';
    END IF;
    IF length(v_row->>'operational_note') > 300 THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Receipt item note is too long';
    END IF;
    INSERT INTO public.purchase_receipt_items(receipt_id, product_id, accepted_quantity, bonus_quantity,
      rejected_quantity, short_quantity, operational_note)
    VALUES (p_receipt_id, v_product, coalesce((v_row->>'accepted_quantity')::numeric,0),
      coalesce((v_row->>'bonus_quantity')::numeric,0), coalesce((v_row->>'rejected_quantity')::numeric,0),
      nullif(v_row->>'short_quantity','')::numeric, nullif(btrim(v_row->>'operational_note'),''));
    v_count := v_count + 1;
  END LOOP;
  INSERT INTO public.purchase_receipt_events(receipt_id,event_type,actor_id,note)
  VALUES (p_receipt_id,'DRAFT_UPDATED',v_actor,'Item: ' || v_count::text);
  RETURN jsonb_build_object('ok',true,'revision',p_expected_revision + 1);
END;
$$;
ALTER FUNCTION public.purchase_receipt_save_draft(uuid,integer,timestamptz,text,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_receipt_save_draft(uuid,integer,timestamptz,text,jsonb) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.purchase_receipt_save_draft(uuid,integer,timestamptz,text,jsonb) TO authenticated;

CREATE FUNCTION public.issue_purchase_receipt_post_intent(p_receipt_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_actor uuid := auth.uid(); v_role public.user_role; v_receipt public.purchase_receipts%rowtype;
  v_payload jsonb; v_hash text; v_existing public.stock_operation_requests%rowtype; v_id uuid;
BEGIN
  v_role := public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Receipt posting access denied';
  END IF;
  SELECT * INTO v_receipt FROM public.purchase_receipts WHERE id = p_receipt_id;
  IF NOT FOUND OR v_receipt.status <> 'DRAFT' THEN RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Receipt is not a draft'; END IF;
  v_payload := jsonb_build_object('receipt_id',p_receipt_id,'draft_revision',v_receipt.draft_revision,
    'content_hash',md5(v_receipt.id::text || ':' || v_receipt.supplier_id::text || ':' || v_receipt.outlet_id::text || ':' ||
      v_receipt.received_at::text || ':' || coalesce(v_receipt.operational_note,'') || ':' ||
      (SELECT coalesce(string_agg(i.product_id::text || ':' || i.accepted_quantity::text || ':' || i.bonus_quantity::text || ':' ||
        i.rejected_quantity::text || ':' || coalesce(i.short_quantity::text,'') || ':' || coalesce(i.operational_note,''), '|' ORDER BY i.product_id), '')
       FROM public.purchase_receipt_items i WHERE i.receipt_id = p_receipt_id)));
  v_hash := md5(v_payload::text);
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_actor::text || ':POST_PURCHASE_RECEIPT:' || p_receipt_id::text, 73190411));
  SELECT * INTO v_existing FROM public.stock_operation_requests WHERE actor_id = v_actor
    AND operation_key = 'POST_PURCHASE_RECEIPT' AND target_key = p_receipt_id::text AND state = 'PENDING' FOR UPDATE;
  IF FOUND THEN
    IF v_existing.payload_hash = v_hash AND v_existing.request_payload = v_payload THEN RETURN v_existing.request_id; END IF;
    UPDATE public.stock_operation_requests SET state='SUPERSEDED', result=jsonb_build_object('ok',false,'code','INTENT_SUPERSEDED'), completed_at=now()
      WHERE request_id=v_existing.request_id;
  END IF;
  INSERT INTO public.stock_operation_requests(actor_id,operation_key,target_key,request_payload,payload_hash)
  VALUES(v_actor,'POST_PURCHASE_RECEIPT',p_receipt_id::text,v_payload,v_hash) RETURNING request_id INTO v_id;
  RETURN v_id;
END;
$$;
ALTER FUNCTION public.issue_purchase_receipt_post_intent(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.issue_purchase_receipt_post_intent(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.issue_purchase_receipt_post_intent(uuid) TO authenticated;

CREATE FUNCTION public.apply_purchase_receipt_post_intent(p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_actor uuid := auth.uid(); v_role public.user_role; v_req public.stock_operation_requests%rowtype;
  v_receipt public.purchase_receipts%rowtype; v_period public.stock_authority_periods%rowtype; v_projection public.stock_balance_projection%rowtype;
  v_item record; v_batch uuid; v_before numeric; v_after numeric; v_version bigint; v_delta numeric; v_count integer := 0; v_hash text;
BEGIN
  v_role := public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Receipt posting access denied';
  END IF;
  SELECT * INTO v_req FROM public.stock_operation_requests WHERE request_id=p_request_id AND actor_id=v_actor FOR UPDATE;
  IF NOT FOUND OR v_req.operation_key <> 'POST_PURCHASE_RECEIPT' THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Receipt request unavailable'; END IF;
  IF v_req.state IN ('COMPLETED','STALE','SUPERSEDED') THEN RETURN v_req.result; END IF;
  SELECT * INTO v_receipt FROM public.purchase_receipts WHERE id=(v_req.request_payload->>'receipt_id')::uuid FOR UPDATE;
  IF NOT FOUND OR v_receipt.status <> 'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='Receipt is not a draft'; END IF;
  v_hash := md5(v_receipt.id::text || ':' || v_receipt.supplier_id::text || ':' || v_receipt.outlet_id::text || ':' ||
    v_receipt.received_at::text || ':' || coalesce(v_receipt.operational_note,'') || ':' ||
    (SELECT coalesce(string_agg(i.product_id::text || ':' || i.accepted_quantity::text || ':' || i.bonus_quantity::text || ':' ||
      i.rejected_quantity::text || ':' || coalesce(i.short_quantity::text,'') || ':' || coalesce(i.operational_note,''), '|' ORDER BY i.product_id), '')
     FROM public.purchase_receipt_items i WHERE i.receipt_id = v_receipt.id));
  IF (v_req.request_payload->>'content_hash') IS DISTINCT FROM v_hash
    OR (v_req.request_payload->>'draft_revision')::integer IS DISTINCT FROM v_receipt.draft_revision THEN
    UPDATE public.stock_operation_requests SET state='STALE',result=jsonb_build_object('ok',false,'code','RECEIPT_CHANGED'),completed_at=now()
      WHERE request_id=v_req.request_id;
    RETURN jsonb_build_object('ok',false,'code','RECEIPT_CHANGED');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.suppliers WHERE id=v_receipt.supplier_id AND is_active)
    OR NOT EXISTS (SELECT 1 FROM public.outlets WHERE id=v_receipt.outlet_id AND is_active)
    OR NOT EXISTS (SELECT 1 FROM public.purchase_receipt_items i WHERE i.receipt_id=v_receipt.id AND i.accepted_quantity+i.bonus_quantity>0) THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Receipt is incomplete or unavailable';
  END IF;
  FOR v_item IN SELECT i.* FROM public.purchase_receipt_items i WHERE i.receipt_id=v_receipt.id ORDER BY i.product_id LOOP
    v_delta := v_item.accepted_quantity + v_item.bonus_quantity;
    IF v_delta <= 0 THEN CONTINUE; END IF;
    SELECT * INTO v_projection FROM public.stock_balance_projection p WHERE p.product_id=v_item.product_id AND p.outlet_id=v_receipt.outlet_id FOR UPDATE;
    IF NOT FOUND OR v_projection.effective_quantity IS NULL THEN
      RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Stock projection is unavailable for this outlet period';
    END IF;
  END LOOP;
  -- Match existing stock-operation lock order: projection rows by product ID,
  -- then authority period. This avoids reversing POST_SESSION's lock sequence.
  SELECT * INTO v_period FROM public.stock_authority_periods WHERE outlet_id=v_receipt.outlet_id AND ended_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Stock authority period is unavailable'; END IF;
  IF EXISTS (SELECT 1 FROM public.purchase_receipt_items i
    JOIN public.stock_balance_projection p ON p.product_id=i.product_id AND p.outlet_id=v_receipt.outlet_id
    WHERE i.receipt_id=v_receipt.id AND i.accepted_quantity+i.bonus_quantity>0
      AND p.authority_period_id<>v_period.id) THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Stock projection is unavailable for this outlet period';
  END IF;
  INSERT INTO public.stock_movement_batches(authority_period_id,outlet_id,source_system,operation_request_id,created_by)
  VALUES(v_period.id,v_receipt.outlet_id,'PURCHASING',v_req.request_id,v_actor) RETURNING id INTO v_batch;
  FOR v_item IN SELECT i.* FROM public.purchase_receipt_items i WHERE i.receipt_id=v_receipt.id ORDER BY i.product_id LOOP
    v_delta := v_item.accepted_quantity + v_item.bonus_quantity;
    IF v_delta <= 0 THEN CONTINUE; END IF;
    SELECT d.balance_before,d.balance_after,d.new_balance_version INTO v_before,v_after,v_version
      FROM public.stock_apply_balance_delta(v_item.product_id,v_receipt.outlet_id,v_delta) d;
    INSERT INTO public.stock_movements(batch_id,authority_period_id,outlet_id,product_id,movement_type,source_system,
      quantity_delta,balance_before,balance_after,purchase_receipt_item_id,source_reference,source_event_key,created_by)
    VALUES(v_batch,v_period.id,v_receipt.outlet_id,v_item.product_id,'PURCHASE_RECEIPT','PURCHASING',v_delta,v_before,v_after,
      v_item.id,v_receipt.receipt_reference,v_receipt.id::text || ':' || v_item.id::text,v_actor);
    INSERT INTO public.stock_balance_projection_events(product_id,outlet_id,authority_period_id,event_type,request_id,
      quantity_delta,balance_before,balance_after,balance_version,actor_id)
    VALUES(v_item.product_id,v_receipt.outlet_id,v_period.id,'MOVEMENT_POSTED',v_req.request_id,v_delta,v_before,v_after,v_version,v_actor);
    v_count := v_count + 1;
  END LOOP;
  UPDATE public.purchase_receipts SET status='POSTED',posted_by=v_actor,posted_at=now(),updated_by=v_actor,updated_at=now()
    WHERE id=v_receipt.id;
  INSERT INTO public.purchase_receipt_events(receipt_id,event_type,actor_id,request_id)
    VALUES(v_receipt.id,'POSTED',v_actor,v_req.request_id);
  UPDATE public.stock_operation_requests SET state='COMPLETED',result=jsonb_build_object('ok',true,'code','POSTED',
    'receiptId',v_receipt.id,'movementBatchId',v_batch,'movementCount',v_count),completed_at=now()
    WHERE request_id=v_req.request_id;
  RETURN jsonb_build_object('ok',true,'code','POSTED','receiptId',v_receipt.id,'movementBatchId',v_batch,'movementCount',v_count);
END;
$$;
ALTER FUNCTION public.apply_purchase_receipt_post_intent(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.apply_purchase_receipt_post_intent(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.apply_purchase_receipt_post_intent(uuid) TO authenticated;

CREATE FUNCTION public.purchase_receipt_product_search(p_search text, p_page integer DEFAULT 1)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = pg_catalog AS $$
DECLARE v_role public.user_role; v_term text := btrim(coalesce(p_search,'')); v_page integer := greatest(coalesce(p_page,1),1);
BEGIN
  v_role := public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'GUDANG'::public.user_role) THEN
    RETURN jsonb_build_object('ok',false,'code','FORBIDDEN');
  END IF;
  IF length(v_term)<2 OR length(v_term)>100 THEN RETURN jsonb_build_object('ok',true,'rows','[]'::jsonb,'page',v_page); END IF;
  RETURN jsonb_build_object('ok',true,'rows',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.name,x.sku,x.id) FROM (
    SELECT p.id,p.name,p.sku,
      (SELECT b.barcode FROM public.product_barcodes b WHERE b.product_id=p.id AND b.is_active ORDER BY b.created_at,b.id LIMIT 1) AS barcode
    FROM public.products p
    WHERE p.name ILIKE '%'||v_term||'%' OR p.sku ILIKE '%'||v_term||'%' OR EXISTS
      (SELECT 1 FROM public.product_barcodes b WHERE b.product_id=p.id AND b.is_active AND b.barcode=v_term)
    ORDER BY p.name,p.sku,p.id LIMIT 25 OFFSET (v_page-1)*25
  ) x),'[]'::jsonb),'page',v_page);
END;
$$;
REVOKE ALL ON FUNCTION public.purchase_receipt_product_search(text,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_receipt_product_search(text,integer) TO authenticated;

CREATE FUNCTION public.purchase_receipt_resolve_barcode(p_barcode text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = pg_catalog AS $$
DECLARE v_role public.user_role; v_count integer; v_product jsonb;
BEGIN
  v_role := public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'GUDANG'::public.user_role) THEN
    RETURN jsonb_build_object('ok',false,'code','FORBIDDEN');
  END IF;
  IF p_barcode IS NULL OR btrim(p_barcode) = '' OR length(p_barcode) > 160 THEN
    RETURN jsonb_build_object('ok',false,'code','INVALID_BARCODE');
  END IF;
  SELECT count(*)::integer INTO v_count FROM (SELECT DISTINCT b.product_id FROM public.product_barcodes b
    WHERE b.is_active AND b.barcode = btrim(p_barcode)) matches;
  IF v_count = 0 THEN RETURN jsonb_build_object('ok',false,'code','BARCODE_NOT_FOUND'); END IF;
  IF v_count > 1 THEN RETURN jsonb_build_object('ok',false,'code','BARCODE_AMBIGUOUS'); END IF;
  SELECT jsonb_build_object('id',p.id,'name',p.name,'sku',p.sku,'barcode',b.barcode)
    INTO v_product FROM public.product_barcodes b JOIN public.products p ON p.id=b.product_id
    WHERE b.is_active AND b.barcode=btrim(p_barcode) ORDER BY b.created_at,b.id LIMIT 1;
  RETURN jsonb_build_object('ok',true,'code','BARCODE_MATCH','product',v_product);
END;
$$;
REVOKE ALL ON FUNCTION public.purchase_receipt_resolve_barcode(text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_receipt_resolve_barcode(text) TO authenticated;

COMMIT;
