-- C3A: protected receipt acquisition evidence and atomic PURCHASE_RECEIPT WAC events.
-- Capability only: this does not create costing authority, bootstrap, or activate WAC.
BEGIN;

CREATE TYPE public.inventory_cost_projection_status AS ENUM
  ('VALUED','PROVISIONAL','PARTIALLY_UNVALUED','UNVALUED');
CREATE TYPE public.purchase_receipt_acquisition_evidence_kind AS ENUM
  ('MANAGER_ESTIMATE','AUTHORITATIVE_ZERO','REMOVED');
CREATE TYPE public.inventory_cost_acquisition_basis AS ENUM
  ('MANAGER_ESTIMATE','AUTHORITATIVE_ZERO','CURRENT_WAC','VERIFIED_IPOS_HPP','UNVALUED');

-- Existing valuation_status values are migrated to the expanded projection contract.
ALTER TABLE public.inventory_cost_projections
  DROP CONSTRAINT inventory_cost_projection_valuation_consistent;
ALTER TABLE public.inventory_cost_events
  ALTER COLUMN valuation_status_before TYPE public.inventory_cost_projection_status
    USING valuation_status_before::text::public.inventory_cost_projection_status,
  ALTER COLUMN valuation_status_after TYPE public.inventory_cost_projection_status
    USING valuation_status_after::text::public.inventory_cost_projection_status;
ALTER TABLE public.inventory_cost_projections
  ALTER COLUMN valuation_status TYPE public.inventory_cost_projection_status
    USING valuation_status::text::public.inventory_cost_projection_status;

ALTER TABLE public.inventory_cost_projections
  ADD COLUMN physical_quantity numeric,
  ADD COLUMN provisional_quantity numeric NOT NULL DEFAULT 0,
  ADD COLUMN unvalued_quantity numeric NOT NULL DEFAULT 0;

-- Backfill only the costing projection shape. Stock remains the sole quantity authority.
UPDATE public.inventory_cost_projections cp
SET physical_quantity = sb.effective_quantity,
    valued_quantity = CASE WHEN cp.valuation_status='UNVALUED' THEN 0 ELSE coalesce(cp.valued_quantity,0) END,
    provisional_quantity = CASE WHEN cp.valuation_status='PROVISIONAL' THEN
      CASE WHEN cp.valuation_status='UNVALUED' THEN 0 ELSE coalesce(cp.valued_quantity,0) END ELSE 0 END,
    unvalued_quantity = CASE WHEN cp.valuation_status='UNVALUED' THEN coalesce(sb.effective_quantity,0)
      ELSE coalesce(sb.effective_quantity,0)-coalesce(cp.valued_quantity,0) END
FROM public.stock_balance_projection sb
WHERE sb.outlet_id=cp.outlet_id AND sb.product_id=cp.product_id;

ALTER TABLE public.inventory_cost_events
  ADD COLUMN physical_quantity_delta numeric,
  ADD COLUMN physical_quantity_before numeric,
  ADD COLUMN physical_quantity_after numeric,
  ADD COLUMN valued_quantity_delta numeric,
  ADD COLUMN provisional_quantity_delta numeric,
  ADD COLUMN provisional_quantity_before numeric,
  ADD COLUMN provisional_quantity_after numeric,
  ADD COLUMN unvalued_quantity_delta numeric,
  ADD COLUMN unvalued_quantity_before numeric,
  ADD COLUMN unvalued_quantity_after numeric,
  ADD COLUMN valuation_basis public.inventory_cost_acquisition_basis,
  ADD COLUMN frozen_unit_cost numeric(20,8),
  ADD COLUMN basis_cost_event_id uuid REFERENCES public.inventory_cost_events(id) ON DELETE RESTRICT,
  ADD COLUMN receipt_id uuid REFERENCES public.purchase_receipts(id) ON DELETE RESTRICT,
  ADD COLUMN receipt_item_id uuid REFERENCES public.purchase_receipt_items(id) ON DELETE RESTRICT,
  ADD COLUMN stock_movement_id uuid REFERENCES public.stock_movements(id) ON DELETE RESTRICT,
  ADD COLUMN stock_request_id uuid REFERENCES public.stock_operation_requests(request_id) ON DELETE RESTRICT,
  ADD COLUMN acquisition_evidence_revision integer;

ALTER TABLE public.inventory_cost_projections
  ALTER COLUMN physical_quantity SET NOT NULL,
  ADD CONSTRAINT inventory_cost_projection_state_consistent CHECK (
    physical_quantity >= 0 AND physical_quantity < 100000000000 AND physical_quantity=trunc(physical_quantity,3)
    AND valued_quantity IS NOT NULL AND valued_quantity >= 0 AND valued_quantity < 100000000000
      AND valued_quantity=trunc(valued_quantity,3)
    AND provisional_quantity >= 0 AND provisional_quantity <= valued_quantity
      AND provisional_quantity=trunc(provisional_quantity,3)
    AND unvalued_quantity >= 0 AND unvalued_quantity=trunc(unvalued_quantity,3)
    AND physical_quantity=valued_quantity+unvalued_quantity
    AND ((valued_quantity=0 AND current_wac IS NULL AND
          (inventory_value IS NULL OR (physical_quantity=0 AND inventory_value=0)))
      OR (valued_quantity>0 AND inventory_value IS NOT NULL AND current_wac IS NOT NULL
          AND current_wac=round(inventory_value/valued_quantity,8)))
    AND ((physical_quantity=0 AND valued_quantity=0 AND unvalued_quantity=0
          AND provisional_quantity=0 AND valuation_status='VALUED' AND inventory_value=0 AND current_wac IS NULL)
      OR (physical_quantity>0 AND valued_quantity=0 AND unvalued_quantity=physical_quantity
          AND provisional_quantity=0 AND valuation_status='UNVALUED' AND inventory_value IS NULL AND current_wac IS NULL)
      OR (physical_quantity>0 AND valued_quantity>0 AND unvalued_quantity>0
          AND valuation_status='PARTIALLY_UNVALUED')
      OR (physical_quantity>0 AND valued_quantity=physical_quantity AND unvalued_quantity=0
          AND provisional_quantity>0 AND valuation_status='PROVISIONAL')
      OR (physical_quantity>0 AND valued_quantity=physical_quantity AND unvalued_quantity=0
          AND provisional_quantity=0 AND valuation_status='VALUED'))
  ),
  ADD CONSTRAINT inventory_cost_projection_stock_quantity_fk FOREIGN KEY (product_id,outlet_id)
    REFERENCES public.stock_balance_projection(product_id,outlet_id) ON DELETE RESTRICT;

ALTER TABLE public.inventory_cost_events
  ADD CONSTRAINT inventory_cost_event_projection_state_valid CHECK (
    (physical_quantity_delta IS NULL OR physical_quantity_delta=trunc(physical_quantity_delta,3))
    AND (physical_quantity_before IS NULL OR (physical_quantity_before>=0 AND physical_quantity_before=trunc(physical_quantity_before,3)))
    AND (physical_quantity_after IS NULL OR (physical_quantity_after>=0 AND physical_quantity_after=trunc(physical_quantity_after,3)))
    AND (valued_quantity_delta IS NULL OR valued_quantity_delta=trunc(valued_quantity_delta,3))
    AND (provisional_quantity_delta IS NULL OR provisional_quantity_delta=trunc(provisional_quantity_delta,3))
    AND (provisional_quantity_before IS NULL OR (provisional_quantity_before>=0 AND provisional_quantity_before=trunc(provisional_quantity_before,3)))
    AND (provisional_quantity_after IS NULL OR (provisional_quantity_after>=0 AND provisional_quantity_after=trunc(provisional_quantity_after,3)))
    AND (unvalued_quantity_delta IS NULL OR unvalued_quantity_delta=trunc(unvalued_quantity_delta,3))
    AND (unvalued_quantity_before IS NULL OR (unvalued_quantity_before>=0 AND unvalued_quantity_before=trunc(unvalued_quantity_before,3)))
    AND (unvalued_quantity_after IS NULL OR (unvalued_quantity_after>=0 AND unvalued_quantity_after=trunc(unvalued_quantity_after,3)))
    AND (frozen_unit_cost IS NULL OR (frozen_unit_cost>=0 AND frozen_unit_cost<1000000000000))
    AND ((valuation_basis='CURRENT_WAC' AND basis_cost_event_id IS NOT NULL)
      OR (valuation_basis IS DISTINCT FROM 'CURRENT_WAC' AND basis_cost_event_id IS NULL))
    AND (acquisition_evidence_revision IS NULL OR acquisition_evidence_revision>0)
    AND ((receipt_id IS NULL AND receipt_item_id IS NULL AND stock_movement_id IS NULL AND stock_request_id IS NULL)
      OR (receipt_id IS NOT NULL AND receipt_item_id IS NOT NULL AND stock_movement_id IS NOT NULL AND stock_request_id IS NOT NULL))
  );
