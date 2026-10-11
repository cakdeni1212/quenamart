-- P1D-C: bounded commercial receipt read only. Checkout remains in P1D-B.
BEGIN;

CREATE FUNCTION public.pos_sale_receipt_read(p_sale_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_role public.user_role;
  v_outlet uuid;
  v_outlet_count integer;
  v_result jsonb;
BEGIN
  v_role := public.current_active_user_role();
  IF v_actor IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'KASIR'::public.user_role)
     OR p_sale_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT count(*)::integer, (array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1]
    INTO v_outlet_count, v_outlet
  FROM public.stock_authority_periods ap
  JOIN public.outlets o ON o.id=ap.outlet_id
  WHERE ap.ended_at IS NULL AND o.is_active;

  IF v_outlet_count <> 1 OR v_outlet IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object(
    'sale_id', s.id,
    'sale_number', s.sale_number,
    'completed_at', s.completed_at,
    'cashier_label', coalesce(nullif(btrim(cr.result->>'cashier_label'), ''), 'Kasir'),
    'items', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'name', si.product_name_snapshot,
        'sku', si.sku_snapshot,
        'unit', si.unit_snapshot,
        'quantity', si.quantity,
        'unit_selling_price', si.unit_selling_price,
        'line_subtotal', si.line_subtotal
      ) ORDER BY si.line_number), '[]'::jsonb)
      FROM public.sale_items si WHERE si.sale_id=s.id AND si.outlet_id=s.outlet_id
    ),
    'subtotal', s.subtotal,
    'discount_total', s.discount_total,
    'grand_total', s.grand_total,
    'payments', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'method', sp.method,
        'applied_amount', sp.applied_amount,
        'received_amount', sp.received_amount,
        'change_amount', sp.change_amount,
        'reference_text', sp.reference_text
      ) ORDER BY sp.recorded_at, sp.id), '[]'::jsonb)
      FROM public.sale_payments sp WHERE sp.sale_id=s.id AND sp.outlet_id=s.outlet_id
    )
  ) INTO v_result
  FROM public.sales s
  JOIN public.pos_checkout_requests cr
    ON cr.request_id=s.checkout_request_id AND cr.outlet_id=s.outlet_id
  WHERE s.id=p_sale_id
    AND s.outlet_id=v_outlet
    AND s.source_system='QUENA_POS'::public.pos_sale_source
    AND s.status='COMPLETED'::public.pos_sale_status
    AND (v_role IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) OR s.cashier_id=v_actor);

  RETURN v_result;
END;
$$;

ALTER FUNCTION public.pos_sale_receipt_read(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_sale_receipt_read(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_sale_receipt_read(uuid) TO authenticated;

COMMIT;
