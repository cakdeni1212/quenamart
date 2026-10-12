-- Bounded, commercial-only read model for completed native POS sales.
BEGIN;

-- Keep the existing receipt contract fail-closed for profiles deactivated after their JWT was issued.
CREATE OR REPLACE FUNCTION public.pos_sale_receipt_read(p_sale_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog
AS $$
DECLARE
  v_actor uuid:=auth.uid();
  v_role public.user_role;
  v_outlet uuid;
  v_outlet_count integer;
  v_result jsonb;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL
     OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'KASIR'::public.user_role)
     OR p_sale_id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT count(*)::integer,(array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1]
    INTO v_outlet_count,v_outlet
  FROM public.stock_authority_periods ap
  JOIN public.outlets o ON o.id=ap.outlet_id
  WHERE ap.ended_at IS NULL AND o.is_active;
  IF v_outlet_count<>1 OR v_outlet IS NULL THEN RETURN NULL; END IF;

  SELECT jsonb_build_object(
    'sale_id',s.id,'sale_number',s.sale_number,'completed_at',s.completed_at,
    'cashier_label',coalesce(nullif(btrim(cr.result->>'cashier_label'),''),'Kasir'),
    'items',(SELECT coalesce(jsonb_agg(jsonb_build_object(
      'name',si.product_name_snapshot,'sku',si.sku_snapshot,'unit',si.unit_snapshot,
      'quantity',si.quantity,'unit_selling_price',si.unit_selling_price,'line_subtotal',si.line_subtotal
    ) ORDER BY si.line_number),'[]'::jsonb)
      FROM public.sale_items si WHERE si.sale_id=s.id AND si.outlet_id=s.outlet_id),
    'subtotal',s.subtotal,'discount_total',s.discount_total,'grand_total',s.grand_total,
    'payments',(SELECT coalesce(jsonb_agg(jsonb_build_object(
      'method',sp.method,'applied_amount',sp.applied_amount,'received_amount',sp.received_amount,
      'change_amount',sp.change_amount,'reference_text',sp.reference_text
    ) ORDER BY sp.recorded_at,sp.id),'[]'::jsonb)
      FROM public.sale_payments sp WHERE sp.sale_id=s.id AND sp.outlet_id=s.outlet_id)
  ) INTO v_result
  FROM public.sales s
  JOIN public.pos_checkout_requests cr ON cr.request_id=s.checkout_request_id AND cr.outlet_id=s.outlet_id
  WHERE s.id=p_sale_id AND s.outlet_id=v_outlet
    AND s.source_system='QUENA_POS'::public.pos_sale_source
    AND s.status='COMPLETED'::public.pos_sale_status
    AND (v_role IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) OR s.cashier_id=v_actor);
  RETURN v_result;
END;
$$;
ALTER FUNCTION public.pos_sale_receipt_read(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_sale_receipt_read(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_sale_receipt_read(uuid) TO authenticated;

CREATE FUNCTION public.pos_sales_history_read(
  p_from date,
  p_to date,
  p_search text DEFAULT NULL,
  p_method text DEFAULT NULL,
  p_page integer DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog
AS $$
DECLARE
  v_actor uuid:=auth.uid();
  v_role public.user_role;
  v_outlet uuid;
  v_outlet_count integer;
  v_search text:=nullif(btrim(p_search),'');
  v_page integer:=coalesce(p_page,1);
  v_result jsonb;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'KASIR'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='SALES_HISTORY_UNAUTHORIZED';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to<p_from OR p_to-p_from>365
     OR v_page<1 OR v_page>1000000
     OR (v_search IS NOT NULL AND (length(v_search)>80 OR v_search ~ '[[:cntrl:]]'))
     OR (p_method IS NOT NULL AND p_method NOT IN ('CASH','QRIS','CARD','E_WALLET')) THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='SALES_HISTORY_FILTER_INVALID';
  END IF;

  SELECT count(*)::integer,(array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1]
    INTO v_outlet_count,v_outlet
  FROM public.stock_authority_periods ap
  JOIN public.outlets o ON o.id=ap.outlet_id
  WHERE ap.ended_at IS NULL AND o.is_active;
  IF v_outlet_count<>1 OR v_outlet IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='SALES_HISTORY_UNAUTHORIZED';
  END IF;

  WITH filtered AS MATERIALIZED (
    SELECT s.id,s.sale_number,s.completed_at,s.grand_total,s.cashier_id,
      coalesce(nullif(btrim(cr.result->>'cashier_label'),''),nullif(btrim(p.full_name),''),'Kasir') AS cashier_label,
      (SELECT count(*)::integer FROM public.sale_items si WHERE si.sale_id=s.id AND si.outlet_id=s.outlet_id) AS item_count,
      (SELECT CASE WHEN count(*)=1 THEN min(sp.method::text) WHEN count(*)>1 THEN 'MIXED' ELSE NULL END
         FROM public.sale_payments sp WHERE sp.sale_id=s.id AND sp.outlet_id=s.outlet_id) AS payment_method
    FROM public.sales s
    JOIN public.pos_checkout_requests cr ON cr.request_id=s.checkout_request_id AND cr.outlet_id=s.outlet_id
    LEFT JOIN public.profiles p ON p.id=s.cashier_id
    WHERE s.outlet_id=v_outlet
      AND s.source_system='QUENA_POS'::public.pos_sale_source
      AND s.status='COMPLETED'::public.pos_sale_status
      AND s.completed_at >= (p_from::timestamp AT TIME ZONE 'Asia/Jakarta')
      AND s.completed_at < ((p_to+1)::timestamp AT TIME ZONE 'Asia/Jakarta')
      AND (v_role<>'KASIR'::public.user_role OR s.cashier_id=v_actor)
      AND (v_search IS NULL OR position(lower(v_search) in lower(s.sale_number))>0)
      AND (p_method IS NULL OR EXISTS(
        SELECT 1 FROM public.sale_payments sp
        WHERE sp.sale_id=s.id AND sp.outlet_id=s.outlet_id AND sp.method::text=p_method
      ))
  ), summary AS (
    SELECT count(*)::bigint AS transaction_count,
      coalesce(sum(grand_total),0)::numeric(32,2)::text AS total_sales,
      coalesce(round(avg(grand_total),2),0)::numeric(32,2)::text AS average_transaction
    FROM filtered
  ), page_rows AS (
    SELECT id,sale_number,completed_at,cashier_label,item_count,grand_total::text AS grand_total,payment_method
    FROM filtered
    ORDER BY completed_at DESC,id DESC
    LIMIT 20 OFFSET ((v_page-1)*20)
  ), row_json AS (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id',id,'sale_number',sale_number,'completed_at',completed_at,
      'cashier_label',cashier_label,'item_count',item_count,
      'grand_total',grand_total,'payment_method',payment_method
    ) ORDER BY completed_at DESC,id DESC),'[]'::jsonb) AS rows
    FROM page_rows
  )
  SELECT jsonb_build_object(
    'rows',row_json.rows,
    'page',v_page,
    'page_size',20,
    'total_count',summary.transaction_count,
    'total_pages',greatest(1,ceil(summary.transaction_count::numeric/20)::integer),
    'summary',jsonb_build_object(
      'total_sales',summary.total_sales,
      'transaction_count',summary.transaction_count,
      'average_transaction',summary.average_transaction
    )
  ) INTO v_result
  FROM summary CROSS JOIN row_json;
  RETURN v_result;
END;
$$;

ALTER FUNCTION public.pos_sales_history_read(date,date,text,text,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pos_sales_history_read(date,date,text,text,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_sales_history_read(date,date,text,text,integer) TO authenticated;

COMMIT;
