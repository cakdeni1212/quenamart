-- Purchasing: audited cancellation for unposted receipt and linked invoice drafts.
-- Physical deletion remains prohibited. Storage cleanup is server-side and retryable.
BEGIN;

ALTER TABLE public.purchase_receipts DROP CONSTRAINT purchase_receipts_status_check;
ALTER TABLE public.purchase_receipts ADD CONSTRAINT purchase_receipts_status_check
  CHECK (status IN ('DRAFT','POSTED','CANCELLED'));
DROP POLICY purchase_receipts_read_authorized ON public.purchase_receipts;
CREATE POLICY purchase_receipts_read_authorized ON public.purchase_receipts FOR SELECT TO authenticated
  USING (public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role)
    OR (public.current_active_user_role()='GUDANG'::public.user_role AND status<>'CANCELLED'));
DROP POLICY purchase_receipt_items_read_authorized ON public.purchase_receipt_items;
CREATE POLICY purchase_receipt_items_read_authorized ON public.purchase_receipt_items FOR SELECT TO authenticated
  USING (EXISTS(SELECT 1 FROM public.purchase_receipts r WHERE r.id=receipt_id AND
    (r.status<>'CANCELLED' OR public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role))));
DROP POLICY purchase_receipt_events_read_authorized ON public.purchase_receipt_events;
CREATE POLICY purchase_receipt_events_read_authorized ON public.purchase_receipt_events FOR SELECT TO authenticated
  USING (EXISTS(SELECT 1 FROM public.purchase_receipts r WHERE r.id=receipt_id AND
    (r.status<>'CANCELLED' OR public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role))));
ALTER TABLE public.purchase_receipts
  ADD COLUMN cancelled_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  ADD COLUMN cancelled_at timestamptz;
ALTER TABLE public.purchase_receipts DROP CONSTRAINT purchase_receipt_posting_consistent;
ALTER TABLE public.purchase_receipts ADD CONSTRAINT purchase_receipt_lifecycle_consistent CHECK (
  (status='DRAFT' AND posted_by IS NULL AND posted_at IS NULL AND cancelled_by IS NULL AND cancelled_at IS NULL)
  OR (status='POSTED' AND posted_by IS NOT NULL AND posted_at IS NOT NULL AND cancelled_by IS NULL AND cancelled_at IS NULL)
  OR (status='CANCELLED' AND posted_by IS NULL AND posted_at IS NULL AND cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL)
);

ALTER TABLE public.purchase_receipt_events DROP CONSTRAINT purchase_receipt_events_event_type_check;
ALTER TABLE public.purchase_receipt_events ADD CONSTRAINT purchase_receipt_events_event_type_check
  CHECK (event_type IN ('CREATED','DRAFT_UPDATED','POSTED','CANCELLED'));

ALTER TABLE public.purchase_invoices DROP CONSTRAINT purchase_invoices_status_check;
ALTER TABLE public.purchase_invoices ADD CONSTRAINT purchase_invoices_status_check
  CHECK (status IN ('DRAFT','FINALIZED','CANCELLED'));
ALTER TABLE public.purchase_invoices
  ADD COLUMN cancelled_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  ADD COLUMN cancelled_at timestamptz;
ALTER TABLE public.purchase_invoices DROP CONSTRAINT purchase_invoice_finalized_shape;
ALTER TABLE public.purchase_invoices ADD CONSTRAINT purchase_invoice_lifecycle_shape CHECK (
  (status='DRAFT' AND finalized_by IS NULL AND finalized_at IS NULL AND cancelled_by IS NULL AND cancelled_at IS NULL)
  OR (status='FINALIZED' AND invoice_number IS NOT NULL AND invoice_date IS NOT NULL
    AND payment_type IS NOT NULL AND supplier_invoice_total IS NOT NULL
    AND finalized_by IS NOT NULL AND finalized_at IS NOT NULL AND cancelled_by IS NULL AND cancelled_at IS NULL
    AND (payment_type <> 'TEMPO' OR due_date IS NOT NULL))
  OR (status='CANCELLED' AND finalized_by IS NULL AND finalized_at IS NULL
    AND cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL)
);
ALTER TABLE public.purchase_invoice_events DROP CONSTRAINT purchase_invoice_events_event_type_check;
ALTER TABLE public.purchase_invoice_events ADD CONSTRAINT purchase_invoice_events_event_type_check
  CHECK (event_type IN ('CREATED','DRAFT_UPDATED','RECEIPT_LINKED','RECEIPT_UNLINKED','FINALIZED','PAYMENT_RECORDED','DOCUMENT_ADDED','CANCELLED'));

