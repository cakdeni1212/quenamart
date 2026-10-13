-- Supplier workspace: extend the existing supplier master and add bounded reads.
BEGIN;

ALTER TABLE public.suppliers
  ADD COLUMN address text,
  ADD COLUMN notes text,
  ADD CONSTRAINT suppliers_address_nonblank CHECK (address IS NULL OR btrim(address) <> ''),
  ADD CONSTRAINT suppliers_notes_nonblank CHECK (notes IS NULL OR btrim(notes) <> '');

CREATE FUNCTION public.supplier_workspace_upsert(
  p_supplier_id uuid, p_display_name text, p_contact_name text, p_phone text,
  p_address text, p_notes text, p_is_active boolean
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE a uuid := auth.uid(); r public.user_role; result_id uuid;
BEGIN
  r := public.current_active_user_role();
  IF a IS NULL OR r IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Supplier management permission denied';
  END IF;
  IF p_display_name IS NULL OR btrim(p_display_name)='' OR length(btrim(p_display_name))>160
    OR (p_contact_name IS NOT NULL AND (btrim(p_contact_name)='' OR length(btrim(p_contact_name))>120))
    OR (p_phone IS NOT NULL AND (btrim(p_phone)='' OR length(btrim(p_phone))>40))
    OR (p_address IS NOT NULL AND (btrim(p_address)='' OR length(btrim(p_address))>500))
    OR (p_notes IS NOT NULL AND (btrim(p_notes)='' OR length(btrim(p_notes))>1000)) THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Supplier fields are invalid';
  END IF;
  IF p_supplier_id IS NULL THEN
    INSERT INTO public.suppliers(display_name,contact_name,phone,address,notes,is_active,created_by,updated_by)
      VALUES(btrim(p_display_name),nullif(btrim(p_contact_name),''),nullif(btrim(p_phone),''),
        nullif(btrim(p_address),''),nullif(btrim(p_notes),''),true,a,a) RETURNING id INTO result_id;
  ELSE
    UPDATE public.suppliers SET display_name=btrim(p_display_name),contact_name=nullif(btrim(p_contact_name),''),
      phone=nullif(btrim(p_phone),''),address=nullif(btrim(p_address),''),notes=nullif(btrim(p_notes),''),
      is_active=coalesce(p_is_active,is_active),updated_by=a,updated_at=now()
      WHERE id=p_supplier_id RETURNING id INTO result_id;
    IF result_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Supplier not found'; END IF;
  END IF;
  RETURN result_id;
END $$;
ALTER FUNCTION public.supplier_workspace_upsert(uuid,text,text,text,text,text,boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.supplier_workspace_upsert(uuid,text,text,text,text,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.supplier_workspace_upsert(uuid,text,text,text,text,text,boolean) TO authenticated;

CREATE FUNCTION public.supplier_workspace_page(p_search text,p_status text,p_tempo text,p_page integer,p_page_size integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r public.user_role:=public.current_active_user_role(); a uuid:=auth.uid(); outlet uuid; outlet_count integer;
  pg integer:=greatest(coalesce(p_page,1),1); sz integer:=least(greatest(coalesce(p_page_size,20),1),30);
  rows_json jsonb; total_rows integer; summary_json jsonb; search_text text:=left(btrim(coalesce(p_search,'')),80);
BEGIN
  IF a IS NULL OR r IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'GUDANG'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Supplier workspace access denied';
  END IF;
  SELECT count(*),(array_agg(outlet_id ORDER BY started_at DESC))[1] INTO outlet_count,outlet
    FROM public.stock_authority_periods WHERE ended_at IS NULL;
  IF outlet_count<>1 OR outlet IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Active outlet unavailable'; END IF;
  IF r='GUDANG'::public.user_role THEN
    WITH selected AS (
      SELECT s.id,s.supplier_code,s.display_name,s.contact_name,s.phone,s.address,s.is_active
      FROM public.suppliers s WHERE s.is_active AND (search_text='' OR s.display_name ILIKE '%'||search_text||'%'
        OR s.supplier_code ILIKE '%'||search_text||'%' OR coalesce(s.contact_name,'') ILIKE '%'||search_text||'%'
        OR coalesce(s.phone,'') ILIKE '%'||search_text||'%')
    )
    SELECT count(*) INTO total_rows FROM selected;
    WITH selected AS (
      SELECT s.id,s.supplier_code,s.display_name,s.contact_name,s.phone,s.address,s.is_active
      FROM public.suppliers s WHERE s.is_active AND (search_text='' OR s.display_name ILIKE '%'||search_text||'%'
        OR s.supplier_code ILIKE '%'||search_text||'%' OR coalesce(s.contact_name,'') ILIKE '%'||search_text||'%'
        OR coalesce(s.phone,'') ILIKE '%'||search_text||'%')
    ) SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.display_name,x.id),'[]'::jsonb) INTO rows_json FROM (
      SELECT * FROM selected ORDER BY display_name,id OFFSET (pg-1)*sz LIMIT sz
    ) x;
    RETURN jsonb_build_object('rows',rows_json,'total',total_rows,'page',pg,'pageSize',sz,'summary',NULL,'financialAccess',false);
  END IF;
  WITH payable AS (
    SELECT sp.supplier_id, count(*) FILTER(WHERE sp.original_amount-coalesce(pa.paid,0)>0)::integer open_count,
      coalesce(sum(greatest(sp.original_amount-coalesce(pa.paid,0),0)),0)::numeric(20,2) outstanding,
      min(i.due_date) FILTER(WHERE sp.original_amount-coalesce(pa.paid,0)>0) nearest_due
    FROM public.supplier_payables sp JOIN public.purchase_invoices i ON i.id=sp.invoice_id
    LEFT JOIN LATERAL (SELECT sum(a.amount) paid FROM public.supplier_payment_allocations a WHERE a.payable_id=sp.id) pa ON true
    WHERE sp.outlet_id=outlet GROUP BY sp.supplier_id
  ), last_receipt AS (
    SELECT supplier_id,max(posted_at) last_purchase FROM public.purchase_receipts
    WHERE outlet_id=outlet AND status='POSTED' GROUP BY supplier_id
  ), selected AS (
    SELECT s.id,s.supplier_code,s.display_name,s.contact_name,s.phone,s.address,s.is_active,
      coalesce(p.open_count,0) open_count,coalesce(p.outstanding,0)::text outstanding,
      p.nearest_due,lr.last_purchase
    FROM public.suppliers s LEFT JOIN payable p ON p.supplier_id=s.id LEFT JOIN last_receipt lr ON lr.supplier_id=s.id
    WHERE (p_status NOT IN ('ACTIVE','INACTIVE') OR s.is_active=(p_status='ACTIVE'))
      AND (p_tempo NOT IN ('HAS_TEMPO','NO_TEMPO') OR (coalesce(p.open_count,0)>0)=(p_tempo='HAS_TEMPO'))
      AND (search_text='' OR s.display_name ILIKE '%'||search_text||'%' OR s.supplier_code ILIKE '%'||search_text||'%'
        OR coalesce(s.contact_name,'') ILIKE '%'||search_text||'%' OR coalesce(s.phone,'') ILIKE '%'||search_text||'%')
  )
  SELECT count(*) INTO total_rows FROM selected;
  WITH payable AS (
    SELECT sp.supplier_id,count(*) FILTER(WHERE sp.original_amount-coalesce(pa.paid,0)>0)::integer open_count,
      coalesce(sum(greatest(sp.original_amount-coalesce(pa.paid,0),0)),0)::numeric(20,2) outstanding,
      min(i.due_date) FILTER(WHERE sp.original_amount-coalesce(pa.paid,0)>0) nearest_due
    FROM public.supplier_payables sp JOIN public.purchase_invoices i ON i.id=sp.invoice_id
    LEFT JOIN LATERAL (SELECT sum(a.amount) paid FROM public.supplier_payment_allocations a WHERE a.payable_id=sp.id) pa ON true
    WHERE sp.outlet_id=outlet GROUP BY sp.supplier_id
  ), last_receipt AS (
    SELECT supplier_id,max(posted_at) last_purchase FROM public.purchase_receipts WHERE outlet_id=outlet AND status='POSTED' GROUP BY supplier_id
  ), selected AS (
    SELECT s.id,s.supplier_code,s.display_name,s.contact_name,s.phone,s.address,s.is_active,coalesce(p.open_count,0) open_count,
      coalesce(p.outstanding,0)::text outstanding,p.nearest_due,lr.last_purchase
    FROM public.suppliers s LEFT JOIN payable p ON p.supplier_id=s.id LEFT JOIN last_receipt lr ON lr.supplier_id=s.id
    WHERE (p_status NOT IN ('ACTIVE','INACTIVE') OR s.is_active=(p_status='ACTIVE'))
      AND (p_tempo NOT IN ('HAS_TEMPO','NO_TEMPO') OR (coalesce(p.open_count,0)>0)=(p_tempo='HAS_TEMPO'))
      AND (search_text='' OR s.display_name ILIKE '%'||search_text||'%' OR s.supplier_code ILIKE '%'||search_text||'%'
        OR coalesce(s.contact_name,'') ILIKE '%'||search_text||'%' OR coalesce(s.phone,'') ILIKE '%'||search_text||'%')
  )
  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.display_name,x.id),'[]'::jsonb) INTO rows_json FROM (
    SELECT * FROM selected ORDER BY display_name,id OFFSET (pg-1)*sz LIMIT sz
  ) x;
  SELECT jsonb_build_object('activeSuppliers',(SELECT count(*) FROM public.suppliers WHERE is_active),
      'tempoCount',count(*) FILTER(WHERE outstanding>0),'outstanding',coalesce(sum(greatest(outstanding,0)),0)::text,
      'nearestDue',min(nearest_due) FILTER(WHERE outstanding>0)) INTO summary_json
    FROM (SELECT sp.original_amount-coalesce(sum(a.amount),0) outstanding,i.due_date nearest_due
      FROM public.supplier_payables sp JOIN public.purchase_invoices i ON i.id=sp.invoice_id
      LEFT JOIN public.supplier_payment_allocations a ON a.payable_id=sp.id WHERE sp.outlet_id=outlet
      GROUP BY sp.id,i.id) q;
  RETURN jsonb_build_object('rows',rows_json,'total',total_rows,'page',pg,'pageSize',sz,'summary',summary_json,'financialAccess',true);
