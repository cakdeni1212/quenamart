-- Quena Mart HPP acceptance preview parity and baseline.
-- Target: project giwuzemjmimuvhtvjfhq
-- Candidate: 20260929260000_costing_initial_hpp_acceptance_v1.sql
-- Expected SHA-256: 425a8182a370a8d4f84cfe471f991f37fcb16ff4b6cb88940861ac71c5428c6a
-- Read-only SELECT statements only. Run manually in the authorized project SQL console.

WITH stock_rows AS (
  SELECT s.outlet_id,s.product_id,s.effective_quantity,s.balance_version,p.name AS product_name,p.sku,
    c.hpp AS current_hpp,c.updated_at AS current_hpp_updated_at,c.source_import_row_id
  FROM public.stock_balance_projection s
  JOIN public.products p ON p.id=s.product_id
  LEFT JOIN public.product_costs c ON c.product_id=s.product_id AND c.outlet_id=s.outlet_id
), enriched AS (
  SELECT b.*,
    src.batch_id AS source_import_batch_id,src.commit_id AS normalization_commit_id,
    src.row_status AS source_row_status,src.normalized_hpp AS normalized_source_hpp,
    coalesce(src.override_conflicts,'{}'::text[]) AS source_conflict_codes,
    hist.id AS latest_cost_history_id,hist.hpp AS latest_history_hpp,hist.source_import_row_id AS latest_history_source_row_id,
    rev.id AS latest_review_id,rev.status AS latest_review_status,rev.source_import_row_id AS latest_review_source_row_id,
    ov.id AS active_override_id,coalesce(ov.override_count,0)::integer AS active_override_count,
    ov.corrected_value AS active_override_value,ov.source_import_row_id AS active_override_source_row_id,
    rec.id AS latest_reconciliation_event_id,rec.event_type AS latest_reconciliation_event_type,
    coalesce(findings.codes,'{}'::text[]) AS open_cost_findings,
    sell.amount AS selling_price,sell.source_import_row_id AS selling_price_source_row_id,
    sell.updated_at AS selling_price_updated_at,sell_hist.id AS latest_selling_price_history_id,
    coalesce(src.source_valid,false) AS source_valid
  FROM stock_rows b
  LEFT JOIN LATERAL (
    SELECT ir.batch_id,ir.status AS row_status,c.commit_id,c.override_conflicts,
      CASE WHEN c.normalized_data->>'hpp' ~ '^-?[0-9]+([.][0-9]+)?$'
        THEN (c.normalized_data->>'hpp')::numeric ELSE NULL END AS normalized_hpp,
      (ir.status='VALID'::public.ipos_import_row_status AND ib.status='COMPLETED'
        AND n.status='COMPLETED' AND c.action IN ('C'||'REATE','UP'||'DATE')
        AND cardinality(c.override_conflicts)=0 AND jsonb_array_length(c.validation_errors)=0) AS source_valid
    FROM public.ipos_import_rows ir
    JOIN public.ipos_import_batches ib ON ib.id=ir.batch_id AND ib.outlet_id=ir.outlet_id
    JOIN public.ipos_normalization_commit_rows c ON c.source_row_id=ir.id AND c.product_id=ir.product_id
      AND c.batch_id=ir.batch_id AND c.outlet_id=ir.outlet_id
    JOIN public.ipos_normalization_commits n ON n.id=c.commit_id AND n.outlet_id=c.outlet_id
    WHERE ir.id=b.source_import_row_id AND ir.product_id=b.product_id AND ir.outlet_id=b.outlet_id
    ORDER BY n.completed_at DESC,n.created_at DESC,n.id DESC,c.created_at DESC LIMIT 1
  ) src ON true
  LEFT JOIN LATERAL (
    SELECT h.id,h.hpp,h.source_import_row_id FROM public.product_cost_history h
    WHERE h.product_id=b.product_id AND h.outlet_id=b.outlet_id
    ORDER BY h.effective_at DESC,h.created_at DESC,h.id DESC LIMIT 1
  ) hist ON true
  LEFT JOIN LATERAL (
    SELECT r.id,r.status,r.source_import_row_id FROM public.product_field_audit_reviews r
    WHERE r.product_id=b.product_id AND r.outlet_id=b.outlet_id AND r.field_key='hpp'
    ORDER BY r.reviewed_at DESC,r.id DESC LIMIT 1
  ) rev ON true
  LEFT JOIN LATERAL (
    SELECT (array_agg(o.id ORDER BY o.corrected_at DESC,o.id DESC))[1] AS id,count(*) AS override_count,
      (array_agg((o.corrected_value #>> '{}')::numeric ORDER BY o.corrected_at DESC,o.id DESC))[1] AS corrected_value,
      (array_agg(o.source_import_row_id ORDER BY o.corrected_at DESC,o.id DESC))[1] AS source_import_row_id
    FROM public.product_field_overrides o
    WHERE o.product_id=b.product_id AND o.outlet_id=b.outlet_id AND o.field_key='hpp' AND o.is_active
  ) ov ON true
  LEFT JOIN LATERAL (
    SELECT e.id,e.event_type FROM public.product_field_reconciliation_events e
    WHERE e.product_id=b.product_id AND e.outlet_id=b.outlet_id AND e.field_key='hpp'
    ORDER BY e.created_at DESC,e.id DESC LIMIT 1
  ) rec ON true
  LEFT JOIN LATERAL (
    SELECT array_agg(DISTINCT (f.finding_code::text||':'||f.id::text)
      ORDER BY (f.finding_code::text||':'||f.id::text)) AS codes
    FROM public.product_audit_findings f
    WHERE f.product_id=b.product_id AND f.outlet_id=b.outlet_id AND f.status='OPEN'
      AND f.finding_code IN ('ZERO_OR_MISSING_HPP'::public.product_audit_finding_code,
        'SELLING_PRICE_BELOW_HPP'::public.product_audit_finding_code)
  ) findings ON true
  LEFT JOIN public.product_selling_prices sell ON sell.product_id=b.product_id AND sell.outlet_id=b.outlet_id
  LEFT JOIN LATERAL (
    SELECT h.id FROM public.product_selling_price_history h
    WHERE h.product_id=b.product_id AND h.outlet_id=b.outlet_id
    ORDER BY h.effective_at DESC,h.created_at DESC,h.id DESC LIMIT 1
  ) sell_hist ON true
), hpp_stats AS (
  SELECT e.outlet_id,percentile_disc(0.99) WITHIN GROUP (ORDER BY e.current_hpp)
    FILTER (WHERE e.current_hpp>0 AND e.current_hpp<1000000000000 AND e.current_hpp=trunc(e.current_hpp,2)) AS p99_hpp
  FROM enriched e WHERE e.effective_quantity>0 GROUP BY e.outlet_id
), with_warnings AS (
  SELECT e.*,s.p99_hpp FROM enriched e JOIN hpp_stats s ON s.outlet_id=e.outlet_id
), classified AS (
  SELECT w.*,
    ARRAY(SELECT x FROM unnest(ARRAY[
      CASE WHEN w.current_hpp IS NULL THEN 'HPP_MISSING' END,
      CASE WHEN w.current_hpp=0 THEN 'HPP_ZERO' END,
      CASE WHEN w.current_hpp<0 OR w.current_hpp>=1000000000000 OR w.current_hpp<>trunc(w.current_hpp,2) THEN 'HPP_INVALID_BOUNDS_OR_SCALE' END,
      CASE WHEN w.source_import_row_id IS NULL THEN 'SOURCE_PROVENANCE_MISSING' END,
      CASE WHEN w.source_import_row_id IS NOT NULL AND NOT w.source_valid THEN 'SOURCE_PROVENANCE_INVALID' END,
      CASE WHEN w.source_valid AND w.normalized_source_hpp IS NULL THEN 'NORMALIZED_SOURCE_HPP_MISSING' END,
      CASE WHEN w.source_valid AND w.normalized_source_hpp IS NOT NULL AND
        (w.normalized_source_hpp<0 OR w.normalized_source_hpp>=1000000000000 OR w.normalized_source_hpp<>trunc(w.normalized_source_hpp,2))
        THEN 'NORMALIZED_SOURCE_HPP_INVALID_BOUNDS_OR_SCALE' END,
      CASE WHEN w.source_valid AND w.current_hpp IS DISTINCT FROM w.normalized_source_hpp THEN 'CURRENT_SOURCE_HPP_MISMATCH' END,
      CASE WHEN cardinality(w.source_conflict_codes)>0 THEN 'SOURCE_OVERRIDE_CONFLICT' END,
      CASE WHEN w.latest_cost_history_id IS NULL THEN 'COST_HISTORY_MISSING' END,
      CASE WHEN w.latest_cost_history_id IS NOT NULL AND
        (w.latest_history_hpp IS DISTINCT FROM w.current_hpp OR w.latest_history_source_row_id IS DISTINCT FROM w.source_import_row_id)
        THEN 'LATEST_COST_HISTORY_MISMATCH' END,
      CASE WHEN w.active_override_count>0 THEN 'ACTIVE_HPP_OVERRIDE' END,
      CASE WHEN w.latest_review_id IS NOT NULL AND
        (w.latest_review_status<>'SUDAH_DIVERIFIKASI'::public.product_field_audit_status
          OR w.latest_review_source_row_id IS DISTINCT FROM w.source_import_row_id)
        THEN 'UNRESOLVED_OR_CONFLICTING_HPP_REVIEW' END,
      CASE WHEN w.latest_reconciliation_event_type='SOURCE_CONFLICT' THEN 'OPEN_HPP_SOURCE_CONFLICT' END,
      CASE WHEN cardinality(w.open_cost_findings)>0 THEN 'OPEN_COST_AUDIT_FINDING' END,
      CASE WHEN w.selling_price IS NULL OR w.selling_price<=0 THEN 'SELLING_PRICE_MISSING_OR_INVALID' END,
      CASE WHEN w.current_hpp IS NOT NULL AND w.selling_price>0 AND w.current_hpp>=w.selling_price THEN 'HPP_NOT_BELOW_SELLING_PRICE' END
    ]) x WHERE x IS NOT NULL ORDER BY x) AS blocking_reasons,
    ARRAY(SELECT x FROM unnest(ARRAY[
      CASE WHEN w.current_hpp=1 THEN 'ONE_RUPIAH_HPP' END,
      CASE WHEN w.current_hpp>0 AND w.selling_price>w.current_hpp AND
        ((w.selling_price-w.current_hpp)/w.selling_price*100)<=5 THEN 'GROSS_MARGIN_AT_OR_BELOW_5_PERCENT' END,
      CASE WHEN w.current_hpp>0 AND w.selling_price>w.current_hpp AND
        ((w.selling_price-w.current_hpp)/w.selling_price*100)>80 THEN 'GROSS_MARGIN_ABOVE_80_PERCENT' END,
      CASE WHEN w.current_hpp>0 AND w.p99_hpp>0 AND w.current_hpp>3*w.p99_hpp THEN 'HIGH_ABSOLUTE_HPP_OUTLIER' END
    ]) x WHERE x IS NOT NULL ORDER BY x) AS warning_codes
  FROM with_warnings w
), positive_rows AS (
  SELECT c.*,
    CASE WHEN cardinality(c.blocking_reasons)=0 THEN 'AUTO_CANDIDATE' ELSE 'EXCEPTION' END AS classification
  FROM classified c WHERE c.effective_quantity>0
), summary AS (
  SELECT count(*)::bigint AS positive_stock_products,
    count(*) FILTER (WHERE classification='AUTO_CANDIDATE')::bigint AS auto_candidates,
    count(*) FILTER (WHERE classification='EXCEPTION')::bigint AS blocking_exceptions,
    count(*) FILTER (WHERE cardinality(warning_codes)>0)::bigint AS products_with_warnings,
    coalesce(sum(effective_quantity*current_hpp) FILTER (WHERE classification='AUTO_CANDIDATE'),0)::numeric(32,8) AS candidate_opening_value
  FROM positive_rows
), output_rows AS (
  SELECT 'A — SUMMARY'::text AS section,'summary'::text AS item,NULL::bigint AS product_count,
    jsonb_build_object(
      'total_products',(SELECT count(*)::bigint FROM public.products),
      'positive_stock_products',s.positive_stock_products,
      'zero_stock_products',(SELECT count(*)::bigint FROM stock_rows WHERE effective_quantity=0),
      'auto_candidates',s.auto_candidates,
      'blocking_exceptions',s.blocking_exceptions,
      'products_with_warnings',s.products_with_warnings,
      'candidate_opening_value',s.candidate_opening_value
    ) AS details
  FROM summary s
  UNION ALL
  SELECT 'B — BLOCKERS',u.reason,count(DISTINCT p.product_id)::bigint,NULL::jsonb
  FROM positive_rows p CROSS JOIN LATERAL unnest(p.blocking_reasons) AS u(reason)
  GROUP BY u.reason
  UNION ALL
  SELECT 'B — BLOCKERS','products_with_multiple_blockers',count(*)::bigint,NULL::jsonb
  FROM positive_rows WHERE cardinality(blocking_reasons)>1
  UNION ALL
  SELECT 'C — WARNINGS',u.warning,count(DISTINCT p.product_id)::bigint,NULL::jsonb
  FROM positive_rows p CROSS JOIN LATERAL unnest(p.warning_codes) AS u(warning)
  GROUP BY u.warning
  UNION ALL
  SELECT 'C — WARNINGS','products_with_multiple_warnings',count(*)::bigint,NULL::jsonb
  FROM positive_rows WHERE cardinality(warning_codes)>1
  UNION ALL
  SELECT 'C — WARNINGS','products_with_blocker_and_warning',count(*)::bigint,NULL::jsonb
  FROM positive_rows WHERE cardinality(blocking_reasons)>0 AND cardinality(warning_codes)>0
  UNION ALL
  SELECT 'D — EXCEPTIONS',coalesce(p.sku,'(no SKU)')||' · '||p.product_name,1::bigint,
    jsonb_build_object('sku',p.sku,'product_name',p.product_name,'effective_stock',p.effective_quantity,
      'current_hpp',p.current_hpp,'selling_price',p.selling_price,'blocker_reasons',p.blocking_reasons,
      'warning_reasons',p.warning_codes,'current_hpp_review_status',p.latest_review_status,
      'relevant_open_hpp_finding',p.open_cost_findings)
  FROM positive_rows p WHERE cardinality(p.blocking_reasons)>0
  UNION ALL
  SELECT 'E — WARNING EXAMPLES',w.warning_code,1::bigint,
    jsonb_build_object('sku',w.sku,'product_name',w.product_name,'effective_stock',w.effective_quantity,
      'current_hpp',w.current_hpp,'selling_price',w.selling_price,'blocker_reasons',w.blocking_reasons,
      'warning_reasons',w.warning_codes,'is_blocking_exception',cardinality(w.blocking_reasons)>0)
  FROM (
    SELECT p.*,u.warning AS warning_code,
      row_number() OVER (PARTITION BY u.warning ORDER BY cardinality(p.blocking_reasons),p.sku NULLS LAST,p.product_id) AS rn
    FROM positive_rows p CROSS JOIN LATERAL unnest(p.warning_codes) AS u(warning)
  ) w WHERE w.rn=1
  UNION ALL
  SELECT 'F — BASELINE','product_inventory',count(*)::bigint,NULL::jsonb FROM public.product_inventory
  UNION ALL
  SELECT 'F — BASELINE','stock_balance_projection',count(*)::bigint,NULL::jsonb FROM public.stock_balance_projection
  UNION ALL
  SELECT 'F — BASELINE','stock_movements',count(*)::bigint,NULL::jsonb FROM public.stock_movements
  UNION ALL
  SELECT 'F — BASELINE','stock_movement_batches',count(*)::bigint,NULL::jsonb FROM public.stock_movement_batches
  UNION ALL
  SELECT 'F — BASELINE','stock_authority_periods:'||CASE WHEN ended_at IS NULL THEN 'OPEN' ELSE 'CLOSED' END||':'||mode::text,
    count(*)::bigint,NULL::jsonb FROM public.stock_authority_periods GROUP BY ended_at IS NULL,mode
  UNION ALL
  SELECT 'F — BASELINE','opname_sessions:'||status::text,count(*)::bigint,NULL::jsonb
    FROM public.stock_opname_sessions GROUP BY status
  UNION ALL
  SELECT 'F — BASELINE','suppliers',count(*)::bigint,NULL::jsonb FROM public.suppliers
  UNION ALL
  SELECT 'F — BASELINE','purchase_receipts:'||status::text,count(*)::bigint,NULL::jsonb
    FROM public.purchase_receipts GROUP BY status
  UNION ALL
  SELECT 'F — BASELINE','purchase_receipt_items',count(*)::bigint,NULL::jsonb FROM public.purchase_receipt_items
  UNION ALL
  SELECT 'F — BASELINE','purchase_receipt_events',count(*)::bigint,NULL::jsonb FROM public.purchase_receipt_events
  UNION ALL
  SELECT 'F — BASELINE','purchase_invoices:'||status::text,count(*)::bigint,NULL::jsonb
    FROM public.purchase_invoices GROUP BY status
  UNION ALL
  SELECT 'F — BASELINE','purchase_invoice_receipts',count(*)::bigint,NULL::jsonb FROM public.purchase_invoice_receipts
  UNION ALL
  SELECT 'F — BASELINE','supplier_payables',count(*)::bigint,NULL::jsonb FROM public.supplier_payables
  UNION ALL
  SELECT 'F — BASELINE','supplier_payments',count(*)::bigint,NULL::jsonb FROM public.supplier_payments
  UNION ALL
  SELECT 'F — BASELINE','supplier_payment_allocations',count(*)::bigint,NULL::jsonb FROM public.supplier_payment_allocations
  UNION ALL
  SELECT 'F — BASELINE','purchase_invoice_documents',count(*)::bigint,NULL::jsonb FROM public.purchase_invoice_documents
  UNION ALL
  SELECT 'F — BASELINE','product_costs',count(*)::bigint,NULL::jsonb FROM public.product_costs
  UNION ALL
  SELECT 'F — BASELINE','product_cost_history',count(*)::bigint,NULL::jsonb FROM public.product_cost_history
  UNION ALL
  SELECT 'F — BASELINE','inventory_cost_event_batches',count(*)::bigint,NULL::jsonb FROM public.inventory_cost_event_batches
  UNION ALL
  SELECT 'F — BASELINE','inventory_cost_events',count(*)::bigint,NULL::jsonb FROM public.inventory_cost_events
  UNION ALL
  SELECT 'F — BASELINE','inventory_cost_projections',count(*)::bigint,NULL::jsonb FROM public.inventory_cost_projections
  UNION ALL
  SELECT 'F — BASELINE','inventory_costing_outlet_authority',count(*)::bigint,NULL::jsonb FROM public.inventory_costing_outlet_authority
)
SELECT section,item,product_count,details
FROM output_rows
ORDER BY section,item;