ALTER TABLE public.purchase_invoice_documents
  ADD COLUMN cleanup_status text NOT NULL DEFAULT 'ACTIVE'
    CHECK (cleanup_status IN ('ACTIVE','CLEANUP_PENDING','CLEANED')),
  ADD COLUMN cleanup_attempts integer NOT NULL DEFAULT 0 CHECK (cleanup_attempts >= 0),
  ADD COLUMN cleanup_last_attempt_at timestamptz,
  ADD COLUMN cleaned_at timestamptz;
CREATE INDEX purchase_invoice_documents_cleanup_idx
  ON public.purchase_invoice_documents(invoice_id,id) WHERE cleanup_status='CLEANUP_PENDING';

CREATE OR REPLACE FUNCTION public.guard_purchase_receipt_immutability()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Purchase receipt history cannot be deleted';
  END IF;
  IF OLD.status IN ('POSTED','CANCELLED') THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Posted or cancelled purchase receipts are immutable';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_purchase_receipt_immutability() FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.guard_purchase_invoice_immutable()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Purchase invoice history cannot be deleted'; END IF;
  IF OLD.status IN ('FINALIZED','CANCELLED') THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Finalized or cancelled purchase invoices are immutable'; END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.guard_purchase_invoice_immutable() FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.purchase_invoice_attach_document(p_invoice_id uuid,p_storage_path text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_id uuid;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Financial purchasing access denied'; END IF;
  IF p_storage_path !~ ('^invoices/'||p_invoice_id::text||'/[0-9a-fA-F-]{36}\.(jpg|jpeg|png|webp|pdf)$')
    OR NOT EXISTS(SELECT 1 FROM storage.objects o WHERE o.bucket_id='quena-purchasing-invoices' AND o.name=p_storage_path)
    OR NOT EXISTS(SELECT 1 FROM public.purchase_invoices i WHERE i.id=p_invoice_id AND i.status='DRAFT') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invoice document is unavailable';
  END IF;
  INSERT INTO public.purchase_invoice_documents(invoice_id,storage_path,uploaded_by) VALUES(p_invoice_id,p_storage_path,v_actor) RETURNING id INTO v_id;
  INSERT INTO public.purchase_invoice_events(invoice_id,event_type,actor_id,note) VALUES(p_invoice_id,'DOCUMENT_ADDED',v_actor,'Dokumen nota dilampirkan');
  RETURN v_id;
