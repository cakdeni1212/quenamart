-- Bounded owner reports read model. Period facts use immutable sale/expense
-- evidence; inventory and supplier balances are explicitly current snapshots.
BEGIN;

CREATE FUNCTION public.owner_reports_read(p_from date, p_to date, p_compare_from date, p_compare_to date)
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
  v_days integer;
  v_prev_to date;
  v_prev_from date;
  v_costing_status public.inventory_cost_authority_status;
  v_result jsonb;
BEGIN
  v_role := public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='OWNER_REPORTS_UNAUTHORIZED';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from + 1 > 366 THEN
    RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='OWNER_REPORTS_PERIOD_INVALID';
  END IF;
  v_days := p_to - p_from + 1;
  IF p_compare_from IS NULL OR p_compare_to IS NULL OR p_compare_to < p_compare_from
    OR p_compare_to - p_compare_from + 1 > 366 THEN
    RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='OWNER_REPORTS_COMPARISON_INVALID';
  END IF;
  v_prev_from := p_compare_from;
  v_prev_to := p_compare_to;

  SELECT count(*)::integer, (array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1]
    INTO v_outlet_count, v_outlet
  FROM public.stock_authority_periods ap JOIN public.outlets o ON o.id=ap.outlet_id
  WHERE ap.ended_at IS NULL AND o.is_active;
  IF v_outlet_count <> 1 OR v_outlet IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='OWNER_REPORTS_OUTLET_UNAVAILABLE';
  END IF;
  SELECT a.status INTO v_costing_status FROM public.inventory_costing_outlet_authority a WHERE a.outlet_id=v_outlet;

  WITH period_bounds AS (
    SELECT p_from::timestamp AT TIME ZONE 'Asia/Jakarta' AS starts_at,
      (p_to+1)::timestamp AT TIME ZONE 'Asia/Jakarta' AS ends_at,
      v_prev_from::timestamp AT TIME ZONE 'Asia/Jakarta' AS previous_starts_at,
      (v_prev_to+1)::timestamp AT TIME ZONE 'Asia/Jakarta' AS previous_ends_at
  ), period_sales AS MATERIALIZED (
    SELECT s.id,s.source_system::text AS source_system,s.grand_total,s.completed_at,
      timezone('Asia/Jakarta',s.completed_at)::date AS sale_date
    FROM public.sales s CROSS JOIN period_bounds b
    WHERE s.outlet_id=v_outlet AND s.status='COMPLETED'::public.pos_sale_status
      AND s.completed_at>=b.starts_at AND s.completed_at<b.ends_at
  ), prev_sales AS MATERIALIZED (
    SELECT s.id,s.grand_total FROM public.sales s CROSS JOIN period_bounds b
    WHERE s.outlet_id=v_outlet AND s.status='COMPLETED'::public.pos_sale_status
      AND s.completed_at>=b.previous_starts_at AND s.completed_at<b.previous_ends_at
  ), sales_totals AS (
    SELECT coalesce(sum(grand_total),0)::numeric AS revenue,count(*)::bigint AS txn FROM period_sales
  ), prev_totals AS (
    SELECT coalesce(sum(grand_total),0)::numeric AS revenue,count(*)::bigint AS txn FROM prev_sales
  ), cogs_by_sale AS (
    SELECT ps.id,
      count(si.id)::bigint AS item_count,
      count(e.id)::bigint AS evidence_count,
      count(e.id) FILTER (WHERE e.status='RESOLVED'::public.pos_sale_item_cogs_status AND e.resolved_cogs_amount IS NOT NULL)::bigint AS resolved_count,
      coalesce(sum(e.resolved_cogs_amount) FILTER (WHERE e.status='RESOLVED'::public.pos_sale_item_cogs_status AND e.resolved_cogs_amount IS NOT NULL),0)::numeric AS cogs
    FROM period_sales ps
    LEFT JOIN public.sale_items si ON si.sale_id=ps.id AND si.outlet_id=v_outlet
    LEFT JOIN public.sale_item_cost_evidence e ON e.sale_item_id=si.id AND e.sale_id=ps.id AND e.outlet_id=v_outlet
    GROUP BY ps.id
  ), cogs_state AS (
    SELECT count(*) FILTER (WHERE item_count=0 OR evidence_count<>item_count OR resolved_count<>item_count)::bigint AS incomplete,
      coalesce(sum(cogs),0)::numeric AS cogs
    FROM cogs_by_sale
  ), posted_expenses AS MATERIALIZED (
    SELECT e.category,e.amount FROM public.operational_expenses e
    WHERE e.outlet_id=v_outlet AND e.status='POSTED' AND e.expense_date BETWEEN p_from AND p_to
  ), expense_total AS (SELECT coalesce(sum(amount),0)::numeric AS amount,count(*)::bigint AS count FROM posted_expenses),
  trend_days AS (
    SELECT d.day::date AS day FROM generate_series(p_from::timestamp,p_to::timestamp,interval '1 day') AS d(day)
  ), daily_sales AS (
    SELECT sale_date,sum(grand_total)::numeric AS revenue,count(*)::bigint AS txn FROM period_sales GROUP BY sale_date
  ), daily_cost AS (
    SELECT ps.sale_date, sum(cb.cogs)::numeric AS cogs,
      bool_or(cb.item_count=0 OR cb.evidence_count<>cb.item_count OR cb.resolved_count<>cb.item_count) AS incomplete
    FROM period_sales ps JOIN cogs_by_sale cb ON cb.id=ps.id GROUP BY ps.sale_date
  ), daily_exp AS (
    SELECT e.expense_date AS day,sum(e.amount)::numeric AS amount FROM public.operational_expenses e
    WHERE e.outlet_id=v_outlet AND e.status='POSTED' AND e.expense_date BETWEEN p_from AND p_to GROUP BY e.expense_date
  ), daily AS (
    SELECT td.day,coalesce(ds.revenue,0)::numeric AS revenue,coalesce(ds.txn,0)::bigint AS txn,
      coalesce(dc.cogs,0)::numeric AS cogs,coalesce(dc.incomplete,false) AS incomplete,
      coalesce(de.amount,0)::numeric AS expense
    FROM trend_days td LEFT JOIN daily_sales ds ON ds.sale_date=td.day
    LEFT JOIN daily_cost dc ON dc.sale_date=td.day LEFT JOIN daily_exp de ON de.day=td.day
  ), chart_sales AS (
    SELECT CASE WHEN v_days<=60 THEN day ELSE date_trunc('week',day::timestamp)::date END AS bucket,
      sum(revenue)::numeric AS revenue,sum(txn)::bigint AS txn
    FROM daily GROUP BY 1
  ), chart_profit AS (
    SELECT CASE WHEN v_days<=60 THEN day ELSE date_trunc('week',day::timestamp)::date END AS bucket,
      sum(revenue)::numeric AS revenue,sum(cogs)::numeric AS cogs,sum(expense)::numeric AS expense
    FROM daily GROUP BY 1
  ), payments AS (
    SELECT sp.method::text AS method,sum(sp.applied_amount)::numeric AS amount,count(DISTINCT sp.sale_id)::bigint AS txn
    FROM public.sale_payments sp JOIN period_sales ps ON ps.id=sp.sale_id
    WHERE sp.outlet_id=v_outlet GROUP BY sp.method
  ), payment_rows AS (
    SELECT m.method,coalesce(p.amount,0)::numeric AS amount,coalesce(p.txn,0)::bigint AS txn
    FROM (VALUES ('CASH'),('QRIS'),('CARD'),('E_WALLET')) m(method) LEFT JOIN payments p ON p.method=m.method
  ), payment_check AS (
    SELECT coalesce((SELECT sum(amount) FROM payments),0)::numeric AS paid,
      (SELECT revenue FROM sales_totals) AS revenue
  ), sources AS (
    SELECT source_system,sum(grand_total)::numeric AS amount,count(*)::bigint AS txn
    FROM period_sales GROUP BY source_system
  ), top_products AS (
    SELECT si.product_name_snapshot AS name,si.sku_snapshot AS sku,sum(si.quantity)::numeric AS quantity,
      sum(si.line_subtotal)::numeric AS revenue
    FROM public.sale_items si JOIN period_sales ps ON ps.id=si.sale_id
    WHERE si.outlet_id=v_outlet GROUP BY si.product_name_snapshot,si.sku_snapshot
    ORDER BY sum(si.line_subtotal) DESC,si.product_name_snapshot COLLATE "C",si.sku_snapshot COLLATE "C"
    LIMIT 10
  ), expense_categories AS (
    SELECT category,sum(amount)::numeric AS amount,count(*)::bigint AS count
    FROM posted_expenses GROUP BY category ORDER BY sum(amount) DESC,category LIMIT 12
  ), source_by_product AS (
    SELECT b.product_id,sum(b.remaining_provisional_quantity)::numeric AS provisional,
      sum(b.remaining_unvalued_quantity)::numeric AS unvalued
    FROM public.inventory_cost_source_layer_balances b
    WHERE b.outlet_id=v_outlet AND b.state='ACTIVE' GROUP BY b.product_id
  ), stock AS MATERIALIZED (
    SELECT i.product_id,pr.name,bp.effective_quantity,i.minimum_quantity,
      cp.valued_quantity,cp.inventory_value,cp.valuation_status,
      coalesce(sb.provisional,0)::numeric AS provisional_quantity,
      coalesce(sb.unvalued,0)::numeric AS unvalued_quantity
    FROM public.product_inventory i
    JOIN public.products pr ON pr.id=i.product_id
    LEFT JOIN public.stock_balance_projection bp ON bp.product_id=i.product_id AND bp.outlet_id=i.outlet_id
    LEFT JOIN public.inventory_cost_projections cp ON cp.product_id=i.product_id AND cp.outlet_id=i.outlet_id
    LEFT JOIN source_by_product sb ON sb.product_id=i.product_id
    WHERE i.outlet_id=v_outlet
  ), stock_summary AS (
    SELECT count(*)::bigint AS skus,
      count(*) FILTER (WHERE effective_quantity=0)::bigint AS out_of_stock,
      count(*) FILTER (WHERE effective_quantity>0 AND minimum_quantity>0 AND effective_quantity<=minimum_quantity)::bigint AS at_minimum,
      count(*) FILTER (WHERE effective_quantity IS NULL)::bigint AS missing_stock,
      count(*) FILTER (WHERE valued_quantity IS NULL OR inventory_value IS NULL)::bigint AS missing_cost,
      count(*) FILTER (WHERE effective_quantity IS NULL OR valued_quantity IS NULL
        OR abs(effective_quantity-valued_quantity-unvalued_quantity)>0.0005)::bigint AS quantity_mismatch,
      coalesce(sum(valued_quantity),0)::numeric AS valued_quantity,
      coalesce(sum(inventory_value),0)::numeric AS inventory_value,
      coalesce(sum(effective_quantity),0)::numeric AS physical_quantity
    FROM stock
  ), source_summary AS (
    SELECT coalesce(sum(provisional_quantity),0)::numeric AS provisional,
      coalesce(sum(unvalued_quantity),0)::numeric AS unvalued
    FROM stock
  ), payable AS MATERIALIZED (
    SELECT sp.id,sp.original_amount,coalesce(a.paid,0)::numeric AS paid,
      greatest(sp.original_amount-coalesce(a.paid,0),0)::numeric AS outstanding,i.due_date,i.invoice_number,s.display_name AS supplier
    FROM public.supplier_payables sp JOIN public.purchase_invoices i ON i.id=sp.invoice_id
    JOIN public.suppliers s ON s.id=sp.supplier_id
    LEFT JOIN LATERAL (SELECT sum(pa.amount)::numeric AS paid FROM public.supplier_payment_allocations pa WHERE pa.payable_id=sp.id) a ON true
    WHERE sp.outlet_id=v_outlet AND i.outlet_id=v_outlet AND i.status='FINALIZED' AND i.payment_type='TEMPO'
  ), payable_summary AS (
    SELECT coalesce(sum(outstanding),0)::numeric AS outstanding,
      count(*) FILTER (WHERE outstanding>0)::bigint AS unpaid_count,
      coalesce(sum(outstanding) FILTER (WHERE outstanding>0 AND due_date>=timezone('Asia/Jakarta',now())::date AND due_date<=timezone('Asia/Jakarta',now())::date+7),0)::numeric AS due_soon,
      count(*) FILTER (WHERE outstanding>0 AND due_date>=timezone('Asia/Jakarta',now())::date AND due_date<=timezone('Asia/Jakarta',now())::date+7)::bigint AS due_soon_count,
      coalesce(sum(outstanding) FILTER (WHERE outstanding>0 AND due_date<timezone('Asia/Jakarta',now())::date),0)::numeric AS overdue,
      count(*) FILTER (WHERE outstanding>0 AND due_date<timezone('Asia/Jakarta',now())::date)::bigint AS overdue_count
    FROM payable
  ), readiness AS (
    SELECT (SELECT count(*) FROM period_sales)::bigint AS sale_count
  )
  SELECT jsonb_build_object(
    'period',jsonb_build_object('from',p_from,'to',p_to,'days',v_days,'comparison_from',v_prev_from,'comparison_to',v_prev_to),
    'kpis',jsonb_build_object(
      'revenue',(SELECT revenue::numeric(32,2)::text FROM sales_totals),
      'transactions',(SELECT txn FROM sales_totals),
      'average_basket',CASE WHEN (SELECT txn FROM sales_totals)=0 THEN '0.00' ELSE round((SELECT revenue FROM sales_totals)/(SELECT txn FROM sales_totals),2)::numeric(32,2)::text END,
      'comparison_revenue',(SELECT revenue::numeric(32,2)::text FROM prev_totals),
      'comparison_transactions',(SELECT txn FROM prev_totals),
      'change_percent',CASE WHEN (SELECT revenue FROM prev_totals)=0 THEN NULL ELSE round(((SELECT revenue FROM sales_totals)-(SELECT revenue FROM prev_totals))/(SELECT revenue FROM prev_totals)*100,1)::text END,
      'comparison_available',(SELECT revenue FROM prev_totals)<>0,
      'expenses',(SELECT amount::numeric(32,2)::text FROM expense_total),
      'expense_count',(SELECT count FROM expense_total),
      'profit_status',CASE WHEN v_costing_status IS DISTINCT FROM 'WAC_ACTIVE'::public.inventory_cost_authority_status THEN 'COSTING_INACTIVE' WHEN (SELECT incomplete FROM cogs_state)>0 THEN 'INCOMPLETE' ELSE 'RESOLVED' END,
      'gross_profit',CASE WHEN v_costing_status='WAC_ACTIVE'::public.inventory_cost_authority_status AND (SELECT incomplete FROM cogs_state)=0 THEN ((SELECT revenue FROM sales_totals)-(SELECT cogs FROM cogs_state))::numeric(32,2)::text ELSE NULL END,
      'gross_margin',CASE WHEN v_costing_status='WAC_ACTIVE'::public.inventory_cost_authority_status AND (SELECT incomplete FROM cogs_state)=0 AND (SELECT revenue FROM sales_totals)>0 THEN round(((SELECT revenue FROM sales_totals)-(SELECT cogs FROM cogs_state))/(SELECT revenue FROM sales_totals)*100,2)::text ELSE NULL END,
      'operating_profit',CASE WHEN v_costing_status='WAC_ACTIVE'::public.inventory_cost_authority_status AND (SELECT incomplete FROM cogs_state)=0 THEN ((SELECT revenue FROM sales_totals)-(SELECT cogs FROM cogs_state)-(SELECT amount FROM expense_total))::numeric(32,2)::text ELSE NULL END,
      'incomplete_sales',(SELECT incomplete FROM cogs_state),
      'cogs',(SELECT cogs::numeric(32,2)::text FROM cogs_state)
    ),
    'trend_granularity',CASE WHEN v_days<=60 THEN 'DAY' ELSE 'WEEK' END,
    'sales_trend',(SELECT coalesce(jsonb_agg(jsonb_build_object('date',bucket,'revenue',revenue::numeric(32,2)::text,'transactions',txn) ORDER BY bucket),'[]'::jsonb) FROM chart_sales),
    'profit_trend',CASE WHEN v_costing_status='WAC_ACTIVE'::public.inventory_cost_authority_status AND (SELECT incomplete FROM cogs_state)=0
      THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('date',bucket,'revenue',revenue::numeric(32,2)::text,'gross_profit',(revenue-cogs)::numeric(32,2)::text,'operating_profit',(revenue-cogs-expense)::numeric(32,2)::text) ORDER BY bucket),'[]'::jsonb) FROM chart_profit)
      ELSE NULL END,
    'profit_unavailable_reason',CASE WHEN v_costing_status IS DISTINCT FROM 'WAC_ACTIVE'::public.inventory_cost_authority_status THEN 'COSTING_INACTIVE' WHEN (SELECT incomplete FROM cogs_state)>0 THEN 'INCOMPLETE' ELSE NULL END,
    'expenses_by_category',(SELECT coalesce(jsonb_agg(jsonb_build_object('category',category,'amount',amount::numeric(32,2)::text,'count',count,'percent',CASE WHEN (SELECT amount FROM expense_total)=0 THEN '0' ELSE round(amount/(SELECT amount FROM expense_total)*100,1)::text END) ORDER BY amount DESC,category),'[]'::jsonb) FROM expense_categories),
    'payments',(SELECT coalesce(jsonb_agg(jsonb_build_object('method',method,'amount',amount::numeric(32,2)::text,'transactions',txn) ORDER BY CASE method WHEN 'CASH' THEN 1 WHEN 'QRIS' THEN 2 WHEN 'CARD' THEN 3 ELSE 4 END),'[]'::jsonb) FROM payment_rows),
    'payment_reconciliation',jsonb_build_object('sales_revenue',(SELECT revenue::numeric(32,2)::text FROM payment_check),'payment_total',(SELECT paid::numeric(32,2)::text FROM payment_check),'difference',((SELECT revenue-paid FROM payment_check))::numeric(32,2)::text,'matches',(SELECT revenue=paid FROM payment_check)),
    'sales_sources',(SELECT coalesce(jsonb_agg(jsonb_build_object('source',source_system,'revenue',amount::numeric(32,2)::text,'transactions',txn) ORDER BY source_system),'[]'::jsonb) FROM sources),
    'top_products',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',name,'sku',sku,'quantity',quantity::text,'revenue',revenue::numeric(32,2)::text,'contribution',CASE WHEN (SELECT revenue FROM sales_totals)=0 THEN '0' ELSE round(revenue/(SELECT revenue FROM sales_totals)*100,1)::text END) ORDER BY revenue DESC,name COLLATE "C",sku COLLATE "C"),'[]'::jsonb) FROM top_products),
    'top_categories',NULL,
    'current_inventory',jsonb_build_object('as_of',timezone('Asia/Jakarta',now())::date,'sku_count',(SELECT skus FROM stock_summary),'out_of_stock',(SELECT out_of_stock FROM stock_summary),'at_minimum',(SELECT at_minimum FROM stock_summary),'missing_stock',(SELECT missing_stock FROM stock_summary),'physical_quantity',(SELECT physical_quantity::text FROM stock_summary),'valued_quantity',(SELECT valued_quantity::text FROM stock_summary),'provisional_quantity',(SELECT provisional::text FROM source_summary),'unvalued_quantity',(SELECT unvalued::text FROM source_summary),'valuation_reconciled',(SELECT quantity_mismatch=0 FROM stock_summary),'inventory_value',CASE WHEN v_costing_status='WAC_ACTIVE'::public.inventory_cost_authority_status AND (SELECT missing_cost FROM stock_summary)=0 AND (SELECT quantity_mismatch FROM stock_summary)=0 AND (SELECT unvalued FROM source_summary)=0 AND (SELECT provisional FROM source_summary)=0 THEN (SELECT inventory_value::numeric(32,2)::text FROM stock_summary) ELSE NULL END,'valuation_status',CASE WHEN v_costing_status='WAC_ACTIVE'::public.inventory_cost_authority_status AND (SELECT missing_cost FROM stock_summary)=0 AND (SELECT quantity_mismatch FROM stock_summary)=0 AND (SELECT unvalued FROM source_summary)=0 AND (SELECT provisional FROM source_summary)=0 THEN 'AVAILABLE' ELSE 'UNAVAILABLE' END),
    'current_tempo',jsonb_build_object('as_of',timezone('Asia/Jakarta',now())::date,'outstanding',(SELECT outstanding::numeric(32,2)::text FROM payable_summary),'unpaid_invoices',(SELECT unpaid_count FROM payable_summary),'due_soon',(SELECT due_soon::numeric(32,2)::text FROM payable_summary),'due_soon_count',(SELECT due_soon_count FROM payable_summary),'overdue',(SELECT overdue::numeric(32,2)::text FROM payable_summary),'overdue_count',(SELECT overdue_count FROM payable_summary))
  ) INTO v_result;
  RETURN v_result;
END;
$$;

ALTER FUNCTION public.owner_reports_read(date,date,date,date) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.owner_reports_read(date,date,date,date) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.owner_reports_read(date,date,date,date) TO authenticated;
COMMIT;
