BEGIN;

CREATE TABLE public.outlet_pos_settings (
  outlet_id uuid PRIMARY KEY REFERENCES public.outlets(id) ON DELETE RESTRICT,
  receipt_footer_note text,
  receipt_show_address boolean NOT NULL DEFAULT true,
  receipt_show_phone boolean NOT NULL DEFAULT true,
  payment_cash_enabled boolean NOT NULL DEFAULT true,
  payment_qris_enabled boolean NOT NULL DEFAULT true,
  payment_card_enabled boolean NOT NULL DEFAULT true,
  payment_e_wallet_enabled boolean NOT NULL DEFAULT true,
  allow_hold_transactions boolean NOT NULL DEFAULT true,
  confirm_cart_cancellation boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  CONSTRAINT outlet_pos_settings_footer_valid CHECK (
    receipt_footer_note IS NULL OR (btrim(receipt_footer_note)<>'' AND length(receipt_footer_note)<=200 AND receipt_footer_note !~ '[[:cntrl:]]')
  ),
  CONSTRAINT outlet_pos_settings_payment_required CHECK (
    payment_cash_enabled OR payment_qris_enabled OR payment_card_enabled OR payment_e_wallet_enabled
  )
);
ALTER TABLE public.outlet_pos_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.outlet_pos_settings FROM PUBLIC,anon,authenticated,service_role;

ALTER TABLE public.outlet_settings_events DROP CONSTRAINT outlet_settings_events_event_type_check;
ALTER TABLE public.outlet_settings_events ADD CONSTRAINT outlet_settings_events_event_type_check
  CHECK (event_type IN ('OUTLET_SETTINGS_UPDATED','POS_SETTINGS_UPDATED'));

CREATE FUNCTION public.pos_settings_effective(p_outlet_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'outlet_id',o.id,
    'receipt_footer_note',s.receipt_footer_note,
    'receipt_show_address',coalesce(s.receipt_show_address,true),
    'receipt_show_phone',coalesce(s.receipt_show_phone,true),
    'enabled_payment_methods',array_remove(ARRAY[
      CASE WHEN coalesce(s.payment_cash_enabled,true) THEN 'CASH'::text END,
      CASE WHEN coalesce(s.payment_qris_enabled,true) THEN 'QRIS'::text END,
      CASE WHEN coalesce(s.payment_card_enabled,true) THEN 'CARD'::text END,
      CASE WHEN coalesce(s.payment_e_wallet_enabled,true) THEN 'E_WALLET'::text END
    ],NULL),
    'allow_hold_transactions',coalesce(s.allow_hold_transactions,true),
    'confirm_cart_cancellation',coalesce(s.confirm_cart_cancellation,true),
    'updated_at',s.updated_at
  ) INTO v_result
  FROM public.outlets o LEFT JOIN public.outlet_pos_settings s ON s.outlet_id=o.id
  WHERE o.id=p_outlet_id AND o.is_active;
  IF v_result IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POS_SETTINGS_OUTLET_UNAVAILABLE'; END IF;
  RETURN v_result;