END $$;
ALTER FUNCTION public.purchase_invoice_attach_document(uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_invoice_attach_document(uuid,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_invoice_attach_document(uuid,text) TO authenticated;

DROP POLICY purchasing_invoice_upload_manager ON storage.objects;
CREATE POLICY purchasing_invoice_upload_manager ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id='quena-purchasing-invoices'
    AND public.current_active_user_role() IN ('OWNER'::public.user_role,'ADMIN'::public.user_role)
    AND name ~ '^invoices/[0-9a-fA-F-]{8}-[0-9a-fA-F-]{4}-[1-8][0-9a-fA-F-]{3}-[89aAbB][0-9a-fA-F-]{3}-[0-9a-fA-F-]{12}/[0-9a-fA-F-]{36}\.(jpg|jpeg|png|webp|pdf)$'
    AND EXISTS (SELECT 1 FROM public.purchase_invoices i
      WHERE i.id=(split_part(name,'/',2))::uuid AND i.status='DRAFT'));

CREATE OR REPLACE FUNCTION public.purchase_invoice_link_receipt(p_invoice_id uuid,p_receipt_id uuid,p_link boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_invoice public.purchase_invoices%rowtype; v_receipt public.purchase_receipts%rowtype;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Financial purchasing access denied'; END IF;
  SELECT * INTO v_invoice FROM public.purchase_invoices WHERE id=p_invoice_id FOR UPDATE;
  SELECT * INTO v_receipt FROM public.purchase_receipts WHERE id=p_receipt_id FOR KEY SHARE;
  IF v_invoice.id IS NULL OR v_invoice.status<>'DRAFT' OR v_receipt.id IS NULL OR v_receipt.status='CANCELLED'
    OR v_invoice.supplier_id<>v_receipt.supplier_id OR v_invoice.outlet_id<>v_receipt.outlet_id THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Receipt cannot be linked to this invoice';
  END IF;
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

CREATE OR REPLACE FUNCTION public.purchase_invoices_page(p_search text,p_status text,p_page integer,p_page_size integer)
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
    WHERE i.status<>'CANCELLED' GROUP BY i.id,s.id
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

CREATE OR REPLACE FUNCTION public.purchase_receipt_list_details(p_receipt_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_role public.user_role; v_data jsonb;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'GUDANG'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Purchasing access denied'; END IF;
  IF coalesce(cardinality(p_receipt_ids),0)>25 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Receipt page exceeds the allowed size'; END IF;
  SELECT coalesce(jsonb_object_agg(r.id::text,jsonb_build_object('createdByName',coalesce(cp.full_name,'Pengguna tidak tersedia'),
    'postedByName',coalesce(pp.full_name,'Pengguna tidak tersedia'),'cancelledByName',coalesce(xp.full_name,'Pengguna tidak tersedia'),
    'productCount',coalesce(items.product_count,0),'stockAdded',coalesce(items.stock_added,0),
    'financial',CASE WHEN v_role IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN fin.data ELSE NULL END)), '{}'::jsonb) INTO v_data
  FROM public.purchase_receipts r LEFT JOIN public.profiles cp ON cp.id=r.created_by
  LEFT JOIN public.profiles pp ON pp.id=r.posted_by LEFT JOIN public.profiles xp ON xp.id=r.cancelled_by
  LEFT JOIN LATERAL (SELECT count(*)::integer product_count,coalesce(sum(i.accepted_quantity+i.bonus_quantity),0)::numeric(20,3) stock_added
    FROM public.purchase_receipt_items i WHERE i.receipt_id=r.id) items ON true
  LEFT JOIN LATERAL (SELECT jsonb_build_object('invoiceNumber',i.invoice_number,'invoiceTotal',i.supplier_invoice_total,'paymentType',i.payment_type,
      'status',CASE WHEN i.status='CANCELLED' THEN 'DIBATALKAN' WHEN i.status='DRAFT' THEN 'BELUM_DILENGKAPI'
      WHEN i.supplier_invoice_total-coalesce(sum(a.amount),0)<=0 THEN 'LUNAS' WHEN i.due_date<current_date THEN 'TERLAMBAT'
      WHEN i.due_date<=current_date+7 THEN 'JATUH_TEMPO_SEGERA' WHEN coalesce(sum(a.amount),0)>0 THEN 'SEBAGIAN' ELSE 'BELUM_DIBAYAR' END,
      'documentCleanupPending',CASE WHEN v_role IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN EXISTS(
        SELECT 1 FROM public.purchase_invoice_documents d WHERE d.invoice_id=i.id AND d.cleanup_status='CLEANUP_PENDING') ELSE NULL END) data
    FROM public.purchase_invoice_receipts ir JOIN public.purchase_invoices i ON i.id=ir.invoice_id
      LEFT JOIN public.supplier_payables sp ON sp.invoice_id=i.id LEFT JOIN public.supplier_payment_allocations a ON a.payable_id=sp.id
    WHERE ir.receipt_id=r.id GROUP BY i.id) fin ON true
  WHERE r.id=ANY(coalesce(p_receipt_ids,'{}'::uuid[]))
    AND (r.status<>'CANCELLED' OR v_role IN ('OWNER'::public.user_role,'ADMIN'::public.user_role));
  RETURN coalesce(v_data,'{}'::jsonb);
END $$;
ALTER FUNCTION public.purchase_receipt_list_details(uuid[]) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_receipt_list_details(uuid[]) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_receipt_list_details(uuid[]) TO authenticated;

CREATE FUNCTION public.purchase_receipt_cancel_draft(p_receipt_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_actor uuid:=auth.uid(); v_role public.user_role; v_receipt public.purchase_receipts%rowtype;
  v_invoice_id uuid; v_current_invoice_id uuid; v_linked_receipt_id uuid;
  v_paths jsonb:='[]'::jsonb; v_already_cancelled boolean:=false;
BEGIN
  v_role:=public.current_active_user_role();
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Receipt cancellation permission denied';
  END IF;
  IF p_receipt_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Receipt identity is invalid'; END IF;
  SELECT * INTO v_receipt FROM public.purchase_receipts WHERE id=p_receipt_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='Receipt not found'; END IF;
  IF v_receipt.status='POSTED' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Posted purchase receipt cannot be cancelled'; END IF;
  IF v_receipt.status='CANCELLED' THEN
    v_already_cancelled:=true;
  ELSE
    -- Match invoice-link/finalization lock order (invoice, then receipt). If
    -- linking changed while we waited, fail closed and ask for a fresh retry.
    SELECT ir.invoice_id INTO v_invoice_id FROM public.purchase_invoice_receipts ir WHERE ir.receipt_id=p_receipt_id;
    IF v_invoice_id IS NOT NULL THEN
      PERFORM 1 FROM public.purchase_invoices WHERE id=v_invoice_id FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Receipt financial state changed'; END IF;
    END IF;
    SELECT * INTO v_receipt FROM public.purchase_receipts WHERE id=p_receipt_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='Receipt not found'; END IF;
    IF v_receipt.status='POSTED' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Posted purchase receipt cannot be cancelled'; END IF;
    IF v_receipt.status='CANCELLED' THEN v_already_cancelled:=true; END IF;
  END IF;
  IF NOT v_already_cancelled THEN
    SELECT ir.invoice_id INTO v_current_invoice_id FROM public.purchase_invoice_receipts ir WHERE ir.receipt_id=p_receipt_id;
    IF v_current_invoice_id IS DISTINCT FROM v_invoice_id THEN
      RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Receipt financial state changed; retry cancellation';
    END IF;
    IF EXISTS(SELECT 1 FROM public.stock_movements m JOIN public.purchase_receipt_items ri ON ri.id=m.purchase_receipt_item_id
      WHERE ri.receipt_id=p_receipt_id)
      OR EXISTS(SELECT 1 FROM public.stock_movement_batches b JOIN public.stock_operation_requests q ON q.request_id=b.operation_request_id
        WHERE b.source_system='PURCHASING' AND q.operation_key='POST_PURCHASE_RECEIPT' AND q.target_key=p_receipt_id::text) THEN
      RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Receipt already has stock movements';
    END IF;
    IF v_invoice_id IS NOT NULL THEN
      IF NOT EXISTS(SELECT 1 FROM public.purchase_invoices i WHERE i.id=v_invoice_id AND i.status='DRAFT')
        OR EXISTS(SELECT 1 FROM public.supplier_payables p WHERE p.invoice_id=v_invoice_id)
        OR EXISTS(SELECT 1 FROM public.supplier_payments p JOIN public.supplier_payment_allocations a ON a.payment_id=p.id
          JOIN public.supplier_payables sp ON sp.id=a.payable_id WHERE sp.invoice_id=v_invoice_id) THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Receipt has finalized financial state';
      END IF;
      UPDATE public.purchase_invoice_documents SET cleanup_status='CLEANUP_PENDING'
        WHERE invoice_id=v_invoice_id AND cleanup_status<>'CLEANED';
      -- Draft invoices may cover multiple receipts. Cancelling one parent
      -- purchase cancels that shared invoice draft as a whole and records
      -- every removed relationship. Keep this cancelled receipt's link as
      -- audit/idempotency context, so retries can resume document cleanup.
      FOR v_linked_receipt_id IN
        DELETE FROM public.purchase_invoice_receipts
          WHERE invoice_id=v_invoice_id AND receipt_id<>p_receipt_id RETURNING receipt_id
      LOOP
        INSERT INTO public.purchase_invoice_events(invoice_id,event_type,actor_id,note)
          VALUES(v_invoice_id,'RECEIPT_UNLINKED',v_actor,'Hubungan barang masuk dilepas karena draf nota dibatalkan');
      END LOOP;
      UPDATE public.purchase_invoices SET status='CANCELLED',cancelled_by=v_actor,cancelled_at=now(),updated_by=v_actor,updated_at=now()
        WHERE id=v_invoice_id;
      INSERT INTO public.purchase_invoice_events(invoice_id,event_type,actor_id,note)
        VALUES(v_invoice_id,'CANCELLED',v_actor,'Nota draf dibatalkan bersama draf barang masuk');
    END IF;
    UPDATE public.purchase_receipts SET status='CANCELLED',cancelled_by=v_actor,cancelled_at=now(),updated_by=v_actor,updated_at=now()
      WHERE id=p_receipt_id;
    INSERT INTO public.purchase_receipt_events(receipt_id,event_type,actor_id,note)
      VALUES(p_receipt_id,'CANCELLED',v_actor,'Draf barang masuk dibatalkan');
  END IF;
  IF v_invoice_id IS NULL THEN
    SELECT ir.invoice_id INTO v_invoice_id FROM public.purchase_invoice_receipts ir WHERE ir.receipt_id=p_receipt_id;
  END IF;
  IF v_invoice_id IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('documentId',d.id,'storagePath',d.storage_path) ORDER BY d.id),'[]'::jsonb)
      INTO v_paths FROM public.purchase_invoice_documents d
      WHERE d.invoice_id=v_invoice_id AND d.cleanup_status='CLEANUP_PENDING';
  END IF;
  RETURN jsonb_build_object('ok',true,'code',CASE WHEN v_already_cancelled THEN 'ALREADY_CANCELLED' ELSE 'CANCELLED' END,
    'receiptId',p_receipt_id,'invoiceId',v_invoice_id,'documents',v_paths);
END $$;
ALTER FUNCTION public.purchase_receipt_cancel_draft(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_receipt_cancel_draft(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.purchase_receipt_cancel_draft(uuid) TO authenticated;

CREATE FUNCTION public.purchase_invoice_document_cleanup_mark(p_document_id uuid,p_deleted boolean)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_role public.user_role;
BEGIN
  IF coalesce(nullif(current_setting('request.jwt.claim.role',true),''),current_setting('request.jwt.claims',true)::jsonb->>'role','')<>'service_role' THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Document cleanup permission denied';
  END IF;
  UPDATE public.purchase_invoice_documents d SET cleanup_status=CASE WHEN p_deleted THEN 'CLEANED' ELSE 'CLEANUP_PENDING' END,
    cleanup_attempts=cleanup_attempts+1,cleanup_last_attempt_at=now(),cleaned_at=CASE WHEN p_deleted THEN now() ELSE NULL END
  FROM public.purchase_invoices i WHERE d.id=p_document_id AND d.invoice_id=i.id AND i.status='CANCELLED'
    AND d.cleanup_status='CLEANUP_PENDING';
  RETURN FOUND;
END $$;
ALTER FUNCTION public.purchase_invoice_document_cleanup_mark(uuid,boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purchase_invoice_document_cleanup_mark(uuid,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.purchase_invoice_document_cleanup_mark(uuid,boolean) TO service_role;

COMMIT;
