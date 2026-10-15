-- Secure customer read identity for completed native POS receipts.
-- No historical token backfill and no sales/inventory/loyalty mutation.
BEGIN;

CREATE TABLE public.sale_public_receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_id uuid NOT NULL UNIQUE REFERENCES public.sales(id) ON DELETE RESTRICT,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  token_hash text UNIQUE CHECK (token_hash IS NULL OR token_hash ~ '^[0-9a-f]{64}$'),
  status text NOT NULL DEFAULT 'UNISSUED' CHECK (status IN ('UNISSUED','ACTIVE','REVOKED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  rotated_at timestamptz,
  revoked_at timestamptz,
  created_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  updated_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  CONSTRAINT sale_public_receipt_state_token CHECK
    ((status='ACTIVE' AND token_hash IS NOT NULL AND revoked_at IS NULL)
     OR (status='UNISSUED' AND token_hash IS NULL AND revoked_at IS NULL)
     OR (status='REVOKED' AND token_hash IS NULL AND revoked_at IS NOT NULL)),
  CONSTRAINT sale_public_receipt_sale_outlet_fk FOREIGN KEY(sale_id,outlet_id)
    REFERENCES public.sales(id,outlet_id) ON DELETE RESTRICT
);
CREATE INDEX sale_public_receipts_active_hash_idx ON public.sale_public_receipts(token_hash) WHERE status='ACTIVE';
ALTER TABLE public.sale_public_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_public_receipts FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.sale_public_receipts FROM PUBLIC,anon,authenticated,service_role;

CREATE TABLE public.sale_public_receipt_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_id uuid NOT NULL REFERENCES public.sales(id) ON DELETE RESTRICT,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type IN ('IDENTITY_CREATED','LINK_ISSUED','LINK_ROTATED','LINK_REVOKED','DELIVERY_LINK_ISSUED')),
  actor_id uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sale_public_receipt_events_sale_time_idx ON public.sale_public_receipt_events(sale_id,occurred_at DESC);
ALTER TABLE public.sale_public_receipt_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_public_receipt_events FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.sale_public_receipt_events FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.ensure_pos_sale_receipt_identity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE s public.sales%ROWTYPE;
BEGIN
  IF OLD.state::text IS DISTINCT FROM 'COMPLETED'
     AND NEW.state::text='COMPLETED' AND NEW.sale_id IS NOT NULL THEN
    BEGIN
      SELECT * INTO s FROM public.sales WHERE id=NEW.sale_id AND checkout_request_id=NEW.request_id
        AND source_system='QUENA_POS'::public.pos_sale_source AND status='COMPLETED'::public.pos_sale_status;
      IF FOUND THEN
        INSERT INTO public.sale_public_receipts(sale_id,outlet_id,status)
        VALUES(s.id,s.outlet_id,'UNISSUED') ON CONFLICT(sale_id) DO NOTHING;
        IF FOUND THEN
          INSERT INTO public.sale_public_receipt_events(sale_id,outlet_id,event_type)
          VALUES(s.id,s.outlet_id,'IDENTITY_CREATED');
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- Optional receipt access must not abort authoritative checkout.
      RAISE WARNING 'POS receipt identity could not be initialized for completed sale request';
    END;
  END IF;
  RETURN NEW;
END $$;
ALTER FUNCTION public.ensure_pos_sale_receipt_identity() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.ensure_pos_sale_receipt_identity() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER pos_checkout_receipt_identity_after_complete
AFTER UPDATE OF state ON public.pos_checkout_requests
FOR EACH ROW EXECUTE FUNCTION public.ensure_pos_sale_receipt_identity();

