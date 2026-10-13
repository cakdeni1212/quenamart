-- Frozen operational estimates for IPOS_IMPORT only. These rows are never
-- sale-time COGS evidence and never participate in inventory costing.
BEGIN;

ALTER TABLE public.ipos_sales_import_batches
  ADD COLUMN current_estimate_snapshot_id uuid,
  ADD COLUMN frozen_estimate_snapshot_id uuid;

CREATE TABLE public.ipos_sales_estimate_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.ipos_sales_import_batches(id) ON DELETE RESTRICT,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  batch_revision integer NOT NULL CHECK(batch_revision>0),
  report_revenue numeric(32,2) NOT NULL CHECK(report_revenue>=0),
  covered_revenue numeric NOT NULL CHECK(covered_revenue>=0),
  uncovered_revenue numeric NOT NULL CHECK(uncovered_revenue>=0),
  estimated_cost numeric CHECK(estimated_cost IS NULL OR estimated_cost>=0),
  estimated_profit numeric,
  estimated_margin numeric,
  revenue_coverage numeric NOT NULL CHECK(revenue_coverage BETWEEN 0 AND 100),
  total_line_count integer NOT NULL CHECK(total_line_count>=0),
  covered_line_count integer NOT NULL CHECK(covered_line_count>=0),
  uncovered_line_count integer NOT NULL CHECK(uncovered_line_count>=0),
  total_quantity numeric NOT NULL CHECK(total_quantity>=0),
  covered_quantity numeric NOT NULL CHECK(covered_quantity>=0),
  uncovered_quantity numeric NOT NULL CHECK(uncovered_quantity>=0),
  total_sku_count integer NOT NULL CHECK(total_sku_count>=0),
  covered_sku_count integer NOT NULL CHECK(covered_sku_count>=0),
  uncovered_sku_count integer NOT NULL CHECK(uncovered_sku_count>=0),
  calculated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  calculated_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  frozen_at timestamptz,
  CONSTRAINT ipos_estimate_snapshot_id_batch_unique UNIQUE(id,batch_id),
  CONSTRAINT ipos_estimate_snapshot_batch_revision_unique UNIQUE(batch_id,batch_revision),
  CONSTRAINT ipos_estimate_snapshot_counts_consistent CHECK (
    covered_line_count+uncovered_line_count=total_line_count
    AND covered_sku_count+uncovered_sku_count<=total_sku_count
    AND covered_quantity+uncovered_quantity=total_quantity
  )
);
CREATE INDEX ipos_estimate_snapshot_batch_time_idx
  ON public.ipos_sales_estimate_snapshots(batch_id,calculated_at DESC,id DESC);

CREATE TABLE public.ipos_sales_estimate_lines (
  snapshot_id uuid NOT NULL REFERENCES public.ipos_sales_estimate_snapshots(id) ON DELETE RESTRICT,
  import_line_id uuid NOT NULL REFERENCES public.ipos_sales_import_lines(id) ON DELETE RESTRICT,
  product_id uuid REFERENCES public.products(id) ON DELETE RESTRICT,
  sku text NOT NULL,
  product_name text NOT NULL,
  quantity numeric(32,3) NOT NULL CHECK(quantity>0),
  line_revenue numeric(32,2) NOT NULL CHECK(line_revenue>=0),
  cost_source text NOT NULL CHECK(cost_source IN ('WAC','REFERENCE_HPP','UNAVAILABLE')),
  cost_reference numeric(20,8),
  estimated_line_cost numeric,
  estimated_line_profit numeric,
  uncovered_reason text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(snapshot_id,import_line_id),
  CONSTRAINT ipos_sales_estimate_line_cost_shape CHECK (
    (cost_source='UNAVAILABLE' AND cost_reference IS NULL AND estimated_line_cost IS NULL
      AND estimated_line_profit IS NULL AND uncovered_reason IS NOT NULL)
    OR (cost_source<>'UNAVAILABLE' AND cost_reference IS NOT NULL AND estimated_line_cost IS NOT NULL
      AND estimated_line_profit IS NOT NULL AND uncovered_reason IS NULL)
  )
);
CREATE INDEX ipos_sales_estimate_line_snapshot_source_idx
  ON public.ipos_sales_estimate_lines(snapshot_id,cost_source,sku);
