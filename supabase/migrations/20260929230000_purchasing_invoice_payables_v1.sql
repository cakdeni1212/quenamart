-- Purchasing Phase 2: supplier invoices, payable history, and payments.
-- This migration does not change receipt stock posting or product costing.
BEGIN;

CREATE TABLE public.purchase_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_reference text NOT NULL UNIQUE DEFAULT ('PI-' || to_char(clock_timestamp(), 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))),
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  supplier_id uuid NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  invoice_number text,
  invoice_date date,
  due_date date,
  payment_type text CHECK (payment_type IN ('CASH','TEMPO')),
  supplier_invoice_total numeric(20,2) CHECK (supplier_invoice_total IS NULL OR supplier_invoice_total >= 0),
  status text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','FINALIZED')),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  updated_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  finalized_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  finalized_at timestamptz,
  draft_revision integer NOT NULL DEFAULT 1 CHECK (draft_revision > 0),
  CONSTRAINT purchase_invoice_finalized_shape CHECK (
    (status='DRAFT' AND finalized_by IS NULL AND finalized_at IS NULL)
    OR (status='FINALIZED' AND invoice_number IS NOT NULL AND invoice_date IS NOT NULL
      AND payment_type IS NOT NULL AND supplier_invoice_total IS NOT NULL
      AND finalized_by IS NOT NULL AND finalized_at IS NOT NULL
      AND (payment_type <> 'TEMPO' OR due_date IS NOT NULL))
  )
);
CREATE UNIQUE INDEX purchase_invoice_supplier_number_unique
  ON public.purchase_invoices(supplier_id, lower(btrim(invoice_number))) WHERE invoice_number IS NOT NULL;
CREATE INDEX purchase_invoice_supplier_date_idx ON public.purchase_invoices(supplier_id, invoice_date DESC, id DESC);
CREATE INDEX purchase_invoice_outlet_date_idx ON public.purchase_invoices(outlet_id, created_at DESC, id DESC);

CREATE TABLE public.purchase_invoice_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id uuid NOT NULL REFERENCES public.purchase_invoices(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  invoice_quantity numeric(18,3) NOT NULL CHECK (invoice_quantity > 0 AND invoice_quantity < 100000000000),
  purchase_unit_price numeric(18,2) NOT NULL CHECK (purchase_unit_price >= 0),
  line_subtotal numeric(20,2) GENERATED ALWAYS AS (round(invoice_quantity * purchase_unit_price, 2)) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT purchase_invoice_item_product_unique UNIQUE(invoice_id,product_id),
  CONSTRAINT purchase_invoice_item_id_product_unique UNIQUE(id,product_id)
);
CREATE INDEX purchase_invoice_items_invoice_idx ON public.purchase_invoice_items(invoice_id,product_id);

CREATE TABLE public.purchase_invoice_receipts (
  invoice_id uuid NOT NULL REFERENCES public.purchase_invoices(id) ON DELETE RESTRICT,
  receipt_id uuid NOT NULL UNIQUE REFERENCES public.purchase_receipts(id) ON DELETE RESTRICT,
  linked_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  linked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(invoice_id,receipt_id)
);
CREATE INDEX purchase_invoice_receipts_invoice_idx ON public.purchase_invoice_receipts(invoice_id,receipt_id);

CREATE TABLE public.supplier_payables (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id uuid NOT NULL UNIQUE REFERENCES public.purchase_invoices(id) ON DELETE RESTRICT,
  supplier_id uuid NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  original_amount numeric(20,2) NOT NULL CHECK (original_amount >= 0),
  recognized_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  recognized_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT supplier_payable_id_invoice_unique UNIQUE(id,invoice_id)
);
CREATE INDEX supplier_payables_due_idx ON public.supplier_payables(recognized_at DESC,id);

CREATE TABLE public.purchase_financial_requests (
  request_id uuid PRIMARY KEY,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  operation text NOT NULL CHECK (operation IN ('CREATE_INVOICE','FINALIZE_INVOICE','RECORD_PAYMENT')),
  target_id uuid,
  payload_hash text NOT NULL,
  result jsonb,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT purchase_financial_request_terminal CHECK ((result IS NULL) = (completed_at IS NULL))
);

CREATE TABLE public.supplier_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_reference text NOT NULL UNIQUE DEFAULT ('PM-' || to_char(clock_timestamp(), 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))),
  supplier_id uuid NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  payment_date date NOT NULL,
  amount numeric(20,2) NOT NULL CHECK (amount > 0),
  payment_method text NOT NULL CHECK (payment_method IN ('CASH','TRANSFER','OTHER')),
  reference_note text,
  request_id uuid NOT NULL UNIQUE REFERENCES public.purchase_financial_requests(request_id) ON DELETE RESTRICT,
  recorded_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT supplier_payment_note_nonblank CHECK (reference_note IS NULL OR btrim(reference_note) <> '')
);
CREATE INDEX supplier_payments_supplier_date_idx ON public.supplier_payments(supplier_id,payment_date DESC,id DESC);

CREATE TABLE public.supplier_payment_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id uuid NOT NULL REFERENCES public.supplier_payments(id) ON DELETE RESTRICT,
  payable_id uuid NOT NULL REFERENCES public.supplier_payables(id) ON DELETE RESTRICT,
  amount numeric(20,2) NOT NULL CHECK (amount > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT supplier_payment_allocation_unique UNIQUE(payment_id,payable_id)
);
CREATE INDEX supplier_payment_allocations_payable_idx ON public.supplier_payment_allocations(payable_id,payment_id);