END $$;
ALTER FUNCTION public.supplier_workspace_page(text,text,text,integer,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.supplier_workspace_page(text,text,text,integer,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.supplier_workspace_page(text,text,text,integer,integer) TO authenticated;

CREATE FUNCTION public.supplier_workspace_detail(p_supplier_id uuid,p_page integer,p_page_size integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r public.user_role:=public.current_active_user_role(); a uuid:=auth.uid(); outlet uuid; outlet_count integer;
  pg integer:=greatest(coalesce(p_page,1),1); sz integer:=least(greatest(coalesce(p_page_size,20),1),30);
  header_json jsonb; purchases_json jsonb; products_json jsonb; total_rows integer;
BEGIN
  IF a IS NULL OR r IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Supplier financial access denied';
  END IF;
  SELECT count(*),(array_agg(outlet_id ORDER BY started_at DESC))[1] INTO outlet_count,outlet
    FROM public.stock_authority_periods WHERE ended_at IS NULL;
  IF outlet_count<>1 OR outlet IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Active outlet unavailable'; END IF;
  SELECT to_jsonb(s) INTO header_json FROM (SELECT id,supplier_code,display_name,legal_name,contact_name,phone,address,notes,is_active,created_at FROM public.suppliers WHERE id=p_supplier_id) s;
  IF header_json IS NULL THEN RETURN NULL; END IF;
  WITH balances AS (
    SELECT i.id,i.invoice_reference,i.invoice_number,i.invoice_date,i.due_date,coalesce(pa.amount,i.supplier_invoice_total) total,
      coalesce(pa.paid,0)::numeric(20,2) paid,greatest(coalesce(pa.amount,i.supplier_invoice_total)-coalesce(pa.paid,0),0)::numeric(20,2) outstanding,
      i.payment_type,i.finalized_at,
      coalesce((SELECT jsonb_agg(jsonb_build_object('id',rec.id,'reference',rec.receipt_reference,'receivedAt',rec.received_at)
        ORDER BY rec.received_at DESC) FROM public.purchase_invoice_receipts pir JOIN public.purchase_receipts rec ON rec.id=pir.receipt_id
        WHERE pir.invoice_id=i.id),'[]'::jsonb) receipts
    FROM public.purchase_invoices i LEFT JOIN LATERAL (SELECT sp.original_amount amount,sum(a.amount) paid FROM public.supplier_payables sp
      LEFT JOIN public.supplier_payment_allocations a ON a.payable_id=sp.id WHERE sp.invoice_id=i.id GROUP BY sp.id) pa ON true
    WHERE i.supplier_id=p_supplier_id AND i.outlet_id=outlet AND i.status='FINALIZED'
  ) SELECT count(*) INTO total_rows FROM balances;
  WITH balances AS (
    SELECT i.id,i.invoice_reference,i.invoice_number,i.invoice_date,i.due_date,coalesce(pa.amount,i.supplier_invoice_total) total,
      coalesce(pa.paid,0)::numeric(20,2) paid,greatest(coalesce(pa.amount,i.supplier_invoice_total)-coalesce(pa.paid,0),0)::numeric(20,2) outstanding,
      i.payment_type,i.finalized_at,
      coalesce((SELECT jsonb_agg(jsonb_build_object('id',rec.id,'reference',rec.receipt_reference,'receivedAt',rec.received_at)
        ORDER BY rec.received_at DESC) FROM public.purchase_invoice_receipts pir JOIN public.purchase_receipts rec ON rec.id=pir.receipt_id WHERE pir.invoice_id=i.id),'[]'::jsonb) receipts
    FROM public.purchase_invoices i LEFT JOIN LATERAL (SELECT sp.original_amount amount,sum(a.amount) paid FROM public.supplier_payables sp
      LEFT JOIN public.supplier_payment_allocations a ON a.payable_id=sp.id WHERE sp.invoice_id=i.id GROUP BY sp.id) pa ON true
    WHERE i.supplier_id=p_supplier_id AND i.outlet_id=outlet AND i.status='FINALIZED'
  ) SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.finalized_at DESC,x.id),'[]'::jsonb) INTO purchases_json FROM (
    SELECT * FROM balances ORDER BY finalized_at DESC,id OFFSET (pg-1)*sz LIMIT sz) x;
  WITH receipt_products AS (
    SELECT p.id,p.name,p.sku,max(r.posted_at) last_purchase,
      (array_agg(ri.accepted_quantity+ri.bonus_quantity ORDER BY r.posted_at DESC,ri.id DESC))[1] last_received_quantity
    FROM public.purchase_receipts r JOIN public.purchase_receipt_items ri ON ri.receipt_id=r.id
    JOIN public.products p ON p.id=ri.product_id WHERE r.supplier_id=p_supplier_id AND r.outlet_id=outlet AND r.status='POSTED'
    GROUP BY p.id,p.name,p.sku ORDER BY max(r.posted_at) DESC,p.id LIMIT 10
  ) SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) INTO products_json FROM receipt_products x;
  RETURN jsonb_build_object('supplier',header_json,'purchases',purchases_json,'purchaseCount',total_rows,'page',pg,'pageSize',sz,
    'products',products_json,'summary',(SELECT jsonb_build_object('totalPurchases',coalesce(sum(coalesce(pa.amount,i.supplier_invoice_total)),0)::text,
      'outstanding',coalesce(sum(greatest(coalesce(pa.amount,i.supplier_invoice_total)-coalesce(pa.paid,0),0)),0)::text,
      'openInvoices',count(*) FILTER(WHERE coalesce(pa.amount,i.supplier_invoice_total)-coalesce(pa.paid,0)>0),
      'lastPurchase',(SELECT max(rec.posted_at) FROM public.purchase_receipts rec WHERE rec.supplier_id=p_supplier_id AND rec.outlet_id=outlet AND rec.status='POSTED'))
      FROM public.purchase_invoices i LEFT JOIN LATERAL (SELECT sp.original_amount amount,sum(a.amount) paid FROM public.supplier_payables sp
        LEFT JOIN public.supplier_payment_allocations a ON a.payable_id=sp.id WHERE sp.invoice_id=i.id GROUP BY sp.id) pa ON true
      WHERE i.supplier_id=p_supplier_id AND i.outlet_id=outlet AND i.status='FINALIZED'));
END $$;
ALTER FUNCTION public.supplier_workspace_detail(uuid,integer,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.supplier_workspace_detail(uuid,integer,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.supplier_workspace_detail(uuid,integer,integer) TO authenticated;

COMMIT;