END;
$$;
ALTER FUNCTION public.pos_settings_effective(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_settings_effective(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.pos_settings_read()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role:=public.current_active_user_role(); v_outlet uuid; v_result jsonb;
BEGIN
  IF v_actor IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_SETTINGS_READ_DENIED';
  END IF;
  v_outlet:=public.outlet_settings_current_id();
  v_result:=public.pos_settings_effective(v_outlet);
  RETURN v_result;
END;
$$;
ALTER FUNCTION public.pos_settings_read() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_settings_read() FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_settings_read() TO authenticated;

CREATE FUNCTION public.pos_effective_settings_read()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role:=public.current_active_user_role();
BEGIN
  IF v_actor IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'KASIR'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_EFFECTIVE_SETTINGS_DENIED';
  END IF;
  RETURN public.pos_settings_effective(public.outlet_settings_current_id());
END;
$$;
ALTER FUNCTION public.pos_effective_settings_read() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_effective_settings_read() FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_effective_settings_read() TO authenticated;

CREATE FUNCTION public.pos_settings_update(p_outlet_id uuid,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE
  v_actor uuid:=auth.uid(); v_role public.user_role:=public.current_active_user_role(); v_outlet uuid;
  v_footer text; v_address boolean; v_phone boolean; v_cash boolean; v_qris boolean; v_card boolean; v_wallet boolean;
  v_hold boolean; v_confirm boolean; v_changed text[]; v_old jsonb;
BEGIN
  IF v_actor IS NULL OR v_role IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_SETTINGS_UPDATE_DENIED';
  END IF;
  IF p_outlet_id IS NULL OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
    OR p_payload-ARRAY['receipt_footer_note','receipt_show_address','receipt_show_phone','enabled_payment_methods','allow_hold_transactions','confirm_cart_cancellation']<>'{}'::jsonb
    OR jsonb_typeof(p_payload->'receipt_footer_note') NOT IN ('string','null')
    OR jsonb_typeof(p_payload->'receipt_show_address') IS DISTINCT FROM 'boolean'
    OR jsonb_typeof(p_payload->'receipt_show_phone') IS DISTINCT FROM 'boolean'
    OR jsonb_typeof(p_payload->'enabled_payment_methods') IS DISTINCT FROM 'array'
    OR jsonb_typeof(p_payload->'allow_hold_transactions') IS DISTINCT FROM 'boolean'
    OR jsonb_typeof(p_payload->'confirm_cart_cancellation') IS DISTINCT FROM 'boolean' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='POS_SETTINGS_INVALID_PAYLOAD';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'enabled_payment_methods') x WHERE jsonb_typeof(x) IS DISTINCT FROM 'string'
      OR x#>>'{}' NOT IN ('CASH','QRIS','CARD','E_WALLET'))
    OR jsonb_array_length(p_payload->'enabled_payment_methods')<1
    OR jsonb_array_length(p_payload->'enabled_payment_methods')>4
    OR (SELECT count(*) FROM jsonb_array_elements_text(p_payload->'enabled_payment_methods'))<>
       (SELECT count(DISTINCT value) FROM jsonb_array_elements_text(p_payload->'enabled_payment_methods') AS m(value)) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='POS_SETTINGS_INVALID_PAYMENT_METHODS';
  END IF;
  v_footer:=nullif(btrim(p_payload->>'receipt_footer_note'),'');
  IF v_footer IS NOT NULL AND (length(v_footer)>200 OR v_footer ~ '[[:cntrl:]]') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='POS_SETTINGS_INVALID_FOOTER';
  END IF;
  v_address:=(p_payload->>'receipt_show_address')::boolean;
  v_phone:=(p_payload->>'receipt_show_phone')::boolean;
  v_cash:=p_payload->'enabled_payment_methods' ? 'CASH';
  v_qris:=p_payload->'enabled_payment_methods' ? 'QRIS';
  v_card:=p_payload->'enabled_payment_methods' ? 'CARD';
  v_wallet:=p_payload->'enabled_payment_methods' ? 'E_WALLET';
  v_hold:=(p_payload->>'allow_hold_transactions')::boolean;
  v_confirm:=(p_payload->>'confirm_cart_cancellation')::boolean;

  IF p_outlet_id IS DISTINCT FROM public.outlet_settings_current_id() THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='POS_SETTINGS_SCOPE_DENIED';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('POS_SETTINGS_OUTLET:'||p_outlet_id::text,73190411));
  v_old:=public.pos_settings_effective(p_outlet_id);
  v_changed:=array_remove(ARRAY[
    CASE WHEN v_old->>'receipt_footer_note' IS DISTINCT FROM v_footer THEN 'receipt_footer_note' END,
    CASE WHEN (v_old->>'receipt_show_address')::boolean IS DISTINCT FROM v_address THEN 'receipt_show_address' END,
    CASE WHEN (v_old->>'receipt_show_phone')::boolean IS DISTINCT FROM v_phone THEN 'receipt_show_phone' END,
    CASE WHEN (v_old->'enabled_payment_methods') IS DISTINCT FROM to_jsonb(array_remove(ARRAY[
      CASE WHEN v_cash THEN 'CASH'::text END,CASE WHEN v_qris THEN 'QRIS'::text END,
      CASE WHEN v_card THEN 'CARD'::text END,CASE WHEN v_wallet THEN 'E_WALLET'::text END
    ],NULL)) THEN 'enabled_payment_methods' END,
    CASE WHEN (v_old->>'allow_hold_transactions')::boolean IS DISTINCT FROM v_hold THEN 'allow_hold_transactions' END,
    CASE WHEN (v_old->>'confirm_cart_cancellation')::boolean IS DISTINCT FROM v_confirm THEN 'confirm_cart_cancellation' END
  ],NULL);
  IF cardinality(v_changed)=0 THEN RETURN jsonb_build_object('updated',false,'changed_fields','[]'::jsonb,'settings',v_old); END IF;

  INSERT INTO public.outlet_pos_settings(outlet_id,receipt_footer_note,receipt_show_address,receipt_show_phone,
    payment_cash_enabled,payment_qris_enabled,payment_card_enabled,payment_e_wallet_enabled,
    allow_hold_transactions,confirm_cart_cancellation,updated_by,updated_at)
  VALUES(p_outlet_id,v_footer,v_address,v_phone,v_cash,v_qris,v_card,v_wallet,v_hold,v_confirm,v_actor,now())
  ON CONFLICT(outlet_id) DO UPDATE SET receipt_footer_note=EXCLUDED.receipt_footer_note,
    receipt_show_address=EXCLUDED.receipt_show_address,receipt_show_phone=EXCLUDED.receipt_show_phone,
    payment_cash_enabled=EXCLUDED.payment_cash_enabled,payment_qris_enabled=EXCLUDED.payment_qris_enabled,
    payment_card_enabled=EXCLUDED.payment_card_enabled,payment_e_wallet_enabled=EXCLUDED.payment_e_wallet_enabled,
    allow_hold_transactions=EXCLUDED.allow_hold_transactions,confirm_cart_cancellation=EXCLUDED.confirm_cart_cancellation,
    updated_by=EXCLUDED.updated_by,updated_at=EXCLUDED.updated_at;
  INSERT INTO public.outlet_settings_events(outlet_id,actor_id,event_type,changed_fields)
    VALUES(p_outlet_id,v_actor,'POS_SETTINGS_UPDATED',v_changed);
  RETURN jsonb_build_object('updated',true,'changed_fields',to_jsonb(v_changed),'settings',public.pos_settings_effective(p_outlet_id));
END;
$$;
ALTER FUNCTION public.pos_settings_update(uuid,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_settings_update(uuid,jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_settings_update(uuid,jsonb) TO authenticated;

CREATE FUNCTION public.pos_settings_guard_payment_method()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_settings jsonb;
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('POS_SETTINGS_OUTLET:'||NEW.outlet_id::text,73190411));
  v_settings:=public.pos_settings_effective(NEW.outlet_id);
  IF NOT (v_settings->'enabled_payment_methods' ? NEW.method::text) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POS_PAYMENT_METHOD_DISABLED';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.pos_settings_guard_payment_method() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_settings_guard_payment_method() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER sale_payments_enabled_method_guard
BEFORE INSERT ON public.sale_payments
FOR EACH ROW EXECUTE FUNCTION public.pos_settings_guard_payment_method();

CREATE FUNCTION public.pos_settings_guard_hold()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_settings jsonb;
BEGIN
  IF OLD.status IS DISTINCT FROM 'PARKED'::public.pos_cart_status AND NEW.status='PARKED'::public.pos_cart_status THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('POS_SETTINGS_OUTLET:'||NEW.outlet_id::text,73190411));
    v_settings:=public.pos_settings_effective(NEW.outlet_id);
    IF NOT coalesce((v_settings->>'allow_hold_transactions')::boolean,true) THEN
      RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='POS_HOLD_DISABLED';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.pos_settings_guard_hold() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_settings_guard_hold() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER pos_cart_hold_enabled_guard
BEFORE UPDATE OF status ON public.pos_carts
FOR EACH ROW EXECUTE FUNCTION public.pos_settings_guard_hold();

CREATE OR REPLACE FUNCTION public.pos_sale_receipt_read(p_sale_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_outlet uuid; v_outlet_count integer; v_result jsonb;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'KASIR'::public.user_role) OR p_sale_id IS NULL THEN RETURN NULL; END IF;
  SELECT count(*)::integer,(array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1] INTO v_outlet_count,v_outlet
  FROM public.stock_authority_periods ap JOIN public.outlets active_outlet ON active_outlet.id=ap.outlet_id
  WHERE ap.ended_at IS NULL AND active_outlet.is_active;
  IF v_outlet_count<>1 OR v_outlet IS NULL THEN RETURN NULL; END IF;

  SELECT jsonb_build_object(
    'sale_id',s.id,'sale_number',s.sale_number,'completed_at',s.completed_at,
    'cashier_label',coalesce(nullif(btrim(cr.result->>'cashier_label'),''),'Kasir'),
    'outlet_display_name',coalesce(nullif(btrim(o.customer_display_name),''),o.name),
    'outlet_address',CASE WHEN coalesce(ps.receipt_show_address,true) THEN nullif(concat_ws(', ',nullif(btrim(o.address),''),nullif(btrim(o.city),''),nullif(btrim(o.province),''),nullif(btrim(o.postal_code),'')),'') END,
    'outlet_phone',CASE WHEN coalesce(ps.receipt_show_phone,true) THEN o.phone END,
    'outlet_whatsapp',CASE WHEN coalesce(ps.receipt_show_phone,true) THEN o.whatsapp END,
    'receipt_footer_note',ps.receipt_footer_note,
    'items',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',si.product_name_snapshot,'sku',si.sku_snapshot,'unit',si.unit_snapshot,
      'quantity',si.quantity,'unit_selling_price',si.unit_selling_price,'line_subtotal',si.line_subtotal) ORDER BY si.line_number),'[]'::jsonb)
      FROM public.sale_items si WHERE si.sale_id=s.id AND si.outlet_id=s.outlet_id),
    'subtotal',s.subtotal,'discount_total',s.discount_total,'grand_total',s.grand_total,
    'payments',(SELECT coalesce(jsonb_agg(jsonb_build_object('method',sp.method,'applied_amount',sp.applied_amount,
      'received_amount',sp.received_amount,'change_amount',sp.change_amount,'reference_text',sp.reference_text) ORDER BY sp.recorded_at,sp.id),'[]'::jsonb)
      FROM public.sale_payments sp WHERE sp.sale_id=s.id AND sp.outlet_id=s.outlet_id)
  ) INTO v_result
  FROM public.sales s JOIN public.pos_checkout_requests cr ON cr.request_id=s.checkout_request_id AND cr.outlet_id=s.outlet_id
  JOIN public.outlets o ON o.id=s.outlet_id LEFT JOIN public.outlet_pos_settings ps ON ps.outlet_id=o.id
  WHERE s.id=p_sale_id AND s.outlet_id=v_outlet AND s.source_system='QUENA_POS'::public.pos_sale_source
    AND s.status='COMPLETED'::public.pos_sale_status
    AND (v_role IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) OR s.cashier_id=v_actor);
  RETURN v_result;
END;
$$;
ALTER FUNCTION public.pos_sale_receipt_read(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_sale_receipt_read(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_sale_receipt_read(uuid) TO authenticated;

COMMIT;
