-- Audited paid operational expenses. Inventory purchasing/payables are separate ledgers.
BEGIN;

CREATE SEQUENCE public.operational_expense_number_seq AS bigint START WITH 1;
REVOKE ALL ON SEQUENCE public.operational_expense_number_seq FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.operational_expenses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  expense_number text NOT NULL UNIQUE,
  expense_date date NOT NULL,
  category text NOT NULL CHECK (category IN (
    'GAJI','SEWA','LISTRIK','INTERNET','KEBERSIHAN','ATK','MAINTENANCE',
    'TRANSPORT','MARKETING','BIAYA_ADMIN','KONSUMSI','LAIN_LAIN')),
  description text NOT NULL CHECK (btrim(description)<>'' AND length(description)<=500),
  amount numeric(14,2) NOT NULL CHECK (amount>0),
  payment_method text NOT NULL CHECK (payment_method IN ('CASH','QRIS','BANK_TRANSFER','CARD','OTHER')),
  reference_note text CHECK (reference_note IS NULL OR (btrim(reference_note)<>'' AND length(reference_note)<=500)),
  status text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','POSTED','CANCELLED')),
  draft_revision integer NOT NULL DEFAULT 1 CHECK (draft_revision>0),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_by_name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  updated_at timestamptz NOT NULL DEFAULT now(),
  posted_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  posted_by_name text,
  posted_at timestamptz,
  cancelled_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  cancelled_by_name text,
  cancelled_at timestamptz,
  cancellation_reason text CHECK (cancellation_reason IS NULL OR (btrim(cancellation_reason)<>'' AND length(cancellation_reason)<=500)),
  CONSTRAINT operational_expenses_post_state CHECK (
    (status='POSTED' AND posted_at IS NOT NULL AND posted_by IS NOT NULL AND posted_by_name IS NOT NULL)
    OR (status='CANCELLED' AND ((posted_at IS NOT NULL AND posted_by IS NOT NULL AND posted_by_name IS NOT NULL)
      OR (posted_at IS NULL AND posted_by IS NULL AND posted_by_name IS NULL)))
    OR (status='DRAFT' AND posted_at IS NULL AND posted_by IS NULL AND posted_by_name IS NULL)),
  CONSTRAINT operational_expenses_cancel_state CHECK ((status='CANCELLED')=(cancelled_at IS NOT NULL AND cancelled_by IS NOT NULL AND cancelled_by_name IS NOT NULL AND cancellation_reason IS NOT NULL))
);
CREATE INDEX operational_expenses_outlet_date_idx ON public.operational_expenses(outlet_id,expense_date DESC,id DESC);
CREATE INDEX operational_expenses_outlet_status_date_idx ON public.operational_expenses(outlet_id,status,expense_date DESC,id DESC);
ALTER TABLE public.operational_expenses ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.operational_expenses FROM PUBLIC,anon,authenticated,service_role;

