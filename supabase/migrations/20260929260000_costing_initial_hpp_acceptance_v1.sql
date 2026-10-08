-- Costing Engine v1 Checkpoint A: one-time initial HPP acceptance evidence.
-- This migration creates preview/preparation/review/approval capability only.
-- It does not bootstrap costing, create cost projections/events/authority rows,
-- activate WAC, or alter stock, iPos, or legacy HPP records.
BEGIN;

CREATE TYPE public.inventory_cost_hpp_acceptance_status AS ENUM (
  'PREPARED', 'APPROVED', 'INVALIDATED', 'CONSUMED'
);
CREATE TYPE public.inventory_cost_hpp_acceptance_disposition AS ENUM (
  'ACCEPT_CURRENT_HPP', 'OPENING_HPP_OVERRIDE', 'LEAVE_UNVALUED', 'AUTHORITATIVE_ZERO'
);
CREATE TYPE public.inventory_cost_hpp_acceptance_operation AS ENUM (
  'PREPARE', 'RESOLVE', 'APPROVE'
);
CREATE TYPE public.inventory_cost_hpp_acceptance_event_type AS ENUM (
  'PREPARED', 'EXCEPTION_RESOLVED', 'APPROVED', 'INVALIDATED', 'BOOTSTRAP_CONSUMED'
);

CREATE TABLE public.inventory_cost_hpp_acceptance_requests (
  request_id uuid PRIMARY KEY,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  operation public.inventory_cost_hpp_acceptance_operation NOT NULL,
  payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  result jsonb,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_cost_hpp_acceptance_request_terminal
    CHECK ((result IS NULL) = (completed_at IS NULL))
);

CREATE TABLE public.inventory_cost_hpp_acceptance_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  rule_version text NOT NULL CHECK (rule_version = 'INITIAL_HPP_V1'),
  status public.inventory_cost_hpp_acceptance_status NOT NULL DEFAULT 'PREPARED',
  source_snapshot_hash text NOT NULL CHECK (source_snapshot_hash ~ '^[0-9a-f]{32}$'),
  source_import_batch_count integer NOT NULL DEFAULT 0 CHECK (source_import_batch_count >= 0),
  normalization_commit_count integer NOT NULL DEFAULT 0 CHECK (normalization_commit_count >= 0),
  candidate_count integer NOT NULL DEFAULT 0 CHECK (candidate_count >= 0),
  exception_count integer NOT NULL DEFAULT 0 CHECK (exception_count >= 0),
  blocking_reason_counts jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(blocking_reason_counts)='object'),
  warning_product_count integer NOT NULL DEFAULT 0 CHECK (warning_product_count >= 0),
  warning_counts jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(warning_counts) = 'object'),
  candidate_estimated_opening_value numeric(32,8),
  estimated_opening_value numeric(32,8),
  prepared_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  prepared_at timestamptz NOT NULL DEFAULT now(),
  prepare_request_id uuid NOT NULL UNIQUE REFERENCES public.inventory_cost_hpp_acceptance_requests(request_id) ON DELETE RESTRICT,
  approved_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  approved_at timestamptz,
  approve_request_id uuid UNIQUE REFERENCES public.inventory_cost_hpp_acceptance_requests(request_id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_cost_hpp_acceptance_batch_id_outlet_unique UNIQUE(id,outlet_id),
  CONSTRAINT inventory_cost_hpp_acceptance_approval_pair CHECK (
    (status <> 'APPROVED' AND approved_by IS NULL AND approved_at IS NULL AND approve_request_id IS NULL)
    OR (status IN ('APPROVED','CONSUMED') AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND approve_request_id IS NOT NULL)
  ),
  CONSTRAINT inventory_cost_hpp_acceptance_value_valid CHECK (
    (candidate_estimated_opening_value IS NULL OR candidate_estimated_opening_value >= 0)
    AND (estimated_opening_value IS NULL OR estimated_opening_value >= 0)
  )
);
CREATE UNIQUE INDEX inventory_cost_hpp_acceptance_one_active_outlet
  ON public.inventory_cost_hpp_acceptance_batches(outlet_id)
  WHERE status IN ('PREPARED','APPROVED','CONSUMED');
CREATE INDEX inventory_cost_hpp_acceptance_batches_outlet_status_idx
  ON public.inventory_cost_hpp_acceptance_batches(outlet_id,status,prepared_at DESC,id DESC);