CREATE UNIQUE INDEX inventory_cost_purchase_receipt_item_once
  ON public.inventory_cost_events(receipt_item_id)
  WHERE event_type='PURCHASE_RECEIPT' AND receipt_item_id IS NOT NULL;
ALTER TABLE public.purchase_receipt_items
  ADD CONSTRAINT purchase_receipt_item_receipt_product_identity UNIQUE(id,receipt_id,product_id);
ALTER TABLE public.inventory_cost_events
  ADD CONSTRAINT inventory_cost_event_receipt_item_identity_fk
    FOREIGN KEY(receipt_item_id,receipt_id,product_id)
    REFERENCES public.purchase_receipt_items(id,receipt_id,product_id) ON DELETE RESTRICT,
  ADD CONSTRAINT inventory_cost_event_stock_movement_identity_fk
    FOREIGN KEY(stock_movement_id,product_id,outlet_id)
    REFERENCES public.stock_movements(id,product_id,outlet_id) ON DELETE RESTRICT;

ALTER TABLE public.inventory_cost_operation_requests
  DROP CONSTRAINT inventory_cost_operation_requests_operation_key_check,
  ADD CONSTRAINT inventory_cost_operation_requests_operation_key_check
    CHECK (operation_key IN ('BOOTSTRAP_OUTLET','PURCHASE_RECEIPT'));

-- Append-only, manager-only versions. REMOVED is a tombstone; prior revisions remain auditable.
CREATE TABLE public.purchase_receipt_acquisition_estimate_revisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  receipt_id uuid NOT NULL REFERENCES public.purchase_receipts(id) ON DELETE RESTRICT,
  receipt_item_identity uuid NOT NULL,
  receipt_item_id uuid NOT NULL,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  revision integer NOT NULL CHECK (revision>0),
  evidence_kind public.purchase_receipt_acquisition_evidence_kind NOT NULL,
  estimated_unit_price numeric(20,2),
  currency text NOT NULL DEFAULT 'IDR' CHECK (currency='IDR'),
  evidence_reference text,
  reason text,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT purchase_receipt_estimate_revision_unique UNIQUE(receipt_item_identity,revision),
  CONSTRAINT purchase_receipt_estimate_item_identity CHECK (receipt_item_id=receipt_item_identity),
  CONSTRAINT purchase_receipt_estimate_receipt_outlet_fk FOREIGN KEY(receipt_id,outlet_id)
    REFERENCES public.purchase_receipts(id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT purchase_receipt_estimate_value_valid CHECK (
    (evidence_kind='MANAGER_ESTIMATE' AND estimated_unit_price>0 AND estimated_unit_price<1000000000000
      AND estimated_unit_price=trunc(estimated_unit_price,2))
    OR (evidence_kind='AUTHORITATIVE_ZERO' AND estimated_unit_price=0 AND reason IS NOT NULL AND btrim(reason)<>'')
    OR (evidence_kind='REMOVED' AND estimated_unit_price IS NULL)
  ),
  CONSTRAINT purchase_receipt_estimate_text_valid CHECK (
    (reason IS NULL OR (btrim(reason)<>'' AND length(reason)<=1000))
    AND (evidence_reference IS NULL OR (btrim(evidence_reference)<>'' AND length(evidence_reference)<=300))
  )
);
CREATE INDEX purchase_receipt_estimate_current_idx
  ON public.purchase_receipt_acquisition_estimate_revisions(receipt_item_identity,revision DESC);
ALTER TABLE public.purchase_receipt_acquisition_estimate_revisions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.purchase_receipt_acquisition_estimate_revisions FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.purchase_receipt_acquisition_estimate_revisions TO authenticated;
CREATE POLICY purchase_receipt_acquisition_estimate_manager_read
  ON public.purchase_receipt_acquisition_estimate_revisions FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));

CREATE FUNCTION public.guard_purchase_receipt_acquisition_estimate_immutable()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='Receipt acquisition estimate revisions are immutable';
END;
$$;
ALTER FUNCTION public.guard_purchase_receipt_acquisition_estimate_immutable() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_purchase_receipt_acquisition_estimate_immutable() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER purchase_receipt_estimate_immutable
  BEFORE UPDATE OR DELETE ON public.purchase_receipt_acquisition_estimate_revisions
  FOR EACH ROW EXECUTE FUNCTION public.guard_purchase_receipt_acquisition_estimate_immutable();

