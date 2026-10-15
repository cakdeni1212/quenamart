-- Provider-neutral transactional notification outbox. No provider is configured
-- and all delivery automation defaults remain disabled.
BEGIN;

CREATE TABLE public.outlet_whatsapp_settings (
  outlet_id uuid PRIMARY KEY REFERENCES public.outlets(id) ON DELETE RESTRICT,
  whatsapp_transactions_enabled boolean NOT NULL DEFAULT false,
  automatic_receipt_enabled boolean NOT NULL DEFAULT false,
  include_points_earned boolean NOT NULL DEFAULT true,
  include_points_redeemed boolean NOT NULL DEFAULT true,
  include_points_balance boolean NOT NULL DEFAULT true,
  provider_state text NOT NULL DEFAULT 'NOT_CONFIGURED'
    CHECK (provider_state IN ('NOT_CONFIGURED','DISCONNECTED','CONNECTING','CONNECTED','DEGRADED','ERROR')),
  provider_key text,
  public_url_ready boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  CONSTRAINT whatsapp_auto_requires_master CHECK (NOT automatic_receipt_enabled OR whatsapp_transactions_enabled)
);
ALTER TABLE public.outlet_whatsapp_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.outlet_whatsapp_settings FROM PUBLIC,anon,authenticated,service_role;

CREATE TABLE public.whatsapp_settings_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type='WHATSAPP_SETTINGS_UPDATED'),
  changed_fields text[] NOT NULL CHECK (cardinality(changed_fields)>0),
  old_config jsonb NOT NULL CHECK(jsonb_typeof(old_config)='object'),
  new_config jsonb NOT NULL CHECK(jsonb_typeof(new_config)='object'),
  occurred_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.whatsapp_settings_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.whatsapp_settings_events FROM PUBLIC,anon,authenticated,service_role;
CREATE INDEX whatsapp_settings_events_outlet_time_idx ON public.whatsapp_settings_events(outlet_id,occurred_at DESC);

CREATE TABLE public.notification_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  channel text NOT NULL CHECK(channel IN ('WHATSAPP')),
  notification_type text NOT NULL CHECK(notification_type IN ('DIGITAL_RECEIPT')),
  aggregate_type text NOT NULL CHECK(aggregate_type='SALE'),
  aggregate_id uuid NOT NULL REFERENCES public.sales(id) ON DELETE RESTRICT,
  member_id uuid REFERENCES public.members(id) ON DELETE RESTRICT,
  destination_snapshot text NOT NULL,
  payload_snapshot jsonb NOT NULL CHECK(jsonb_typeof(payload_snapshot)='object'),
  status text NOT NULL DEFAULT 'PENDING' CHECK(status IN ('PENDING','PROCESSING','SENT','RETRY','FAILED','CANCELLED','BLOCKED')),
  provider_key text,
  attempt_count integer NOT NULL DEFAULT 0 CHECK(attempt_count>=0 AND attempt_count<=5),
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  last_attempt_at timestamptz,
  sent_at timestamptz,
  failed_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  lease_expires_at timestamptz,
  last_error_code text CHECK(last_error_code IS NULL OR last_error_code ~ '^[A-Z0-9_]{1,64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(channel,notification_type,aggregate_type,aggregate_id),
  CONSTRAINT notification_outbox_member_outlet_fk FOREIGN KEY(member_id,outlet_id)
    REFERENCES public.members(id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT notification_outbox_sale_outlet_fk FOREIGN KEY(aggregate_id,outlet_id)
    REFERENCES public.sales(id,outlet_id) ON DELETE RESTRICT,
  CONSTRAINT notification_outbox_state_timestamps CHECK(
    (status<>'SENT' OR sent_at IS NOT NULL) AND (status<>'FAILED' OR failed_at IS NOT NULL)
    AND (status<>'CANCELLED' OR cancelled_at IS NOT NULL)
  )
);
ALTER TABLE public.notification_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_outbox FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.notification_outbox FROM PUBLIC,anon,authenticated,service_role;
CREATE INDEX notification_outbox_due_idx ON public.notification_outbox(status,next_attempt_at,created_at)
  WHERE status IN ('PENDING','RETRY','PROCESSING');
CREATE INDEX notification_outbox_outlet_created_idx ON public.notification_outbox(outlet_id,created_at DESC);
CREATE INDEX notification_outbox_member_idx ON public.notification_outbox(member_id,created_at DESC);

CREATE TABLE public.notification_delivery_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  notification_id uuid NOT NULL REFERENCES public.notification_outbox(id) ON DELETE RESTRICT,
  attempt_no integer NOT NULL CHECK(attempt_no BETWEEN 1 AND 5),
  provider_key text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  result text CHECK(result IS NULL OR result IN ('SENT','RETRY','FAILED','BLOCKED')),
  provider_message_id text,
  normalized_error_code text CHECK(normalized_error_code IS NULL OR normalized_error_code ~ '^[A-Z0-9_]{1,64}$'),
  safe_error_message text CHECK(safe_error_message IS NULL OR length(safe_error_message)<=240),
  UNIQUE(notification_id,attempt_no)
);
ALTER TABLE public.notification_delivery_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_delivery_attempts FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.notification_delivery_attempts FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.whatsapp_settings_read()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid; s public.outlet_whatsapp_settings%ROWTYPE;
BEGIN
  IF a IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='WHATSAPP_SETTINGS_READ_DENIED'; END IF;
  o:=public.outlet_settings_current_id();
  SELECT * INTO s FROM public.outlet_whatsapp_settings WHERE outlet_id=o;
  RETURN jsonb_build_object('outlet_id',o,'whatsapp_transactions_enabled',coalesce(s.whatsapp_transactions_enabled,false),
    'automatic_receipt_enabled',coalesce(s.automatic_receipt_enabled,false),
    'include_points_earned',coalesce(s.include_points_earned,true),'include_points_redeemed',coalesce(s.include_points_redeemed,true),
    'include_points_balance',coalesce(s.include_points_balance,true),'provider_state',coalesce(s.provider_state,'NOT_CONFIGURED'),
    'public_url_ready',coalesce(s.public_url_ready,false),'updated_at',s.updated_at);