CREATE INDEX ipos_sales_estimate_line_import_idx
  ON public.ipos_sales_estimate_lines(import_line_id,snapshot_id);

ALTER TABLE public.ipos_sales_import_batches
  ADD CONSTRAINT ipos_sales_import_current_estimate_fk
    FOREIGN KEY(current_estimate_snapshot_id,id)
    REFERENCES public.ipos_sales_estimate_snapshots(id,batch_id) ON DELETE RESTRICT,
  ADD CONSTRAINT ipos_sales_import_frozen_estimate_fk
    FOREIGN KEY(frozen_estimate_snapshot_id,id)
    REFERENCES public.ipos_sales_estimate_snapshots(id,batch_id) ON DELETE RESTRICT;

ALTER TABLE public.ipos_sales_estimate_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ipos_sales_estimate_snapshots FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ipos_sales_estimate_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ipos_sales_estimate_lines FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.ipos_sales_estimate_snapshots,public.ipos_sales_estimate_lines
  FROM PUBLIC,anon,authenticated,service_role;
CREATE POLICY ipos_sales_estimate_snapshot_owner_admin_read ON public.ipos_sales_estimate_snapshots
  FOR SELECT TO authenticated USING(public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY ipos_sales_estimate_line_owner_admin_read ON public.ipos_sales_estimate_lines
  FOR SELECT TO authenticated USING(public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
GRANT SELECT ON public.ipos_sales_estimate_snapshots,public.ipos_sales_estimate_lines TO authenticated;

CREATE FUNCTION public.reject_ipos_sales_estimate_mutation()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF TG_TABLE_NAME='ipos_sales_estimate_snapshots' AND TG_OP='UPDATE'
    AND OLD.frozen_at IS NULL AND NEW.frozen_at IS NOT NULL
    AND (to_jsonb(NEW)-'frozen_at')=(to_jsonb(OLD)-'frozen_at') THEN RETURN NEW; END IF;
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='IPOS sales estimate evidence is immutable';
END; $$;
ALTER FUNCTION public.reject_ipos_sales_estimate_mutation() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reject_ipos_sales_estimate_mutation() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER ipos_sales_estimate_snapshot_immutable
  BEFORE UPDATE OR DELETE ON public.ipos_sales_estimate_snapshots
  FOR EACH ROW EXECUTE FUNCTION public.reject_ipos_sales_estimate_mutation();
CREATE TRIGGER ipos_sales_estimate_line_immutable
  BEFORE UPDATE OR DELETE ON public.ipos_sales_estimate_lines
  FOR EACH ROW EXECUTE FUNCTION public.reject_ipos_sales_estimate_mutation();

CREATE FUNCTION public.ipos_sales_estimate_snapshot_refresh()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_snapshot uuid:=gen_random_uuid();v_authority public.inventory_cost_authority_status;
  v_summary record;v_actor uuid:=auth.uid();
BEGIN
  IF NEW.status='COMMITTED' OR NEW.preflight_result IS NULL THEN RETURN NEW; END IF;
  SELECT a.status INTO v_authority FROM public.inventory_costing_outlet_authority a WHERE a.outlet_id=NEW.outlet_id;
  INSERT INTO public.ipos_sales_estimate_snapshots(
    id,batch_id,outlet_id,batch_revision,report_revenue,covered_revenue,uncovered_revenue,
    estimated_cost,estimated_profit,estimated_margin,revenue_coverage,total_line_count,covered_line_count,
    uncovered_line_count,total_quantity,covered_quantity,uncovered_quantity,total_sku_count,
    covered_sku_count,uncovered_sku_count,calculated_by)
  WITH refs AS (
    SELECT l.id,l.batch_id,l.product_id,l.raw_sku,l.raw_item_name,l.raw_quantity,l.raw_line_total,l.resolution,
      CASE WHEN l.resolution='MATCHED'
        AND v_authority='WAC_ACTIVE'::public.inventory_cost_authority_status
        AND cp.valuation_status='VALUED'::public.inventory_cost_projection_status
        AND cp.current_wac IS NOT NULL AND cp.current_wac>=0
        AND sb.effective_quantity IS NOT NULL AND cp.physical_quantity=sb.effective_quantity
        AND cp.valued_quantity=sb.effective_quantity
        AND cp.stock_balance_version=sb.balance_version
        AND cp.stock_authority_period_id=sb.authority_period_id
        THEN 'WAC'
        WHEN l.resolution='MATCHED' AND c.hpp IS NOT NULL AND c.hpp>=0
          AND c.hpp<1000000000000 AND c.hpp=trunc(c.hpp,2)
        THEN 'REFERENCE_HPP'
        ELSE 'UNAVAILABLE' END AS cost_source,
      CASE WHEN l.resolution='MATCHED'
        AND v_authority='WAC_ACTIVE'::public.inventory_cost_authority_status
        AND cp.valuation_status='VALUED'::public.inventory_cost_projection_status
        AND cp.current_wac IS NOT NULL AND cp.current_wac>=0
        AND sb.effective_quantity IS NOT NULL AND cp.physical_quantity=sb.effective_quantity
        AND cp.valued_quantity=sb.effective_quantity
        AND cp.stock_balance_version=sb.balance_version
        AND cp.stock_authority_period_id=sb.authority_period_id
        THEN cp.current_wac
        WHEN l.resolution='MATCHED' AND c.hpp IS NOT NULL AND c.hpp>=0
          AND c.hpp<1000000000000 AND c.hpp=trunc(c.hpp,2)
        THEN c.hpp END AS cost_reference
    FROM public.ipos_sales_import_lines l
    LEFT JOIN public.inventory_cost_projections cp ON cp.outlet_id=NEW.outlet_id AND cp.product_id=l.product_id
    LEFT JOIN public.stock_balance_projection sb ON sb.outlet_id=NEW.outlet_id AND sb.product_id=l.product_id
    LEFT JOIN public.product_costs c ON c.outlet_id=NEW.outlet_id AND c.product_id=l.product_id
    WHERE l.batch_id=NEW.id
  ), calc AS (
    SELECT r.*,
      CASE WHEN r.cost_source='UNAVAILABLE' THEN NULL ELSE r.raw_quantity*r.cost_reference END AS line_cost,
      CASE WHEN r.cost_source='UNAVAILABLE' THEN NULL ELSE r.raw_line_total-r.raw_quantity*r.cost_reference END AS line_profit
    FROM refs r
  )
  SELECT v_snapshot,NEW.id,NEW.outlet_id,NEW.revision,NEW.total_amount,
    coalesce(sum(raw_line_total) FILTER(WHERE cost_source<>'UNAVAILABLE'),0),
    coalesce(sum(raw_line_total) FILTER(WHERE cost_source='UNAVAILABLE'),0),
    CASE WHEN coalesce(sum(raw_line_total) FILTER(WHERE cost_source<>'UNAVAILABLE'),0)>0
      THEN coalesce(sum(line_cost),0) END,
    CASE WHEN coalesce(sum(raw_line_total) FILTER(WHERE cost_source<>'UNAVAILABLE'),0)>0
      THEN coalesce(sum(line_profit),0) END,
    CASE WHEN coalesce(sum(raw_line_total) FILTER(WHERE cost_source<>'UNAVAILABLE'),0)<>0
      THEN sum(line_profit)/sum(raw_line_total) FILTER(WHERE cost_source<>'UNAVAILABLE')*100 END,
    CASE WHEN NEW.total_amount>0 THEN least(100::numeric,
      coalesce(sum(raw_line_total) FILTER(WHERE cost_source<>'UNAVAILABLE'),0)/NEW.total_amount*100)
      WHEN count(*) FILTER(WHERE cost_source='UNAVAILABLE')=0 THEN 100 ELSE 0 END,
    count(*)::integer,count(*) FILTER(WHERE cost_source<>'UNAVAILABLE')::integer,
    count(*) FILTER(WHERE cost_source='UNAVAILABLE')::integer,coalesce(sum(raw_quantity),0),
    coalesce(sum(raw_quantity) FILTER(WHERE cost_source<>'UNAVAILABLE'),0),
    coalesce(sum(raw_quantity) FILTER(WHERE cost_source='UNAVAILABLE'),0),count(DISTINCT raw_sku)::integer,
    count(DISTINCT raw_sku) FILTER(WHERE cost_source<>'UNAVAILABLE')::integer,
    count(DISTINCT raw_sku) FILTER(WHERE cost_source='UNAVAILABLE')::integer,v_actor
  FROM calc;

  INSERT INTO public.ipos_sales_estimate_lines(snapshot_id,import_line_id,product_id,sku,product_name,
    quantity,line_revenue,cost_source,cost_reference,estimated_line_cost,estimated_line_profit,uncovered_reason)
  WITH refs AS (
    SELECT l.*,
      CASE WHEN l.resolution='MATCHED'
        AND v_authority='WAC_ACTIVE'::public.inventory_cost_authority_status
        AND cp.valuation_status='VALUED'::public.inventory_cost_projection_status
        AND cp.current_wac IS NOT NULL AND cp.current_wac>=0
        AND sb.effective_quantity IS NOT NULL AND cp.physical_quantity=sb.effective_quantity
        AND cp.valued_quantity=sb.effective_quantity
        AND cp.stock_balance_version=sb.balance_version
        AND cp.stock_authority_period_id=sb.authority_period_id
        THEN 'WAC'
        WHEN l.resolution='MATCHED' AND c.hpp IS NOT NULL AND c.hpp>=0
          AND c.hpp<1000000000000 AND c.hpp=trunc(c.hpp,2)
        THEN 'REFERENCE_HPP' ELSE 'UNAVAILABLE' END AS cost_source,
      CASE WHEN l.resolution='MATCHED'
        AND v_authority='WAC_ACTIVE'::public.inventory_cost_authority_status
        AND cp.valuation_status='VALUED'::public.inventory_cost_projection_status
        AND cp.current_wac IS NOT NULL AND cp.current_wac>=0
        AND sb.effective_quantity IS NOT NULL AND cp.physical_quantity=sb.effective_quantity
        AND cp.valued_quantity=sb.effective_quantity
        AND cp.stock_balance_version=sb.balance_version
        AND cp.stock_authority_period_id=sb.authority_period_id
        THEN cp.current_wac
        WHEN l.resolution='MATCHED' AND c.hpp IS NOT NULL AND c.hpp>=0
          AND c.hpp<1000000000000 AND c.hpp=trunc(c.hpp,2)
        THEN c.hpp END AS cost_reference
    FROM public.ipos_sales_import_lines l
    LEFT JOIN public.inventory_cost_projections cp ON cp.outlet_id=NEW.outlet_id AND cp.product_id=l.product_id
    LEFT JOIN public.stock_balance_projection sb ON sb.outlet_id=NEW.outlet_id AND sb.product_id=l.product_id
    LEFT JOIN public.product_costs c ON c.outlet_id=NEW.outlet_id AND c.product_id=l.product_id
    WHERE l.batch_id=NEW.id
  )
  SELECT v_snapshot,id,product_id,raw_sku,raw_item_name,raw_quantity,raw_line_total,cost_source,cost_reference,
    CASE WHEN cost_source='UNAVAILABLE' THEN NULL ELSE raw_quantity*cost_reference END,
    CASE WHEN cost_source='UNAVAILABLE' THEN NULL ELSE raw_line_total-raw_quantity*cost_reference END,
    CASE WHEN cost_source<>'UNAVAILABLE' THEN NULL
      WHEN resolution<>'MATCHED' THEN 'SKU belum terdaftar' ELSE 'WAC/HPP belum tersedia' END
  FROM refs;

  UPDATE public.ipos_sales_import_batches SET current_estimate_snapshot_id=v_snapshot WHERE id=NEW.id;
  RETURN NEW;
END; $$;
ALTER FUNCTION public.ipos_sales_estimate_snapshot_refresh() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.ipos_sales_estimate_snapshot_refresh() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER ipos_sales_estimate_refresh_after_recheck
  AFTER UPDATE OF preflight_result,revision ON public.ipos_sales_import_batches
  FOR EACH ROW WHEN (NEW.revision>OLD.revision AND NEW.status<>'COMMITTED')
  EXECUTE FUNCTION public.ipos_sales_estimate_snapshot_refresh();

CREATE FUNCTION public.ipos_sales_estimate_snapshot_freeze()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_snapshot uuid;
BEGIN
  IF NEW.status<>'COMMITTED' OR OLD.status='COMMITTED' THEN RETURN NEW; END IF;
  v_snapshot:=NEW.current_estimate_snapshot_id;
  IF v_snapshot IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='IPOS_ESTIMATE_SNAPSHOT_REQUIRED'; END IF;
  UPDATE public.ipos_sales_estimate_snapshots SET frozen_at=NEW.committed_at
    WHERE id=v_snapshot AND batch_id=NEW.id AND frozen_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='IPOS_ESTIMATE_SNAPSHOT_NOT_FREEZABLE'; END IF;
  UPDATE public.ipos_sales_import_batches SET frozen_estimate_snapshot_id=v_snapshot WHERE id=NEW.id;
  RETURN NEW;
END; $$;
ALTER FUNCTION public.ipos_sales_estimate_snapshot_freeze() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.ipos_sales_estimate_snapshot_freeze() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER ipos_sales_estimate_freeze_on_commit
  AFTER UPDATE OF status ON public.ipos_sales_import_batches
  FOR EACH ROW WHEN (NEW.status='COMMITTED' AND OLD.status<>'COMMITTED')
  EXECUTE FUNCTION public.ipos_sales_estimate_snapshot_freeze();

CREATE FUNCTION public.ipos_sales_estimate_snapshot_read(p_batch_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid();v_role public.user_role;v_outlet uuid;v_count integer;v_snapshot uuid;v_result jsonb;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role)
    THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='IPOS_SALES_ESTIMATE_UNAUTHORIZED'; END IF;
  SELECT count(*)::integer,(array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1] INTO v_count,v_outlet
    FROM public.stock_authority_periods ap JOIN public.outlets o ON o.id=ap.outlet_id
    WHERE ap.ended_at IS NULL AND o.is_active;
  IF v_count<>1 OR NOT EXISTS(SELECT 1 FROM public.ipos_sales_import_batches b WHERE b.id=p_batch_id AND b.outlet_id=v_outlet)
    THEN RETURN NULL; END IF;
  SELECT coalesce(frozen_estimate_snapshot_id,current_estimate_snapshot_id) INTO v_snapshot
    FROM public.ipos_sales_import_batches WHERE id=p_batch_id AND outlet_id=v_outlet;
  IF v_snapshot IS NULL THEN RETURN NULL; END IF;
  SELECT jsonb_build_object(
    'calculatedAt',s.calculated_at,'frozen',s.frozen_at IS NOT NULL,'frozenAt',s.frozen_at,
    'summary',jsonb_build_object('reportRevenue',s.report_revenue::text,'coveredRevenue',s.covered_revenue::text,
      'uncoveredRevenue',s.uncovered_revenue::text,'estimatedCost',s.estimated_cost::text,
      'estimatedProfit',s.estimated_profit::text,'estimatedMargin',s.estimated_margin::text,
      'revenueCoverage',s.revenue_coverage::text,'totalLines',s.total_line_count,'coveredLines',s.covered_line_count,
      'uncoveredLines',s.uncovered_line_count,'totalQuantity',s.total_quantity::text,
      'coveredQuantity',s.covered_quantity::text,'uncoveredQuantity',s.uncovered_quantity::text,
      'totalSku',s.total_sku_count,'coveredSku',s.covered_sku_count,'uncoveredSku',s.uncovered_sku_count),
    'costSources',(SELECT jsonb_build_object(
        'wacSkuCount',count(DISTINCT sku) FILTER(WHERE cost_source='WAC'),
        'referenceHppSkuCount',count(DISTINCT sku) FILTER(WHERE cost_source='REFERENCE_HPP'),
        'unavailableSkuCount',count(DISTINCT sku) FILTER(WHERE cost_source='UNAVAILABLE'))
      FROM public.ipos_sales_estimate_lines WHERE snapshot_id=s.id),
    'uncovered',(SELECT coalesce(jsonb_agg(q),'[]'::jsonb) FROM (
        SELECT jsonb_build_object('sku',sku,'name',product_name,'quantity',sum(quantity)::text,
          'revenue',sum(line_revenue)::text,'reason',min(uncovered_reason)) AS q
        FROM public.ipos_sales_estimate_lines WHERE snapshot_id=s.id AND cost_source='UNAVAILABLE'
        GROUP BY sku,product_name ORDER BY sum(line_revenue) DESC,sku LIMIT 30) u),
    'uncoveredTruncated',(SELECT count(DISTINCT sku)>30 FROM public.ipos_sales_estimate_lines
      WHERE snapshot_id=s.id AND cost_source='UNAVAILABLE'))
  INTO v_result FROM public.ipos_sales_estimate_snapshots s WHERE s.id=v_snapshot AND s.batch_id=p_batch_id;
  RETURN v_result;
END; $$;
ALTER FUNCTION public.ipos_sales_estimate_snapshot_read(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.ipos_sales_estimate_snapshot_read(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.ipos_sales_estimate_snapshot_read(uuid) TO authenticated;

DO $$
DECLARE v_def text;v_old text;v_new text;
BEGIN
  v_def:=pg_get_functiondef('public.ipos_sales_import_batch_read(uuid)'::regprocedure);
  v_old:='jsonb_build_object(''batch'',to_jsonb(b),''transactions'',coalesce((';
  v_new:='jsonb_build_object(''batch'',to_jsonb(b),''estimate'',public.ipos_sales_estimate_snapshot_read(b.id),''transactions'',coalesce((';
  IF position(v_old in v_def)=0 OR (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old)<>1 THEN
    RAISE EXCEPTION 'iPos batch-read payload changed; estimate read integration requires review';
  END IF;
  EXECUTE replace(v_def,v_old,v_new);
END $$;

CREATE FUNCTION public.ipos_estimated_profit_read(p_from date,p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid();v_role public.user_role;v_outlet uuid;v_count integer;v_result jsonb;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role)
    THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='IPOS_SALES_ESTIMATE_UNAUTHORIZED'; END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to<p_from OR p_to-p_from+1>366
    THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='IPOS_SALES_ESTIMATE_PERIOD_INVALID'; END IF;
  SELECT count(*)::integer,(array_agg(ap.outlet_id ORDER BY ap.outlet_id))[1] INTO v_count,v_outlet
    FROM public.stock_authority_periods ap JOIN public.outlets o ON o.id=ap.outlet_id
    WHERE ap.ended_at IS NULL AND o.is_active;
  IF v_count<>1 OR v_outlet IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='IPOS_SALES_ESTIMATE_OUTLET_UNAVAILABLE'; END IF;
  WITH period_sales AS MATERIALIZED (
    SELECT s.id,s.grand_total,s.source_import_batch_id FROM public.sales s
    WHERE s.outlet_id=v_outlet AND s.source_system='IPOS_IMPORT'::public.pos_sale_source
      AND s.status='COMPLETED'::public.pos_sale_status
      AND s.completed_at>=p_from::timestamp AT TIME ZONE 'Asia/Jakarta'
      AND s.completed_at<(p_to+1)::timestamp AT TIME ZONE 'Asia/Jakarta'
  ), lines AS (
    SELECT si.id,si.product_id,si.sku_snapshot,si.product_name_snapshot,si.quantity,
      coalesce(si.source_line_total,si.line_subtotal) AS revenue,
      el.cost_source,el.cost_reference,el.estimated_line_cost,el.estimated_line_profit,el.uncovered_reason,
      snap.calculated_at
    FROM period_sales ps JOIN public.sale_items si ON si.sale_id=ps.id AND si.outlet_id=v_outlet
    LEFT JOIN public.ipos_sales_estimate_lines el ON el.import_line_id=si.source_import_line_id
      AND el.snapshot_id=(SELECT b.frozen_estimate_snapshot_id FROM public.ipos_sales_import_batches b
        WHERE b.id=ps.source_import_batch_id)
    LEFT JOIN public.ipos_sales_estimate_snapshots snap ON snap.id=el.snapshot_id
  ), totals AS (
    SELECT (SELECT coalesce(sum(grand_total),0) FROM period_sales) AS revenue,
      (SELECT count(*) FROM period_sales) AS transactions,
      count(*) AS total_lines,count(*) FILTER(WHERE cost_source IS NOT NULL AND cost_source<>'UNAVAILABLE') AS covered_lines,
      count(*) FILTER(WHERE cost_source IS NULL OR cost_source='UNAVAILABLE') AS uncovered_lines,
      coalesce(sum(quantity),0) AS total_quantity,
      coalesce(sum(quantity) FILTER(WHERE cost_source IS NOT NULL AND cost_source<>'UNAVAILABLE'),0) AS covered_quantity,
      coalesce(sum(quantity) FILTER(WHERE cost_source IS NULL OR cost_source='UNAVAILABLE'),0) AS uncovered_quantity,
      coalesce(sum(revenue) FILTER(WHERE cost_source IS NOT NULL AND cost_source<>'UNAVAILABLE'),0) AS covered_revenue,
      coalesce(sum(revenue) FILTER(WHERE cost_source IS NULL OR cost_source='UNAVAILABLE'),0) AS line_uncovered_revenue,
      coalesce(sum(estimated_line_cost),0) AS estimated_cost,
      coalesce(sum(estimated_line_profit),0) AS estimated_profit,
      count(DISTINCT sku_snapshot) AS total_sku,
      count(DISTINCT sku_snapshot) FILTER(WHERE cost_source IS NOT NULL AND cost_source<>'UNAVAILABLE') AS covered_sku,
      count(DISTINCT sku_snapshot) FILTER(WHERE cost_source IS NULL OR cost_source='UNAVAILABLE') AS uncovered_sku,
      max(calculated_at) AS latest_snapshot_at
    FROM lines
  ), source_counts AS (
    SELECT count(DISTINCT sku_snapshot) FILTER(WHERE cost_source='WAC') AS wac_skus,
      count(DISTINCT sku_snapshot) FILTER(WHERE cost_source='REFERENCE_HPP') AS hpp_skus,
      count(DISTINCT sku_snapshot) FILTER(WHERE cost_source IS NULL OR cost_source='UNAVAILABLE') AS unavailable_skus
    FROM lines
  ), uncovered_rows AS (
    SELECT sku_snapshot AS sku,product_name_snapshot AS name,sum(quantity) AS quantity,
      sum(revenue) AS revenue,min(coalesce(uncovered_reason,'Estimasi belum tersimpan')) AS reason
    FROM lines WHERE cost_source IS NULL OR cost_source='UNAVAILABLE'
    GROUP BY sku_snapshot,product_name_snapshot ORDER BY sum(revenue) DESC,sku_snapshot LIMIT 20
  )
  SELECT jsonb_build_object('revenue',(SELECT revenue::text FROM totals),
    'transactions',(SELECT transactions FROM totals),'totalLines',(SELECT total_lines FROM totals),
    'coveredLines',(SELECT covered_lines FROM totals),'uncoveredLines',(SELECT uncovered_lines FROM totals),
    'totalQuantity',(SELECT total_quantity::text FROM totals),'coveredQuantity',(SELECT covered_quantity::text FROM totals),
    'uncoveredQuantity',(SELECT uncovered_quantity::text FROM totals),
    'coveredRevenue',(SELECT covered_revenue::text FROM totals),
    'uncoveredRevenue',greatest((SELECT revenue FROM totals)-(SELECT covered_revenue FROM totals),0)::text,
    'estimatedCost',CASE WHEN (SELECT covered_revenue FROM totals)>0 THEN (SELECT estimated_cost::text FROM totals) END,
    'estimatedProfit',CASE WHEN (SELECT covered_revenue FROM totals)>0 THEN (SELECT estimated_profit::text FROM totals) END,
    'estimatedMargin',CASE WHEN (SELECT covered_revenue FROM totals)<>0
      THEN ((SELECT estimated_profit FROM totals)/(SELECT covered_revenue FROM totals)*100)::text END,
    'revenueCoverage',CASE WHEN (SELECT revenue FROM totals)>0
      THEN least(100::numeric,(SELECT covered_revenue FROM totals)/(SELECT revenue FROM totals)*100)::text
      ELSE CASE WHEN (SELECT uncovered_lines FROM totals)=0 THEN '100' ELSE '0' END END,
    'totalSku',(SELECT total_sku FROM totals),'coveredSku',(SELECT covered_sku FROM totals),
    'uncoveredSku',(SELECT uncovered_sku FROM totals),
    'wacSkuCount',(SELECT wac_skus FROM source_counts),'referenceHppSkuCount',(SELECT hpp_skus FROM source_counts),
    'unavailableSkuCount',(SELECT unavailable_skus FROM source_counts),
    'calculatedAt',(SELECT latest_snapshot_at FROM totals),
    'uncovered',(SELECT coalesce(jsonb_agg(to_jsonb(uncovered_rows)),'[]'::jsonb) FROM uncovered_rows))
  INTO v_result;
  RETURN v_result;
END; $$;
ALTER FUNCTION public.ipos_estimated_profit_read(date,date) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.ipos_estimated_profit_read(date,date) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.ipos_estimated_profit_read(date,date) TO authenticated;

COMMIT;