CREATE TABLE public.inventory_cost_hpp_acceptance_items (
  batch_id uuid NOT NULL REFERENCES public.inventory_cost_hpp_acceptance_batches(id) ON DELETE RESTRICT,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  classification text NOT NULL CHECK (classification IN ('AUTO_CANDIDATE','EXCEPTION')),
  blocking_reasons text[] NOT NULL DEFAULT '{}',
  warning_codes text[] NOT NULL DEFAULT '{}',
  source_hpp numeric,
  source_import_row_id uuid,
  source_import_batch_id uuid REFERENCES public.ipos_import_batches(id) ON DELETE RESTRICT,
  normalization_commit_id uuid REFERENCES public.ipos_normalization_commits(id) ON DELETE RESTRICT,
  source_row_status public.ipos_import_row_status,
  source_valid boolean NOT NULL,
  normalized_source_hpp numeric,
  source_conflict_codes text[] NOT NULL DEFAULT '{}',
  current_hpp numeric,
  current_hpp_updated_at timestamptz,
  latest_cost_history_id uuid REFERENCES public.product_cost_history(id) ON DELETE RESTRICT,
  latest_history_hpp numeric,
  latest_history_source_row_id uuid,
  latest_review_id uuid REFERENCES public.product_field_audit_reviews(id) ON DELETE RESTRICT,
  latest_review_status public.product_field_audit_status,
  latest_review_source_row_id uuid,
  active_override_id uuid REFERENCES public.product_field_overrides(id) ON DELETE RESTRICT,
  active_override_count integer NOT NULL DEFAULT 0 CHECK (active_override_count >= 0),
  active_override_value numeric,
  active_override_source_row_id uuid,
  latest_reconciliation_event_id uuid REFERENCES public.product_field_reconciliation_events(id) ON DELETE RESTRICT,
  latest_reconciliation_event_type text,
  open_cost_findings text[] NOT NULL DEFAULT '{}',
  selling_price numeric,
  selling_price_source_row_id uuid,
  selling_price_updated_at timestamptz,
  latest_selling_price_history_id uuid REFERENCES public.product_selling_price_history(id) ON DELETE RESTRICT,
  current_source_fingerprint text NOT NULL CHECK (current_source_fingerprint ~ '^[0-9a-f]{32}$'),
  disposition public.inventory_cost_hpp_acceptance_disposition,
  accepted_opening_hpp numeric,
  resolved_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  resolved_at timestamptz,
  resolution_reason text,
  quantity_at_prepare numeric(14,3),
  balance_version_at_prepare bigint,
  quantity_at_approval numeric(14,3),
  balance_version_at_approval bigint,
  approved_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  approved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (batch_id,product_id),
  CONSTRAINT inventory_cost_hpp_acceptance_item_outlet_fk
    FOREIGN KEY (batch_id,outlet_id) REFERENCES public.inventory_cost_hpp_acceptance_batches(id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_hpp_acceptance_item_source_fk
    FOREIGN KEY (source_import_row_id,product_id,outlet_id)
    REFERENCES public.ipos_import_rows(id,product_id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_hpp_acceptance_item_history_source_fk
    FOREIGN KEY (latest_history_source_row_id,product_id,outlet_id)
    REFERENCES public.ipos_import_rows(id,product_id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_hpp_acceptance_item_review_source_fk
    FOREIGN KEY (latest_review_source_row_id,product_id,outlet_id)
    REFERENCES public.ipos_import_rows(id,product_id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_hpp_acceptance_item_override_source_fk
    FOREIGN KEY (active_override_source_row_id,product_id,outlet_id)
    REFERENCES public.ipos_import_rows(id,product_id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_hpp_acceptance_item_selling_source_fk
    FOREIGN KEY (selling_price_source_row_id,product_id,outlet_id)
    REFERENCES public.ipos_import_rows(id,product_id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_hpp_acceptance_item_hpp_valid CHECK (
    (source_hpp IS NULL OR (source_hpp >= 0 AND source_hpp < 1000000000000 AND source_hpp = trunc(source_hpp,2)))
    AND (normalized_source_hpp IS NULL OR (normalized_source_hpp >= 0 AND normalized_source_hpp < 1000000000000 AND normalized_source_hpp = trunc(normalized_source_hpp,2)))
    AND (current_hpp IS NULL OR (current_hpp >= 0 AND current_hpp < 1000000000000 AND current_hpp = trunc(current_hpp,2)))
    AND (latest_history_hpp IS NULL OR (latest_history_hpp >= 0 AND latest_history_hpp < 1000000000000 AND latest_history_hpp = trunc(latest_history_hpp,2)))
    AND (active_override_value IS NULL OR (active_override_value >= 0 AND active_override_value < 1000000000000 AND active_override_value = trunc(active_override_value,2)))
    AND (selling_price IS NULL OR (selling_price >= 0 AND selling_price < 1000000000000 AND selling_price = trunc(selling_price,2)))
    AND (accepted_opening_hpp IS NULL OR (accepted_opening_hpp >= 0 AND accepted_opening_hpp < 1000000000000 AND accepted_opening_hpp = trunc(accepted_opening_hpp,2)))
  ),
  CONSTRAINT inventory_cost_hpp_acceptance_resolution_pair CHECK (
    (disposition IS NULL AND accepted_opening_hpp IS NULL AND resolved_by IS NULL AND resolved_at IS NULL AND resolution_reason IS NULL)
    OR (disposition IS NOT NULL AND resolved_by IS NOT NULL AND resolved_at IS NOT NULL AND resolution_reason IS NOT NULL AND btrim(resolution_reason) <> '')
    OR (classification='AUTO_CANDIDATE' AND disposition='ACCEPT_CURRENT_HPP' AND accepted_opening_hpp=current_hpp AND resolved_by IS NULL AND resolved_at IS NULL AND resolution_reason IS NULL)
  ),
  CONSTRAINT inventory_cost_hpp_acceptance_zero_explicit CHECK (
    disposition <> 'AUTHORITATIVE_ZERO' OR (current_hpp=0 AND accepted_opening_hpp=0)
  ),
  CONSTRAINT inventory_cost_hpp_acceptance_override_positive CHECK (
    disposition <> 'OPENING_HPP_OVERRIDE' OR accepted_opening_hpp > 0
  ),
  CONSTRAINT inventory_cost_hpp_acceptance_classification_shape CHECK (
    (classification='AUTO_CANDIDATE' AND cardinality(blocking_reasons)=0 AND disposition='ACCEPT_CURRENT_HPP')
    OR classification='EXCEPTION'
  ),
  CONSTRAINT inventory_cost_hpp_acceptance_quantity_valid CHECK (
    (quantity_at_prepare IS NULL OR (quantity_at_prepare > 0 AND quantity_at_prepare < 100000000000 AND quantity_at_prepare=trunc(quantity_at_prepare,3)))
    AND (quantity_at_approval IS NULL OR (quantity_at_approval >= 0 AND quantity_at_approval < 100000000000 AND quantity_at_approval=trunc(quantity_at_approval,3)))
  ),
  CONSTRAINT inventory_cost_hpp_acceptance_approval_item_pair CHECK (
    (approved_by IS NULL AND approved_at IS NULL AND quantity_at_approval IS NULL AND balance_version_at_approval IS NULL)
    OR (approved_by IS NOT NULL AND approved_at IS NOT NULL AND balance_version_at_approval IS NOT NULL)
  )
);
CREATE INDEX inventory_cost_hpp_acceptance_items_outlet_batch_product_idx
  ON public.inventory_cost_hpp_acceptance_items(outlet_id,batch_id,product_id);
CREATE INDEX inventory_cost_hpp_acceptance_items_exception_idx
  ON public.inventory_cost_hpp_acceptance_items(batch_id,product_id)
  WHERE classification='EXCEPTION';

CREATE TABLE public.inventory_cost_hpp_acceptance_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.inventory_cost_hpp_acceptance_batches(id) ON DELETE RESTRICT,
  product_id uuid REFERENCES public.products(id) ON DELETE RESTRICT,
  event_type public.inventory_cost_hpp_acceptance_event_type NOT NULL,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  request_id uuid NOT NULL UNIQUE REFERENCES public.inventory_cost_hpp_acceptance_requests(request_id) ON DELETE RESTRICT,
  reason text,
  details jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(details)='object'),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX inventory_cost_hpp_acceptance_events_batch_time_idx
  ON public.inventory_cost_hpp_acceptance_events(batch_id,created_at,id);

ALTER TABLE public.inventory_cost_hpp_acceptance_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_cost_hpp_acceptance_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_cost_hpp_acceptance_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_cost_hpp_acceptance_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_cost_hpp_acceptance_requests,public.inventory_cost_hpp_acceptance_batches,
  public.inventory_cost_hpp_acceptance_items,public.inventory_cost_hpp_acceptance_events FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.inventory_cost_hpp_acceptance_batches,public.inventory_cost_hpp_acceptance_items,
  public.inventory_cost_hpp_acceptance_events TO authenticated;
CREATE POLICY inventory_cost_hpp_acceptance_batches_read_managers
  ON public.inventory_cost_hpp_acceptance_batches FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY inventory_cost_hpp_acceptance_items_read_managers
  ON public.inventory_cost_hpp_acceptance_items FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY inventory_cost_hpp_acceptance_events_read_managers
  ON public.inventory_cost_hpp_acceptance_events FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));

CREATE FUNCTION public.guard_inventory_cost_hpp_acceptance_event()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='HPP acceptance audit events are append-only';
END;
$$;
ALTER FUNCTION public.guard_inventory_cost_hpp_acceptance_event() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_inventory_cost_hpp_acceptance_event() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER inventory_cost_hpp_acceptance_events_immutable
  BEFORE UPDATE OR DELETE ON public.inventory_cost_hpp_acceptance_events
  FOR EACH ROW EXECUTE FUNCTION public.guard_inventory_cost_hpp_acceptance_event();

CREATE FUNCTION public.guard_inventory_cost_hpp_acceptance_batch()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='HPP acceptance batches cannot be deleted'; END IF;
  IF OLD.id IS DISTINCT FROM NEW.id OR OLD.outlet_id IS DISTINCT FROM NEW.outlet_id
    OR OLD.rule_version IS DISTINCT FROM NEW.rule_version OR OLD.source_snapshot_hash IS DISTINCT FROM NEW.source_snapshot_hash
    OR OLD.prepared_by IS DISTINCT FROM NEW.prepared_by OR OLD.prepared_at IS DISTINCT FROM NEW.prepared_at
    OR OLD.prepare_request_id IS DISTINCT FROM NEW.prepare_request_id OR OLD.created_at IS DISTINCT FROM NEW.created_at THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='HPP acceptance batch preparation evidence is immutable';
  END IF;
  IF OLD.candidate_count IS DISTINCT FROM NEW.candidate_count OR OLD.exception_count IS DISTINCT FROM NEW.exception_count
    OR OLD.exception_count IS DISTINCT FROM NEW.exception_count OR OLD.blocking_reason_counts IS DISTINCT FROM NEW.blocking_reason_counts
    OR OLD.warning_product_count IS DISTINCT FROM NEW.warning_product_count OR OLD.warning_counts IS DISTINCT FROM NEW.warning_counts
    OR OLD.candidate_estimated_opening_value IS DISTINCT FROM NEW.candidate_estimated_opening_value
    OR OLD.source_import_batch_count IS DISTINCT FROM NEW.source_import_batch_count
    OR OLD.normalization_commit_count IS DISTINCT FROM NEW.normalization_commit_count THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='HPP acceptance preparation summary is immutable';
  END IF;
  IF OLD.status='PREPARED' AND NEW.status='INVALIDATED'
    AND NEW.approved_by IS NULL AND NEW.approved_at IS NULL AND NEW.approve_request_id IS NULL
    AND NEW.estimated_opening_value IS NOT DISTINCT FROM OLD.estimated_opening_value
    AND NEW.candidate_estimated_opening_value IS NOT DISTINCT FROM OLD.candidate_estimated_opening_value THEN RETURN NEW; END IF;
  IF OLD.status='PREPARED' AND NEW.status='APPROVED'
    AND NEW.approved_by IS NOT NULL AND NEW.approved_at IS NOT NULL AND NEW.approve_request_id IS NOT NULL THEN RETURN NEW; END IF;
  IF OLD.status='APPROVED' AND NEW.status='CONSUMED'
    AND NEW.approved_by IS NOT DISTINCT FROM OLD.approved_by AND NEW.approved_at IS NOT DISTINCT FROM OLD.approved_at
    AND NEW.approve_request_id IS NOT DISTINCT FROM OLD.approve_request_id
    AND NEW.estimated_opening_value IS NOT DISTINCT FROM OLD.estimated_opening_value
    AND NEW.candidate_estimated_opening_value IS NOT DISTINCT FROM OLD.candidate_estimated_opening_value THEN RETURN NEW; END IF;
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Invalid HPP acceptance batch transition';
END;
$$;
ALTER FUNCTION public.guard_inventory_cost_hpp_acceptance_batch() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_inventory_cost_hpp_acceptance_batch() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER inventory_cost_hpp_acceptance_batches_lifecycle_guard
  BEFORE UPDATE OR DELETE ON public.inventory_cost_hpp_acceptance_batches
  FOR EACH ROW EXECUTE FUNCTION public.guard_inventory_cost_hpp_acceptance_batch();

CREATE FUNCTION public.guard_inventory_cost_hpp_acceptance_item()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE v_status public.inventory_cost_hpp_acceptance_status;
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='HPP acceptance evidence cannot be deleted'; END IF;
  SELECT b.status INTO v_status FROM public.inventory_cost_hpp_acceptance_batches b WHERE b.id=OLD.batch_id;
  IF v_status IS DISTINCT FROM 'PREPARED'::public.inventory_cost_hpp_acceptance_status THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Approved or invalidated HPP acceptance evidence is immutable';
  END IF;
  IF OLD.batch_id IS DISTINCT FROM NEW.batch_id OR OLD.outlet_id IS DISTINCT FROM NEW.outlet_id
    OR OLD.product_id IS DISTINCT FROM NEW.product_id OR OLD.classification IS DISTINCT FROM NEW.classification
    OR OLD.blocking_reasons IS DISTINCT FROM NEW.blocking_reasons OR OLD.warning_codes IS DISTINCT FROM NEW.warning_codes
    OR OLD.source_hpp IS DISTINCT FROM NEW.source_hpp OR OLD.source_import_row_id IS DISTINCT FROM NEW.source_import_row_id
    OR OLD.source_import_batch_id IS DISTINCT FROM NEW.source_import_batch_id
    OR OLD.normalization_commit_id IS DISTINCT FROM NEW.normalization_commit_id
    OR OLD.source_row_status IS DISTINCT FROM NEW.source_row_status OR OLD.source_valid IS DISTINCT FROM NEW.source_valid
    OR OLD.normalized_source_hpp IS DISTINCT FROM NEW.normalized_source_hpp
    OR OLD.source_conflict_codes IS DISTINCT FROM NEW.source_conflict_codes OR OLD.current_hpp IS DISTINCT FROM NEW.current_hpp
    OR OLD.current_hpp_updated_at IS DISTINCT FROM NEW.current_hpp_updated_at
    OR OLD.latest_cost_history_id IS DISTINCT FROM NEW.latest_cost_history_id OR OLD.latest_history_hpp IS DISTINCT FROM NEW.latest_history_hpp
    OR OLD.latest_history_source_row_id IS DISTINCT FROM NEW.latest_history_source_row_id
    OR OLD.latest_review_id IS DISTINCT FROM NEW.latest_review_id OR OLD.latest_review_status IS DISTINCT FROM NEW.latest_review_status
    OR OLD.latest_review_source_row_id IS DISTINCT FROM NEW.latest_review_source_row_id
    OR OLD.active_override_id IS DISTINCT FROM NEW.active_override_id OR OLD.active_override_count IS DISTINCT FROM NEW.active_override_count
    OR OLD.active_override_value IS DISTINCT FROM NEW.active_override_value
    OR OLD.active_override_source_row_id IS DISTINCT FROM NEW.active_override_source_row_id
    OR OLD.latest_reconciliation_event_id IS DISTINCT FROM NEW.latest_reconciliation_event_id
    OR OLD.latest_reconciliation_event_type IS DISTINCT FROM NEW.latest_reconciliation_event_type
    OR OLD.open_cost_findings IS DISTINCT FROM NEW.open_cost_findings OR OLD.selling_price IS DISTINCT FROM NEW.selling_price
    OR OLD.selling_price_source_row_id IS DISTINCT FROM NEW.selling_price_source_row_id
    OR OLD.selling_price_updated_at IS DISTINCT FROM NEW.selling_price_updated_at
    OR OLD.latest_selling_price_history_id IS DISTINCT FROM NEW.latest_selling_price_history_id
    OR OLD.current_source_fingerprint IS DISTINCT FROM NEW.current_source_fingerprint
    OR OLD.quantity_at_prepare IS DISTINCT FROM NEW.quantity_at_prepare
    OR OLD.balance_version_at_prepare IS DISTINCT FROM NEW.balance_version_at_prepare
    OR OLD.created_at IS DISTINCT FROM NEW.created_at THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='HPP acceptance source snapshot is immutable';
  END IF;
  IF NEW.disposition IS DISTINCT FROM OLD.disposition THEN
    IF NEW.resolved_by IS NULL OR NEW.resolved_by IS DISTINCT FROM auth.uid()
      OR NEW.resolved_at IS NULL OR NEW.resolution_reason IS NULL OR btrim(NEW.resolution_reason)=''
      OR NEW.disposition IS NULL THEN
      RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Authenticated reasoned exception resolution is required';
    END IF;
  END IF;
  IF OLD.approved_by IS NOT NULL OR OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='HPP acceptance approval evidence is immutable';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.guard_inventory_cost_hpp_acceptance_item() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_inventory_cost_hpp_acceptance_item() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER inventory_cost_hpp_acceptance_items_immutable_guard
  BEFORE UPDATE OR DELETE ON public.inventory_cost_hpp_acceptance_items
  FOR EACH ROW EXECUTE FUNCTION public.guard_inventory_cost_hpp_acceptance_item();

-- Internal live evaluator. Stock quantity is intentionally omitted from the
-- fingerprint: acceptance approves unit cost, not bootstrap quantity.
CREATE FUNCTION public.inventory_cost_hpp_acceptance_evaluate(p_outlet_id uuid)
RETURNS TABLE (
  outlet_id uuid, product_id uuid, product_name text, sku text,
  effective_quantity numeric, balance_version bigint,
  current_hpp numeric, current_hpp_updated_at timestamptz, source_import_row_id uuid,
  source_import_batch_id uuid, normalization_commit_id uuid, source_row_status public.ipos_import_row_status,source_valid boolean,
  normalized_source_hpp numeric, source_conflict_codes text[], latest_cost_history_id uuid,
  latest_history_hpp numeric, latest_history_source_row_id uuid,
  latest_review_id uuid, latest_review_status public.product_field_audit_status, latest_review_source_row_id uuid,
  active_override_id uuid, active_override_count integer, active_override_value numeric, active_override_source_row_id uuid,
  latest_reconciliation_event_id uuid, latest_reconciliation_event_type text,
  open_cost_findings text[], selling_price numeric, selling_price_source_row_id uuid,
  selling_price_updated_at timestamptz, latest_selling_price_history_id uuid,
  blocking_reasons text[], warning_codes text[], classification text, source_fingerprint text
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
WITH stock_rows AS (
  SELECT s.outlet_id,s.product_id,s.effective_quantity,s.balance_version,p.name AS product_name,p.sku,
    c.hpp AS current_hpp,c.updated_at AS current_hpp_updated_at,c.source_import_row_id
  FROM public.stock_balance_projection s
  JOIN public.products p ON p.id=s.product_id
  LEFT JOIN public.product_costs c ON c.product_id=s.product_id AND c.outlet_id=s.outlet_id
  WHERE s.outlet_id=p_outlet_id
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
        AND n.status='COMPLETED' AND c.action IN ('CREATE','UPDATE')
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
  SELECT percentile_disc(0.99) WITHIN GROUP (ORDER BY e.current_hpp)
    FILTER (WHERE e.current_hpp>0 AND e.current_hpp<1000000000000 AND e.current_hpp=trunc(e.current_hpp,2)) AS p99_hpp
  FROM enriched e WHERE e.effective_quantity>0
), with_warnings AS (
  SELECT e.*,s.p99_hpp FROM enriched e CROSS JOIN hpp_stats s
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
    ]) x WHERE x IS NOT NULL ORDER BY x) AS warning_codes,
    md5(jsonb_build_array(w.current_hpp::text,w.current_hpp_updated_at::text,w.source_import_row_id::text,w.source_import_batch_id::text,
      w.normalization_commit_id::text,w.source_row_status::text,w.normalized_source_hpp::text,
      w.source_valid,w.source_conflict_codes,w.latest_cost_history_id::text,w.latest_history_hpp::text,
      w.latest_history_source_row_id::text,w.latest_review_id::text,w.latest_review_status::text,
      w.latest_review_source_row_id::text,w.active_override_id::text,w.active_override_count,
      w.active_override_value::text,w.active_override_source_row_id::text,
      w.latest_reconciliation_event_id::text,w.latest_reconciliation_event_type,w.open_cost_findings,
      w.selling_price::text,w.selling_price_source_row_id::text,w.selling_price_updated_at::text,
      w.latest_selling_price_history_id::text)::text) AS source_fingerprint
  FROM with_warnings w
)
SELECT c.outlet_id,c.product_id,c.product_name,c.sku,c.effective_quantity,c.balance_version,
  c.current_hpp,c.current_hpp_updated_at,c.source_import_row_id,c.source_import_batch_id,
  c.normalization_commit_id,c.source_row_status,c.source_valid,c.normalized_source_hpp,c.source_conflict_codes,
  c.latest_cost_history_id,c.latest_history_hpp,c.latest_history_source_row_id,
  c.latest_review_id,c.latest_review_status,c.latest_review_source_row_id,
  c.active_override_id,c.active_override_count,c.active_override_value,c.active_override_source_row_id,
  c.latest_reconciliation_event_id,c.latest_reconciliation_event_type,
  c.open_cost_findings,c.selling_price,c.selling_price_source_row_id,c.selling_price_updated_at,
  c.latest_selling_price_history_id,c.blocking_reasons,c.warning_codes,
  CASE WHEN cardinality(c.blocking_reasons)=0 THEN 'AUTO_CANDIDATE' ELSE 'EXCEPTION' END,c.source_fingerprint
FROM classified c;
$$;
ALTER FUNCTION public.inventory_cost_hpp_acceptance_evaluate(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_hpp_acceptance_evaluate(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.inventory_cost_initial_hpp_acceptance_preview(
  p_outlet_id uuid,p_filter text DEFAULT 'ALL',p_search text DEFAULT NULL,p_page integer DEFAULT 1,p_page_size integer DEFAULT 50
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE
  v_role public.user_role:=public.current_active_user_role();
  v_filter text:=coalesce(nullif(upper(btrim(p_filter)),''),'ALL');
  v_search text:=nullif(btrim(coalesce(p_search,'')),'');
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_total integer;v_rows jsonb;v_summary jsonb;
BEGIN
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RETURN jsonb_build_object('ok',false,'code','FORBIDDEN');
  END IF;
  IF p_outlet_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.outlets o WHERE o.id=p_outlet_id AND o.is_active) THEN
    RETURN jsonb_build_object('ok',false,'code','INVALID_OUTLET');
  END IF;
  IF v_filter NOT IN ('ALL','CANDIDATES','EXCEPTIONS','WARNINGS') THEN
    RETURN jsonb_build_object('ok',false,'code','INVALID_FILTER');
  END IF;
  WITH eval AS MATERIALIZED (SELECT * FROM public.inventory_cost_hpp_acceptance_evaluate(p_outlet_id)),
  summary AS (
    SELECT count(*)::integer AS positive_count,
      count(*) FILTER(WHERE classification='AUTO_CANDIDATE')::integer AS candidate_count,
      count(*) FILTER(WHERE classification='EXCEPTION')::integer AS exception_count,
      count(*) FILTER(WHERE cardinality(warning_codes)>0)::integer AS warning_product_count,
      coalesce(sum(effective_quantity*current_hpp) FILTER(WHERE classification='AUTO_CANDIDATE'),0)::numeric(32,8) AS estimate
    FROM eval WHERE effective_quantity>0
  ), reasons AS (
    SELECT coalesce(jsonb_object_agg(reason,cnt),'{}'::jsonb) AS counts FROM (
      SELECT u.reason,count(*)::integer AS cnt FROM eval CROSS JOIN LATERAL unnest(blocking_reasons) AS u(reason)
      WHERE effective_quantity>0 GROUP BY u.reason ORDER BY u.reason
    ) x
  ), warnings AS (
    SELECT coalesce(jsonb_object_agg(warning,cnt),'{}'::jsonb) AS counts FROM (
      SELECT u.warning,count(*)::integer AS cnt FROM eval CROSS JOIN LATERAL unnest(warning_codes) AS u(warning)
      WHERE effective_quantity>0 GROUP BY u.warning ORDER BY u.warning
    ) x
  )
  SELECT jsonb_build_object('positiveStockProducts',s.positive_count,'autoCandidates',s.candidate_count,
    'exceptions',s.exception_count,'warningProducts',s.warning_product_count,'estimatedAutoCandidateValue',s.estimate,
    'exceptionCountsByReason',r.counts,'warningCountsByCode',w.counts) INTO v_summary
  FROM summary s CROSS JOIN reasons r CROSS JOIN warnings w;
  WITH eval AS MATERIALIZED (SELECT * FROM public.inventory_cost_hpp_acceptance_evaluate(p_outlet_id)), filtered AS (
    SELECT e.* FROM eval e JOIN public.products p ON p.id=e.product_id
    WHERE e.effective_quantity>0 AND
      (v_filter='ALL' OR (v_filter='CANDIDATES' AND classification='AUTO_CANDIDATE')
      OR (v_filter='EXCEPTIONS' AND classification='EXCEPTION')
      OR (v_filter='WARNINGS' AND cardinality(warning_codes)>0))
      AND (v_search IS NULL OR p.name ILIKE '%'||v_search||'%' OR p.sku ILIKE '%'||v_search||'%')
  )
  SELECT count(*)::integer INTO v_total FROM filtered;
  WITH eval AS MATERIALIZED (SELECT * FROM public.inventory_cost_hpp_acceptance_evaluate(p_outlet_id)), filtered AS (
    SELECT e.* FROM eval e WHERE e.effective_quantity>0 AND (v_filter='ALL' OR (v_filter='CANDIDATES' AND classification='AUTO_CANDIDATE')
      OR (v_filter='EXCEPTIONS' AND classification='EXCEPTION')
      OR (v_filter='WARNINGS' AND cardinality(warning_codes)>0))
      AND (v_search IS NULL OR e.product_name ILIKE '%'||v_search||'%' OR e.sku ILIKE '%'||v_search||'%')
    ORDER BY e.product_name,e.sku,e.product_id OFFSET ((v_page::bigint)-1)*v_size LIMIT v_size
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('productId',product_id,'name',product_name,'sku',sku,
    'effectiveQuantity',effective_quantity,'currentHpp',current_hpp,'sellingPrice',selling_price,
      'classification',classification,'blockingReasons',blocking_reasons,'warnings',warning_codes,
      'sourceHpp',normalized_source_hpp,'sourceRowId',source_import_row_id,'sourceBatchId',source_import_batch_id,
      'normalizationCommitId',normalization_commit_id,'sourceRowStatus',source_row_status,'sourceValid',source_valid,
      'latestHistoryHpp',latest_history_hpp,'latestHistorySourceRowId',latest_history_source_row_id,
      'latestReviewStatus',latest_review_status,'activeHppOverride',active_override_id IS NOT NULL,
      'openCostFindings',open_cost_findings)
    ORDER BY product_name,sku,product_id),'[]'::jsonb) INTO v_rows FROM filtered;
  RETURN jsonb_build_object('ok',true,'summary',v_summary,'filter',v_filter,'search',v_search,
    'page',v_page,'pageSize',v_size,'total',v_total,'rows',v_rows);
END;
$$;
ALTER FUNCTION public.inventory_cost_initial_hpp_acceptance_preview(uuid,text,text,integer,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.inventory_cost_initial_hpp_acceptance_preview(uuid,text,text,integer,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.inventory_cost_initial_hpp_acceptance_preview(uuid,text,text,integer,integer) TO authenticated;

CREATE FUNCTION public.prepare_initial_hpp_acceptance(p_outlet_id uuid,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE
  v_actor uuid:=auth.uid();v_role public.user_role;v_req public.inventory_cost_hpp_acceptance_requests%rowtype;
  v_batch uuid;v_payload jsonb;v_result jsonb;v_candidates integer;v_exceptions integer;
  v_warning_products integer;v_warning_counts jsonb;v_estimate numeric(32,8);v_snapshot_hash text;
  v_blocking_counts jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Authentication required'; END IF;
  v_role:=public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='HPP acceptance access denied'; END IF;
  IF p_outlet_id IS NULL OR p_request_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.outlets o WHERE o.id=p_outlet_id AND o.is_active) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Active outlet and request identity are required';
  END IF;
  v_payload:=jsonb_build_object('outletId',p_outlet_id,'operation','PREPARE','ruleVersion','INITIAL_HPP_V1');
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_HPP_ACCEPTANCE_REQUEST:'||p_request_id::text,73190411));
  SELECT * INTO v_req FROM public.inventory_cost_hpp_acceptance_requests r WHERE r.request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF v_req.actor_id<>v_actor OR v_req.operation<>'PREPARE' OR v_req.payload<>v_payload THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='HPP acceptance request identity mismatch'; END IF;
    IF v_req.result IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='HPP acceptance request is incomplete'; END IF;
    RETURN v_req.result;
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(734921,2);
  IF EXISTS(SELECT 1 FROM public.inventory_cost_hpp_acceptance_batches b WHERE b.outlet_id=p_outlet_id AND b.status IN ('PREPARED','APPROVED','CONSUMED')) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='An active initial HPP acceptance batch already exists for this outlet';
  END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority a WHERE a.outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections p WHERE p.outlet_id=p_outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_event_batches b WHERE b.outlet_id=p_outlet_id) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Initial HPP acceptance is unavailable after costing bootstrap or activation';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.inventory_cost_hpp_acceptance_evaluate(p_outlet_id) WHERE effective_quantity>0) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='No positive effective stock is available for HPP acceptance';
  END IF;
  INSERT INTO public.inventory_cost_hpp_acceptance_requests(request_id,actor_id,operation,payload)
    VALUES(p_request_id,v_actor,'PREPARE',v_payload);
  WITH e AS MATERIALIZED (SELECT * FROM public.inventory_cost_hpp_acceptance_evaluate(p_outlet_id) WHERE effective_quantity>0)
  SELECT count(*) FILTER(WHERE classification='AUTO_CANDIDATE')::integer,
    count(*) FILTER(WHERE classification='EXCEPTION')::integer,
    count(*) FILTER(WHERE cardinality(warning_codes)>0)::integer,
    coalesce(sum(effective_quantity*current_hpp) FILTER(WHERE effective_quantity>0 AND classification='AUTO_CANDIDATE'),0)::numeric(32,8),
    md5(coalesce(string_agg(product_id::text||':'||source_fingerprint,E'\n' ORDER BY product_id),'')),
    (SELECT coalesce(jsonb_object_agg(warning,cnt),'{}'::jsonb) FROM
      (SELECT u.warning,count(*)::integer cnt FROM e CROSS JOIN LATERAL unnest(warning_codes) AS u(warning) GROUP BY u.warning ORDER BY u.warning) z),
    (SELECT coalesce(jsonb_object_agg(reason,cnt),'{}'::jsonb) FROM
      (SELECT u.reason,count(*)::integer cnt FROM e CROSS JOIN LATERAL unnest(blocking_reasons) AS u(reason) GROUP BY u.reason ORDER BY u.reason) z)
  INTO v_candidates,v_exceptions,v_warning_products,v_estimate,v_snapshot_hash,v_warning_counts,v_blocking_counts FROM e;
  INSERT INTO public.inventory_cost_hpp_acceptance_batches(outlet_id,rule_version,status,source_snapshot_hash,
    source_import_batch_count,normalization_commit_count,candidate_count,exception_count,blocking_reason_counts,warning_product_count,
    warning_counts,candidate_estimated_opening_value,prepared_by,prepare_request_id)
  SELECT p_outlet_id,'INITIAL_HPP_V1','PREPARED',v_snapshot_hash,
      (SELECT count(DISTINCT source_import_batch_id)::integer FROM public.inventory_cost_hpp_acceptance_evaluate(p_outlet_id) WHERE effective_quantity>0 AND source_import_batch_id IS NOT NULL),
    (SELECT count(DISTINCT normalization_commit_id)::integer FROM public.inventory_cost_hpp_acceptance_evaluate(p_outlet_id) WHERE effective_quantity>0 AND normalization_commit_id IS NOT NULL),
    v_candidates,v_exceptions,v_blocking_counts,v_warning_products,v_warning_counts,v_estimate,v_actor,p_request_id
  RETURNING id INTO v_batch;
  INSERT INTO public.inventory_cost_hpp_acceptance_items(batch_id,outlet_id,product_id,classification,blocking_reasons,warning_codes,
    source_hpp,source_import_row_id,source_import_batch_id,normalization_commit_id,source_row_status,source_valid,normalized_source_hpp,
    source_conflict_codes,current_hpp,current_hpp_updated_at,latest_cost_history_id,latest_history_hpp,latest_history_source_row_id,
    latest_review_id,latest_review_status,latest_review_source_row_id,active_override_id,active_override_count,
    active_override_value,active_override_source_row_id,
    latest_reconciliation_event_id,latest_reconciliation_event_type,open_cost_findings,selling_price,selling_price_source_row_id,
    selling_price_updated_at,latest_selling_price_history_id,
    current_source_fingerprint,disposition,accepted_opening_hpp,quantity_at_prepare,balance_version_at_prepare)
  SELECT v_batch,e.outlet_id,e.product_id,e.classification,e.blocking_reasons,e.warning_codes,e.normalized_source_hpp,e.source_import_row_id,
    e.source_import_batch_id,e.normalization_commit_id,e.source_row_status,e.source_valid,e.normalized_source_hpp,e.source_conflict_codes,
    e.current_hpp,e.current_hpp_updated_at,e.latest_cost_history_id,e.latest_history_hpp,e.latest_history_source_row_id,
    e.latest_review_id,e.latest_review_status,e.latest_review_source_row_id,e.active_override_id,e.active_override_count,
    e.active_override_value,e.active_override_source_row_id,
    e.latest_reconciliation_event_id,e.latest_reconciliation_event_type,e.open_cost_findings,e.selling_price,e.selling_price_source_row_id,
    e.selling_price_updated_at,e.latest_selling_price_history_id,
    e.source_fingerprint,CASE WHEN e.classification='AUTO_CANDIDATE' THEN 'ACCEPT_CURRENT_HPP'::public.inventory_cost_hpp_acceptance_disposition END,
    CASE WHEN e.classification='AUTO_CANDIDATE' THEN e.current_hpp END,e.effective_quantity,e.balance_version
  FROM public.inventory_cost_hpp_acceptance_evaluate(p_outlet_id) e WHERE e.effective_quantity>0 ORDER BY e.product_id;
  v_result:=jsonb_build_object('ok',true,'code','PREPARED','batchId',v_batch,'candidateCount',v_candidates,
    'exceptionCount',v_exceptions,'blockingReasonCounts',v_blocking_counts,'warningProductCount',v_warning_products,
    'warningCounts',v_warning_counts,'estimatedAutoCandidateValue',v_estimate);
  INSERT INTO public.inventory_cost_hpp_acceptance_events(batch_id,event_type,actor_id,request_id,details)
    VALUES(v_batch,'PREPARED',v_actor,p_request_id,v_result);
  UPDATE public.inventory_cost_hpp_acceptance_requests SET result=v_result,completed_at=now() WHERE request_id=p_request_id;
  RETURN v_result;
END;
$$;
ALTER FUNCTION public.prepare_initial_hpp_acceptance(uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.prepare_initial_hpp_acceptance(uuid,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.prepare_initial_hpp_acceptance(uuid,uuid) TO authenticated;

CREATE FUNCTION public.resolve_initial_hpp_acceptance_exception(
  p_batch_id uuid,p_product_id uuid,p_disposition public.inventory_cost_hpp_acceptance_disposition,
  p_opening_hpp numeric,p_reason text,p_request_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE
  v_actor uuid:=auth.uid();v_role public.user_role;v_reason text:=regexp_replace(coalesce(p_reason,''),'^[[:space:]]+|[[:space:]]+$','','g');
  v_payload jsonb;v_req public.inventory_cost_hpp_acceptance_requests%rowtype;v_batch public.inventory_cost_hpp_acceptance_batches%rowtype;
  v_item public.inventory_cost_hpp_acceptance_items%rowtype;v_live record;v_result jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Authentication required'; END IF;
  v_role:=public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='HPP acceptance access denied'; END IF;
  IF p_batch_id IS NULL OR p_product_id IS NULL OR p_disposition IS NULL OR p_request_id IS NULL OR v_reason='' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Batch, product, disposition, request, and reason are required';
  END IF;
  IF p_disposition NOT IN ('ACCEPT_CURRENT_HPP','OPENING_HPP_OVERRIDE','LEAVE_UNVALUED','AUTHORITATIVE_ZERO') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Unsupported initial HPP disposition';
  END IF;
  IF p_disposition='OPENING_HPP_OVERRIDE' AND (p_opening_hpp IS NULL OR p_opening_hpp<=0 OR p_opening_hpp>=1000000000000 OR p_opening_hpp<>trunc(p_opening_hpp,2)) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Opening HPP override must be positive, within range, and have at most 2 decimals';
  END IF;
  IF p_disposition<>'OPENING_HPP_OVERRIDE' AND p_opening_hpp IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Opening HPP is only valid for OPENING_HPP_OVERRIDE'; END IF;
  v_payload:=jsonb_build_object('batchId',p_batch_id,'productId',p_product_id,'disposition',p_disposition::text,
    'openingHpp',p_opening_hpp,'reason',v_reason,'operation','RESOLVE');
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_HPP_ACCEPTANCE_REQUEST:'||p_request_id::text,73190411));
  SELECT * INTO v_req FROM public.inventory_cost_hpp_acceptance_requests r WHERE r.request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF v_req.actor_id<>v_actor OR v_req.operation<>'RESOLVE' OR v_req.payload<>v_payload THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='HPP acceptance request identity mismatch'; END IF;
    IF v_req.result IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='HPP acceptance request is incomplete'; END IF;
    RETURN v_req.result;
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(734921,2);
  SELECT * INTO v_batch FROM public.inventory_cost_hpp_acceptance_batches b WHERE b.id=p_batch_id FOR UPDATE;
  IF NOT FOUND OR v_batch.status<>'PREPARED' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='HPP acceptance batch is not open for exception review'; END IF;
  SELECT * INTO v_item FROM public.inventory_cost_hpp_acceptance_items i WHERE i.batch_id=p_batch_id AND i.product_id=p_product_id FOR UPDATE;
  IF NOT FOUND OR v_item.classification<>'EXCEPTION' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Product is not an exception in this acceptance batch'; END IF;
  SELECT * INTO v_live FROM public.inventory_cost_hpp_acceptance_evaluate(v_batch.outlet_id) e WHERE e.product_id=p_product_id;
  IF NOT FOUND OR v_live.source_fingerprint IS DISTINCT FROM v_item.current_source_fingerprint THEN
    UPDATE public.inventory_cost_hpp_acceptance_batches SET status='INVALIDATED',updated_at=now() WHERE id=p_batch_id;
    INSERT INTO public.inventory_cost_hpp_acceptance_requests(request_id,actor_id,operation,payload) VALUES(p_request_id,v_actor,'RESOLVE',v_payload);
    v_result:=jsonb_build_object('ok',false,'code','STALE_BATCH','batchId',p_batch_id,'productId',p_product_id);
    INSERT INTO public.inventory_cost_hpp_acceptance_events(batch_id,product_id,event_type,actor_id,request_id,reason,details)
      VALUES(p_batch_id,p_product_id,'INVALIDATED',v_actor,p_request_id,'Source facts changed before exception resolution',v_result);
    UPDATE public.inventory_cost_hpp_acceptance_requests SET result=v_result,completed_at=now() WHERE request_id=p_request_id;
    RETURN v_result;
  END IF;
  IF p_disposition='ACCEPT_CURRENT_HPP' AND (v_item.current_hpp IS NULL OR v_item.current_hpp=0) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Current HPP is unavailable or zero; use AUTHORITATIVE_ZERO only for explicit zero';
  END IF;
  IF p_disposition='AUTHORITATIVE_ZERO' AND v_item.current_hpp IS DISTINCT FROM 0::numeric THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='AUTHORITATIVE_ZERO requires an existing explicit HPP value of zero';
  END IF;
  INSERT INTO public.inventory_cost_hpp_acceptance_requests(request_id,actor_id,operation,payload)
    VALUES(p_request_id,v_actor,'RESOLVE',v_payload);
  UPDATE public.inventory_cost_hpp_acceptance_items SET disposition=p_disposition,
    accepted_opening_hpp=CASE WHEN p_disposition='OPENING_HPP_OVERRIDE' THEN p_opening_hpp
      WHEN p_disposition IN ('ACCEPT_CURRENT_HPP','AUTHORITATIVE_ZERO') THEN current_hpp ELSE NULL END,
    resolved_by=v_actor,resolved_at=now(),resolution_reason=v_reason,updated_at=now()
  WHERE batch_id=p_batch_id AND product_id=p_product_id;
  v_result:=jsonb_build_object('ok',true,'code','EXCEPTION_RESOLVED','batchId',p_batch_id,
    'productId',p_product_id,'disposition',p_disposition::text);
  INSERT INTO public.inventory_cost_hpp_acceptance_events(batch_id,product_id,event_type,actor_id,request_id,reason,details)
    VALUES(p_batch_id,p_product_id,'EXCEPTION_RESOLVED',v_actor,p_request_id,v_reason,
      v_result||jsonb_build_object('acceptedOpeningHpp',CASE WHEN p_disposition='OPENING_HPP_OVERRIDE' THEN p_opening_hpp
        WHEN p_disposition IN ('ACCEPT_CURRENT_HPP','AUTHORITATIVE_ZERO') THEN v_item.current_hpp ELSE NULL END));
  UPDATE public.inventory_cost_hpp_acceptance_requests SET result=v_result,completed_at=now() WHERE request_id=p_request_id;
  RETURN v_result;
END;
$$;
ALTER FUNCTION public.resolve_initial_hpp_acceptance_exception(uuid,uuid,public.inventory_cost_hpp_acceptance_disposition,numeric,text,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.resolve_initial_hpp_acceptance_exception(uuid,uuid,public.inventory_cost_hpp_acceptance_disposition,numeric,text,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.resolve_initial_hpp_acceptance_exception(uuid,uuid,public.inventory_cost_hpp_acceptance_disposition,numeric,text,uuid) TO authenticated;

CREATE FUNCTION public.approve_initial_hpp_acceptance(p_batch_id uuid,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE
  v_actor uuid:=auth.uid();v_role public.user_role;v_payload jsonb;v_req public.inventory_cost_hpp_acceptance_requests%rowtype;
  v_batch public.inventory_cost_hpp_acceptance_batches%rowtype;v_stale_count integer;v_unresolved integer;
  v_value numeric(32,8);v_valued integer;v_unvalued integer;v_result jsonb;v_updated integer;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Authentication required'; END IF;
  v_role:=public.current_active_user_role();
  IF v_role IS DISTINCT FROM 'OWNER'::public.user_role THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Only OWNER may approve initial HPP acceptance'; END IF;
  IF p_batch_id IS NULL OR p_request_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Batch and request identity are required'; END IF;
  v_payload:=jsonb_build_object('batchId',p_batch_id,'operation','APPROVE','ruleVersion','INITIAL_HPP_V1');
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('COST_HPP_ACCEPTANCE_REQUEST:'||p_request_id::text,73190411));
  SELECT * INTO v_req FROM public.inventory_cost_hpp_acceptance_requests r WHERE r.request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF v_req.actor_id<>v_actor OR v_req.operation<>'APPROVE' OR v_req.payload<>v_payload THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='HPP acceptance request identity mismatch'; END IF;
    IF v_req.result IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='HPP acceptance request is incomplete'; END IF;
    RETURN v_req.result;
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(734921,2);
  SELECT * INTO v_batch FROM public.inventory_cost_hpp_acceptance_batches b WHERE b.id=p_batch_id FOR UPDATE;
  IF NOT FOUND OR v_batch.status<>'PREPARED' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='HPP acceptance batch is not approvable'; END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority a WHERE a.outlet_id=v_batch.outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_projections p WHERE p.outlet_id=v_batch.outlet_id)
    OR EXISTS(SELECT 1 FROM public.inventory_cost_event_batches b WHERE b.outlet_id=v_batch.outlet_id) THEN
    INSERT INTO public.inventory_cost_hpp_acceptance_requests(request_id,actor_id,operation,payload) VALUES(p_request_id,v_actor,'APPROVE',v_payload);
    UPDATE public.inventory_cost_hpp_acceptance_batches SET status='INVALIDATED',updated_at=now() WHERE id=p_batch_id;
    v_result:=jsonb_build_object('ok',false,'code','COSTING_ALREADY_BOOTSTRAPPED','batchId',p_batch_id);
    INSERT INTO public.inventory_cost_hpp_acceptance_events(batch_id,event_type,actor_id,request_id,reason,details)
      VALUES(p_batch_id,'INVALIDATED',v_actor,p_request_id,'Costing bootstrap or authority exists',v_result);
    UPDATE public.inventory_cost_hpp_acceptance_requests SET result=v_result,completed_at=now() WHERE request_id=p_request_id;
    RETURN v_result;
  END IF;
  WITH live AS MATERIALIZED (
    SELECT e.product_id,e.source_fingerprint FROM public.inventory_cost_hpp_acceptance_evaluate(v_batch.outlet_id) e
  )
  SELECT count(*)::integer INTO v_stale_count
  FROM public.inventory_cost_hpp_acceptance_items i
  LEFT JOIN live ON live.product_id=i.product_id
  WHERE i.batch_id=p_batch_id AND live.source_fingerprint IS DISTINCT FROM i.current_source_fingerprint;
  IF v_stale_count>0 THEN
    INSERT INTO public.inventory_cost_hpp_acceptance_requests(request_id,actor_id,operation,payload) VALUES(p_request_id,v_actor,'APPROVE',v_payload);
    UPDATE public.inventory_cost_hpp_acceptance_batches SET status='INVALIDATED',updated_at=now() WHERE id=p_batch_id;
    v_result:=jsonb_build_object('ok',false,'code','STALE_BATCH','batchId',p_batch_id,'staleProductCount',v_stale_count);
    INSERT INTO public.inventory_cost_hpp_acceptance_events(batch_id,event_type,actor_id,request_id,reason,details)
      VALUES(p_batch_id,'INVALIDATED',v_actor,p_request_id,'Cost trust facts changed after preparation',v_result);
    UPDATE public.inventory_cost_hpp_acceptance_requests SET result=v_result,completed_at=now() WHERE request_id=p_request_id;
    RETURN v_result;
  END IF;
  SELECT count(*)::integer INTO v_unresolved FROM public.inventory_cost_hpp_acceptance_items i
    WHERE i.batch_id=p_batch_id AND i.classification='EXCEPTION'
      AND (i.disposition IS NULL OR i.resolved_by IS NULL OR i.resolved_at IS NULL OR nullif(btrim(i.resolution_reason),'') IS NULL);
  IF v_unresolved>0 THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Every exception must have an explicit reasoned disposition before approval'; END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_cost_hpp_acceptance_items i WHERE i.batch_id=p_batch_id AND
    ((i.disposition='ACCEPT_CURRENT_HPP' AND (i.current_hpp IS NULL OR i.current_hpp=0 OR i.accepted_opening_hpp IS DISTINCT FROM i.current_hpp))
      OR (i.disposition='OPENING_HPP_OVERRIDE' AND (i.accepted_opening_hpp IS NULL OR i.accepted_opening_hpp<=0))
      OR (i.disposition='AUTHORITATIVE_ZERO' AND (i.current_hpp IS DISTINCT FROM 0::numeric OR i.accepted_opening_hpp IS DISTINCT FROM 0::numeric)))) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Initial HPP resolution is inconsistent with its evidence';
  END IF;
  INSERT INTO public.inventory_cost_hpp_acceptance_requests(request_id,actor_id,operation,payload) VALUES(p_request_id,v_actor,'APPROVE',v_payload);
  WITH live AS MATERIALIZED (SELECT * FROM public.inventory_cost_hpp_acceptance_evaluate(v_batch.outlet_id)),
  values_by_item AS (
    SELECT i.product_id,l.effective_quantity,l.balance_version,
      CASE WHEN i.disposition IN ('ACCEPT_CURRENT_HPP','OPENING_HPP_OVERRIDE','AUTHORITATIVE_ZERO') THEN i.accepted_opening_hpp END AS accepted_hpp,
      i.disposition
    FROM public.inventory_cost_hpp_acceptance_items i JOIN live l ON l.product_id=i.product_id
    WHERE i.batch_id=p_batch_id
  )
  UPDATE public.inventory_cost_hpp_acceptance_items i SET quantity_at_approval=v.effective_quantity,
    balance_version_at_approval=v.balance_version,approved_by=v_actor,approved_at=now(),updated_at=now()
  FROM values_by_item v WHERE i.batch_id=p_batch_id AND i.product_id=v.product_id;
  GET DIAGNOSTICS v_updated=ROW_COUNT;
  IF v_updated<>(SELECT count(*) FROM public.inventory_cost_hpp_acceptance_items i WHERE i.batch_id=p_batch_id) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Current stock projection changed while approving HPP acceptance';
  END IF;
  SELECT CASE WHEN bool_or(i.disposition IN ('ACCEPT_CURRENT_HPP','OPENING_HPP_OVERRIDE','AUTHORITATIVE_ZERO')
        AND i.quantity_at_approval IS NULL) THEN NULL
      ELSE coalesce(sum(i.quantity_at_approval*i.accepted_opening_hpp)
        FILTER(WHERE i.disposition IN ('ACCEPT_CURRENT_HPP','OPENING_HPP_OVERRIDE','AUTHORITATIVE_ZERO')),0)::numeric(32,8) END,
    count(*) FILTER(WHERE i.disposition IN ('ACCEPT_CURRENT_HPP','OPENING_HPP_OVERRIDE','AUTHORITATIVE_ZERO'))::integer,
    count(*) FILTER(WHERE i.disposition='LEAVE_UNVALUED')::integer
  INTO v_value,v_valued,v_unvalued FROM public.inventory_cost_hpp_acceptance_items i WHERE i.batch_id=p_batch_id;
  UPDATE public.inventory_cost_hpp_acceptance_batches SET status='APPROVED',approved_by=v_actor,approved_at=now(),
    approve_request_id=p_request_id,estimated_opening_value=v_value,updated_at=now() WHERE id=p_batch_id;
  v_result:=jsonb_build_object('ok',true,'code','APPROVED','batchId',p_batch_id,'candidateCount',v_batch.candidate_count,
    'exceptionCount',v_batch.exception_count,'valuedDispositionCount',v_valued,'leaveUnvaluedCount',v_unvalued,
    'estimatedOpeningValue',v_value,'approvedBy',v_actor,'approvedAt',now());
  INSERT INTO public.inventory_cost_hpp_acceptance_events(batch_id,event_type,actor_id,request_id,details)
    VALUES(p_batch_id,'APPROVED',v_actor,p_request_id,v_result);
  UPDATE public.inventory_cost_hpp_acceptance_requests SET result=v_result,completed_at=now() WHERE request_id=p_request_id;
  RETURN v_result;
END;
$$;
ALTER FUNCTION public.approve_initial_hpp_acceptance(uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.approve_initial_hpp_acceptance(uuid,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.approve_initial_hpp_acceptance(uuid,uuid) TO authenticated;

GRANT USAGE ON TYPE public.inventory_cost_hpp_acceptance_status,
  public.inventory_cost_hpp_acceptance_disposition,public.inventory_cost_hpp_acceptance_operation,
  public.inventory_cost_hpp_acceptance_event_type TO authenticated;
REVOKE ALL ON TYPE public.inventory_cost_hpp_acceptance_status,
  public.inventory_cost_hpp_acceptance_disposition,public.inventory_cost_hpp_acceptance_operation,
  public.inventory_cost_hpp_acceptance_event_type FROM PUBLIC,anon;

COMMIT;