CREATE FUNCTION public.append_purchase_receipt_estimate_revision(
  p_receipt_id uuid,p_item_id uuid,p_product_id uuid,p_outlet_id uuid,
  p_kind public.purchase_receipt_acquisition_evidence_kind,p_price numeric,p_reason text,p_reference text
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_revision integer; v_actor uuid:=auth.uid();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Authentication required'; END IF;
  SELECT coalesce(max(r.revision),0)+1 INTO v_revision
  FROM public.purchase_receipt_acquisition_estimate_revisions r
  WHERE r.receipt_item_identity=p_item_id;
  INSERT INTO public.purchase_receipt_acquisition_estimate_revisions(
    outlet_id,receipt_id,receipt_item_identity,receipt_item_id,product_id,revision,evidence_kind,
    estimated_unit_price,reason,evidence_reference,created_by)
  VALUES(p_outlet_id,p_receipt_id,p_item_id,p_item_id,p_product_id,v_revision,p_kind,p_price,
    nullif(btrim(p_reason),''),nullif(btrim(p_reference),''),v_actor);
  RETURN v_revision;
END;
$$;
ALTER FUNCTION public.append_purchase_receipt_estimate_revision(uuid,uuid,uuid,uuid,public.purchase_receipt_acquisition_evidence_kind,numeric,text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.append_purchase_receipt_estimate_revision(uuid,uuid,uuid,uuid,public.purchase_receipt_acquisition_evidence_kind,numeric,text,text) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.purchase_receipt_acquisition_estimate_save(
  p_receipt_id uuid,p_receipt_item_id uuid,p_expected_draft_revision integer,
  p_expected_evidence_revision integer,p_evidence_kind text,p_unit_price numeric,
  p_reason text DEFAULT NULL,p_reference text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_receipt public.purchase_receipts%rowtype;
  v_item public.purchase_receipt_items%rowtype; v_latest public.purchase_receipt_acquisition_estimate_revisions%rowtype;
  v_kind public.purchase_receipt_acquisition_evidence_kind; v_revision integer; v_new_draft_revision integer;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Acquisition estimate management denied';
  END IF;
  IF p_receipt_id IS NULL OR p_receipt_item_id IS NULL OR p_expected_draft_revision IS NULL OR p_expected_draft_revision<1
    OR p_expected_evidence_revision IS NULL OR p_expected_evidence_revision<0
    OR p_evidence_kind IS NULL OR p_evidence_kind NOT IN ('MANAGER_ESTIMATE','AUTHORITATIVE_ZERO','REMOVE')
    OR (p_reason IS NOT NULL AND (btrim(p_reason)='' OR length(p_reason)>1000))
    OR (p_reference IS NOT NULL AND (btrim(p_reference)='' OR length(p_reference)>300)) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Acquisition estimate input is invalid';
  END IF;
  SELECT * INTO v_receipt FROM public.purchase_receipts r WHERE r.id=p_receipt_id FOR UPDATE;
  IF NOT FOUND OR v_receipt.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Receipt is not editable'; END IF;
  IF v_receipt.draft_revision<>p_expected_draft_revision THEN
    RETURN jsonb_build_object('ok',false,'code','DRAFT_CHANGED','draftRevision',v_receipt.draft_revision);
  END IF;
  SELECT * INTO v_item FROM public.purchase_receipt_items i WHERE i.id=p_receipt_item_id AND i.receipt_id=p_receipt_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='Receipt item is unavailable'; END IF;
  SELECT * INTO v_latest FROM public.purchase_receipt_acquisition_estimate_revisions r
    WHERE r.receipt_item_identity=v_item.id ORDER BY r.revision DESC LIMIT 1;
  IF coalesce(v_latest.revision,0)<>p_expected_evidence_revision THEN
    RETURN jsonb_build_object('ok',false,'code','EVIDENCE_CHANGED','evidenceRevision',coalesce(v_latest.revision,0));
  END IF;
  v_kind:=CASE p_evidence_kind WHEN 'MANAGER_ESTIMATE' THEN 'MANAGER_ESTIMATE'::public.purchase_receipt_acquisition_evidence_kind
    WHEN 'AUTHORITATIVE_ZERO' THEN 'AUTHORITATIVE_ZERO'::public.purchase_receipt_acquisition_evidence_kind
    ELSE 'REMOVED'::public.purchase_receipt_acquisition_evidence_kind END;
  IF v_kind='MANAGER_ESTIMATE' AND (p_unit_price IS NULL OR p_unit_price<=0 OR p_unit_price>=1000000000000 OR p_unit_price<>trunc(p_unit_price,2)) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Manager estimate must be positive and have at most two decimal places';
  ELSIF v_kind='AUTHORITATIVE_ZERO' AND (p_unit_price IS DISTINCT FROM 0 OR p_reason IS NULL OR btrim(p_reason)='') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Authoritative zero requires zero price and a reason';
  ELSIF v_kind='REMOVED' AND p_unit_price IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Removed estimate cannot contain a price';
  ELSIF v_kind='REMOVED' AND (v_latest.id IS NULL OR v_latest.evidence_kind='REMOVED') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='No active estimate exists to remove';
  END IF;
  v_revision:=public.append_purchase_receipt_estimate_revision(v_receipt.id,v_item.id,v_item.product_id,
    v_receipt.outlet_id,v_kind,p_unit_price,p_reason,p_reference);
  UPDATE public.purchase_receipts SET draft_revision=draft_revision+1,updated_by=v_actor,updated_at=now()
    WHERE id=v_receipt.id RETURNING draft_revision INTO v_new_draft_revision;
  INSERT INTO public.purchase_receipt_events(receipt_id,event_type,actor_id,note)
    VALUES(v_receipt.id,'DRAFT_UPDATED',v_actor,'Acquisition evidence revised');
  RETURN jsonb_build_object('ok',true,'evidenceRevision',v_revision,'draftRevision',v_new_draft_revision);
END;
$$;
ALTER FUNCTION public.purchase_receipt_acquisition_estimate_save(uuid,uuid,integer,integer,text,numeric,text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_receipt_acquisition_estimate_save(uuid,uuid,integer,integer,text,numeric,text,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_receipt_acquisition_estimate_save(uuid,uuid,integer,integer,text,numeric,text,text) TO authenticated;

-- Reconcile operational items by product identity rather than deleting all rows. Removed item evidence is tombstoned.
CREATE OR REPLACE FUNCTION public.purchase_receipt_save_draft(p_receipt_id uuid,p_expected_revision integer,
  p_received_at timestamptz,p_note text,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_receipt public.purchase_receipts%rowtype;
  v_row jsonb; v_product uuid; v_count integer:=0; v_removed record; v_new_id uuid;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'GUDANG'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Goods receipt access denied';
  END IF;
  IF p_receipt_id IS NULL OR p_expected_revision IS NULL OR p_expected_revision<1 OR p_received_at IS NULL
    OR jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items)>500
    OR (p_note IS NOT NULL AND (btrim(p_note)='' OR length(p_note)>1000)) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Receipt draft is invalid';
  END IF;
  SELECT * INTO v_receipt FROM public.purchase_receipts WHERE id=p_receipt_id FOR UPDATE;
  IF NOT FOUND OR v_receipt.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Receipt is not editable'; END IF;
  IF v_receipt.draft_revision<>p_expected_revision THEN
    RETURN jsonb_build_object('ok',false,'code','DRAFT_CHANGED','revision',v_receipt.draft_revision);
  END IF;
  IF jsonb_array_length(p_items)=0 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='At least one receipt item is required'; END IF;
  IF (SELECT count(DISTINCT x.product_id) FROM jsonb_to_recordset(p_items) AS x(product_id uuid))<>jsonb_array_length(p_items) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='A product may appear only once on a receipt';
  END IF;
  FOR v_row IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    v_product:=(v_row->>'product_id')::uuid;
    IF v_product IS NULL OR NOT EXISTS(SELECT 1 FROM public.products p WHERE p.id=v_product) THEN
      RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Receipt product is unavailable';
    END IF;
    IF EXISTS(SELECT 1 FROM jsonb_object_keys(v_row) AS k(key) WHERE key NOT IN
      ('product_id','accepted_quantity','bonus_quantity','rejected_quantity','short_quantity','operational_note')) THEN
      RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Unsupported receipt item field';
    END IF;
    IF v_row ? 'operational_note' AND jsonb_typeof(v_row->'operational_note') NOT IN ('string','null') THEN
      RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Receipt item note must be text';
    END IF;
    IF length(v_row->>'operational_note')>300 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Receipt item note is too long'; END IF;
  END LOOP;
  UPDATE public.purchase_receipts SET received_at=p_received_at,operational_note=nullif(btrim(p_note),''),
    updated_by=v_actor,updated_at=now(),draft_revision=draft_revision+1 WHERE id=p_receipt_id;
  FOR v_removed IN SELECT i.id,i.product_id FROM public.purchase_receipt_items i
    WHERE i.receipt_id=p_receipt_id AND NOT EXISTS(
      SELECT 1 FROM jsonb_to_recordset(p_items) AS x(product_id uuid) WHERE x.product_id=i.product_id)
    ORDER BY i.product_id LOOP
    IF EXISTS(SELECT 1 FROM public.purchase_receipt_acquisition_estimate_revisions r
      WHERE r.receipt_item_identity=v_removed.id AND r.evidence_kind<>'REMOVED'
      AND r.revision=(SELECT max(r2.revision) FROM public.purchase_receipt_acquisition_estimate_revisions r2 WHERE r2.receipt_item_identity=v_removed.id)) THEN
      PERFORM public.append_purchase_receipt_estimate_revision(p_receipt_id,v_removed.id,v_removed.product_id,
        v_receipt.outlet_id,'REMOVED',NULL,'Item dihapus dari draf',NULL);
    END IF;
    DELETE FROM public.purchase_receipt_items WHERE id=v_removed.id;
  END LOOP;
  FOR v_row IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    v_product:=(v_row->>'product_id')::uuid;
    INSERT INTO public.purchase_receipt_items(receipt_id,product_id,accepted_quantity,bonus_quantity,
      rejected_quantity,short_quantity,operational_note)
    VALUES(p_receipt_id,v_product,coalesce((v_row->>'accepted_quantity')::numeric,0),
      coalesce((v_row->>'bonus_quantity')::numeric,0),coalesce((v_row->>'rejected_quantity')::numeric,0),
      nullif(v_row->>'short_quantity','')::numeric,nullif(btrim(v_row->>'operational_note'),''))
    ON CONFLICT(receipt_id,product_id) DO UPDATE SET accepted_quantity=excluded.accepted_quantity,
      bonus_quantity=excluded.bonus_quantity,rejected_quantity=excluded.rejected_quantity,
      short_quantity=excluded.short_quantity,operational_note=excluded.operational_note,updated_at=now()
    RETURNING id INTO v_new_id;
    v_count:=v_count+1;
  END LOOP;
  INSERT INTO public.purchase_receipt_events(receipt_id,event_type,actor_id,note)
    VALUES(p_receipt_id,'DRAFT_UPDATED',v_actor,'Item: '||v_count::text);
  RETURN jsonb_build_object('ok',true,'revision',p_expected_revision+1);
END;
$$;
ALTER FUNCTION public.purchase_receipt_save_draft(uuid,integer,timestamptz,text,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_receipt_save_draft(uuid,integer,timestamptz,text,jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_receipt_save_draft(uuid,integer,timestamptz,text,jsonb) TO authenticated;

-- Include the current estimate revision set in the stock-post intent fingerprint.
-- Lock order: outlet cutover advisory -> receipt row -> actor/receipt intent advisory -> pending request row.
CREATE OR REPLACE FUNCTION public.issue_purchase_receipt_post_intent(p_receipt_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_receipt public.purchase_receipts%rowtype;
  v_payload jsonb; v_hash text; v_existing public.stock_operation_requests%rowtype; v_id uuid; v_authority public.inventory_cost_authority_status;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'GUDANG'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Receipt posting access denied';
  END IF;
  -- Discover only the outlet first. Every post path then takes the shared cutover
  -- lock before receipt and operation-request row locks.
  SELECT r.outlet_id INTO v_receipt.outlet_id FROM public.purchase_receipts r WHERE r.id=p_receipt_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Receipt is unavailable'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_BOOTSTRAP_OUTLET:'||v_receipt.outlet_id::text,73190411));
  SELECT * INTO v_receipt FROM public.purchase_receipts WHERE id=p_receipt_id FOR UPDATE;
  IF NOT FOUND OR v_receipt.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Receipt is not a draft'; END IF;
  SELECT a.status INTO v_authority FROM public.inventory_costing_outlet_authority a WHERE a.outlet_id=v_receipt.outlet_id;
  IF v_authority='BOOTSTRAP_READY' THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Penerimaan sementara dijeda saat persiapan awal costing berlangsung';
  END IF;
  v_payload:=jsonb_build_object('receipt_id',p_receipt_id,'draft_revision',v_receipt.draft_revision,
    'content_hash',md5(v_receipt.id::text||':'||v_receipt.supplier_id::text||':'||v_receipt.outlet_id::text||':'||
      v_receipt.received_at::text||':'||coalesce(v_receipt.operational_note,'')||':'||
      (SELECT coalesce(string_agg(i.product_id::text||':'||i.accepted_quantity::text||':'||i.bonus_quantity::text||':'||
        i.rejected_quantity::text||':'||coalesce(i.short_quantity::text,'')||':'||coalesce(i.operational_note,''),'|' ORDER BY i.product_id),'')
       FROM public.purchase_receipt_items i WHERE i.receipt_id=p_receipt_id)),
    'acquisition_evidence_hash',(SELECT md5(coalesce(string_agg(i.id::text||':'||coalesce(r.revision,0)::text,'|' ORDER BY i.product_id),''))
      FROM public.purchase_receipt_items i LEFT JOIN LATERAL (SELECT x.revision FROM public.purchase_receipt_acquisition_estimate_revisions x
        WHERE x.receipt_item_identity=i.id ORDER BY x.revision DESC LIMIT 1) r ON true WHERE i.receipt_id=p_receipt_id));
  v_hash:=md5(v_payload::text);
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_actor::text||':POST_PURCHASE_RECEIPT:'||p_receipt_id::text,73190411));
  SELECT * INTO v_existing FROM public.stock_operation_requests WHERE actor_id=v_actor
    AND operation_key='POST_PURCHASE_RECEIPT' AND target_key=p_receipt_id::text AND state='PENDING' FOR UPDATE;
  IF FOUND THEN
    IF v_existing.payload_hash=v_hash AND v_existing.request_payload=v_payload THEN RETURN v_existing.request_id; END IF;
    UPDATE public.stock_operation_requests SET state='SUPERSEDED',result=jsonb_build_object('ok',false,'code','INTENT_SUPERSEDED'),completed_at=now()
      WHERE request_id=v_existing.request_id;
  END IF;
  INSERT INTO public.stock_operation_requests(actor_id,operation_key,target_key,request_payload,payload_hash)
    VALUES(v_actor,'POST_PURCHASE_RECEIPT',p_receipt_id::text,v_payload,v_hash) RETURNING request_id INTO v_id;
  RETURN v_id;
END;
$$;
ALTER FUNCTION public.issue_purchase_receipt_post_intent(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.issue_purchase_receipt_post_intent(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.issue_purchase_receipt_post_intent(uuid) TO authenticated;

CREATE FUNCTION public.inventory_cost_apply_purchase_receipt(
  p_request_id uuid,p_receipt_id uuid,p_movement_batch_id uuid,p_period_id uuid
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_receipt public.purchase_receipts%rowtype; v_item record; v_cost public.inventory_cost_projections%rowtype;
  v_est public.purchase_receipt_acquisition_estimate_revisions%rowtype; v_basis public.inventory_cost_acquisition_basis;
  v_unit numeric(20,8); v_amount numeric(32,8); v_basis_cost_event_id uuid;
  v_payload jsonb:='[]'::jsonb; v_hash text; v_result jsonb;
  v_cost_request public.inventory_cost_operation_requests%rowtype; v_batch uuid; v_event uuid; v_movement public.stock_movements%rowtype;
  v_physical numeric; v_valued numeric; v_provisional numeric; v_unvalued numeric; v_value numeric(32,8);
  v_wac numeric(20,8); v_status public.inventory_cost_projection_status; v_revision integer; v_count integer:=0;
  v_actor uuid:=auth.uid();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Receipt costing actor mismatch'; END IF;
  SELECT * INTO v_receipt FROM public.purchase_receipts r WHERE r.id=p_receipt_id;
  IF NOT FOUND OR v_receipt.outlet_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='Receipt unavailable for costing'; END IF;
  -- Stock rows and authority period are already locked by the caller. Lock costing rows next, ordered by product.
  FOR v_item IN SELECT i.*,m.id AS movement_id,m.quantity_delta,m.balance_before,m.balance_after,
      sb.balance_version AS stock_balance_version
    FROM public.purchase_receipt_items i JOIN public.stock_movements m
      ON m.purchase_receipt_item_id=i.id AND m.movement_type='PURCHASE_RECEIPT'
    JOIN public.stock_balance_projection sb ON sb.outlet_id=v_receipt.outlet_id AND sb.product_id=i.product_id
    WHERE i.receipt_id=p_receipt_id ORDER BY i.product_id LOOP
    SELECT * INTO v_cost FROM public.inventory_cost_projections cp
      WHERE cp.outlet_id=v_receipt.outlet_id AND cp.product_id=v_item.product_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='WAC projection is missing for a posted receipt product'; END IF;
    IF v_cost.stock_authority_period_id<>p_period_id OR v_cost.physical_quantity IS DISTINCT FROM v_item.balance_before THEN
      RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='Costing and stock projections are out of sync';
    END IF;
    SELECT * INTO v_est FROM public.purchase_receipt_acquisition_estimate_revisions e
      WHERE e.receipt_item_identity=v_item.id ORDER BY e.revision DESC LIMIT 1;
    v_revision:=CASE WHEN FOUND THEN v_est.revision ELSE 0 END;
    v_basis:='UNVALUED'; v_unit:=NULL; v_amount:=NULL; v_basis_cost_event_id:=NULL;
    IF v_est.id IS NOT NULL AND v_est.evidence_kind='MANAGER_ESTIMATE' AND v_item.accepted_quantity>0 THEN
      v_basis:='MANAGER_ESTIMATE'; v_unit:=v_est.estimated_unit_price::numeric(20,8);
      v_amount:=round(v_item.accepted_quantity*v_unit,8)::numeric(32,8);
    ELSIF v_est.id IS NOT NULL AND v_est.evidence_kind='AUTHORITATIVE_ZERO' THEN
      v_basis:='AUTHORITATIVE_ZERO'; v_unit:=0; v_amount:=0;
    ELSIF v_item.accepted_quantity>0 AND v_cost.valued_quantity>0 AND v_cost.inventory_value IS NOT NULL
      AND v_cost.current_wac IS NOT NULL AND v_cost.last_cost_event_id IS NOT NULL
      AND v_cost.current_wac=round(v_cost.inventory_value/v_cost.valued_quantity,8)
      AND v_cost.valuation_status<>'UNVALUED' THEN
      v_basis:='CURRENT_WAC'; v_unit:=v_cost.current_wac; v_basis_cost_event_id:=v_cost.last_cost_event_id;
      v_amount:=round(v_item.accepted_quantity*v_unit,8)::numeric(32,8);
    END IF;
    -- No fallback to unverified product_costs.hpp: the strict HPP acceptance evaluator is not a receipt-price API.
    v_payload:=v_payload||jsonb_build_array(jsonb_build_object('item',v_item.id,'product',v_item.product_id,
      'evidenceRevision',v_revision,'basis',v_basis,'unitCost',v_unit::text,'acquisitionValue',v_amount::text,
      'costVersion',v_cost.cost_version,'lastCostEvent',v_cost.last_cost_event_id,
      'basisCostEventId',v_basis_cost_event_id,
      'stockMovement',v_item.movement_id,'stockBalanceVersion',v_item.stock_balance_version));
  END LOOP;
  IF jsonb_array_length(v_payload)=0 THEN RETURN 0; END IF;
  v_hash:=md5(jsonb_build_object('operation','PURCHASE_RECEIPT','actor',v_actor,'request',p_request_id,
    'receipt',p_receipt_id,'outlet',v_receipt.outlet_id,'items',v_payload)::text);
  INSERT INTO public.inventory_cost_operation_requests(request_id,actor_id,operation_key,target_key,payload_hash)
    VALUES(p_request_id,v_actor,'PURCHASE_RECEIPT',p_receipt_id::text,v_hash);
  INSERT INTO public.inventory_cost_event_batches(outlet_id,batch_type,source_entity_type,source_entity_id,
    operation_request_id,allocation_method,created_by)
  VALUES(v_receipt.outlet_id,'PURCHASE_RECEIPT','PURCHASE_RECEIPT',p_receipt_id,p_request_id,
    'PAID_QUANTITY_WITH_BONUS_DILUTION',v_actor) RETURNING id INTO v_batch;

  FOR v_item IN SELECT i.*,m.id AS movement_id,m.quantity_delta,m.balance_before,m.balance_after,
      sb.balance_version AS stock_balance_version
    FROM public.purchase_receipt_items i JOIN public.stock_movements m
      ON m.purchase_receipt_item_id=i.id AND m.movement_type='PURCHASE_RECEIPT'
    JOIN public.stock_balance_projection sb ON sb.outlet_id=v_receipt.outlet_id AND sb.product_id=i.product_id
    WHERE i.receipt_id=p_receipt_id ORDER BY i.product_id LOOP
    SELECT * INTO v_cost FROM public.inventory_cost_projections cp
      WHERE cp.outlet_id=v_receipt.outlet_id AND cp.product_id=v_item.product_id FOR UPDATE;
    SELECT * INTO v_est FROM public.purchase_receipt_acquisition_estimate_revisions e
      WHERE e.receipt_item_identity=v_item.id ORDER BY e.revision DESC LIMIT 1;
    v_revision:=CASE WHEN FOUND THEN v_est.revision ELSE 0 END;
    v_basis:='UNVALUED'; v_unit:=NULL; v_amount:=NULL; v_basis_cost_event_id:=NULL;
    IF v_est.id IS NOT NULL AND v_est.evidence_kind='MANAGER_ESTIMATE' AND v_item.accepted_quantity>0 THEN
      v_basis:='MANAGER_ESTIMATE'; v_unit:=v_est.estimated_unit_price::numeric(20,8);
      v_amount:=round(v_item.accepted_quantity*v_unit,8)::numeric(32,8);
    ELSIF v_est.id IS NOT NULL AND v_est.evidence_kind='AUTHORITATIVE_ZERO' THEN
      v_basis:='AUTHORITATIVE_ZERO'; v_unit:=0; v_amount:=0;
    ELSIF v_item.accepted_quantity>0 AND v_cost.valued_quantity>0 AND v_cost.inventory_value IS NOT NULL
      AND v_cost.current_wac IS NOT NULL AND v_cost.last_cost_event_id IS NOT NULL
      AND v_cost.current_wac=round(v_cost.inventory_value/v_cost.valued_quantity,8)
      AND v_cost.valuation_status<>'UNVALUED' THEN
      v_basis:='CURRENT_WAC'; v_unit:=v_cost.current_wac; v_basis_cost_event_id:=v_cost.last_cost_event_id;
      v_amount:=round(v_item.accepted_quantity*v_unit,8)::numeric(32,8);
    END IF;
    v_physical:=v_item.balance_after;
    IF v_basis='UNVALUED' THEN
      v_valued:=v_cost.valued_quantity; v_provisional:=v_cost.provisional_quantity;
      v_unvalued:=v_cost.unvalued_quantity+v_item.quantity_delta; v_value:=v_cost.inventory_value;
    ELSE
      v_valued:=v_cost.valued_quantity+v_item.quantity_delta;
      v_provisional:=v_cost.provisional_quantity+CASE WHEN v_basis IN ('MANAGER_ESTIMATE','CURRENT_WAC') THEN v_item.quantity_delta ELSE 0 END;
      v_unvalued:=v_cost.unvalued_quantity;
      v_value:=round(coalesce(v_cost.inventory_value,0)+v_amount,8)::numeric(32,8);
    END IF;
    v_wac:=CASE WHEN v_valued>0 THEN round(v_value/v_valued,8)::numeric(20,8) ELSE NULL END;
    v_status:=CASE WHEN v_physical=0 THEN 'VALUED'::public.inventory_cost_projection_status
      WHEN v_valued=0 THEN 'UNVALUED'::public.inventory_cost_projection_status
      WHEN v_unvalued>0 THEN 'PARTIALLY_UNVALUED'::public.inventory_cost_projection_status
      WHEN v_provisional>0 THEN 'PROVISIONAL'::public.inventory_cost_projection_status
      ELSE 'VALUED'::public.inventory_cost_projection_status END;
    IF v_valued=0 THEN v_value:=NULL;v_wac:=NULL; END IF;
    INSERT INTO public.inventory_cost_events(batch_id,outlet_id,product_id,event_type,source_entity_type,source_entity_id,
      source_event_id,quantity_delta,valued_quantity_before,valued_quantity_after,inventory_value_delta,
      inventory_value_before,inventory_value_after,wac_before,wac_after,valuation_status_before,valuation_status_after,
      cost_version_before,cost_version_after,stock_balance_version,stock_authority_period_id,actor_id,operation_request_id,
      physical_quantity_delta,physical_quantity_before,physical_quantity_after,valued_quantity_delta,
      provisional_quantity_delta,
      provisional_quantity_before,provisional_quantity_after,unvalued_quantity_delta,unvalued_quantity_before,
      unvalued_quantity_after,valuation_basis,frozen_unit_cost,receipt_id,receipt_item_id,stock_movement_id,
      basis_cost_event_id,stock_request_id,acquisition_evidence_revision,metadata)
    VALUES(v_batch,v_receipt.outlet_id,v_item.product_id,'PURCHASE_RECEIPT','PURCHASE_RECEIPT',p_receipt_id,
      v_item.movement_id,v_item.quantity_delta,v_cost.valued_quantity,v_valued,
      CASE WHEN v_basis='UNVALUED' THEN NULL ELSE v_amount END,v_cost.inventory_value,v_value,v_cost.current_wac,v_wac,
      v_cost.valuation_status,v_status,v_cost.cost_version,v_cost.cost_version+1,v_item.stock_balance_version,p_period_id,
      v_actor,p_request_id,v_item.quantity_delta,v_item.balance_before,v_item.balance_after,
      v_valued-v_cost.valued_quantity,
      v_provisional-v_cost.provisional_quantity,v_cost.provisional_quantity,v_provisional,
      v_unvalued-v_cost.unvalued_quantity,v_cost.unvalued_quantity,v_unvalued,v_basis,v_unit,p_receipt_id,
      v_item.id,v_item.movement_id,v_basis_cost_event_id,p_request_id,nullif(v_revision,0),
      jsonb_build_object('acceptedQuantity',v_item.accepted_quantity,'bonusQuantity',v_item.bonus_quantity,
        'rejectedQuantityExcluded',v_item.rejected_quantity,'shortQuantityExcluded',v_item.short_quantity,
        'basisRevision',nullif(v_revision,0),'acquisitionValue',v_amount::text)) RETURNING id INTO v_event;
    UPDATE public.inventory_cost_projections SET physical_quantity=v_physical,valued_quantity=v_valued,
      provisional_quantity=v_provisional,unvalued_quantity=v_unvalued,inventory_value=v_value,current_wac=v_wac,
      valuation_status=v_status,cost_version=v_cost.cost_version+1,stock_balance_version=v_item.stock_balance_version,
      stock_authority_period_id=p_period_id,last_cost_event_id=v_event,updated_at=now()
    WHERE outlet_id=v_receipt.outlet_id AND product_id=v_item.product_id;
    v_count:=v_count+1;
  END LOOP;
  v_result:=jsonb_build_object('ok',true,'code','PURCHASE_RECEIPT_COSTED','receiptId',p_receipt_id,'eventCount',v_count);
  UPDATE public.inventory_cost_operation_requests SET result=v_result,completed_at=now() WHERE request_id=p_request_id;
  RETURN v_count;
END;
$$;
ALTER FUNCTION public.inventory_cost_apply_purchase_receipt(uuid,uuid,uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_apply_purchase_receipt(uuid,uuid,uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;

-- Keep the existing controlled cutover entry point compatible with the expanded projection.
-- This only defines future bootstrap behavior; this migration never invokes it.
CREATE OR REPLACE FUNCTION public.inventory_cost_bootstrap_outlet(p_outlet_id uuid,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_hash text;
  v_request public.inventory_cost_operation_requests%rowtype; v_period uuid; v_batch uuid; v_stock record;
  v_hpp numeric; v_hpp_source uuid; v_review uuid; v_status public.inventory_cost_projection_status;
  v_value numeric(32,8); v_wac numeric(20,8); v_event uuid; v_valued numeric; v_unvalued numeric;
  v_count integer:=0; v_valued_count integer:=0; v_unvalued_count integer:=0; v_result jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Authentication required'; END IF;
  v_role:=public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Costing access denied';
  END IF;
  IF p_outlet_id IS NULL OR p_request_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.outlets o WHERE o.id=p_outlet_id AND o.is_active) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Active outlet and request identity are required';
  END IF;
  v_hash:=md5(p_outlet_id::text);
  -- Lock order: outlet cutover advisory -> request advisory -> operation-request row
  -- -> stock projection rows by product_id -> open authority period -> costing rows by product_id.
  -- This matches receipt apply, which takes no row lock during its initial outlet discovery.
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_BOOTSTRAP_OUTLET:'||p_outlet_id::text,73190411));
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_BOOTSTRAP_REQUEST:'||p_request_id::text,73190411));
  SELECT * INTO v_request FROM public.inventory_cost_operation_requests r WHERE r.request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF v_request.actor_id<>v_actor OR v_request.operation_key<>'BOOTSTRAP_OUTLET' OR v_request.target_key<>p_outlet_id::text OR v_request.payload_hash<>v_hash THEN
      RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Costing request identity mismatch';
    END IF;
    IF v_request.result IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Costing request is incomplete'; END IF;
    RETURN v_request.result;
  END IF;
  INSERT INTO public.inventory_cost_operation_requests(request_id,actor_id,operation_key,target_key,payload_hash)
    VALUES(p_request_id,v_actor,'BOOTSTRAP_OUTLET',p_outlet_id::text,v_hash);
  IF EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority a WHERE a.outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections p WHERE p.outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_event_batches b WHERE b.outlet_id=p_outlet_id) THEN
    v_result:=jsonb_build_object('ok',false,'code','ALREADY_BOOTSTRAPPED','outletId',p_outlet_id);
    UPDATE public.inventory_cost_operation_requests SET result=v_result,completed_at=now() WHERE request_id=p_request_id;
    RETURN v_result;
  END IF;
  FOR v_stock IN SELECT p.product_id,p.outlet_id,p.effective_quantity,p.balance_version,p.authority_period_id
    FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id ORDER BY p.product_id FOR UPDATE LOOP NULL; END LOOP;
  SELECT ap.id INTO v_period FROM public.stock_authority_periods ap WHERE ap.outlet_id=p_outlet_id AND ap.ended_at IS NULL FOR UPDATE;
  IF v_period IS NULL OR EXISTS(SELECT 1 FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id AND p.authority_period_id<>v_period)
    OR NOT EXISTS(SELECT 1 FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Stock authority period is unavailable or inconsistent';
  END IF;
  INSERT INTO public.inventory_cost_event_batches(outlet_id,batch_type,source_entity_type,source_entity_id,
    operation_request_id,allocation_method,created_by)
  VALUES(p_outlet_id,'OPENING','STOCK_AUTHORITY_CUTOVER',p_outlet_id,p_request_id,'VERIFIED_HPP_AT_CUTOVER',v_actor)
  RETURNING id INTO v_batch;
  FOR v_stock IN SELECT p.product_id,p.outlet_id,p.effective_quantity,p.balance_version,p.authority_period_id
    FROM public.stock_balance_projection p WHERE p.outlet_id=p_outlet_id ORDER BY p.product_id LOOP
    IF v_stock.effective_quantity IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Effective stock quantity is unknown'; END IF;
    v_hpp:=NULL;v_hpp_source:=NULL;v_review:=NULL;v_wac:=NULL;v_value:=NULL;
    SELECT c.hpp,c.source_import_row_id,r.id INTO v_hpp,v_hpp_source,v_review
    FROM public.product_costs c
    JOIN public.ipos_import_rows ir ON ir.id=c.source_import_row_id AND ir.product_id=c.product_id AND ir.outlet_id=c.outlet_id AND ir.status='VALID'
    JOIN LATERAL (SELECT fr.id,fr.status FROM public.product_field_audit_reviews fr
      WHERE fr.product_id=c.product_id AND fr.outlet_id=c.outlet_id AND fr.field_key='hpp'
      ORDER BY fr.reviewed_at DESC,fr.id DESC LIMIT 1) r ON r.status='SUDAH_DIVERIFIKASI'::public.product_field_audit_status
    WHERE c.product_id=v_stock.product_id AND c.outlet_id=p_outlet_id AND c.hpp IS NOT NULL AND c.hpp>=0
      AND c.hpp<1000000000000 AND c.hpp=trunc(c.hpp,2)
      AND EXISTS(SELECT 1 FROM public.product_field_audit_reviews fr WHERE fr.id=r.id AND fr.source_import_row_id=c.source_import_row_id);
    IF v_stock.effective_quantity=0 THEN
      v_status:='VALUED';v_valued:=0;v_unvalued:=0;v_value:=0;v_wac:=NULL;
    ELSIF v_hpp IS NOT NULL THEN
      v_status:='VALUED';v_valued:=v_stock.effective_quantity;v_unvalued:=0;v_wac:=v_hpp::numeric(20,8);
      v_value:=round(v_stock.effective_quantity*v_hpp,8)::numeric(32,8);
    ELSE
      v_status:='UNVALUED';v_valued:=0;v_unvalued:=v_stock.effective_quantity;v_value:=NULL;v_wac:=NULL;
    END IF;
    INSERT INTO public.inventory_cost_events(batch_id,outlet_id,product_id,event_type,source_entity_type,source_entity_id,
      valued_quantity_before,valued_quantity_delta,valued_quantity_after,
      inventory_value_before,inventory_value_delta,inventory_value_after,wac_after,valuation_status_after,
      cost_version_before,cost_version_after,stock_balance_version,stock_authority_period_id,
      source_hpp_value,source_hpp_import_row_id,source_hpp_verification_review_id,actor_id,operation_request_id,
      physical_quantity_delta,physical_quantity_before,physical_quantity_after,provisional_quantity_delta,
      provisional_quantity_before,provisional_quantity_after,unvalued_quantity_delta,unvalued_quantity_before,
      unvalued_quantity_after,valuation_basis,frozen_unit_cost,metadata)
    VALUES(v_batch,p_outlet_id,v_stock.product_id,'OPENING','STOCK_AUTHORITY_CUTOVER',p_outlet_id,0,v_valued,v_valued,
      0,v_value,v_value,v_wac,v_status,0,1,v_stock.balance_version,v_stock.authority_period_id,v_hpp,v_hpp_source,v_review,
      v_actor,p_request_id,v_stock.effective_quantity,0,v_stock.effective_quantity,0,0,0,v_unvalued,0,v_unvalued,
      CASE WHEN v_stock.effective_quantity=0 THEN NULL WHEN v_hpp IS NOT NULL THEN 'VERIFIED_IPOS_HPP'::public.inventory_cost_acquisition_basis
        ELSE 'UNVALUED'::public.inventory_cost_acquisition_basis END,
      CASE WHEN v_hpp IS NOT NULL THEN v_hpp::numeric(20,8) ELSE NULL END,
      jsonb_build_object('quantitySource','stock_balance_projection','hppSource','product_costs.hpp',
        'hppVerification','latest matching SUDAH_DIVERIFIKASI review')) RETURNING id INTO v_event;
    INSERT INTO public.inventory_cost_projections(outlet_id,product_id,valued_quantity,inventory_value,current_wac,
      valuation_status,cost_version,stock_balance_version,stock_authority_period_id,last_cost_event_id,
      physical_quantity,provisional_quantity,unvalued_quantity)
    VALUES(p_outlet_id,v_stock.product_id,v_valued,v_value,v_wac,v_status,1,v_stock.balance_version,
      v_stock.authority_period_id,v_event,v_stock.effective_quantity,0,v_unvalued);
    v_count:=v_count+1;
    IF v_status='UNVALUED' THEN v_unvalued_count:=v_unvalued_count+1; ELSE v_valued_count:=v_valued_count+1; END IF;
  END LOOP;
  INSERT INTO public.inventory_costing_outlet_authority(outlet_id,status,bootstrap_batch_id,bootstrapped_by,bootstrapped_at)
    VALUES(p_outlet_id,'BOOTSTRAP_READY',v_batch,v_actor,now());
  v_result:=jsonb_build_object('ok',true,'code','BOOTSTRAP_READY','outletId',p_outlet_id,'batchId',v_batch,
    'productCount',v_count,'valuedCount',v_valued_count,'unvaluedCount',v_unvalued_count,'authorityStatus','BOOTSTRAP_READY');
  UPDATE public.inventory_cost_operation_requests SET result=v_result,completed_at=now() WHERE request_id=p_request_id;
  RETURN v_result;
END;
$$;
ALTER FUNCTION public.inventory_cost_bootstrap_outlet(uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_bootstrap_outlet(uuid,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.inventory_cost_bootstrap_outlet(uuid,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.inventory_cost_projection_page(p_outlet_id uuid,p_search text DEFAULT NULL,
  p_page integer DEFAULT 1,p_page_size integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=pg_catalog AS $$
DECLARE v_role public.user_role; v_term text:=nullif(btrim(coalesce(p_search,'')),'');
  v_page integer:=greatest(coalesce(p_page,1),1); v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_total integer; v_rows jsonb;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RETURN jsonb_build_object('ok',false,'code','FORBIDDEN');
  END IF;
  IF p_outlet_id IS NULL THEN RETURN jsonb_build_object('ok',false,'code','INVALID_OUTLET'); END IF;
  SELECT count(*)::integer INTO v_total FROM public.inventory_cost_projections cp JOIN public.products p ON p.id=cp.product_id
    WHERE cp.outlet_id=p_outlet_id AND (v_term IS NULL OR p.name ILIKE '%'||v_term||'%' OR p.sku ILIKE '%'||v_term||'%');
  SELECT coalesce(jsonb_agg(jsonb_build_object('productId',x.product_id,'name',x.name,'sku',x.sku,
    'physicalQuantity',x.physical_quantity,'valuedQuantity',x.valued_quantity,
    'provisionalQuantity',x.provisional_quantity,'unvaluedQuantity',x.unvalued_quantity,
    'inventoryValue',x.inventory_value,'currentWac',x.current_wac,'valuationStatus',x.valuation_status,
    'costVersion',x.cost_version,'stockBalanceVersion',x.stock_balance_version,
    'stockAuthorityPeriodId',x.stock_authority_period_id,'lastCostEventId',x.last_cost_event_id,
    'bootstrapHpp',x.source_hpp_value,'bootstrapHppImportRowId',x.source_hpp_import_row_id,
    'bootstrapHppReviewId',x.source_hpp_verification_review_id) ORDER BY x.name,x.sku,x.product_id),'[]'::jsonb)
  INTO v_rows FROM (
    SELECT cp.*,p.name,p.sku,opening.source_hpp_value,opening.source_hpp_import_row_id,opening.source_hpp_verification_review_id
    FROM public.inventory_cost_projections cp JOIN public.products p ON p.id=cp.product_id
    LEFT JOIN LATERAL (SELECT e.source_hpp_value,e.source_hpp_import_row_id,e.source_hpp_verification_review_id
      FROM public.inventory_cost_events e WHERE e.outlet_id=cp.outlet_id AND e.product_id=cp.product_id
        AND e.event_type='OPENING' ORDER BY e.created_at,e.id LIMIT 1) opening ON true
    WHERE cp.outlet_id=p_outlet_id AND (v_term IS NULL OR p.name ILIKE '%'||v_term||'%' OR p.sku ILIKE '%'||v_term||'%')
    ORDER BY p.name,p.sku,cp.product_id OFFSET ((v_page::bigint)-1)*v_size LIMIT v_size
  ) x;
  RETURN jsonb_build_object('ok',true,'page',v_page,'pageSize',v_size,'total',v_total,'rows',v_rows,
    'authorityStatus',coalesce((SELECT a.status::text FROM public.inventory_costing_outlet_authority a
      WHERE a.outlet_id=p_outlet_id),'REFERENCE_ONLY'));
END;
$$;
ALTER FUNCTION public.inventory_cost_projection_page(uuid,text,integer,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_projection_page(uuid,text,integer,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.inventory_cost_projection_page(uuid,text,integer,integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.apply_purchase_receipt_post_intent(p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_req public.stock_operation_requests%rowtype;
  v_receipt public.purchase_receipts%rowtype; v_receipt_id uuid; v_period public.stock_authority_periods%rowtype;
  v_projection public.stock_balance_projection%rowtype; v_authority public.inventory_cost_authority_status;
  v_item record; v_batch uuid; v_before numeric; v_after numeric; v_version bigint; v_delta numeric;
  v_count integer:=0; v_hash text; v_cost_events integer:=0; v_evidence_hash text;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'GUDANG'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Receipt posting access denied';
  END IF;
  -- Lock order: unlocked request/receipt identity discovery -> outlet cutover advisory
  -- -> receipt row -> operation-request row -> stock projection rows by product_id
  -- -> open authority period -> costing projection rows by product_id.
  -- Never hold the request row while waiting for the outlet lock.
  SELECT * INTO v_req FROM public.stock_operation_requests WHERE request_id=p_request_id AND actor_id=v_actor;
  IF NOT FOUND OR v_req.operation_key<>'POST_PURCHASE_RECEIPT' THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Receipt request unavailable'; END IF;
  IF v_req.state IN ('COMPLETED','STALE','SUPERSEDED') THEN RETURN v_req.result; END IF;
  v_receipt_id:=(v_req.request_payload->>'receipt_id')::uuid;
  SELECT r.outlet_id INTO v_receipt.outlet_id FROM public.purchase_receipts r WHERE r.id=v_receipt_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Receipt is not available'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_BOOTSTRAP_OUTLET:'||v_receipt.outlet_id::text,73190411));
  SELECT * INTO v_receipt FROM public.purchase_receipts WHERE id=v_receipt_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Receipt is not available'; END IF;
  SELECT * INTO v_req FROM public.stock_operation_requests WHERE request_id=p_request_id AND actor_id=v_actor FOR UPDATE;
  IF NOT FOUND OR v_req.operation_key<>'POST_PURCHASE_RECEIPT'
    OR (v_req.request_payload->>'receipt_id')::uuid IS DISTINCT FROM v_receipt.id THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Receipt request identity changed';
  END IF;
  IF v_req.state IN ('COMPLETED','STALE','SUPERSEDED') THEN RETURN v_req.result; END IF;
  IF v_receipt.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Receipt is not a draft'; END IF;
  v_hash:=md5(v_receipt.id::text||':'||v_receipt.supplier_id::text||':'||v_receipt.outlet_id::text||':'||
    v_receipt.received_at::text||':'||coalesce(v_receipt.operational_note,'')||':'||
    (SELECT coalesce(string_agg(i.product_id::text||':'||i.accepted_quantity::text||':'||i.bonus_quantity::text||':'||
      i.rejected_quantity::text||':'||coalesce(i.short_quantity::text,'')||':'||coalesce(i.operational_note,''),'|' ORDER BY i.product_id),'')
     FROM public.purchase_receipt_items i WHERE i.receipt_id=v_receipt.id));
  v_evidence_hash:=(SELECT md5(coalesce(string_agg(i.id::text||':'||coalesce(r.revision,0)::text,'|' ORDER BY i.product_id),''))
    FROM public.purchase_receipt_items i LEFT JOIN LATERAL (SELECT x.revision FROM public.purchase_receipt_acquisition_estimate_revisions x
      WHERE x.receipt_item_identity=i.id ORDER BY x.revision DESC LIMIT 1) r ON true WHERE i.receipt_id=v_receipt.id);
  IF (v_req.request_payload->>'content_hash') IS DISTINCT FROM v_hash
    OR (v_req.request_payload->>'acquisition_evidence_hash') IS DISTINCT FROM v_evidence_hash
    OR (v_req.request_payload->>'draft_revision')::integer IS DISTINCT FROM v_receipt.draft_revision THEN
    UPDATE public.stock_operation_requests SET state='STALE',result=jsonb_build_object('ok',false,'code','RECEIPT_CHANGED'),completed_at=now()
      WHERE request_id=v_req.request_id;
    RETURN jsonb_build_object('ok',false,'code','RECEIPT_CHANGED');
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.suppliers WHERE id=v_receipt.supplier_id AND is_active)
    OR NOT EXISTS(SELECT 1 FROM public.outlets WHERE id=v_receipt.outlet_id AND is_active)
    OR NOT EXISTS(SELECT 1 FROM public.purchase_receipt_items i WHERE i.receipt_id=v_receipt.id AND i.accepted_quantity+i.bonus_quantity>0) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Receipt is incomplete or unavailable';
  END IF;
  SELECT a.status INTO v_authority FROM public.inventory_costing_outlet_authority a WHERE a.outlet_id=v_receipt.outlet_id;
  IF v_authority='BOOTSTRAP_READY' THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Penerimaan sementara dijeda saat persiapan awal costing berlangsung';
  END IF;
  FOR v_item IN SELECT i.* FROM public.purchase_receipt_items i WHERE i.receipt_id=v_receipt.id ORDER BY i.product_id LOOP
    v_delta:=v_item.accepted_quantity+v_item.bonus_quantity;
    IF v_delta<=0 THEN CONTINUE; END IF;
    SELECT * INTO v_projection FROM public.stock_balance_projection p WHERE p.product_id=v_item.product_id AND p.outlet_id=v_receipt.outlet_id FOR UPDATE;
    IF NOT FOUND OR v_projection.effective_quantity IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Stock projection is unavailable for this outlet period'; END IF;
  END LOOP;
  SELECT * INTO v_period FROM public.stock_authority_periods WHERE outlet_id=v_receipt.outlet_id AND ended_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Stock authority period is unavailable'; END IF;
  IF EXISTS(SELECT 1 FROM public.purchase_receipt_items i JOIN public.stock_balance_projection p
    ON p.product_id=i.product_id AND p.outlet_id=v_receipt.outlet_id
    WHERE i.receipt_id=v_receipt.id AND i.accepted_quantity+i.bonus_quantity>0 AND p.authority_period_id<>v_period.id) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Stock projection is unavailable for this outlet period';
  END IF;
  INSERT INTO public.stock_movement_batches(authority_period_id,outlet_id,source_system,operation_request_id,created_by)
    VALUES(v_period.id,v_receipt.outlet_id,'PURCHASING',v_req.request_id,v_actor) RETURNING id INTO v_batch;
  FOR v_item IN SELECT i.* FROM public.purchase_receipt_items i WHERE i.receipt_id=v_receipt.id ORDER BY i.product_id LOOP
    v_delta:=v_item.accepted_quantity+v_item.bonus_quantity;
    IF v_delta<=0 THEN CONTINUE; END IF;
    SELECT d.balance_before,d.balance_after,d.new_balance_version INTO v_before,v_after,v_version
      FROM public.stock_apply_balance_delta(v_item.product_id,v_receipt.outlet_id,v_delta) d;
    INSERT INTO public.stock_movements(batch_id,authority_period_id,outlet_id,product_id,movement_type,source_system,
      quantity_delta,balance_before,balance_after,purchase_receipt_item_id,source_reference,source_event_key,created_by)
    VALUES(v_batch,v_period.id,v_receipt.outlet_id,v_item.product_id,'PURCHASE_RECEIPT','PURCHASING',v_delta,v_before,v_after,
      v_item.id,v_receipt.receipt_reference,v_receipt.id::text||':'||v_item.id::text,v_actor);
    INSERT INTO public.stock_balance_projection_events(product_id,outlet_id,authority_period_id,event_type,request_id,
      quantity_delta,balance_before,balance_after,balance_version,actor_id)
    VALUES(v_item.product_id,v_receipt.outlet_id,v_period.id,'MOVEMENT_POSTED',v_req.request_id,v_delta,v_before,v_after,v_version,v_actor);
    v_count:=v_count+1;
  END LOOP;
  IF v_authority='WAC_ACTIVE' THEN
    v_cost_events:=public.inventory_cost_apply_purchase_receipt(v_req.request_id,v_receipt.id,v_batch,v_period.id);
  END IF;
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
REVOKE ALL ON FUNCTION public.apply_purchase_receipt_post_intent(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.apply_purchase_receipt_post_intent(uuid) TO authenticated;

GRANT USAGE ON TYPE public.inventory_cost_projection_status,
  public.purchase_receipt_acquisition_evidence_kind,public.inventory_cost_acquisition_basis TO authenticated;
REVOKE ALL ON TYPE public.inventory_cost_projection_status,
  public.purchase_receipt_acquisition_evidence_kind,public.inventory_cost_acquisition_basis FROM PUBLIC,anon;

COMMIT;
