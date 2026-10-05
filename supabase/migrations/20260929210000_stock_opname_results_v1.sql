BEGIN;

-- Posting-time display snapshots. Existing posted rows intentionally remain NULL
-- and are handled as legacy records by the read RPC below.
ALTER TABLE public.stock_opname_sessions
  ADD COLUMN posted_outlet_name_snapshot text,
  ADD COLUMN posted_metadata_captured_at timestamptz,
  ADD CONSTRAINT stock_opname_posted_outlet_snapshot_consistent CHECK (
    (posted_metadata_captured_at IS NULL AND posted_outlet_name_snapshot IS NULL)
    OR (posted_metadata_captured_at IS NOT NULL
      AND posted_outlet_name_snapshot IS NOT NULL
      AND pg_catalog.btrim(posted_outlet_name_snapshot) <> '')
  );

ALTER TABLE public.stock_opname_items
  ADD COLUMN posted_product_name_snapshot text,
  ADD COLUMN posted_sku_snapshot text,
  ADD COLUMN posted_rack_label_snapshot text,
  ADD COLUMN posted_unit_label_snapshot text,
  ADD COLUMN posted_display_barcode_snapshot text,
  ADD COLUMN posted_metadata_captured_at timestamptz,
  ADD CONSTRAINT stock_opname_item_posted_snapshot_consistent CHECK (
    (posted_metadata_captured_at IS NULL
      AND posted_product_name_snapshot IS NULL
      AND posted_sku_snapshot IS NULL
      AND posted_rack_label_snapshot IS NULL
      AND posted_unit_label_snapshot IS NULL
      AND posted_display_barcode_snapshot IS NULL)
    OR (posted_metadata_captured_at IS NOT NULL
      AND posted_product_name_snapshot IS NOT NULL
      AND pg_catalog.btrim(posted_product_name_snapshot) <> ''
      AND posted_sku_snapshot IS NOT NULL
      AND pg_catalog.btrim(posted_sku_snapshot) <> ''
      AND (posted_display_barcode_snapshot IS NULL
        OR pg_catalog.btrim(posted_display_barcode_snapshot) <> ''))
  );

CREATE OR REPLACE FUNCTION public.guard_stock_opname_session_result_snapshot()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.posted_outlet_name_snapshot IS NOT NULL
      OR NEW.posted_metadata_captured_at IS NOT NULL THEN
      RAISE EXCEPTION 'Stock-opname outlet snapshot may only be captured during posting';
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.posted_outlet_name_snapshot, NEW.posted_metadata_captured_at)
      IS DISTINCT FROM
     (OLD.posted_outlet_name_snapshot, OLD.posted_metadata_captured_at) THEN
    IF OLD.posted_metadata_captured_at IS NOT NULL
      OR OLD.status <> 'REVIEW'::public.stock_opname_status
      OR NEW.status <> 'POSTED'::public.stock_opname_status
      OR NEW.posted_metadata_captured_at IS NULL THEN
      RAISE EXCEPTION 'Stock-opname posting metadata snapshot is immutable';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.guard_stock_opname_session_result_snapshot() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_stock_opname_session_result_snapshot()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER stock_opname_session_snapshot_guard
  BEFORE INSERT OR UPDATE ON public.stock_opname_sessions
  FOR EACH ROW EXECUTE FUNCTION public.guard_stock_opname_session_result_snapshot();

