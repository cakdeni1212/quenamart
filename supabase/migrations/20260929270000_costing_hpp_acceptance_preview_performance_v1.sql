-- HPP acceptance preview performance: evaluate the live population once per
-- request and reuse that materialized result for summary, count, and rows.
-- Classification semantics and the public JSON/RPC contract are unchanged.
BEGIN;

CREATE OR REPLACE FUNCTION public.inventory_cost_initial_hpp_acceptance_preview(
  p_outlet_id uuid,
  p_filter text DEFAULT 'ALL',
  p_search text DEFAULT NULL,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 50
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE
  v_role public.user_role := public.current_active_user_role();
  v_filter text := coalesce(nullif(upper(btrim(p_filter)),''),'ALL');
  v_search text := nullif(btrim(coalesce(p_search,'')),'');
  v_page integer := greatest(coalesce(p_page,1),1);
  v_size integer := least(greatest(coalesce(p_page_size,50),1),100);
  v_result jsonb;
BEGIN
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RETURN jsonb_build_object('ok',false,'code','FORBIDDEN');
  END IF;
  IF p_outlet_id IS NULL OR NOT EXISTS(
    SELECT 1 FROM public.outlets o WHERE o.id=p_outlet_id AND o.is_active
  ) THEN
    RETURN jsonb_build_object('ok',false,'code','INVALID_OUTLET');
  END IF;
  IF v_filter NOT IN ('ALL','CANDIDATES','EXCEPTIONS','WARNINGS') THEN
    RETURN jsonb_build_object('ok',false,'code','INVALID_FILTER');
  END IF;

  WITH evaluated AS MATERIALIZED (
    SELECT * FROM public.inventory_cost_hpp_acceptance_evaluate(p_outlet_id)
  ), positive AS MATERIALIZED (
    SELECT * FROM evaluated WHERE effective_quantity>0
  ), summary AS (
    SELECT count(*)::integer AS positive_count,
      count(*) FILTER(WHERE classification='AUTO_CANDIDATE')::integer AS candidate_count,
      count(*) FILTER(WHERE classification='EXCEPTION')::integer AS exception_count,
      count(*) FILTER(WHERE cardinality(warning_codes)>0)::integer AS warning_product_count,
      coalesce(sum(effective_quantity*current_hpp)
        FILTER(WHERE classification='AUTO_CANDIDATE'),0)::numeric(32,8) AS estimate
    FROM positive
  ), reasons AS (
    SELECT coalesce(jsonb_object_agg(reason,cnt),'{}'::jsonb) AS counts
    FROM (
      SELECT u.reason,count(*)::integer AS cnt
      FROM positive CROSS JOIN LATERAL unnest(blocking_reasons) AS u(reason)
      GROUP BY u.reason ORDER BY u.reason
    ) x
  ), warnings AS (
    SELECT coalesce(jsonb_object_agg(warning,cnt),'{}'::jsonb) AS counts
    FROM (
      SELECT u.warning,count(*)::integer AS cnt
      FROM positive CROSS JOIN LATERAL unnest(warning_codes) AS u(warning)
      GROUP BY u.warning ORDER BY u.warning
    ) x
  ), filtered AS MATERIALIZED (
    SELECT e.* FROM positive e
    WHERE (v_filter='ALL'
      OR (v_filter='CANDIDATES' AND classification='AUTO_CANDIDATE')
      OR (v_filter='EXCEPTIONS' AND classification='EXCEPTION')
      OR (v_filter='WARNINGS' AND cardinality(warning_codes)>0))
      AND (v_search IS NULL OR product_name ILIKE '%'||v_search||'%'
        OR sku ILIKE '%'||v_search||'%')
  ), page_rows AS (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'productId',product_id,
      'name',product_name,
      'sku',sku,
      'effectiveQuantity',effective_quantity,
      'currentHpp',current_hpp,
      'sellingPrice',selling_price,
      'classification',classification,
      'blockingReasons',blocking_reasons,
      'warnings',warning_codes,
      'sourceHpp',normalized_source_hpp,
      'sourceRowId',source_import_row_id,
      'sourceBatchId',source_import_batch_id,
      'normalizationCommitId',normalization_commit_id,
      'sourceRowStatus',source_row_status,
      'sourceValid',source_valid,
      'latestHistoryHpp',latest_history_hpp,
      'latestHistorySourceRowId',latest_history_source_row_id,
      'latestReviewStatus',latest_review_status,
      'activeHppOverride',active_override_id IS NOT NULL,
      'openCostFindings',open_cost_findings
    ) ORDER BY product_name,sku,product_id),'[]'::jsonb) AS rows
    FROM (
      SELECT * FROM filtered
      ORDER BY product_name,sku,product_id
      OFFSET ((v_page::bigint)-1)*v_size LIMIT v_size
    ) page
  ), filtered_count AS (
    SELECT count(*)::integer AS total FROM filtered
  )
  SELECT jsonb_build_object(
    'ok',true,
    'summary',jsonb_build_object(
      'positiveStockProducts',s.positive_count,
      'autoCandidates',s.candidate_count,
      'exceptions',s.exception_count,
      'warningProducts',s.warning_product_count,
      'estimatedAutoCandidateValue',s.estimate,
      'exceptionCountsByReason',r.counts,
      'warningCountsByCode',w.counts
    ),
    'filter',v_filter,
    'search',v_search,
    'page',v_page,
    'pageSize',v_size,
    'total',fc.total,
    'rows',pr.rows
  ) INTO v_result
  FROM summary s CROSS JOIN reasons r CROSS JOIN warnings w
    CROSS JOIN filtered_count fc CROSS JOIN page_rows pr;

  RETURN v_result;
END;
$$;

ALTER FUNCTION public.inventory_cost_initial_hpp_acceptance_preview(uuid,text,text,integer,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_initial_hpp_acceptance_preview(uuid,text,text,integer,integer)
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.inventory_cost_initial_hpp_acceptance_preview(uuid,text,text,integer,integer)
  TO authenticated;

COMMIT;