END $$;
ALTER FUNCTION public.whatsapp_settings_read() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whatsapp_settings_read() FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.whatsapp_settings_read() TO authenticated;

CREATE FUNCTION public.whatsapp_settings_update(p_outlet_id uuid,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid;
  v_master boolean; v_auto boolean; v_earned boolean; v_redeemed boolean; v_balance boolean; changed text[];
  prior public.outlet_whatsapp_settings%ROWTYPE;
BEGIN
  IF a IS NULL OR r IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='WHATSAPP_SETTINGS_UPDATE_DENIED'; END IF;
  o:=public.outlet_settings_current_id();
  IF p_outlet_id IS DISTINCT FROM o OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
    OR p_payload-ARRAY['whatsapp_transactions_enabled','automatic_receipt_enabled','include_points_earned','include_points_redeemed','include_points_balance']<>'{}'::jsonb
    OR jsonb_typeof(p_payload->'whatsapp_transactions_enabled') IS DISTINCT FROM 'boolean'
    OR jsonb_typeof(p_payload->'automatic_receipt_enabled') IS DISTINCT FROM 'boolean'
    OR jsonb_typeof(p_payload->'include_points_earned') IS DISTINCT FROM 'boolean'
    OR jsonb_typeof(p_payload->'include_points_redeemed') IS DISTINCT FROM 'boolean'
    OR jsonb_typeof(p_payload->'include_points_balance') IS DISTINCT FROM 'boolean' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='WHATSAPP_SETTINGS_INVALID_PAYLOAD'; END IF;
  v_master:=(p_payload->>'whatsapp_transactions_enabled')::boolean; v_auto:=(p_payload->>'automatic_receipt_enabled')::boolean;
  v_earned:=(p_payload->>'include_points_earned')::boolean; v_redeemed:=(p_payload->>'include_points_redeemed')::boolean;
  v_balance:=(p_payload->>'include_points_balance')::boolean;
  IF v_auto AND NOT v_master THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='WHATSAPP_SETTINGS_INVALID_PAYLOAD'; END IF;
  INSERT INTO public.outlet_whatsapp_settings(outlet_id) VALUES(o) ON CONFLICT DO NOTHING;
  SELECT * INTO prior FROM public.outlet_whatsapp_settings WHERE outlet_id=o FOR UPDATE;
  changed:=array_remove(ARRAY[
    CASE WHEN prior.whatsapp_transactions_enabled IS DISTINCT FROM v_master THEN 'whatsapp_transactions_enabled' END,
    CASE WHEN prior.automatic_receipt_enabled IS DISTINCT FROM v_auto THEN 'automatic_receipt_enabled' END,
    CASE WHEN prior.include_points_earned IS DISTINCT FROM v_earned THEN 'include_points_earned' END,
    CASE WHEN prior.include_points_redeemed IS DISTINCT FROM v_redeemed THEN 'include_points_redeemed' END,
    CASE WHEN prior.include_points_balance IS DISTINCT FROM v_balance THEN 'include_points_balance' END
  ],NULL);
  IF cardinality(changed)>0 THEN
    UPDATE public.outlet_whatsapp_settings SET whatsapp_transactions_enabled=v_master,automatic_receipt_enabled=v_auto,
      include_points_earned=v_earned,include_points_redeemed=v_redeemed,include_points_balance=v_balance,updated_at=now(),updated_by=a
      WHERE outlet_id=o;
    INSERT INTO public.whatsapp_settings_events(outlet_id,actor_id,event_type,changed_fields,old_config,new_config)
      VALUES(o,a,'WHATSAPP_SETTINGS_UPDATED',changed,
        jsonb_build_object('whatsapp_transactions_enabled',prior.whatsapp_transactions_enabled,'automatic_receipt_enabled',prior.automatic_receipt_enabled,
          'include_points_earned',prior.include_points_earned,'include_points_redeemed',prior.include_points_redeemed,'include_points_balance',prior.include_points_balance),
        jsonb_build_object('whatsapp_transactions_enabled',v_master,'automatic_receipt_enabled',v_auto,
          'include_points_earned',v_earned,'include_points_redeemed',v_redeemed,'include_points_balance',v_balance));
  END IF;
  RETURN public.whatsapp_settings_read();
END $$;
ALTER FUNCTION public.whatsapp_settings_update(uuid,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whatsapp_settings_update(uuid,jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.whatsapp_settings_update(uuid,jsonb) TO authenticated;

-- Called only by the checkout completion trigger; snapshots no bearer link/token.
CREATE FUNCTION public.enqueue_whatsapp_digital_receipt(p_sale_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE s public.sales%ROWTYPE; m public.members%ROWTYPE; w public.outlet_whatsapp_settings%ROWTYPE;
  receipt_id uuid; consent record; earned bigint:=0; redeemed bigint:=0; balance_after bigint; payload jsonb;
BEGIN
  SELECT * INTO s FROM public.sales WHERE id=p_sale_id AND source_system='QUENA_POS'::public.pos_sale_source
    AND status='COMPLETED'::public.pos_sale_status;
  IF NOT FOUND OR s.member_id IS NULL THEN RETURN false; END IF;
  SELECT * INTO w FROM public.outlet_whatsapp_settings WHERE outlet_id=s.outlet_id;
  IF NOT FOUND OR NOT w.whatsapp_transactions_enabled OR NOT w.automatic_receipt_enabled
    OR w.provider_state<>'CONNECTED' OR w.provider_key IS NULL OR NOT w.public_url_ready THEN RETURN false; END IF;
  SELECT * INTO m FROM public.members WHERE id=s.member_id AND outlet_id=s.outlet_id AND status='ACTIVE';
  IF NOT FOUND OR m.phone_normalized IS NULL THEN RETURN false; END IF;
  SELECT ce.id,ce.policy_version,ce.granted INTO consent FROM public.member_consent_evidence ce
    WHERE ce.member_id=m.id AND ce.outlet_id=s.outlet_id AND ce.consent_type='MEMBERSHIP_SERVICE'
    ORDER BY ce.occurred_at DESC,ce.id DESC LIMIT 1;
  IF NOT FOUND OR consent.granted IS NOT TRUE THEN RETURN false; END IF;
  SELECT id INTO receipt_id FROM public.sale_public_receipts WHERE sale_id=s.id AND outlet_id=s.outlet_id
    AND status IN ('UNISSUED','ACTIVE');
  IF NOT FOUND THEN RETURN false; END IF;
  SELECT coalesce(sum(points_delta) FILTER(WHERE event_type='SALE_EARN'),0)::bigint,
    coalesce(-sum(points_delta) FILTER(WHERE event_type='SALE_REDEEM'),0)::bigint,
    coalesce(max((policy_snapshot->>'balance_after_event')::bigint) FILTER(WHERE event_type='SALE_EARN'),
      max((policy_snapshot->>'balance_after_event')::bigint) FILTER(WHERE event_type='SALE_REDEEM'))
    INTO earned,redeemed,balance_after FROM public.member_point_ledger WHERE sale_id=s.id;
  SELECT jsonb_build_object('contract_version','DIGITAL_RECEIPT_V1','sale_number',s.sale_number,'sale_total',s.grand_total,
    'customer_name',m.full_name,'points_earned',CASE WHEN w.include_points_earned AND earned>0 THEN earned END,
    'points_redeemed',CASE WHEN w.include_points_redeemed AND redeemed>0 THEN redeemed END,
    'points_balance_after',CASE WHEN w.include_points_balance THEN balance_after END,
    'receipt_reference',receipt_id,'consent_evidence_id',consent.id,'consent_policy_version',consent.policy_version,
    'outlet_display_name',coalesce(nullif(btrim(o.customer_display_name),''),o.name))
    INTO payload FROM public.outlets o WHERE o.id=s.outlet_id;
  INSERT INTO public.notification_outbox(outlet_id,channel,notification_type,aggregate_type,aggregate_id,member_id,
    destination_snapshot,payload_snapshot,provider_key,status)
    VALUES(s.outlet_id,'WHATSAPP','DIGITAL_RECEIPT','SALE',s.id,m.id,m.phone_normalized,payload,w.provider_key,'PENDING')
    ON CONFLICT(channel,notification_type,aggregate_type,aggregate_id) DO NOTHING;
  RETURN FOUND;
END $$;
ALTER FUNCTION public.enqueue_whatsapp_digital_receipt(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.enqueue_whatsapp_digital_receipt(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.after_pos_sale_whatsapp_outbox()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
  IF OLD.state::text IS DISTINCT FROM 'COMPLETED' AND NEW.state::text='COMPLETED' AND NEW.sale_id IS NOT NULL THEN
    BEGIN
      PERFORM public.enqueue_whatsapp_digital_receipt(NEW.sale_id);
    EXCEPTION WHEN OTHERS THEN
      -- Notification intent is optional; it must never roll back completed sale accounting.
      RAISE WARNING 'WhatsApp receipt intent could not be recorded for completed sale request';
    END;
  END IF;
  RETURN NEW;
END $$;
ALTER FUNCTION public.after_pos_sale_whatsapp_outbox() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.after_pos_sale_whatsapp_outbox() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER zz_pos_checkout_whatsapp_outbox_after_complete
AFTER UPDATE OF state ON public.pos_checkout_requests FOR EACH ROW EXECUTE FUNCTION public.after_pos_sale_whatsapp_outbox();

CREATE FUNCTION public.whatsapp_center_summary()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid; s public.outlet_whatsapp_settings%ROWTYPE;
BEGIN
  IF a IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='WHATSAPP_CENTER_READ_DENIED'; END IF;
  o:=public.outlet_settings_current_id(); SELECT * INTO s FROM public.outlet_whatsapp_settings WHERE outlet_id=o;
  RETURN jsonb_build_object('provider_state',coalesce(s.provider_state,'NOT_CONFIGURED'),
    'automation_enabled',coalesce(s.whatsapp_transactions_enabled,false) AND coalesce(s.automatic_receipt_enabled,false),
    'today_sent',(SELECT count(*) FROM public.notification_outbox n WHERE n.outlet_id=o AND n.status='SENT' AND n.sent_at>=date_trunc('day',now())),
    'pending',(SELECT count(*) FROM public.notification_outbox n WHERE n.outlet_id=o AND n.status IN ('PENDING','RETRY','PROCESSING')),
    'failed',(SELECT count(*) FROM public.notification_outbox n WHERE n.outlet_id=o AND n.status='FAILED'),
    'oldest_pending_at',(SELECT min(created_at) FROM public.notification_outbox n WHERE n.outlet_id=o AND n.status IN ('PENDING','RETRY','PROCESSING')),
    'recent',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',n.id,'customer_name',n.payload_snapshot->>'customer_name',
      'destination_masked',CASE WHEN length(n.destination_snapshot)>6 THEN left(n.destination_snapshot,4)||'••••'||right(n.destination_snapshot,3) ELSE '••••' END,
      'sale_number',n.payload_snapshot->>'sale_number','notification_type',n.notification_type,'status',n.status,
      'created_at',n.created_at,'sent_at',n.sent_at) ORDER BY n.created_at DESC),'[]'::jsonb)
      FROM (SELECT * FROM public.notification_outbox WHERE outlet_id=o ORDER BY created_at DESC LIMIT 50) n));
END $$;
ALTER FUNCTION public.whatsapp_center_summary() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whatsapp_center_summary() FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.whatsapp_center_summary() TO authenticated;

CREATE FUNCTION public.whatsapp_sale_delivery_status(p_sale_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid; s public.sales%ROWTYPE; n public.notification_outbox%ROWTYPE;
  m public.members%ROWTYPE; w public.outlet_whatsapp_settings%ROWTYPE;
BEGIN
  IF a IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role,'KASIR'::public.user_role) OR p_sale_id IS NULL THEN RETURN NULL; END IF;
  o:=public.outlet_settings_current_id(); SELECT * INTO s FROM public.sales WHERE id=p_sale_id AND outlet_id=o
    AND source_system='QUENA_POS'::public.pos_sale_source AND status='COMPLETED'::public.pos_sale_status;
  IF NOT FOUND OR (r='KASIR'::public.user_role AND s.cashier_id<>a) THEN RETURN NULL; END IF;
  SELECT * INTO n FROM public.notification_outbox WHERE aggregate_id=s.id AND channel='WHATSAPP' AND notification_type='DIGITAL_RECEIPT';
  IF FOUND THEN RETURN jsonb_build_object('status',n.status,'attempt_count',n.attempt_count,'updated_at',n.updated_at); END IF;
  IF s.member_id IS NULL THEN RETURN jsonb_build_object('status','NO_MEMBER','attempt_count',0,'updated_at',NULL); END IF;
  SELECT * INTO m FROM public.members WHERE id=s.member_id AND outlet_id=s.outlet_id AND status='ACTIVE';
  IF NOT FOUND OR m.phone_normalized IS NULL OR coalesce((SELECT ce.granted FROM public.member_consent_evidence ce
    WHERE ce.member_id=s.member_id AND ce.outlet_id=s.outlet_id AND ce.consent_type='MEMBERSHIP_SERVICE'
    ORDER BY ce.occurred_at DESC,ce.id DESC LIMIT 1),false) IS NOT TRUE THEN
    RETURN jsonb_build_object('status','NOT_ELIGIBLE','attempt_count',0,'updated_at',NULL); END IF;
  SELECT * INTO w FROM public.outlet_whatsapp_settings WHERE outlet_id=o;
  IF NOT FOUND OR NOT w.whatsapp_transactions_enabled OR NOT w.automatic_receipt_enabled
    OR w.provider_state<>'CONNECTED' OR NOT w.public_url_ready THEN
    RETURN jsonb_build_object('status','AUTOMATION_DISABLED','attempt_count',0,'updated_at',NULL); END IF;
  RETURN jsonb_build_object('status','NOT_QUEUED','attempt_count',0,'updated_at',NULL);
END $$;
ALTER FUNCTION public.whatsapp_sale_delivery_status(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whatsapp_sale_delivery_status(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.whatsapp_sale_delivery_status(uuid) TO authenticated;

-- Worker RPCs are service-role-only; there is intentionally no browser mutation path.
CREATE FUNCTION public.notification_outbox_claim(p_limit integer DEFAULT 10)
RETURNS SETOF public.notification_outbox LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' OR p_limit IS NULL OR p_limit<1 OR p_limit>50 THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='NOTIFICATION_WORKER_DENIED'; END IF;
  UPDATE public.notification_outbox SET status='FAILED',failed_at=now(),lease_expires_at=NULL,
    last_error_code='MAX_ATTEMPTS',updated_at=now()
    WHERE status='PROCESSING' AND lease_expires_at<now() AND attempt_count>=5;
  RETURN QUERY WITH due AS (
    SELECT id FROM public.notification_outbox WHERE
      ((status IN ('PENDING','RETRY') AND next_attempt_at<=now()) OR
       (status='PROCESSING' AND lease_expires_at<now())) AND attempt_count<5
    ORDER BY next_attempt_at,created_at FOR UPDATE SKIP LOCKED LIMIT p_limit
  ), updated AS (UPDATE public.notification_outbox n SET status='PROCESSING',attempt_count=n.attempt_count+1,
    last_attempt_at=now(),lease_expires_at=now()+interval '5 minutes',updated_at=now()
    FROM due WHERE n.id=due.id RETURNING n.*), attempt_started AS (
    INSERT INTO public.notification_delivery_attempts(notification_id,attempt_no,provider_key,started_at)
    SELECT u.id,u.attempt_count,coalesce(u.provider_key,'UNCONFIGURED'),now() FROM updated u
    ON CONFLICT(notification_id,attempt_no) DO NOTHING RETURNING notification_id)
    SELECT u.* FROM updated u;
END $$;
ALTER FUNCTION public.notification_outbox_claim(integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.notification_outbox_claim(integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.notification_outbox_claim(integer) TO service_role;

CREATE FUNCTION public.notification_outbox_record_result(p_id uuid,p_result text,p_error_code text DEFAULT NULL,
  p_safe_message text DEFAULT NULL,p_provider_message_id text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE n public.notification_outbox%ROWTYPE; retry_minutes integer[]:=ARRAY[1,5,30,120]; v_status text; v_delay integer;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' OR p_id IS NULL OR p_result NOT IN ('SENT','RETRY','FAILED','BLOCKED')
    OR (p_error_code IS NOT NULL AND p_error_code !~ '^[A-Z0-9_]{1,64}$')
    OR (p_safe_message IS NOT NULL AND (length(p_safe_message)>240 OR p_safe_message ~* '(https?://|/struk/)' OR p_safe_message ~ '[A-Za-z0-9_-]{43}'))
    OR (p_provider_message_id IS NOT NULL AND (length(p_provider_message_id)>180 OR p_provider_message_id ~* 'https?://')) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='NOTIFICATION_WORKER_DENIED'; END IF;
  SELECT * INTO n FROM public.notification_outbox WHERE id=p_id FOR UPDATE;
  IF NOT FOUND OR n.status<>'PROCESSING' THEN RETURN false; END IF;
  v_status:=CASE WHEN p_result='RETRY' AND n.attempt_count<5 THEN 'RETRY' WHEN p_result='RETRY' THEN 'FAILED' ELSE p_result END;
  v_delay:=retry_minutes[least(greatest(n.attempt_count,1),array_length(retry_minutes,1))];
  UPDATE public.notification_outbox SET status=v_status,last_error_code=CASE WHEN v_status='SENT' THEN NULL ELSE p_error_code END,
    sent_at=CASE WHEN v_status='SENT' THEN now() ELSE sent_at END,
    failed_at=CASE WHEN v_status='FAILED' THEN now() ELSE failed_at END,
    next_attempt_at=CASE WHEN v_status='RETRY' THEN now()+make_interval(mins=>v_delay) ELSE next_attempt_at END,
    lease_expires_at=NULL,updated_at=now() WHERE id=p_id;
  INSERT INTO public.notification_delivery_attempts(notification_id,attempt_no,provider_key,started_at,completed_at,result,
    provider_message_id,normalized_error_code,safe_error_message)
    VALUES(p_id,n.attempt_count,coalesce(n.provider_key,'UNCONFIGURED'),coalesce(n.last_attempt_at,now()),now(),v_status,p_provider_message_id,p_error_code,p_safe_message)
    ON CONFLICT(notification_id,attempt_no) DO UPDATE SET completed_at=EXCLUDED.completed_at,result=EXCLUDED.result,
      provider_message_id=EXCLUDED.provider_message_id,normalized_error_code=EXCLUDED.normalized_error_code,
      safe_error_message=EXCLUDED.safe_error_message;
  RETURN true;
END $$;
ALTER FUNCTION public.notification_outbox_record_result(uuid,text,text,text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.notification_outbox_record_result(uuid,text,text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.notification_outbox_record_result(uuid,text,text,text,text) TO service_role;

CREATE FUNCTION public.whatsapp_notification_cancel(p_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid; changed integer;
BEGIN
  IF a IS NULL OR r IS DISTINCT FROM 'OWNER'::public.user_role OR p_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='WHATSAPP_CANCEL_DENIED'; END IF;
  o:=public.outlet_settings_current_id();
  UPDATE public.notification_outbox SET status='CANCELLED',cancelled_at=now(),cancelled_by=a,updated_at=now(),lease_expires_at=NULL
    WHERE id=p_id AND outlet_id=o AND status IN ('PENDING','RETRY');
  GET DIAGNOSTICS changed=ROW_COUNT; RETURN changed=1;
END $$;
ALTER FUNCTION public.whatsapp_notification_cancel(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whatsapp_notification_cancel(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.whatsapp_notification_cancel(uuid) TO authenticated;

COMMIT;
