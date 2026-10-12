-- Bounded, read-only owner dashboard data. All business dates use Jakarta.
BEGIN;

CREATE FUNCTION public.owner_dashboard_read(p_trend_days integer DEFAULT 7)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_role public.user_role;
  v_outlet uuid;
  v_outlet_count integer;
  v_today date := timezone('Asia/Jakarta', now())::date;
  v_days integer := coalesce(p_trend_days, 7);
  v_costing_status public.inventory_cost_authority_status;
  v_result jsonb;
BEGIN
  v_role := public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN (
    'OWNER'::public.user_role, 'ADMIN'::public.user_role
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='OWNER_DASHBOARD_UNAUTHORIZED';
  END IF;
  IF v_days NOT IN (7, 30) THEN
    RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='OWNER_DASHBOARD_FILTER_INVALID';
  END IF;

  SELECT count(*)::integer, (array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1]
    INTO v_outlet_count, v_outlet
  FROM public.stock_authority_periods ap
  JOIN public.outlets o ON o.id = ap.outlet_id
  WHERE ap.ended_at IS NULL AND o.is_active;
  IF v_outlet_count <> 1 OR v_outlet IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='OWNER_DASHBOARD_OUTLET_UNAVAILABLE';
  END IF;

  SELECT a.status INTO v_costing_status
  FROM public.inventory_costing_outlet_authority a
  WHERE a.outlet_id = v_outlet;

  WITH bounds AS (
    SELECT v_today::timestamp AT TIME ZONE 'Asia/Jakarta' AS today_start,
      (v_today + 1)::timestamp AT TIME ZONE 'Asia/Jakarta' AS tomorrow_start,
      (v_today - 1)::timestamp AT TIME ZONE 'Asia/Jakarta' AS yesterday_start
  ), today_sales AS MATERIALIZED (
    SELECT s.id, s.grand_total
    FROM public.sales s CROSS JOIN bounds b
    WHERE s.outlet_id = v_outlet
      AND s.source_system = 'QUENA_POS'::public.pos_sale_source
      AND s.status = 'COMPLETED'::public.pos_sale_status
      AND s.completed_at >= b.today_start AND s.completed_at < b.tomorrow_start
  ), yesterday_sales AS MATERIALIZED (
    SELECT s.grand_total
    FROM public.sales s CROSS JOIN bounds b
    WHERE s.outlet_id = v_outlet
      AND s.source_system = 'QUENA_POS'::public.pos_sale_source
      AND s.status = 'COMPLETED'::public.pos_sale_status
      AND s.completed_at >= b.yesterday_start AND s.completed_at < b.today_start
  ), sales_summary AS (
    SELECT (SELECT coalesce(sum(grand_total), 0) FROM today_sales) AS today_total,
      (SELECT count(*)::bigint FROM today_sales) AS today_count,
      (SELECT coalesce(sum(grand_total), 0) FROM yesterday_sales) AS yesterday_total,
      (SELECT count(*)::bigint FROM yesterday_sales) AS yesterday_count
  ), daily_sales AS (
    SELECT timezone('Asia/Jakarta', s.completed_at)::date AS sale_date,
      sum(s.grand_total) AS total, count(*)::bigint AS sale_count
    FROM public.sales s
    WHERE s.outlet_id = v_outlet
      AND s.source_system = 'QUENA_POS'::public.pos_sale_source
      AND s.status = 'COMPLETED'::public.pos_sale_status
      AND s.completed_at >= ((v_today - (v_days - 1))::timestamp AT TIME ZONE 'Asia/Jakarta')
      AND s.completed_at < ((v_today + 1)::timestamp AT TIME ZONE 'Asia/Jakarta')
    GROUP BY timezone('Asia/Jakarta', s.completed_at)::date
  ), trend AS (
    SELECT d.day::date AS sale_date, coalesce(ds.total, 0)::numeric AS total,
      coalesce(ds.sale_count, 0)::bigint AS sale_count
    FROM generate_series(v_today - (v_days - 1), v_today, interval '1 day') d(day)
    LEFT JOIN daily_sales ds ON ds.sale_date = d.day::date
  ), payments_by_method AS (
    SELECT sp.method::text AS method, sum(sp.applied_amount) AS total,
      count(DISTINCT sp.sale_id)::bigint AS sale_count
    FROM public.sale_payments sp
    JOIN today_sales ts ON ts.id = sp.sale_id
    WHERE sp.outlet_id = v_outlet
    GROUP BY sp.method
  ), payment_summary AS (
    SELECT m.method, coalesce(p.total, 0)::numeric AS total,
      coalesce(p.sale_count, 0)::bigint AS sale_count
    FROM (VALUES ('CASH'), ('QRIS'), ('CARD'), ('E_WALLET')) m(method)
    LEFT JOIN payments_by_method p ON p.method = m.method
  ), profit_rows AS (
    SELECT ts.id, count(si.id)::bigint AS item_count,
      count(e.id)::bigint AS evidence_count,
      count(e.id) FILTER (WHERE e.status = 'RESOLVED'::public.pos_sale_item_cogs_status
        AND e.resolved_cogs_amount IS NOT NULL)::bigint AS resolved_count,
      coalesce(sum(e.resolved_cogs_amount) FILTER (
        WHERE e.status = 'RESOLVED'::public.pos_sale_item_cogs_status
          AND e.resolved_cogs_amount IS NOT NULL
      ), 0)::numeric AS resolved_cogs
    FROM today_sales ts
    LEFT JOIN public.sale_items si ON si.sale_id = ts.id AND si.outlet_id = v_outlet
    LEFT JOIN public.sale_item_cost_evidence e ON e.sale_item_id = si.id
      AND e.sale_id = si.sale_id AND e.outlet_id = v_outlet
    GROUP BY ts.id
  ), profit_summary AS (
    SELECT count(*) FILTER (WHERE item_count = 0 OR evidence_count <> item_count
      OR resolved_count <> item_count)::bigint AS incomplete_sales,
      coalesce(sum(resolved_cogs), 0)::numeric AS resolved_cogs
    FROM profit_rows
  ), stock_rows AS MATERIALIZED (
    SELECT p.id AS product_id, p.name, bp.effective_quantity,
      i.minimum_quantity, os.rack_label AS rack
    FROM public.product_inventory i
    JOIN public.products p ON p.id = i.product_id
    LEFT JOIN public.stock_balance_projection bp ON bp.product_id = i.product_id
      AND bp.outlet_id = i.outlet_id
    LEFT JOIN public.product_outlet_settings os ON os.product_id = i.product_id
      AND os.outlet_id = i.outlet_id
    WHERE i.outlet_id = v_outlet AND bp.effective_quantity IS NOT NULL
      AND (bp.effective_quantity = 0 OR (coalesce(i.minimum_quantity, 0) > 0
        AND bp.effective_quantity <= i.minimum_quantity))
  ), stock_summary AS (
    SELECT count(*)::bigint AS low_stock_count FROM stock_rows
  ), stock_integrity AS (
    SELECT count(*)::bigint AS missing_projection_count
    FROM public.product_inventory i
    LEFT JOIN public.stock_balance_projection bp ON bp.product_id = i.product_id
      AND bp.outlet_id = i.outlet_id
    WHERE i.outlet_id = v_outlet AND (bp.product_id IS NULL OR bp.effective_quantity IS NULL)
  ), stock_shortlist AS (
    SELECT product_id, name, effective_quantity, minimum_quantity, rack
    FROM stock_rows
    ORDER BY (effective_quantity = 0) DESC,
      (coalesce(minimum_quantity, 0) - effective_quantity) DESC,
      name COLLATE "C", product_id
    LIMIT 6
  ), payable_balances AS MATERIALIZED (
    SELECT sp.id, sp.invoice_id, s.display_name AS supplier_name,
      i.invoice_number, i.due_date,
      greatest(sp.original_amount - coalesce(a.paid, 0), 0)::numeric AS outstanding
    FROM public.supplier_payables sp
    JOIN public.purchase_invoices i ON i.id = sp.invoice_id
    JOIN public.suppliers s ON s.id = sp.supplier_id
    LEFT JOIN LATERAL (
      SELECT sum(pa.amount)::numeric AS paid
      FROM public.supplier_payment_allocations pa
      WHERE pa.payable_id = sp.id
    ) a ON true
    WHERE sp.outlet_id = v_outlet AND i.outlet_id = v_outlet
      AND i.status = 'FINALIZED' AND i.payment_type = 'TEMPO'
  ), payable_summary AS (
    SELECT coalesce(sum(outstanding), 0)::numeric AS outstanding_total,
      coalesce(sum(outstanding) FILTER (WHERE due_date >= v_today
        AND due_date <= v_today + 7), 0)::numeric AS due_soon_total,
      coalesce(sum(outstanding) FILTER (WHERE due_date < v_today), 0)::numeric AS overdue_total,
      count(*) FILTER (WHERE outstanding > 0 AND due_date >= v_today
        AND due_date <= v_today + 7)::bigint AS due_soon_count,
      count(*) FILTER (WHERE outstanding > 0 AND due_date < v_today)::bigint AS overdue_count
    FROM payable_balances
  ), urgent_payables AS (
    SELECT id, supplier_name, invoice_number, due_date, outstanding,
      greatest(v_today - due_date, 0)::integer AS days_overdue
    FROM payable_balances
    WHERE outstanding > 0 AND due_date <= v_today + 7
    ORDER BY due_date, outstanding DESC, id
    LIMIT 5
  ), opname_summary AS (
    SELECT count(*)::bigint AS open_count
    FROM public.stock_opname_sessions
    WHERE outlet_id = v_outlet AND status IN ('COUNTING'::public.stock_opname_status,
      'REVIEW'::public.stock_opname_status)
  )
  SELECT jsonb_build_object(
    'business_date', v_today,
    'sales', jsonb_build_object(
      'today_total', ss.today_total::numeric(32,2)::text,
      'today_count', ss.today_count,
      'average_basket', CASE WHEN ss.today_count = 0 THEN '0.00'
        ELSE round(ss.today_total / ss.today_count, 2)::numeric(32,2)::text END,
      'yesterday_total', ss.yesterday_total::numeric(32,2)::text,
      'yesterday_count', ss.yesterday_count,
      'comparison', CASE WHEN ss.yesterday_total = 0 AND ss.today_total = 0 THEN 'NO_SALES'
        WHEN ss.yesterday_total = 0 THEN 'NEW' ELSE 'CHANGE' END,
      'change_percent', CASE WHEN ss.yesterday_total = 0 THEN NULL
        ELSE round((ss.today_total - ss.yesterday_total) / ss.yesterday_total * 100, 1)::text END
    ),
    'trend_days', v_days,
    'trend', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'date', t.sale_date, 'total', t.total::numeric(32,2)::text, 'transaction_count', t.sale_count
    ) ORDER BY t.sale_date), '[]'::jsonb) FROM trend t),
    'payments', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'method', p.method, 'total', p.total::numeric(32,2)::text, 'sale_count', p.sale_count
    ) ORDER BY CASE p.method WHEN 'CASH' THEN 1 WHEN 'QRIS' THEN 2 WHEN 'CARD' THEN 3 ELSE 4 END), '[]'::jsonb)
      FROM payment_summary p),
    'profit', jsonb_build_object(
      'status', CASE WHEN v_costing_status IS DISTINCT FROM 'WAC_ACTIVE'::public.inventory_cost_authority_status
          THEN 'COSTING_INACTIVE' WHEN ps.incomplete_sales > 0 THEN 'INCOMPLETE' ELSE 'RESOLVED' END,
      'gross_profit', CASE WHEN v_costing_status = 'WAC_ACTIVE'::public.inventory_cost_authority_status
          AND ps.incomplete_sales = 0
        THEN (ss.today_total - ps.resolved_cogs)::numeric(32,2)::text ELSE NULL END,
      'incomplete_sales', ps.incomplete_sales
    ),
    'stock', jsonb_build_object(
      'low_stock_count', (SELECT low_stock_count FROM stock_summary),
      'missing_projection_count', (SELECT missing_projection_count FROM stock_integrity),
      'items', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'product_id', x.product_id, 'name', x.name, 'effective_quantity', x.effective_quantity,
        'minimum_quantity', x.minimum_quantity, 'rack', x.rack
      ) ORDER BY (x.effective_quantity = 0) DESC,
        (coalesce(x.minimum_quantity, 0) - x.effective_quantity) DESC, x.name COLLATE "C", x.product_id), '[]'::jsonb)
        FROM stock_shortlist x)
    ),
    'tempo', jsonb_build_object(
      'outstanding_total', (SELECT outstanding_total::numeric(32,2)::text FROM payable_summary),
      'due_soon_total', (SELECT due_soon_total::numeric(32,2)::text FROM payable_summary),
      'overdue_total', (SELECT overdue_total::numeric(32,2)::text FROM payable_summary),
      'due_soon_count', (SELECT due_soon_count FROM payable_summary),
      'overdue_count', (SELECT overdue_count FROM payable_summary),
      'urgent', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id', u.id, 'supplier_name', u.supplier_name, 'invoice_number', u.invoice_number,
        'due_date', u.due_date, 'outstanding', u.outstanding::numeric(32,2)::text,
        'days_overdue', u.days_overdue
      ) ORDER BY u.due_date, u.outstanding DESC, u.id), '[]'::jsonb) FROM urgent_payables u)
    ),
    'attention', jsonb_build_object(
      'costing_active', coalesce(v_costing_status = 'WAC_ACTIVE'::public.inventory_cost_authority_status, false),
      'low_stock_count', (SELECT low_stock_count FROM stock_summary),
      'missing_stock_projection_count', (SELECT missing_projection_count FROM stock_integrity),
      'due_soon_count', (SELECT due_soon_count FROM payable_summary),
      'overdue_count', (SELECT overdue_count FROM payable_summary),
      'open_opname_count', (SELECT open_count FROM opname_summary),
      'incomplete_profit_sales', ps.incomplete_sales
    )
  ) INTO v_result
  FROM sales_summary ss CROSS JOIN profit_summary ps;

  RETURN v_result;
END;
$$;

ALTER FUNCTION public.owner_dashboard_read(integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.owner_dashboard_read(integer) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.owner_dashboard_read(integer) TO authenticated;

-- Dashboard Tempo reads finalized due-date slices by outlet; existing list index
-- is created_at based and does not support this dashboard predicate/order.
CREATE INDEX purchase_invoices_dashboard_tempo_due_idx
  ON public.purchase_invoices(outlet_id, due_date, id)
  WHERE status = 'FINALIZED' AND payment_type = 'TEMPO';
CREATE INDEX supplier_payables_dashboard_outlet_idx
  ON public.supplier_payables(outlet_id, invoice_id);

COMMIT;