CREATE TABLE public.purchase_invoice_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id uuid NOT NULL REFERENCES public.purchase_invoices(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type IN ('CREATED','DRAFT_UPDATED','RECEIPT_LINKED','RECEIPT_UNLINKED','FINALIZED','PAYMENT_RECORDED','DOCUMENT_ADDED')),
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  request_id uuid REFERENCES public.purchase_financial_requests(request_id) ON DELETE RESTRICT,
  note text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX purchase_invoice_events_invoice_idx ON public.purchase_invoice_events(invoice_id,created_at,id);

CREATE TABLE public.purchase_invoice_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id uuid NOT NULL REFERENCES public.purchase_invoices(id) ON DELETE RESTRICT,
  storage_path text NOT NULL UNIQUE,
  uploaded_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  uploaded_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT purchasing_invoice_path_shape CHECK (storage_path ~ ('^invoices/' || invoice_id::text || '/[0-9a-fA-F-]{36}\.(jpg|jpeg|png|webp|pdf)$'))
);
CREATE INDEX purchase_invoice_documents_invoice_idx ON public.purchase_invoice_documents(invoice_id,uploaded_at,id);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM storage.buckets WHERE id='quena-purchasing-invoices'
    AND (public OR file_size_limit <> 10485760
      OR allowed_mime_types <> ARRAY['image/jpeg','image/png','image/webp','application/pdf']::text[])) THEN
    RAISE EXCEPTION 'quena-purchasing-invoices bucket has unexpected settings';
  END IF;
END $$;
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES('quena-purchasing-invoices','quena-purchasing-invoices',false,10485760,
  ARRAY['image/jpeg','image/png','image/webp','application/pdf']::text[])
ON CONFLICT(id) DO NOTHING;

ALTER TABLE public.purchase_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_invoice_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_invoice_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_payables ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_payment_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_financial_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_invoice_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_invoice_documents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.purchase_invoices,public.purchase_invoice_items,public.purchase_invoice_receipts,
  public.supplier_payables,public.supplier_payments,public.supplier_payment_allocations,
  public.purchase_financial_requests,public.purchase_invoice_events,public.purchase_invoice_documents
  FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.purchase_invoices,public.purchase_invoice_items,public.purchase_invoice_receipts,
  public.supplier_payables,public.supplier_payments,public.supplier_payment_allocations,
  public.purchase_invoice_events,public.purchase_invoice_documents TO authenticated;

CREATE POLICY purchasing_finance_invoices_read ON public.purchase_invoices FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY purchasing_finance_items_read ON public.purchase_invoice_items FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY purchasing_finance_links_read ON public.purchase_invoice_receipts FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY purchasing_payables_read ON public.supplier_payables FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY purchasing_payments_read ON public.supplier_payments FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY purchasing_allocations_read ON public.supplier_payment_allocations FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY purchasing_financial_events_read ON public.purchase_invoice_events FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY purchasing_documents_read ON public.purchase_invoice_documents FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY purchasing_requests_no_read ON public.purchase_financial_requests FOR SELECT TO authenticated USING(false);

CREATE POLICY purchasing_invoice_upload_manager ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id='quena-purchasing-invoices'
    AND public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role)
    AND name ~ '^invoices/[0-9a-fA-F-]{8}-[0-9a-fA-F-]{4}-[1-8][0-9a-fA-F-]{3}-[89aAbB][0-9a-fA-F-]{3}-[0-9a-fA-F-]{12}/[0-9a-fA-F-]{36}\.(jpg|jpeg|png|webp|pdf)$'
    AND EXISTS (SELECT 1 FROM public.purchase_invoices i
      WHERE i.id=(split_part(name,'/',2))::uuid));
CREATE POLICY purchasing_invoice_read_manager ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id='quena-purchasing-invoices'
    AND public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY purchasing_invoice_storage_insert_anon_restrict ON storage.objects AS RESTRICTIVE FOR INSERT TO anon
  WITH CHECK (bucket_id<>'quena-purchasing-invoices');