CREATE TABLE public.operational_expense_requests (
  request_id uuid PRIMARY KEY,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  operation text NOT NULL CHECK(operation IN ('CREATE','POST','CANCEL')),
  payload_hash text NOT NULL CHECK(payload_hash ~ '^[0-9a-f]{32}$'),
  expense_id uuid NOT NULL REFERENCES public.operational_expenses(id) ON DELETE RESTRICT,
  result jsonb NOT NULL,
  completed_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.operational_expense_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.operational_expense_requests FROM PUBLIC,anon,authenticated,service_role;

CREATE TABLE public.operational_expense_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  expense_id uuid NOT NULL REFERENCES public.operational_expenses(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK(event_type IN ('CREATED','UPDATED','POSTED','CANCELLED')),
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  actor_name text NOT NULL,
  request_id uuid REFERENCES public.operational_expense_requests(request_id) ON DELETE RESTRICT,
  note text,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX operational_expense_events_expense_idx ON public.operational_expense_events(expense_id,id);
ALTER TABLE public.operational_expense_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.operational_expense_events FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.guard_operational_expense_update()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='EXPENSE_HISTORY_IMMUTABLE'; END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.outlet_id IS DISTINCT FROM OLD.outlet_id
    OR NEW.expense_number IS DISTINCT FROM OLD.expense_number OR NEW.created_by IS DISTINCT FROM OLD.created_by
    OR NEW.created_by_name IS DISTINCT FROM OLD.created_by_name OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='EXPENSE_IDENTITY_IMMUTABLE';
  END IF;
  IF OLD.status='DRAFT' AND NEW.status='DRAFT' THEN
    IF NEW.draft_revision<>OLD.draft_revision+1 OR NEW.posted_by IS NOT NULL OR NEW.posted_at IS NOT NULL
      OR NEW.cancelled_by IS NOT NULL OR NEW.cancelled_at IS NOT NULL OR NEW.cancellation_reason IS NOT NULL THEN
      RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='EXPENSE_DRAFT_TRANSITION_INVALID';
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status='DRAFT' AND NEW.status='POSTED' THEN
    IF NEW.expense_date IS DISTINCT FROM OLD.expense_date OR NEW.category IS DISTINCT FROM OLD.category
      OR NEW.description IS DISTINCT FROM OLD.description OR NEW.amount IS DISTINCT FROM OLD.amount
      OR NEW.payment_method IS DISTINCT FROM OLD.payment_method OR NEW.reference_note IS DISTINCT FROM OLD.reference_note
      OR NEW.draft_revision<>OLD.draft_revision OR NEW.posted_by IS NULL OR NEW.posted_at IS NULL
      OR NEW.cancelled_by IS NOT NULL OR NEW.cancelled_at IS NOT NULL THEN
      RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='EXPENSE_POST_TRANSITION_INVALID';
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status IN ('DRAFT','POSTED') AND NEW.status='CANCELLED' THEN
    IF NEW.expense_date IS DISTINCT FROM OLD.expense_date OR NEW.category IS DISTINCT FROM OLD.category
      OR NEW.description IS DISTINCT FROM OLD.description OR NEW.amount IS DISTINCT FROM OLD.amount
      OR NEW.payment_method IS DISTINCT FROM OLD.payment_method OR NEW.reference_note IS DISTINCT FROM OLD.reference_note
      OR NEW.draft_revision<>OLD.draft_revision OR NEW.posted_by IS DISTINCT FROM OLD.posted_by
      OR NEW.posted_by_name IS DISTINCT FROM OLD.posted_by_name OR NEW.posted_at IS DISTINCT FROM OLD.posted_at
      OR NEW.cancelled_by IS NULL OR NEW.cancelled_at IS NULL OR NEW.cancellation_reason IS NULL THEN
      RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='EXPENSE_CANCEL_TRANSITION_INVALID';
    END IF;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='EXPENSE_POSTED_IMMUTABLE';
END $$;
ALTER FUNCTION public.guard_operational_expense_update() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_operational_expense_update() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER operational_expense_update_guard BEFORE UPDATE OR DELETE ON public.operational_expenses
FOR EACH ROW EXECUTE FUNCTION public.guard_operational_expense_update();

CREATE FUNCTION public.guard_operational_expense_append_only()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='EXPENSE_AUDIT_IMMUTABLE'; END $$;
ALTER FUNCTION public.guard_operational_expense_append_only() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_operational_expense_append_only() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER operational_expense_events_append_only BEFORE UPDATE OR DELETE ON public.operational_expense_events
FOR EACH ROW EXECUTE FUNCTION public.guard_operational_expense_append_only();
CREATE TRIGGER operational_expense_requests_append_only BEFORE UPDATE OR DELETE ON public.operational_expense_requests
FOR EACH ROW EXECUTE FUNCTION public.guard_operational_expense_append_only();

CREATE FUNCTION public.operational_expense_outlet()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE n integer; outlet uuid;
BEGIN
  SELECT count(*),(array_agg(p.outlet_id ORDER BY p.started_at DESC))[1] INTO n,outlet
  FROM public.stock_authority_periods p JOIN public.outlets o ON o.id=p.outlet_id
  WHERE p.ended_at IS NULL AND o.is_active;
  IF n<>1 OR outlet IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='EXPENSE_OUTLET_UNAVAILABLE'; END IF;
  RETURN outlet;
END $$;
ALTER FUNCTION public.operational_expense_outlet() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.operational_expense_outlet() FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.operational_expense_create(
  p_request_id uuid,p_expense_date date,p_category text,p_description text,p_amount numeric,
  p_payment_method text,p_reference_note text,p_post boolean DEFAULT true
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid:=auth.uid(); role public.user_role; outlet uuid; actor_name text; request_row public.operational_expense_requests%rowtype;
  payload text; digest text; expense_id uuid; expense_no text; result jsonb; status_value text:='DRAFT';
BEGIN
  role:=public.current_active_user_role();
  IF actor IS NULL OR role IS NULL OR role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='EXPENSE_UNAUTHORIZED'; END IF;
  IF p_request_id IS NULL OR p_expense_date IS NULL OR p_category IS NULL OR p_category NOT IN ('GAJI','SEWA','LISTRIK','INTERNET','KEBERSIHAN','ATK','MAINTENANCE','TRANSPORT','MARKETING','BIAYA_ADMIN','KONSUMSI','LAIN_LAIN')
    OR p_description IS NULL OR btrim(p_description)='' OR length(btrim(p_description))>500
    OR p_amount IS NULL OR p_amount<=0 OR p_amount>999999999999.99 OR p_amount<>round(p_amount,2)
    OR p_payment_method IS NULL OR p_payment_method NOT IN ('CASH','QRIS','BANK_TRANSFER','CARD','OTHER')
    OR (p_reference_note IS NOT NULL AND (btrim(p_reference_note)='' OR length(btrim(p_reference_note))>500))
    OR p_post IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='EXPENSE_INPUT_INVALID'; END IF;
  outlet:=public.operational_expense_outlet();
  payload:=concat_ws(chr(31),p_expense_date::text,p_category,btrim(p_description),p_amount::numeric(14,2)::text,p_payment_method,coalesce(btrim(p_reference_note),''),p_post::text);
  digest:=md5(payload);
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text||':EXPENSE_CREATE:'||p_request_id::text,7742081));
  SELECT * INTO request_row FROM public.operational_expense_requests WHERE request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF request_row.actor_id<>actor OR request_row.operation<>'CREATE' OR request_row.payload_hash<>digest THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='EXPENSE_REQUEST_CONFLICT'; END IF;
    RETURN request_row.result;
  END IF;
  SELECT coalesce(nullif(btrim(full_name),''),'Pengguna Quena') INTO actor_name FROM public.profiles WHERE id=actor AND is_active;
  IF actor_name IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='EXPENSE_UNAUTHORIZED'; END IF;
  expense_no:='QEXP-'||to_char(timezone('Asia/Jakarta',now()),'YYYYMMDD')||'-'||lpad(nextval('public.operational_expense_number_seq')::text,6,'0');
  INSERT INTO public.operational_expenses(outlet_id,expense_number,expense_date,category,description,amount,payment_method,reference_note,created_by,created_by_name,updated_by)
    VALUES(outlet,expense_no,p_expense_date,p_category,btrim(p_description),p_amount,btrim(p_payment_method),nullif(btrim(p_reference_note),''),actor,actor_name,actor)
    RETURNING id INTO expense_id;
  IF p_post THEN
    status_value:='POSTED';
    UPDATE public.operational_expenses SET status='POSTED',posted_by=actor,posted_by_name=actor_name,posted_at=now(),updated_by=actor,updated_at=now()
      WHERE id=expense_id;
  END IF;
  result:=jsonb_build_object('id',expense_id,'expenseNumber',expense_no,'status',status_value,'revision',1);
  INSERT INTO public.operational_expense_requests(request_id,actor_id,operation,payload_hash,expense_id,result)
    VALUES(p_request_id,actor,'CREATE',digest,expense_id,result);
  INSERT INTO public.operational_expense_events(expense_id,event_type,actor_id,actor_name,request_id,evidence)
    VALUES(expense_id,'CREATED',actor,actor_name,p_request_id,
      jsonb_build_object('date',p_expense_date,'category',p_category,'description',btrim(p_description),
        'amount',p_amount::numeric(14,2)::text,'payment_method',p_payment_method,
        'reference_note',nullif(btrim(p_reference_note),''),'status','DRAFT','revision',1));
  IF p_post THEN
    INSERT INTO public.operational_expense_events(expense_id,event_type,actor_id,actor_name,request_id,evidence)
      VALUES(expense_id,'POSTED',actor,actor_name,p_request_id,
        jsonb_build_object('date',p_expense_date,'category',p_category,'description',btrim(p_description),
          'amount',p_amount::numeric(14,2)::text,'payment_method',p_payment_method,
          'reference_note',nullif(btrim(p_reference_note),''),'status','POSTED','revision',1));
  END IF;
  RETURN result;
END $$;
ALTER FUNCTION public.operational_expense_create(uuid,date,text,text,numeric,text,text,boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.operational_expense_create(uuid,date,text,text,numeric,text,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.operational_expense_create(uuid,date,text,text,numeric,text,text,boolean) TO authenticated;

CREATE FUNCTION public.operational_expense_update_draft(
  p_expense_id uuid,p_expected_revision integer,p_expense_date date,p_category text,p_description text,
  p_amount numeric,p_payment_method text,p_reference_note text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid:=auth.uid(); role public.user_role; actor_name text; expense_row public.operational_expenses%rowtype;
BEGIN
  role:=public.current_active_user_role();
  IF actor IS NULL OR role IS NULL OR role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='EXPENSE_UNAUTHORIZED'; END IF;
  IF p_expense_id IS NULL OR p_expected_revision IS NULL OR p_expected_revision<1 OR p_expense_date IS NULL
    OR p_category IS NULL OR p_category NOT IN ('GAJI','SEWA','LISTRIK','INTERNET','KEBERSIHAN','ATK','MAINTENANCE','TRANSPORT','MARKETING','BIAYA_ADMIN','KONSUMSI','LAIN_LAIN')
    OR p_description IS NULL OR btrim(p_description)='' OR length(btrim(p_description))>500 OR p_amount IS NULL OR p_amount<=0
    OR p_amount>999999999999.99 OR p_amount<>round(p_amount,2) OR p_payment_method IS NULL OR p_payment_method NOT IN ('CASH','QRIS','BANK_TRANSFER','CARD','OTHER')
    OR (p_reference_note IS NOT NULL AND (btrim(p_reference_note)='' OR length(btrim(p_reference_note))>500)) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='EXPENSE_INPUT_INVALID'; END IF;
  PERFORM public.operational_expense_outlet();
  SELECT * INTO expense_row FROM public.operational_expenses WHERE id=p_expense_id FOR UPDATE;
  IF NOT FOUND OR expense_row.outlet_id<>public.operational_expense_outlet() THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='EXPENSE_NOT_FOUND'; END IF;
  IF expense_row.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='EXPENSE_NOT_EDITABLE'; END IF;
  IF expense_row.draft_revision<>p_expected_revision THEN RETURN jsonb_build_object('ok',false,'code','EXPENSE_STALE','revision',expense_row.draft_revision); END IF;
  SELECT coalesce(nullif(btrim(full_name),''),'Pengguna Quena') INTO actor_name FROM public.profiles WHERE id=actor AND is_active;
  UPDATE public.operational_expenses SET expense_date=p_expense_date,category=p_category,description=btrim(p_description),amount=p_amount,
    payment_method=p_payment_method,reference_note=nullif(btrim(p_reference_note),''),draft_revision=draft_revision+1,updated_by=actor,updated_at=now()
    WHERE id=p_expense_id RETURNING * INTO expense_row;
  INSERT INTO public.operational_expense_events(expense_id,event_type,actor_id,actor_name,note,evidence)
    VALUES(p_expense_id,'UPDATED',actor,actor_name,'Draf diperbarui ke revisi '||expense_row.draft_revision::text,
      jsonb_build_object('date',expense_row.expense_date,'category',expense_row.category,'description',expense_row.description,
        'amount',expense_row.amount::numeric(14,2)::text,'payment_method',expense_row.payment_method,
        'reference_note',expense_row.reference_note,'status',expense_row.status,'revision',expense_row.draft_revision));
  RETURN jsonb_build_object('ok',true,'revision',expense_row.draft_revision);
END $$;
ALTER FUNCTION public.operational_expense_update_draft(uuid,integer,date,text,text,numeric,text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.operational_expense_update_draft(uuid,integer,date,text,text,numeric,text,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.operational_expense_update_draft(uuid,integer,date,text,text,numeric,text,text) TO authenticated;

CREATE FUNCTION public.operational_expense_post(p_expense_id uuid,p_request_id uuid,p_expected_revision integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid:=auth.uid(); role public.user_role; actor_name text; expense_row public.operational_expenses%rowtype;
  old_request public.operational_expense_requests%rowtype; digest text; result jsonb;
BEGIN
  role:=public.current_active_user_role();
  IF actor IS NULL OR role IS NULL OR role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='EXPENSE_UNAUTHORIZED'; END IF;
  IF p_expense_id IS NULL OR p_request_id IS NULL OR p_expected_revision IS NULL OR p_expected_revision<1 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='EXPENSE_INPUT_INVALID'; END IF;
  PERFORM public.operational_expense_outlet();
  digest:=md5(concat_ws(':',p_expense_id::text,p_expected_revision::text));
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text||':EXPENSE_POST:'||p_request_id::text,7742081));
  SELECT * INTO old_request FROM public.operational_expense_requests WHERE request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF old_request.actor_id<>actor OR old_request.operation<>'POST' OR old_request.payload_hash<>digest THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='EXPENSE_REQUEST_CONFLICT'; END IF;
    RETURN old_request.result;
  END IF;
  SELECT * INTO expense_row FROM public.operational_expenses WHERE id=p_expense_id FOR UPDATE;
  IF NOT FOUND OR expense_row.outlet_id<>public.operational_expense_outlet() THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='EXPENSE_NOT_FOUND'; END IF;
  IF expense_row.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='EXPENSE_NOT_EDITABLE'; END IF;
  IF expense_row.draft_revision<>p_expected_revision THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='EXPENSE_STALE'; END IF;
  SELECT coalesce(nullif(btrim(full_name),''),'Pengguna Quena') INTO actor_name FROM public.profiles WHERE id=actor AND is_active;
  UPDATE public.operational_expenses SET status='POSTED',posted_by=actor,posted_by_name=actor_name,posted_at=now(),updated_by=actor,updated_at=now()
    WHERE id=p_expense_id;
  result:=jsonb_build_object('id',p_expense_id,'status','POSTED','expenseNumber',expense_row.expense_number);
  INSERT INTO public.operational_expense_requests(request_id,actor_id,operation,payload_hash,expense_id,result)
    VALUES(p_request_id,actor,'POST',digest,p_expense_id,result);
  INSERT INTO public.operational_expense_events(expense_id,event_type,actor_id,actor_name,request_id,evidence)
    VALUES(p_expense_id,'POSTED',actor,actor_name,p_request_id,
      jsonb_build_object('date',expense_row.expense_date,'category',expense_row.category,'description',expense_row.description,
        'amount',expense_row.amount::numeric(14,2)::text,'payment_method',expense_row.payment_method,
        'reference_note',expense_row.reference_note,'status','POSTED','revision',expense_row.draft_revision));
  RETURN result;
END $$;
ALTER FUNCTION public.operational_expense_post(uuid,uuid,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.operational_expense_post(uuid,uuid,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.operational_expense_post(uuid,uuid,integer) TO authenticated;

CREATE FUNCTION public.operational_expense_cancel(p_expense_id uuid,p_request_id uuid,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid:=auth.uid(); role public.user_role; actor_name text; expense_row public.operational_expenses%rowtype;
  old_request public.operational_expense_requests%rowtype; digest text; result jsonb;
BEGIN
  role:=public.current_active_user_role();
  IF actor IS NULL OR role IS NULL OR role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='EXPENSE_UNAUTHORIZED'; END IF;
  IF p_expense_id IS NULL OR p_request_id IS NULL OR p_reason IS NULL OR btrim(p_reason)='' OR length(btrim(p_reason))>500
    THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='EXPENSE_CANCEL_REASON_REQUIRED'; END IF;
  PERFORM public.operational_expense_outlet();
  digest:=md5(concat_ws(':',p_expense_id::text,btrim(p_reason)));
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text||':EXPENSE_CANCEL:'||p_request_id::text,7742081));
  SELECT * INTO old_request FROM public.operational_expense_requests WHERE request_id=p_request_id FOR UPDATE;
  IF FOUND THEN
    IF old_request.actor_id<>actor OR old_request.operation<>'CANCEL' OR old_request.payload_hash<>digest THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='EXPENSE_REQUEST_CONFLICT'; END IF;
    RETURN old_request.result;
  END IF;
  SELECT * INTO expense_row FROM public.operational_expenses WHERE id=p_expense_id FOR UPDATE;
  IF NOT FOUND OR expense_row.outlet_id<>public.operational_expense_outlet() THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='EXPENSE_NOT_FOUND'; END IF;
  IF expense_row.status='CANCELLED' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='EXPENSE_ALREADY_CANCELLED'; END IF;
  SELECT coalesce(nullif(btrim(full_name),''),'Pengguna Quena') INTO actor_name FROM public.profiles WHERE id=actor AND is_active;
  UPDATE public.operational_expenses SET status='CANCELLED',cancelled_by=actor,cancelled_by_name=actor_name,cancelled_at=now(),
    cancellation_reason=btrim(p_reason),updated_by=actor,updated_at=now() WHERE id=p_expense_id;
  result:=jsonb_build_object('id',p_expense_id,'status','CANCELLED','expenseNumber',expense_row.expense_number);
  INSERT INTO public.operational_expense_requests(request_id,actor_id,operation,payload_hash,expense_id,result)
    VALUES(p_request_id,actor,'CANCEL',digest,p_expense_id,result);
  INSERT INTO public.operational_expense_events(expense_id,event_type,actor_id,actor_name,request_id,note,evidence)
    VALUES(p_expense_id,'CANCELLED',actor,actor_name,p_request_id,btrim(p_reason),
      jsonb_build_object('date',expense_row.expense_date,'category',expense_row.category,'description',expense_row.description,
        'amount',expense_row.amount::numeric(14,2)::text,'payment_method',expense_row.payment_method,
        'reference_note',expense_row.reference_note,'status','CANCELLED','reason',btrim(p_reason),
        'was_posted',expense_row.status='POSTED','revision',expense_row.draft_revision));
  RETURN result;
END $$;
ALTER FUNCTION public.operational_expense_cancel(uuid,uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.operational_expense_cancel(uuid,uuid,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.operational_expense_cancel(uuid,uuid,text) TO authenticated;

CREATE FUNCTION public.operational_expenses_page(
  p_date_from date,p_date_to date,p_search text,p_category text,p_method text,p_status text,p_page integer,p_page_size integer
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid:=auth.uid(); role public.user_role; outlet uuid; page_number integer:=greatest(coalesce(p_page,1),1);
  page_size integer:=least(greatest(coalesce(p_page_size,20),1),30); q text:=left(btrim(coalesce(p_search,'')),100);
  category_filter text:=coalesce(p_category,''); method_filter text:=coalesce(p_method,''); status_filter text:=coalesce(p_status,'');
  response jsonb;
BEGIN
  role:=public.current_active_user_role();
  IF actor IS NULL OR role IS NULL OR role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='EXPENSE_UNAUTHORIZED'; END IF;
  IF p_date_from IS NULL OR p_date_to IS NULL OR p_date_from>p_date_to OR p_date_to-p_date_from>366
    OR category_filter NOT IN ('','GAJI','SEWA','LISTRIK','INTERNET','KEBERSIHAN','ATK','MAINTENANCE','TRANSPORT','MARKETING','BIAYA_ADMIN','KONSUMSI','LAIN_LAIN')
    OR method_filter NOT IN ('','CASH','QRIS','BANK_TRANSFER','CARD','OTHER') OR status_filter NOT IN ('','DRAFT','POSTED','CANCELLED')
    THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='EXPENSE_FILTER_INVALID'; END IF;
  outlet:=public.operational_expense_outlet();
  WITH filtered AS MATERIALIZED (
    SELECT e.* FROM public.operational_expenses e WHERE e.outlet_id=outlet AND e.expense_date BETWEEN p_date_from AND p_date_to
      AND (q='' OR e.expense_number ILIKE '%'||q||'%' OR e.description ILIKE '%'||q||'%' OR coalesce(e.reference_note,'') ILIKE '%'||q||'%')
      AND (category_filter='' OR e.category=category_filter) AND (method_filter='' OR e.payment_method=method_filter)
      AND (status_filter='' OR e.status=status_filter)
  ), summary AS (
    SELECT coalesce(sum(amount) FILTER(WHERE status='POSTED'),0)::numeric(16,2) AS total,
      count(*) FILTER(WHERE status='POSTED')::integer AS count,
      coalesce(round(sum(amount) FILTER(WHERE status='POSTED')/nullif(count(*) FILTER(WHERE status='POSTED'),0),2),0)::numeric(16,2) AS average
    FROM filtered
  ), largest AS (
    SELECT category,sum(amount)::numeric(16,2) amount FROM filtered WHERE status='POSTED' GROUP BY category ORDER BY sum(amount) DESC,category LIMIT 1
  ), rows_page AS (
    SELECT f.id,f.expense_number,f.expense_date,f.category,f.description,f.amount::numeric(14,2)::text amount,
      f.payment_method,f.reference_note,f.status,f.draft_revision,f.created_at,f.posted_at,f.cancelled_at
    FROM filtered f ORDER BY f.expense_date DESC,f.created_at DESC,f.id DESC OFFSET (page_number-1)*page_size LIMIT page_size
  )
  SELECT jsonb_build_object('rows',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.expense_date DESC,r.created_at DESC,r.id DESC),'[]'::jsonb) FROM rows_page r),
    'total',(SELECT count(*)::integer FROM filtered),'page',page_number,'pageSize',page_size,
    'summary',jsonb_build_object('total',s.total::text,'count',s.count,'average',s.average::text,
      'largestCategory',(SELECT category FROM largest),'largestCategoryAmount',(SELECT amount::text FROM largest)))
    INTO response FROM summary s;
  RETURN response;
END $$;
ALTER FUNCTION public.operational_expenses_page(date,date,text,text,text,text,integer,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.operational_expenses_page(date,date,text,text,text,text,integer,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.operational_expenses_page(date,date,text,text,text,text,integer,integer) TO authenticated;

CREATE FUNCTION public.operational_expense_detail(p_expense_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid:=auth.uid(); role public.user_role; outlet uuid; result jsonb;
BEGIN
  role:=public.current_active_user_role();
  IF actor IS NULL OR role IS NULL OR role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='EXPENSE_UNAUTHORIZED'; END IF;
  outlet:=public.operational_expense_outlet();
  SELECT to_jsonb(x)||jsonb_build_object('events',coalesce((SELECT jsonb_agg(jsonb_build_object('type',ev.event_type,'actor',ev.actor_name,
    'at',ev.created_at,'note',ev.note,'evidence',ev.evidence) ORDER BY ev.id) FROM public.operational_expense_events ev WHERE ev.expense_id=x.id),'[]'::jsonb))
  INTO result FROM (
    SELECT e.id,e.outlet_id,e.expense_number,e.expense_date,e.category,e.description,e.amount::numeric(14,2)::text amount,
      e.payment_method,e.reference_note,e.status,e.draft_revision,e.created_by_name created_by,e.created_at,e.posted_by_name posted_by,
      e.posted_at,e.cancelled_by_name cancelled_by,e.cancelled_at,e.cancellation_reason
    FROM public.operational_expenses e WHERE e.id=p_expense_id AND e.outlet_id=outlet
  ) x;
  RETURN result;
END $$;
ALTER FUNCTION public.operational_expense_detail(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.operational_expense_detail(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.operational_expense_detail(uuid) TO authenticated;

-- One authenticated aggregate feeds the Owner Dashboard without using current HPP/WAC.
CREATE FUNCTION public.owner_dashboard_operating_expense_read()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid:=auth.uid(); role public.user_role; outlet uuid; base jsonb; business_date date;
  expense_total numeric(16,2); gross numeric(16,2); profit_status text; result jsonb;
BEGIN
  role:=public.current_active_user_role();
  IF actor IS NULL OR role IS NULL OR role NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='EXPENSE_UNAUTHORIZED'; END IF;
  outlet:=public.operational_expense_outlet();
  base:=public.owner_dashboard_read(7);
  business_date:=(base->>'business_date')::date;
  SELECT coalesce(sum(amount),0)::numeric(16,2) INTO expense_total FROM public.operational_expenses
    WHERE outlet_id=outlet AND expense_date=business_date AND status='POSTED';
  profit_status:=base#>>'{profit,status}';
  IF profit_status='RESOLVED' AND base#>>'{profit,gross_profit}' IS NOT NULL THEN gross:=(base#>>'{profit,gross_profit}')::numeric; END IF;
  result:=jsonb_build_object('business_date',business_date,'expenses_today',expense_total::text,
    'gross_profit_status',profit_status,'gross_profit',CASE WHEN gross IS NULL THEN NULL ELSE gross::numeric(16,2)::text END,
    'operating_profit',CASE WHEN gross IS NULL THEN NULL ELSE (gross-expense_total)::numeric(16,2)::text END);
  RETURN result;
END $$;
ALTER FUNCTION public.owner_dashboard_operating_expense_read() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.owner_dashboard_operating_expense_read() FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.owner_dashboard_operating_expense_read() TO authenticated;

COMMIT;