CREATE FUNCTION public.pos_sale_public_receipt_issue(p_sale_id uuid,p_token_hash text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid;
  s public.sales%ROWTYPE; prior public.sale_public_receipts%ROWTYPE; action_name text;
BEGIN
  IF a IS NULL OR r IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'KASIR'::public.user_role)
     OR p_sale_id IS NULL OR p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='RECEIPT_LINK_NOT_AVAILABLE';
  END IF;
  o:=public.member_current_outlet();
  SELECT * INTO s FROM public.sales WHERE id=p_sale_id AND outlet_id=o
    AND source_system='QUENA_POS'::public.pos_sale_source AND status='COMPLETED'::public.pos_sale_status FOR UPDATE;
  IF NOT FOUND OR (r='KASIR'::public.user_role AND s.cashier_id<>a) THEN
    RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='RECEIPT_LINK_NOT_AVAILABLE';
  END IF;
  SELECT * INTO prior FROM public.sale_public_receipts WHERE sale_id=s.id FOR UPDATE;
  action_name:=CASE WHEN NOT FOUND OR prior.status='UNISSUED' THEN 'LINK_ISSUED' ELSE 'LINK_ROTATED' END;
  INSERT INTO public.sale_public_receipts(sale_id,outlet_id,token_hash,status,updated_at,rotated_at,revoked_at,created_by,updated_by)
  VALUES(s.id,o,p_token_hash,'ACTIVE',now(),NULL,NULL,a,a)
  ON CONFLICT(sale_id) DO UPDATE SET token_hash=EXCLUDED.token_hash,status='ACTIVE',updated_at=now(),
    rotated_at=now(),revoked_at=NULL,updated_by=a;
  INSERT INTO public.sale_public_receipt_events(sale_id,outlet_id,event_type,actor_id)
  VALUES(s.id,o,action_name,a);
  RETURN jsonb_build_object('ok',true);
END $$;
ALTER FUNCTION public.pos_sale_public_receipt_issue(uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_sale_public_receipt_issue(uuid,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_sale_public_receipt_issue(uuid,text) TO authenticated;

CREATE FUNCTION public.customer_public_receipt_read(p_token_hash text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE result jsonb;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' OR p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$' THEN
    RETURN NULL;
  END IF;
  SELECT jsonb_build_object(
    'store',jsonb_build_object(
      'name',coalesce(nullif(btrim(o.customer_display_name),''),o.name),
      'address',CASE WHEN coalesce(ps.receipt_show_address,true) THEN nullif(concat_ws(', ',nullif(btrim(o.address),''),nullif(btrim(o.city),''),nullif(btrim(o.province),''),nullif(btrim(o.postal_code),'')),'') END,
      'phone',CASE WHEN coalesce(ps.receipt_show_phone,true) THEN coalesce(nullif(btrim(o.phone),''),nullif(btrim(o.whatsapp),'')) END,
      'footer',ps.receipt_footer_note
    ),
    'sale',jsonb_build_object('number',s.sale_number,'completed_at',s.completed_at,
      'cashier',coalesce(nullif(btrim(cr.result->>'cashier_label'),''),'Kasir')),
    'items',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',si.product_name_snapshot,'unit',si.unit_snapshot,
      'quantity',si.quantity,'unit_price',si.unit_selling_price,'line_total',si.line_subtotal) ORDER BY si.line_number),'[]'::jsonb)
      FROM public.sale_items si WHERE si.sale_id=s.id AND si.outlet_id=s.outlet_id),
    'totals',jsonb_build_object('subtotal',s.subtotal,'discount_total',s.discount_total,'grand_total',s.grand_total),
    'payments',(SELECT coalesce(jsonb_agg(jsonb_build_object('method',sp.method,'amount',sp.applied_amount,
      'received',CASE WHEN sp.method='CASH'::public.pos_sale_payment_method THEN sp.received_amount END,
      'change',CASE WHEN sp.method='CASH'::public.pos_sale_payment_method THEN sp.change_amount END)
      ORDER BY sp.recorded_at,sp.id),'[]'::jsonb) FROM public.sale_payments sp WHERE sp.sale_id=s.id AND sp.outlet_id=s.outlet_id),
    'member',CASE WHEN s.member_id IS NULL THEN NULL ELSE jsonb_build_object('name',m.full_name,'member_number',m.member_number) END,
    'loyalty',CASE WHEN s.member_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.member_point_ledger l WHERE l.sale_id=s.id) THEN NULL
      ELSE jsonb_build_object(
        'points_earned',coalesce((SELECT sum(points_delta) FROM public.member_point_ledger WHERE sale_id=s.id AND event_type='SALE_EARN'),0),
        'points_redeemed',coalesce(-(SELECT sum(points_delta) FROM public.member_point_ledger WHERE sale_id=s.id AND event_type='SALE_REDEEM'),0),
        'points_discount',coalesce((SELECT (policy_snapshot->>'discount_amount')::numeric FROM public.member_point_ledger WHERE sale_id=s.id AND event_type='SALE_REDEEM' LIMIT 1),0),
        'balance_after',coalesce(
          (SELECT nullif(policy_snapshot->>'balance_after_event','')::bigint FROM public.member_point_ledger WHERE sale_id=s.id AND event_type='SALE_EARN' LIMIT 1),
          (SELECT nullif(policy_snapshot->>'balance_after_event','')::bigint FROM public.member_point_ledger WHERE sale_id=s.id AND event_type='SALE_REDEEM' LIMIT 1)
        )
      ) END
  ) INTO result
  FROM public.sale_public_receipts pr
  JOIN public.sales s ON s.id=pr.sale_id AND s.outlet_id=pr.outlet_id
  JOIN public.pos_checkout_requests cr ON cr.request_id=s.checkout_request_id AND cr.outlet_id=s.outlet_id
  JOIN public.outlets o ON o.id=s.outlet_id
  LEFT JOIN public.outlet_pos_settings ps ON ps.outlet_id=o.id
  LEFT JOIN public.members m ON m.id=s.member_id AND m.outlet_id=s.outlet_id
  WHERE pr.token_hash=p_token_hash AND pr.status='ACTIVE'
    AND s.source_system='QUENA_POS'::public.pos_sale_source AND s.status='COMPLETED'::public.pos_sale_status;
  RETURN result;