CREATE POLICY purchasing_invoice_storage_insert_auth_restrict ON storage.objects AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (bucket_id<>'quena-purchasing-invoices' OR public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY purchasing_invoice_storage_select_anon_restrict ON storage.objects AS RESTRICTIVE FOR SELECT TO anon
  USING (bucket_id<>'quena-purchasing-invoices');
CREATE POLICY purchasing_invoice_storage_select_auth_restrict ON storage.objects AS RESTRICTIVE FOR SELECT TO authenticated
  USING (bucket_id<>'quena-purchasing-invoices' OR public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
CREATE POLICY purchasing_invoice_storage_update_anon_restrict ON storage.objects AS RESTRICTIVE FOR UPDATE TO anon
  USING (bucket_id<>'quena-purchasing-invoices') WITH CHECK (bucket_id<>'quena-purchasing-invoices');
CREATE POLICY purchasing_invoice_storage_update_auth_restrict ON storage.objects AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (bucket_id<>'quena-purchasing-invoices') WITH CHECK (bucket_id<>'quena-purchasing-invoices');
CREATE POLICY purchasing_invoice_storage_delete_anon_restrict ON storage.objects AS RESTRICTIVE FOR DELETE TO anon
  USING (bucket_id<>'quena-purchasing-invoices');
CREATE POLICY purchasing_invoice_storage_delete_auth_restrict ON storage.objects AS RESTRICTIVE FOR DELETE TO authenticated
  USING (bucket_id<>'quena-purchasing-invoices');

CREATE FUNCTION public.guard_purchase_invoice_immutable()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Purchase invoice history cannot be deleted'; END IF;
  IF OLD.status='FINALIZED' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Finalized purchase invoices are immutable'; END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.guard_purchase_invoice_immutable() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER purchase_invoice_immutable_guard BEFORE UPDATE OR DELETE ON public.purchase_invoices
  FOR EACH ROW EXECUTE FUNCTION public.guard_purchase_invoice_immutable();

CREATE FUNCTION public.guard_purchase_invoice_item_draft()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE v_id uuid := CASE WHEN TG_OP='DELETE' THEN OLD.invoice_id ELSE NEW.invoice_id END;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.purchase_invoices i WHERE i.id=v_id AND i.status='DRAFT' FOR KEY SHARE) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Invoice lines are editable only while draft';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.guard_purchase_invoice_item_draft() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER purchase_invoice_item_draft_guard BEFORE INSERT OR UPDATE OR DELETE ON public.purchase_invoice_items
  FOR EACH ROW EXECUTE FUNCTION public.guard_purchase_invoice_item_draft();

CREATE FUNCTION public.purchase_invoice_create_draft(p_outlet_id uuid,p_supplier_id uuid,p_request_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_existing public.purchase_financial_requests%rowtype; v_invoice uuid;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Financial purchasing access denied'; END IF;
  IF p_request_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.outlets o WHERE o.id=p_outlet_id AND o.is_active)
    OR NOT EXISTS(SELECT 1 FROM public.suppliers s WHERE s.id=p_supplier_id AND s.is_active) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invoice supplier or outlet is invalid'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_actor::text||':CREATE_INVOICE:'||p_request_id::text,73190411));
  SELECT * INTO v_existing FROM public.purchase_financial_requests WHERE request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id<>v_actor OR v_existing.operation<>'CREATE_INVOICE' OR v_existing.payload_hash<>md5(p_outlet_id::text||':'||p_supplier_id::text) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Financial request identity mismatch'; END IF;
    RETURN v_existing.target_id;
  END IF;
  INSERT INTO public.purchase_invoices(outlet_id,supplier_id,created_by,updated_by) VALUES(p_outlet_id,p_supplier_id,v_actor,v_actor) RETURNING id INTO v_invoice;
  INSERT INTO public.purchase_financial_requests(request_id,actor_id,operation,target_id,payload_hash,result,completed_at)
    VALUES(p_request_id,v_actor,'CREATE_INVOICE',v_invoice,md5(p_outlet_id::text||':'||p_supplier_id::text),jsonb_build_object('invoiceId',v_invoice),now());
  INSERT INTO public.purchase_invoice_events(invoice_id,event_type,actor_id,request_id) VALUES(v_invoice,'CREATED',v_actor,p_request_id);
  RETURN v_invoice;
END $$;
ALTER FUNCTION public.purchase_invoice_create_draft(uuid,uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_invoice_create_draft(uuid,uuid,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_invoice_create_draft(uuid,uuid,uuid) TO authenticated;

CREATE FUNCTION public.purchase_invoice_save_draft(p_invoice_id uuid,p_expected_revision integer,p_invoice_number text,
  p_invoice_date date,p_due_date date,p_payment_type text,p_supplier_total numeric,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_invoice public.purchase_invoices%rowtype; v_line jsonb; v_product uuid; v_count integer:=0;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Financial purchasing access denied'; END IF;
  IF p_invoice_id IS NULL OR p_expected_revision<1 OR jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items)>500
    OR coalesce(length(btrim(p_invoice_number)),0)>120 OR p_invoice_date IS NULL
    OR p_payment_type NOT IN ('CASH','TEMPO') OR p_supplier_total IS NULL OR p_supplier_total<0
    OR (p_payment_type='TEMPO' AND p_due_date IS NULL) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invoice draft is invalid'; END IF;
  SELECT * INTO v_invoice FROM public.purchase_invoices WHERE id=p_invoice_id FOR UPDATE;
  IF NOT FOUND OR v_invoice.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Invoice is not editable'; END IF;
  IF v_invoice.draft_revision<>p_expected_revision THEN RETURN jsonb_build_object('ok',false,'code','INVOICE_CHANGED','revision',v_invoice.draft_revision); END IF;
  IF (SELECT count(DISTINCT x.product_id) FROM jsonb_to_recordset(p_items) AS x(product_id uuid))<>jsonb_array_length(p_items) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invoice product may appear only once'; END IF;
  UPDATE public.purchase_invoices SET invoice_number=nullif(btrim(p_invoice_number),''),invoice_date=p_invoice_date,due_date=p_due_date,
    payment_type=p_payment_type,supplier_invoice_total=p_supplier_total,updated_by=v_actor,updated_at=now(),draft_revision=draft_revision+1 WHERE id=p_invoice_id;
  DELETE FROM public.purchase_invoice_items WHERE invoice_id=p_invoice_id;
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF EXISTS(SELECT 1 FROM jsonb_object_keys(v_line) k(key) WHERE key NOT IN ('product_id','invoice_quantity','purchase_unit_price')) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Unsupported invoice item field'; END IF;
    v_product:=(v_line->>'product_id')::uuid;
    IF v_product IS NULL OR NOT EXISTS(SELECT 1 FROM public.products p WHERE p.id=v_product) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invoice product is unavailable'; END IF;
    INSERT INTO public.purchase_invoice_items(invoice_id,product_id,invoice_quantity,purchase_unit_price)
      VALUES(p_invoice_id,v_product,(v_line->>'invoice_quantity')::numeric,(v_line->>'purchase_unit_price')::numeric);
    v_count:=v_count+1;
  END LOOP;
  INSERT INTO public.purchase_invoice_events(invoice_id,event_type,actor_id,note) VALUES(p_invoice_id,'DRAFT_UPDATED',v_actor,'Baris: '||v_count::text);
  RETURN jsonb_build_object('ok',true,'revision',p_expected_revision+1);
END $$;
ALTER FUNCTION public.purchase_invoice_save_draft(uuid,integer,text,date,date,text,numeric,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_invoice_save_draft(uuid,integer,text,date,date,text,numeric,jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_invoice_save_draft(uuid,integer,text,date,date,text,numeric,jsonb) TO authenticated;

CREATE FUNCTION public.purchase_invoice_link_receipt(p_invoice_id uuid,p_receipt_id uuid,p_link boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_invoice public.purchase_invoices%rowtype; v_receipt public.purchase_receipts%rowtype;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Financial purchasing access denied'; END IF;
  SELECT * INTO v_invoice FROM public.purchase_invoices WHERE id=p_invoice_id FOR UPDATE;
  SELECT * INTO v_receipt FROM public.purchase_receipts WHERE id=p_receipt_id FOR KEY SHARE;
  IF v_invoice.id IS NULL OR v_receipt.id IS NULL OR v_invoice.supplier_id<>v_receipt.supplier_id OR v_invoice.outlet_id<>v_receipt.outlet_id
    OR (v_invoice.status<>'DRAFT' AND NOT p_link) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Receipt cannot be linked to this invoice'; END IF;
  IF p_link THEN
    INSERT INTO public.purchase_invoice_receipts(invoice_id,receipt_id,linked_by) VALUES(p_invoice_id,p_receipt_id,v_actor)
      ON CONFLICT(receipt_id) DO NOTHING;
    IF NOT EXISTS(SELECT 1 FROM public.purchase_invoice_receipts WHERE invoice_id=p_invoice_id AND receipt_id=p_receipt_id) THEN RAISE EXCEPTION USING ERRCODE='23505',MESSAGE='Receipt is linked to another invoice'; END IF;
    INSERT INTO public.purchase_invoice_events(invoice_id,event_type,actor_id) VALUES(p_invoice_id,'RECEIPT_LINKED',v_actor);
  ELSE
    DELETE FROM public.purchase_invoice_receipts WHERE invoice_id=p_invoice_id AND receipt_id=p_receipt_id;
    INSERT INTO public.purchase_invoice_events(invoice_id,event_type,actor_id) VALUES(p_invoice_id,'RECEIPT_UNLINKED',v_actor);
  END IF;
  RETURN jsonb_build_object('ok',true);
END $$;
ALTER FUNCTION public.purchase_invoice_link_receipt(uuid,uuid,boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_invoice_link_receipt(uuid,uuid,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_invoice_link_receipt(uuid,uuid,boolean) TO authenticated;

CREATE FUNCTION public.purchase_invoice_finalize(p_invoice_id uuid,p_request_id uuid,p_expected_revision integer,p_initial_paid numeric,p_payment_method text,p_payment_date date,p_payment_note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_i public.purchase_invoices%rowtype; v_req public.purchase_financial_requests%rowtype;
  v_payload text; v_total numeric(20,2); v_system numeric(20,2); v_payable uuid; v_payment uuid; v_alloc numeric(20,2);
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Financial purchasing access denied'; END IF;
  IF p_request_id IS NULL OR p_invoice_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invoice finalization request is invalid'; END IF;
  v_payload:=p_invoice_id::text||':'||p_expected_revision::text||':'||coalesce(p_initial_paid,0)::text||':'||coalesce(p_payment_method,'')||':'||coalesce(p_payment_date::text,'')||':'||coalesce(p_payment_note,'');
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_actor::text||':FINALIZE_INVOICE:'||p_request_id::text,73190411));
  SELECT * INTO v_req FROM public.purchase_financial_requests WHERE request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF v_req.actor_id<>v_actor OR v_req.operation<>'FINALIZE_INVOICE' OR v_req.payload_hash<>md5(v_payload) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Financial request identity mismatch'; END IF;
    RETURN v_req.result;
  END IF;
  SELECT * INTO v_i FROM public.purchase_invoices WHERE id=p_invoice_id FOR UPDATE;
  IF NOT FOUND OR v_i.status<>'DRAFT' OR v_i.draft_revision<>p_expected_revision THEN RETURN jsonb_build_object('ok',false,'code','INVOICE_CHANGED'); END IF;
  IF v_i.invoice_number IS NULL OR v_i.invoice_date IS NULL OR v_i.payment_type IS NULL OR v_i.supplier_invoice_total IS NULL
    OR (v_i.payment_type='TEMPO' AND v_i.due_date IS NULL) OR NOT EXISTS(SELECT 1 FROM public.purchase_invoice_items WHERE invoice_id=p_invoice_id) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invoice needs complete details and at least one line';
  END IF;
  v_total:=v_i.supplier_invoice_total;
  v_system:=coalesce((SELECT sum(line_subtotal) FROM public.purchase_invoice_items WHERE invoice_id=p_invoice_id),0);
  IF coalesce(p_initial_paid,0)<0 OR coalesce(p_initial_paid,0)>v_total OR (p_initial_paid>0 AND (p_payment_method NOT IN ('CASH','TRANSFER','OTHER') OR p_payment_date IS NULL))
    OR (p_payment_note IS NOT NULL AND (btrim(p_payment_note)='' OR length(p_payment_note)>300)) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Initial payment is invalid'; END IF;
  UPDATE public.purchase_invoices SET status='FINALIZED',finalized_by=v_actor,finalized_at=now(),updated_by=v_actor,updated_at=now() WHERE id=p_invoice_id;
  INSERT INTO public.supplier_payables(invoice_id,supplier_id,outlet_id,original_amount,recognized_by)
    VALUES(p_invoice_id,v_i.supplier_id,v_i.outlet_id,v_total,v_actor) RETURNING id INTO v_payable;
  INSERT INTO public.purchase_financial_requests(request_id,actor_id,operation,target_id,payload_hash)
    VALUES(p_request_id,v_actor,'FINALIZE_INVOICE',p_invoice_id,md5(v_payload));
  IF p_initial_paid>0 THEN
    INSERT INTO public.supplier_payments(supplier_id,outlet_id,payment_date,amount,payment_method,reference_note,request_id,recorded_by)
      VALUES(v_i.supplier_id,v_i.outlet_id,p_payment_date,p_initial_paid,p_payment_method,nullif(btrim(p_payment_note),''),p_request_id,v_actor) RETURNING id INTO v_payment;
    INSERT INTO public.supplier_payment_allocations(payment_id,payable_id,amount) VALUES(v_payment,v_payable,p_initial_paid);
    INSERT INTO public.purchase_invoice_events(invoice_id,event_type,actor_id,request_id) VALUES(p_invoice_id,'PAYMENT_RECORDED',v_actor,p_request_id);
  END IF;
  INSERT INTO public.purchase_invoice_events(invoice_id,event_type,actor_id,request_id) VALUES(p_invoice_id,'FINALIZED',v_actor,p_request_id);
  SELECT coalesce(sum(a.amount),0) INTO v_alloc FROM public.supplier_payment_allocations a WHERE a.payable_id=v_payable;
  UPDATE public.purchase_financial_requests SET result=jsonb_build_object('ok',true,'code','FINALIZED','invoiceId',p_invoice_id,'payableId',v_payable,'systemTotal',v_system,'invoiceTotal',v_total,'paid',v_alloc),completed_at=now() WHERE request_id=p_request_id;
  RETURN (SELECT result FROM public.purchase_financial_requests WHERE request_id=p_request_id);
END $$;
ALTER FUNCTION public.purchase_invoice_finalize(uuid,uuid,integer,numeric,text,date,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_invoice_finalize(uuid,uuid,integer,numeric,text,date,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_invoice_finalize(uuid,uuid,integer,numeric,text,date,text) TO authenticated;

CREATE FUNCTION public.purchase_record_supplier_payment(p_request_id uuid,p_supplier_id uuid,p_outlet_id uuid,p_payment_date date,p_amount numeric,p_payment_method text,p_reference_note text,p_allocations jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_req public.purchase_financial_requests%rowtype; v_line jsonb; v_payable uuid; v_amount numeric(20,2); v_payment uuid; v_total numeric(20,2); v_invoice_supplier uuid; v_invoice_outlet uuid; v_outstanding numeric(20,2); v_payload text;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Financial purchasing access denied'; END IF;
  IF p_request_id IS NULL OR p_payment_date IS NULL OR p_amount<=0 OR p_payment_method NOT IN ('CASH','TRANSFER','OTHER')
    OR jsonb_typeof(p_allocations) IS DISTINCT FROM 'array' OR jsonb_array_length(p_allocations)<1 OR jsonb_array_length(p_allocations)>100 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Payment is invalid'; END IF;
  v_payload:=p_supplier_id::text||':'||p_outlet_id::text||':'||p_payment_date::text||':'||p_amount::text||':'||p_payment_method||':'||coalesce(p_reference_note,'')||':'||p_allocations::text;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_actor::text||':RECORD_PAYMENT:'||p_request_id::text,73190411));
  SELECT * INTO v_req FROM public.purchase_financial_requests WHERE request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF v_req.actor_id<>v_actor OR v_req.operation<>'RECORD_PAYMENT' OR v_req.payload_hash<>md5(v_payload) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Financial request identity mismatch'; END IF;
    RETURN v_req.result;
  END IF;
  IF p_reference_note IS NOT NULL AND (btrim(p_reference_note)='' OR length(p_reference_note)>300) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Payment note is invalid'; END IF;
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_allocations) ORDER BY (value->>'payable_id')::uuid LOOP
    v_payable:=(v_line->>'payable_id')::uuid; v_amount:=(v_line->>'amount')::numeric;
    SELECT p.supplier_id,p.outlet_id,p.original_amount INTO v_invoice_supplier,v_invoice_outlet,v_total
      FROM public.supplier_payables p WHERE p.id=v_payable FOR UPDATE;
    IF NOT FOUND OR v_invoice_supplier<>p_supplier_id OR v_invoice_outlet<>p_outlet_id THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Payment allocation target is invalid'; END IF;
    SELECT v_total-coalesce(sum(a.amount),0) INTO v_outstanding FROM public.supplier_payment_allocations a WHERE a.payable_id=v_payable;
    IF v_amount<=0 OR v_amount>v_outstanding THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Payment exceeds payable balance'; END IF;
  END LOOP;
  IF (SELECT sum((value->>'amount')::numeric) FROM jsonb_array_elements(p_allocations))<>p_amount
    OR jsonb_array_length(p_allocations)<>(SELECT count(DISTINCT (value->>'payable_id')::uuid) FROM jsonb_array_elements(p_allocations)) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Payment allocation total is invalid'; END IF;
  INSERT INTO public.purchase_financial_requests(request_id,actor_id,operation,payload_hash) VALUES(p_request_id,v_actor,'RECORD_PAYMENT',md5(v_payload));
  INSERT INTO public.supplier_payments(supplier_id,outlet_id,payment_date,amount,payment_method,reference_note,request_id,recorded_by)
    VALUES(p_supplier_id,p_outlet_id,p_payment_date,p_amount,p_payment_method,nullif(btrim(p_reference_note),''),p_request_id,v_actor) RETURNING id INTO v_payment;
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_allocations) LOOP
    v_payable:=(v_line->>'payable_id')::uuid; v_amount:=(v_line->>'amount')::numeric;
    INSERT INTO public.supplier_payment_allocations(payment_id,payable_id,amount) VALUES(v_payment,v_payable,v_amount);
    INSERT INTO public.purchase_invoice_events(invoice_id,event_type,actor_id,request_id)
      SELECT p.invoice_id,'PAYMENT_RECORDED',v_actor,p_request_id FROM public.supplier_payables p WHERE p.id=v_payable;
  END LOOP;
  UPDATE public.purchase_financial_requests SET target_id=v_payment,result=jsonb_build_object('ok',true,'code','PAYMENT_RECORDED','paymentId',v_payment),completed_at=now() WHERE request_id=p_request_id;
  RETURN (SELECT result FROM public.purchase_financial_requests WHERE request_id=p_request_id);
END $$;
ALTER FUNCTION public.purchase_record_supplier_payment(uuid,uuid,uuid,date,numeric,text,text,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_record_supplier_payment(uuid,uuid,uuid,date,numeric,text,text,jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_record_supplier_payment(uuid,uuid,uuid,date,numeric,text,text,jsonb) TO authenticated;

CREATE FUNCTION public.purchase_invoice_attach_document(p_invoice_id uuid,p_storage_path text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_id uuid;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Financial purchasing access denied'; END IF;
  IF p_storage_path !~ ('^invoices/'||p_invoice_id::text||'/[0-9a-fA-F-]{36}\.(jpg|jpeg|png|webp|pdf)$')
    OR NOT EXISTS(SELECT 1 FROM storage.objects o WHERE o.bucket_id='quena-purchasing-invoices' AND o.name=p_storage_path)
    OR NOT EXISTS(SELECT 1 FROM public.purchase_invoices i WHERE i.id=p_invoice_id) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invoice document is unavailable'; END IF;
  INSERT INTO public.purchase_invoice_documents(invoice_id,storage_path,uploaded_by) VALUES(p_invoice_id,p_storage_path,v_actor) RETURNING id INTO v_id;
  INSERT INTO public.purchase_invoice_events(invoice_id,event_type,actor_id,note) VALUES(p_invoice_id,'DOCUMENT_ADDED',v_actor,'Dokumen nota dilampirkan');
  RETURN v_id;
END $$;
ALTER FUNCTION public.purchase_invoice_attach_document(uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_invoice_attach_document(uuid,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_invoice_attach_document(uuid,text) TO authenticated;

CREATE FUNCTION public.purchase_invoice_financial_detail(p_invoice_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_role public.user_role; v_result jsonb;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Financial purchasing access denied'; END IF;
  SELECT jsonb_build_object('header',to_jsonb(i)||jsonb_build_object('supplier',jsonb_build_object('id',s.id,'name',s.display_name),'outlet',o.name,
      'createdByName',coalesce(cp.full_name,'Pengguna tidak tersedia'),'updatedByName',coalesce(up.full_name,'Pengguna tidak tersedia'),
      'finalizedByName',coalesce(fp.full_name,'Pengguna tidak tersedia')),
    'items',coalesce((SELECT jsonb_agg(jsonb_build_object('id',ii.id,'productId',ii.product_id,'name',p.name,'sku',p.sku,'quantity',ii.invoice_quantity,'unitPrice',ii.purchase_unit_price,'subtotal',ii.line_subtotal) ORDER BY p.name,p.sku,ii.id)
      FROM public.purchase_invoice_items ii JOIN public.products p ON p.id=ii.product_id WHERE ii.invoice_id=i.id),'[]'::jsonb),
    'receipts',coalesce((SELECT jsonb_agg(jsonb_build_object('id',r.id,'reference',r.receipt_reference,'status',r.status,'receivedAt',r.received_at) ORDER BY r.created_at,r.id)
      FROM public.purchase_invoice_receipts ir JOIN public.purchase_receipts r ON r.id=ir.receipt_id WHERE ir.invoice_id=i.id),'[]'::jsonb),
    'payable',CASE WHEN sp.id IS NULL THEN NULL ELSE jsonb_build_object('id',sp.id,'amount',sp.original_amount,'paid',coalesce(pa.paid,0),'outstanding',sp.original_amount-coalesce(pa.paid,0),'status',
      CASE WHEN sp.original_amount-coalesce(pa.paid,0)<=0 THEN 'LUNAS' WHEN i.due_date<current_date THEN 'TERLAMBAT' WHEN i.due_date<=current_date+7 THEN 'JATUH_TEMPO_SEGERA' WHEN coalesce(pa.paid,0)>0 THEN 'SEBAGIAN' ELSE 'BELUM_DIBAYAR' END) END,
    'payments',coalesce((SELECT jsonb_agg(jsonb_build_object('id',pay.id,'date',pay.payment_date,'amount',a.amount,'method',pay.payment_method,'reference',pay.reference_note,'recordedByName',coalesce(pr.full_name,'Pengguna tidak tersedia'),'recordedAt',pay.recorded_at) ORDER BY pay.payment_date,pay.id)
      FROM public.supplier_payment_allocations a JOIN public.supplier_payments pay ON pay.id=a.payment_id LEFT JOIN public.profiles pr ON pr.id=pay.recorded_by WHERE a.payable_id=sp.id),'[]'::jsonb),
    'documents',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'path',d.storage_path,'uploadedAt',d.uploaded_at,'uploadedByName',coalesce(dp.full_name,'Pengguna tidak tersedia')) ORDER BY d.uploaded_at,d.id)
      FROM public.purchase_invoice_documents d LEFT JOIN public.profiles dp ON dp.id=d.uploaded_by WHERE d.invoice_id=i.id),'[]'::jsonb),
    'events',coalesce((SELECT jsonb_agg(jsonb_build_object('type',e.event_type,'at',e.created_at,'actorName',coalesce(ep.full_name,'Pengguna tidak tersedia'),'note',e.note) ORDER BY e.created_at,e.id)
      FROM public.purchase_invoice_events e LEFT JOIN public.profiles ep ON ep.id=e.actor_id WHERE e.invoice_id=i.id),'[]'::jsonb)) INTO v_result
  FROM public.purchase_invoices i JOIN public.suppliers s ON s.id=i.supplier_id JOIN public.outlets o ON o.id=i.outlet_id
  LEFT JOIN public.profiles cp ON cp.id=i.created_by LEFT JOIN public.profiles up ON up.id=i.updated_by LEFT JOIN public.profiles fp ON fp.id=i.finalized_by
  LEFT JOIN public.supplier_payables sp ON sp.invoice_id=i.id
  LEFT JOIN LATERAL (SELECT sum(a.amount) paid FROM public.supplier_payment_allocations a WHERE a.payable_id=sp.id) pa ON true
  WHERE i.id=p_invoice_id;
  IF v_result IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='Invoice not found'; END IF;
  RETURN v_result;
END $$;
ALTER FUNCTION public.purchase_invoice_financial_detail(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_invoice_financial_detail(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_invoice_financial_detail(uuid) TO authenticated;

CREATE FUNCTION public.purchase_payables_page(p_search text,p_status text,p_page integer,p_page_size integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_role public.user_role; v_page integer:=greatest(coalesce(p_page,1),1); v_size integer:=least(greatest(coalesce(p_page_size,20),1),50); v_rows jsonb; v_total integer; v_summaries jsonb;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Financial purchasing access denied'; END IF;
  WITH balances AS (
    SELECT sp.id,sp.supplier_id,sp.invoice_id,sp.original_amount,i.invoice_number,i.invoice_date,i.due_date,s.display_name supplier_name,
      coalesce(sum(a.amount),0)::numeric(20,2) paid,sp.original_amount-coalesce(sum(a.amount),0)::numeric(20,2) outstanding
    FROM public.supplier_payables sp JOIN public.purchase_invoices i ON i.id=sp.invoice_id JOIN public.suppliers s ON s.id=sp.supplier_id
      LEFT JOIN public.supplier_payment_allocations a ON a.payable_id=sp.id
    GROUP BY sp.id,i.id,s.id
  ), classified AS (
    SELECT b.*,CASE WHEN outstanding<=0 THEN 'LUNAS' WHEN due_date<current_date THEN 'TERLAMBAT'
      WHEN due_date<=current_date+7 THEN 'JATUH_TEMPO_SEGERA' WHEN paid>0 THEN 'SEBAGIAN' ELSE 'BELUM_DIBAYAR' END status
    FROM balances b
  )
  SELECT count(*) INTO v_total FROM classified c WHERE (p_search IS NULL OR p_search='' OR c.supplier_name ILIKE '%'||left(p_search,80)||'%' OR c.invoice_number ILIKE '%'||left(p_search,80)||'%')
    AND (coalesce(p_status,'')='' OR c.status=p_status);
  WITH balances AS (
    SELECT sp.id,sp.supplier_id,sp.invoice_id,sp.original_amount,i.invoice_number,i.invoice_date,i.due_date,s.display_name supplier_name,
      coalesce(sum(a.amount),0)::numeric(20,2) paid,sp.original_amount-coalesce(sum(a.amount),0)::numeric(20,2) outstanding
    FROM public.supplier_payables sp JOIN public.purchase_invoices i ON i.id=sp.invoice_id JOIN public.suppliers s ON s.id=sp.supplier_id
      LEFT JOIN public.supplier_payment_allocations a ON a.payable_id=sp.id
    GROUP BY sp.id,i.id,s.id
  ), classified AS (
    SELECT b.*,CASE WHEN outstanding<=0 THEN 'LUNAS' WHEN due_date<current_date THEN 'TERLAMBAT'
      WHEN due_date<=current_date+7 THEN 'JATUH_TEMPO_SEGERA' WHEN paid>0 THEN 'SEBAGIAN' ELSE 'BELUM_DIBAYAR' END status
    FROM balances b
  )
  SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.due_date NULLS LAST,c.invoice_date DESC,c.id),'[]'::jsonb) INTO v_rows
  FROM (SELECT * FROM classified c WHERE (p_search IS NULL OR p_search='' OR c.supplier_name ILIKE '%'||left(p_search,80)||'%' OR c.invoice_number ILIKE '%'||left(p_search,80)||'%')
    AND (coalesce(p_status,'')='' OR c.status=p_status) ORDER BY c.due_date NULLS LAST,c.invoice_date DESC,c.id OFFSET (v_page-1)*v_size LIMIT v_size) c;
  SELECT jsonb_build_object('totalOutstanding',coalesce(sum(outstanding),0),'dueSoon',coalesce(sum(outstanding) FILTER(WHERE status='JATUH_TEMPO_SEGERA'),0),
    'overdue',coalesce(sum(outstanding) FILTER(WHERE status='TERLAMBAT'),0)) INTO v_summaries FROM (
      SELECT sp.original_amount-coalesce(sum(a.amount),0) outstanding,i.due_date,
        CASE WHEN sp.original_amount-coalesce(sum(a.amount),0)<=0 THEN 'LUNAS' WHEN i.due_date<current_date THEN 'TERLAMBAT'
          WHEN i.due_date<=current_date+7 THEN 'JATUH_TEMPO_SEGERA' WHEN coalesce(sum(a.amount),0)>0 THEN 'SEBAGIAN' ELSE 'BELUM_DIBAYAR' END status
      FROM public.supplier_payables sp JOIN public.purchase_invoices i ON i.id=sp.invoice_id LEFT JOIN public.supplier_payment_allocations a ON a.payable_id=sp.id GROUP BY sp.id,i.id
    ) x;
  RETURN jsonb_build_object('ok',true,'rows',v_rows,'total',v_total,'page',v_page,'pageSize',v_size,'summary',v_summaries);
END $$;
ALTER FUNCTION public.purchase_payables_page(text,text,integer,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_payables_page(text,text,integer,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_payables_page(text,text,integer,integer) TO authenticated;

CREATE FUNCTION public.purchase_invoices_page(p_search text,p_status text,p_page integer,p_page_size integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_role public.user_role; v_result jsonb;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Financial purchasing access denied'; END IF;
  WITH rows AS (
    SELECT i.id,i.invoice_reference,i.invoice_number,i.invoice_date,i.due_date,i.payment_type,i.supplier_invoice_total,i.status,
      i.created_at,i.finalized_at,s.display_name supplier_name,coalesce(sum(a.amount),0)::numeric(20,2) paid,
      CASE WHEN i.status='DRAFT' THEN 'BELUM_DILENGKAPI' WHEN i.supplier_invoice_total-coalesce(sum(a.amount),0)<=0 THEN 'LUNAS'
        WHEN i.due_date<current_date THEN 'TERLAMBAT' WHEN i.due_date<=current_date+7 THEN 'JATUH_TEMPO_SEGERA'
        WHEN coalesce(sum(a.amount),0)>0 THEN 'SEBAGIAN' ELSE 'BELUM_DIBAYAR' END payment_status
    FROM public.purchase_invoices i JOIN public.suppliers s ON s.id=i.supplier_id
      LEFT JOIN public.supplier_payables sp ON sp.invoice_id=i.id LEFT JOIN public.supplier_payment_allocations a ON a.payable_id=sp.id
    GROUP BY i.id,s.id
  ), filtered AS (
    SELECT r.* FROM rows r WHERE (coalesce(p_search,'')='' OR r.supplier_name ILIKE '%'||left(p_search,80)||'%' OR coalesce(r.invoice_number,'') ILIKE '%'||left(p_search,80)||'%' OR r.invoice_reference ILIKE '%'||left(p_search,80)||'%')
      AND (coalesce(p_status,'')='' OR (p_status='DRAFT' AND r.status='DRAFT') OR (p_status<>'DRAFT' AND r.status='FINALIZED' AND r.payment_status=p_status))
  )
  SELECT jsonb_build_object('ok',true,'rows',coalesce((SELECT jsonb_agg(to_jsonb(f) ORDER BY f.created_at DESC,f.id DESC) FROM
    (SELECT * FROM filtered ORDER BY created_at DESC,id DESC OFFSET (greatest(coalesce(p_page,1),1)-1)*least(greatest(coalesce(p_page_size,20),1),50) LIMIT least(greatest(coalesce(p_page_size,20),1),50)) f), '[]'::jsonb),
    'total',(SELECT count(*) FROM filtered),'page',greatest(coalesce(p_page,1),1),'pageSize',least(greatest(coalesce(p_page_size,20),1),50)) INTO v_result;
  RETURN v_result;
END $$;
ALTER FUNCTION public.purchase_invoices_page(text,text,integer,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_invoices_page(text,text,integer,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_invoices_page(text,text,integer,integer) TO authenticated;

CREATE FUNCTION public.purchase_receipt_list_details(p_receipt_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_role public.user_role; v_data jsonb;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'GUDANG'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Purchasing access denied'; END IF;
  IF coalesce(cardinality(p_receipt_ids),0)>25 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Receipt page exceeds the allowed size'; END IF;
  SELECT coalesce(jsonb_object_agg(r.id::text,jsonb_build_object('createdByName',coalesce(cp.full_name,'Pengguna tidak tersedia'),
    'postedByName',coalesce(pp.full_name,'Pengguna tidak tersedia'),'productCount',coalesce(items.product_count,0),'stockAdded',coalesce(items.stock_added,0),
    'financial',CASE WHEN v_role IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN fin.data ELSE NULL END)), '{}'::jsonb) INTO v_data
  FROM public.purchase_receipts r LEFT JOIN public.profiles cp ON cp.id=r.created_by LEFT JOIN public.profiles pp ON pp.id=r.posted_by
  LEFT JOIN LATERAL (SELECT count(*)::integer product_count,coalesce(sum(i.accepted_quantity+i.bonus_quantity),0)::numeric(20,3) stock_added
      FROM public.purchase_receipt_items i WHERE i.receipt_id=r.id) items ON true
  LEFT JOIN LATERAL (
    SELECT jsonb_build_object('invoiceNumber',i.invoice_number,'invoiceTotal',i.supplier_invoice_total,'paymentType',i.payment_type,
      'status',CASE WHEN i.status='DRAFT' THEN 'BELUM_DILENGKAPI' WHEN i.supplier_invoice_total-coalesce(sum(a.amount),0)<=0 THEN 'LUNAS'
        WHEN i.due_date<current_date THEN 'TERLAMBAT' WHEN i.due_date<=current_date+7 THEN 'JATUH_TEMPO_SEGERA'
        WHEN coalesce(sum(a.amount),0)>0 THEN 'SEBAGIAN' ELSE 'BELUM_DIBAYAR' END) data
    FROM public.purchase_invoice_receipts ir JOIN public.purchase_invoices i ON i.id=ir.invoice_id
      LEFT JOIN public.supplier_payables sp ON sp.invoice_id=i.id LEFT JOIN public.supplier_payment_allocations a ON a.payable_id=sp.id
    WHERE ir.receipt_id=r.id GROUP BY i.id
  ) fin ON true
  WHERE r.id=ANY(coalesce(p_receipt_ids,'{}'::uuid[]));
  RETURN coalesce(v_data,'{}'::jsonb);
END $$;
ALTER FUNCTION public.purchase_receipt_list_details(uuid[]) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_receipt_list_details(uuid[]) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_receipt_list_details(uuid[]) TO authenticated;
CREATE FUNCTION public.purchase_receipt_actor_names(p_receipt_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=pg_catalog AS $$
  SELECT public.purchase_receipt_list_details(ARRAY[p_receipt_id]) -> (p_receipt_id::text)
$$;
REVOKE ALL ON FUNCTION public.purchase_receipt_actor_names(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_receipt_actor_names(uuid) TO authenticated;

COMMIT;