CREATE OR REPLACE FUNCTION public.guard_stock_opname_item_result_snapshot()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
  v_capture_session text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.posted_product_name_snapshot IS NOT NULL OR NEW.posted_sku_snapshot IS NOT NULL
      OR NEW.posted_rack_label_snapshot IS NOT NULL OR NEW.posted_unit_label_snapshot IS NOT NULL
      OR NEW.posted_display_barcode_snapshot IS NOT NULL
      OR NEW.posted_metadata_captured_at IS NOT NULL THEN
      RAISE EXCEPTION 'Stock-opname item snapshot may only be captured during posting';
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.posted_product_name_snapshot, NEW.posted_sku_snapshot,
      NEW.posted_rack_label_snapshot, NEW.posted_unit_label_snapshot,
      NEW.posted_display_barcode_snapshot, NEW.posted_metadata_captured_at)
      IS NOT DISTINCT FROM
     (OLD.posted_product_name_snapshot, OLD.posted_sku_snapshot,
      OLD.posted_rack_label_snapshot, OLD.posted_unit_label_snapshot,
      OLD.posted_display_barcode_snapshot, OLD.posted_metadata_captured_at) THEN
    RETURN NEW;
  END IF;

  v_capture_session := pg_catalog.current_setting('quena.stock_opname_snapshot_session', true);
  IF OLD.posted_metadata_captured_at IS NOT NULL
    OR NEW.posted_metadata_captured_at IS NULL
    OR v_capture_session IS DISTINCT FROM OLD.session_id::text
    OR pg_catalog.pg_trigger_depth() < 2
    OR NOT EXISTS (
      SELECT 1 FROM public.stock_opname_sessions s
      WHERE s.id = OLD.session_id AND s.status = 'REVIEW'::public.stock_opname_status
    ) THEN
    RAISE EXCEPTION 'Stock-opname item posting metadata snapshot may only be captured during posting';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.guard_stock_opname_item_result_snapshot() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_stock_opname_item_result_snapshot()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER stock_opname_item_snapshot_guard
  BEFORE INSERT OR UPDATE ON public.stock_opname_items
  FOR EACH ROW EXECUTE FUNCTION public.guard_stock_opname_item_result_snapshot();

-- Runs before the session row becomes POSTED. The existing item guard therefore
-- still sees REVIEW while this helper fills item snapshots. Once this trigger
-- returns, the parent transition makes the existing POSTED guards authoritative.
CREATE OR REPLACE FUNCTION public.capture_stock_opname_posting_metadata()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_captured_at timestamptz;
  v_outlet_name text;
  v_previous_capture_session text;
  v_expected_items bigint;
  v_captured_items bigint;
BEGIN
  IF OLD.status <> 'REVIEW'::public.stock_opname_status
    OR NEW.status <> 'POSTED'::public.stock_opname_status THEN
    RETURN NEW;
  END IF;

  v_captured_at := pg_catalog.clock_timestamp();
  SELECT o.name INTO STRICT v_outlet_name
  FROM public.outlets o
  WHERE o.id = NEW.outlet_id;
  NEW.posted_outlet_name_snapshot := v_outlet_name;
  NEW.posted_metadata_captured_at := v_captured_at;

  SELECT pg_catalog.count(*) INTO v_expected_items
  FROM public.stock_opname_items i
  WHERE i.session_id = NEW.id;
  IF v_expected_items = 0 THEN
    RAISE EXCEPTION 'Cannot finalize an opname session without scoped items';
  END IF;

  v_previous_capture_session := pg_catalog.current_setting(
    'quena.stock_opname_snapshot_session', true);
  PERFORM pg_catalog.set_config(
    'quena.stock_opname_snapshot_session', NEW.id::text, true);

  UPDATE public.stock_opname_items i
  SET posted_product_name_snapshot = p.name,
      posted_sku_snapshot = p.sku,
      posted_rack_label_snapshot = (
        SELECT os.rack_label FROM public.product_outlet_settings os
        WHERE os.product_id = i.product_id AND os.outlet_id = i.outlet_id
      ),
      posted_unit_label_snapshot = p.unit_label,
      posted_display_barcode_snapshot = (
        SELECT b.barcode
        FROM public.product_barcodes b
        WHERE b.product_id = p.id AND b.is_active
        ORDER BY b.created_at ASC, b.id ASC
        LIMIT 1
      ),
      posted_metadata_captured_at = v_captured_at
  FROM public.products p
  WHERE i.session_id = NEW.id AND p.id = i.product_id
    AND i.posted_metadata_captured_at IS NULL;
  GET DIAGNOSTICS v_captured_items = ROW_COUNT;

  PERFORM pg_catalog.set_config(
    'quena.stock_opname_snapshot_session',
    COALESCE(v_previous_capture_session, ''), true);

  IF v_captured_items <> v_expected_items THEN
    RAISE EXCEPTION 'Stock-opname posting metadata snapshot did not cover every item';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.capture_stock_opname_posting_metadata() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.capture_stock_opname_posting_metadata()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER stock_opname_session_snapshot_capture
  BEFORE UPDATE OF status ON public.stock_opname_sessions
  FOR EACH ROW EXECUTE FUNCTION public.capture_stock_opname_posting_metadata();