END $$;
ALTER FUNCTION public.customer_public_receipt_read(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.customer_public_receipt_read(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.customer_public_receipt_read(text) TO service_role;

CREATE FUNCTION public.customer_receipt_delivery_payload(p_sale_id uuid,p_token_hash text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE s public.sales%ROWTYPE; m public.members%ROWTYPE; o public.outlets%ROWTYPE;
  points_earned bigint; points_redeemed bigint; point_discount numeric; balance_after bigint;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' OR p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$' THEN RETURN NULL; END IF;
  SELECT * INTO s FROM public.sales WHERE id=p_sale_id AND source_system='QUENA_POS'::public.pos_sale_source
    AND status='COMPLETED'::public.pos_sale_status;
  IF NOT FOUND OR s.member_id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO m FROM public.members WHERE id=s.member_id AND outlet_id=s.outlet_id;
  SELECT * INTO o FROM public.outlets WHERE id=s.outlet_id;
  IF NOT FOUND OR m.phone_normalized IS NULL OR coalesce((
    SELECT ce.granted FROM public.member_consent_evidence ce
    WHERE ce.member_id=m.id AND ce.outlet_id=s.outlet_id AND ce.consent_type='MEMBERSHIP_SERVICE'
    ORDER BY ce.occurred_at DESC,ce.id DESC LIMIT 1
  ),false) IS NOT TRUE THEN RETURN NULL; END IF;
  SELECT coalesce(sum(points_delta) FILTER(WHERE event_type='SALE_EARN'),0)::bigint,
    coalesce(-sum(points_delta) FILTER(WHERE event_type='SALE_REDEEM'),0)::bigint,
    coalesce(max((policy_snapshot->>'discount_amount')::numeric) FILTER(WHERE event_type='SALE_REDEEM'),0),
    coalesce(max((policy_snapshot->>'balance_after_event')::bigint) FILTER(WHERE event_type='SALE_EARN'),
      max((policy_snapshot->>'balance_after_event')::bigint) FILTER(WHERE event_type='SALE_REDEEM'))
    INTO points_earned,points_redeemed,point_discount,balance_after
    FROM public.member_point_ledger WHERE sale_id=s.id;
  INSERT INTO public.sale_public_receipts(sale_id,outlet_id,token_hash,status,rotated_at,created_by,updated_by)
  VALUES(s.id,s.outlet_id,p_token_hash,'ACTIVE',now(),NULL,NULL)
  ON CONFLICT(sale_id) DO UPDATE SET token_hash=EXCLUDED.token_hash,status='ACTIVE',updated_at=now(),rotated_at=now(),revoked_at=NULL,updated_by=NULL;
  INSERT INTO public.sale_public_receipt_events(sale_id,outlet_id,event_type)
  VALUES(s.id,s.outlet_id,'DELIVERY_LINK_ISSUED');
  RETURN jsonb_build_object('destination_whatsapp',m.phone_normalized,'customer_name',m.full_name,
    'sale_number',s.sale_number,'total',s.grand_total,'points_earned',points_earned,
    'points_redeemed',points_redeemed,'points_discount',point_discount,'balance_after',balance_after);
END $$;
ALTER FUNCTION public.customer_receipt_delivery_payload(uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.customer_receipt_delivery_payload(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.customer_receipt_delivery_payload(uuid,text) TO service_role;

COMMIT;