CREATE OR REPLACE FUNCTION public.stock_opname_posted_results_page(
  p_session_id uuid,
  p_search text DEFAULT NULL,
  p_result_filter text DEFAULT 'ALL',
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 40
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
  WITH args AS MATERIALIZED (
    SELECT p_session_id AS session_id,
      pg_catalog.left(pg_catalog.btrim(COALESCE(p_search, '')), 120) AS search_text,
      pg_catalog.upper(pg_catalog.btrim(COALESCE(p_result_filter, 'ALL'))) AS result_filter,
      LEAST(GREATEST(COALESCE(p_page, 1), 1), 1000000)::bigint AS page,
      LEAST(GREATEST(COALESCE(p_page_size, 40), 1), 100)::bigint AS page_size
  ), role_state AS (
    SELECT public.current_active_user_role() AS role
  ), current_barcodes AS MATERIALIZED (
    SELECT DISTINCT ON (b.product_id) b.product_id, b.barcode
    FROM public.product_barcodes b
    WHERE b.is_active
    ORDER BY b.product_id, b.created_at ASC, b.id ASC
  ), session_row AS MATERIALIZED (
    SELECT s.id, s.outlet_id, s.scope_type, s.status, s.created_at,
      s.submitted_at, s.posted_at, s.created_by, s.submitted_by, s.approved_by,
      s.posted_outlet_name_snapshot, s.posted_metadata_captured_at,
      o.name AS current_outlet_name
    FROM public.stock_opname_sessions s
    LEFT JOIN public.outlets o ON o.id = s.outlet_id
    JOIN args a ON a.session_id = s.id
  ), source_rows AS MATERIALIZED (
    SELECT i.id, i.session_id, i.product_id, i.baseline_quantity,
      i.physical_quantity, i.quantity_variance, i.requires_recount,
      i.exception_reason, i.exception_reviewed_by, i.exception_reviewed_at,
      i.posted_product_name_snapshot, i.posted_sku_snapshot,
      i.posted_rack_label_snapshot, i.posted_unit_label_snapshot,
      i.posted_display_barcode_snapshot, i.posted_metadata_captured_at,
      p.name AS current_product_name, p.sku AS current_sku,
      p.unit_label AS current_unit_label, os.rack_label AS current_rack_label,
      cb.barcode AS current_display_barcode
    FROM public.stock_opname_items i
    LEFT JOIN public.products p ON p.id = i.product_id
    LEFT JOIN public.product_outlet_settings os
      ON os.product_id = i.product_id AND os.outlet_id = i.outlet_id
    LEFT JOIN current_barcodes cb ON cb.product_id = p.id
    JOIN args a ON a.session_id = i.session_id
  ), resolved_rows AS MATERIALIZED (
    SELECT r.*,
      CASE WHEN r.posted_metadata_captured_at IS NOT NULL
        THEN r.posted_product_name_snapshot ELSE r.current_product_name END AS display_product_name,
      CASE WHEN r.posted_metadata_captured_at IS NOT NULL
        THEN r.posted_sku_snapshot ELSE r.current_sku END AS display_sku,
      CASE WHEN r.posted_metadata_captured_at IS NOT NULL
        THEN r.posted_rack_label_snapshot ELSE r.current_rack_label END AS display_rack,
      CASE WHEN r.posted_metadata_captured_at IS NOT NULL
        THEN r.posted_unit_label_snapshot ELSE r.current_unit_label END AS display_unit,
      CASE WHEN r.posted_metadata_captured_at IS NOT NULL
        THEN r.posted_display_barcode_snapshot ELSE r.current_display_barcode END AS display_barcode,
      CASE WHEN r.posted_metadata_captured_at IS NOT NULL THEN 'POST_SNAPSHOT'
        WHEN r.current_product_name IS NOT NULL THEN 'CURRENT_FALLBACK'
        ELSE 'LEGACY_UNAVAILABLE' END AS metadata_provenance,
      (r.physical_quantity IS NULL
        AND r.exception_reason IS NOT NULL AND pg_catalog.btrim(r.exception_reason) <> ''
        AND r.exception_reviewed_by IS NOT NULL AND r.exception_reviewed_at IS NOT NULL
        AND NOT r.requires_recount) AS is_reviewed_exception,
      (r.physical_quantity IS NOT NULL AND NOT r.requires_recount) AS is_counted
    FROM source_rows r
  ), summary AS (
    SELECT pg_catalog.count(*)::bigint AS total,
      pg_catalog.count(*) FILTER (WHERE r.is_counted)::bigint AS counted,
      pg_catalog.count(*) FILTER (WHERE r.is_reviewed_exception)::bigint AS exceptions,
      pg_catalog.count(*) FILTER (WHERE r.is_counted AND r.quantity_variance <> 0)::bigint AS difference,
      pg_catalog.count(*) FILTER (WHERE r.is_counted AND r.quantity_variance = 0)::bigint AS match_count,
      pg_catalog.count(*) FILTER (WHERE r.is_counted AND r.quantity_variance > 0)::bigint AS increased,
      pg_catalog.count(*) FILTER (WHERE r.is_counted AND r.quantity_variance < 0)::bigint AS decreased
    FROM resolved_rows r
  ), matched_rows AS MATERIALIZED (
    SELECT r.*
    FROM resolved_rows r CROSS JOIN args a
    WHERE (a.search_text = '' OR r.display_product_name ILIKE '%' || a.search_text || '%'
      OR r.display_sku ILIKE '%' || a.search_text || '%')
      AND CASE a.result_filter
        WHEN 'ALL' THEN true
        WHEN 'DIFFERENCE' THEN r.is_counted AND r.quantity_variance <> 0
        WHEN 'MATCH' THEN r.is_counted AND r.quantity_variance = 0
        WHEN 'INCREASE' THEN r.is_counted AND r.quantity_variance > 0
        WHEN 'DECREASE' THEN r.is_counted AND r.quantity_variance < 0
        WHEN 'EXCEPTION' THEN r.is_reviewed_exception
        ELSE false
      END
  ), matching_count AS (
    SELECT pg_catalog.count(*)::bigint AS total_matching FROM matched_rows
  ), normalized_page AS (
    SELECT LEAST(a.page, GREATEST(1,
      pg_catalog.ceil(mc.total_matching::numeric / a.page_size)::bigint)) AS page,
      a.page_size, mc.total_matching
    FROM args a CROSS JOIN matching_count mc
  ), bounded_page AS (
    SELECT coalesce(
      pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'item_id', r.id,
        'product_id', r.product_id,
        'product_name', r.display_product_name,
        'sku', r.display_sku,
        'rack', r.display_rack,
        'unit', r.display_unit,
        'display_barcode', r.display_barcode,
        'metadata_provenance', r.metadata_provenance,
        'baseline_quantity', r.baseline_quantity,
        'physical_quantity', r.physical_quantity,
        'difference', r.quantity_variance,
        'historical_after_quantity', CASE WHEN r.is_counted THEN r.physical_quantity ELSE NULL END,
        'historical_after_state', CASE WHEN r.is_counted THEN 'RESULTING_STOCK'
          WHEN r.is_reviewed_exception THEN 'NOT_CHANGED_BY_OPNAME' ELSE 'UNAVAILABLE' END,
        'exception_state', r.is_reviewed_exception,
        'exception_reason', CASE WHEN r.is_reviewed_exception THEN r.exception_reason ELSE NULL END
      ) ORDER BY r.product_id, r.id) FILTER (WHERE r.id IS NOT NULL), '[]'::jsonb) AS rows,
      np.total_matching, np.page, np.page_size
    FROM normalized_page np
    LEFT JOIN (
      SELECT r.* FROM matched_rows r
      ORDER BY r.product_id, r.id
      OFFSET (SELECT (page - 1) * page_size FROM normalized_page)
      LIMIT (SELECT page_size FROM normalized_page)
    ) r ON true
    GROUP BY np.total_matching, np.page, np.page_size
  ), timeline AS (
    SELECT coalesce(
      pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'event_id', e.id,
        'event_type', e.event_type,
        'previous_status', e.previous_status,
        'next_status', e.next_status,
        'actor_id', e.actor_id,
        'created_at', e.created_at
      ) ORDER BY e.created_at, e.id), '[]'::jsonb) AS events
    FROM (
      SELECT e.* FROM public.stock_opname_session_events e
      JOIN session_row s ON s.id = e.session_id
      ORDER BY e.created_at DESC, e.id DESC
      LIMIT 20
    ) e
  )
  SELECT CASE
    WHEN rs.role IS NULL OR rs.role NOT IN ('OWNER'::public.user_role,
        'ADMIN'::public.user_role, 'GUDANG'::public.user_role)
      THEN pg_catalog.jsonb_build_object('ok', false, 'code', 'FORBIDDEN')
    WHEN s.id IS NULL
      THEN pg_catalog.jsonb_build_object('ok', false, 'code', 'NOT_FOUND')
    WHEN s.status <> 'POSTED'::public.stock_opname_status
      THEN pg_catalog.jsonb_build_object('ok', false, 'code', 'SESSION_NOT_POSTED')
    WHEN a.result_filter NOT IN ('ALL', 'DIFFERENCE', 'MATCH', 'INCREASE', 'DECREASE', 'EXCEPTION')
      THEN pg_catalog.jsonb_build_object('ok', false, 'code', 'INVALID_FILTER')
    ELSE pg_catalog.jsonb_build_object(
      'ok', true,
      'header', pg_catalog.jsonb_build_object(
        'session_id', s.id,
        'reference', s.id::text,
        'status', s.status,
        'scope', s.scope_type,
        'outlet_id', s.outlet_id,
        'outlet_name', CASE WHEN s.posted_metadata_captured_at IS NOT NULL
          THEN s.posted_outlet_name_snapshot ELSE s.current_outlet_name END,
        'outlet_metadata_provenance', CASE
          WHEN s.posted_metadata_captured_at IS NOT NULL THEN 'POST_SNAPSHOT'
          WHEN s.current_outlet_name IS NOT NULL THEN 'CURRENT_FALLBACK'
          ELSE 'LEGACY_UNAVAILABLE' END,
        'created_at', s.created_at,
        'submitted_at', s.submitted_at,
        'posted_at', s.posted_at,
        'created_by', s.created_by,
        'submitted_by', s.submitted_by,
        'posted_by', s.approved_by
      ),
      'summary', pg_catalog.jsonb_build_object(
        'total_items', sm.total,
        'counted', sm.counted,
        'exceptions', sm.exceptions,
        'difference', sm.difference,
        'match', sm.match_count,
        'increased', sm.increased,
        'decreased', sm.decreased
      ),
      'page', pg_catalog.jsonb_build_object(
        'total_matching', bp.total_matching,
        'page', bp.page,
        'page_size', bp.page_size
      ),
      'rows', bp.rows,
      'timeline', tl.events
    )
  END
  FROM args a
  CROSS JOIN role_state rs
  LEFT JOIN session_row s ON true
  CROSS JOIN summary sm
  CROSS JOIN bounded_page bp
  CROSS JOIN timeline tl
$$;
ALTER FUNCTION public.stock_opname_posted_results_page(uuid, text, text, integer, integer)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION public.stock_opname_posted_results_page(uuid, text, text, integer, integer)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.stock_opname_posted_results_page(uuid, text, text, integer, integer)
  TO authenticated;

COMMIT;
