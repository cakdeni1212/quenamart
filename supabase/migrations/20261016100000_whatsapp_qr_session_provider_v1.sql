BEGIN;

-- Provider connection/control data only. No message is sent or queued here.
ALTER TABLE public.outlet_whatsapp_settings
  DROP CONSTRAINT outlet_whatsapp_settings_provider_state_check,
  ADD CONSTRAINT outlet_whatsapp_settings_provider_state_check
    CHECK (provider_state IN ('NOT_CONFIGURED','DISCONNECTED','CONNECTING','WAITING_QR','CONNECTED','DEGRADED','ERROR'));

CREATE TABLE public.whatsapp_provider_connections (
  outlet_id uuid PRIMARY KEY REFERENCES public.outlets(id) ON DELETE RESTRICT,
  provider_key text NOT NULL DEFAULT 'QR_SESSION' CHECK(provider_key='QR_SESSION'),
  connection_state text NOT NULL DEFAULT 'NOT_CONFIGURED'
    CHECK(connection_state IN ('NOT_CONFIGURED','WAITING_QR','CONNECTING','CONNECTED','DISCONNECTED','ERROR')),
  connected_number_masked text CHECK(connected_number_masked IS NULL OR length(connected_number_masked)<=32),
  qr_payload_encrypted text,
  qr_expires_at timestamptz,
  last_connected_at timestamptz,
  last_disconnected_at timestamptz,
  last_error_code text CHECK(last_error_code IS NULL OR last_error_code IN ('SESSION_LOGGED_OUT','QR_EXPIRED','NETWORK_ERROR','AUTH_FAILURE','WORKER_STALE','UNKNOWN_PROVIDER_ERROR')),
  last_heartbeat_at timestamptz,
  worker_lease_owner uuid,
  worker_lease_expires_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((qr_payload_encrypted IS NULL) = (qr_expires_at IS NULL))
);
ALTER TABLE public.whatsapp_provider_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.whatsapp_provider_connections FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.whatsapp_provider_connections FROM PUBLIC,anon,authenticated,service_role;

CREATE TABLE public.whatsapp_provider_commands (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  command_type text NOT NULL CHECK(command_type IN ('CONNECT','DISCONNECT','RECONNECT')),
  status text NOT NULL DEFAULT 'QUEUED' CHECK(status IN ('QUEUED','CLAIMED','COMPLETED','FAILED')),
  requested_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  requested_at timestamptz NOT NULL DEFAULT now(),
  claimed_by uuid,
  claimed_at timestamptz,
  completed_at timestamptz,
  safe_result_code text CHECK(safe_result_code IS NULL OR safe_result_code ~ '^[A-Z0-9_]{1,64}$')
);
ALTER TABLE public.whatsapp_provider_commands ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.whatsapp_provider_commands FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.whatsapp_provider_commands FROM PUBLIC,anon,authenticated,service_role;
CREATE INDEX whatsapp_provider_commands_queue_idx ON public.whatsapp_provider_commands(outlet_id,requested_at)
  WHERE status='QUEUED';
CREATE INDEX whatsapp_provider_connections_heartbeat_idx ON public.whatsapp_provider_connections(last_heartbeat_at);

CREATE FUNCTION public.whatsapp_provider_connection_read()
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid; c public.whatsapp_provider_connections%ROWTYPE;
  stale boolean;
BEGIN
  IF a IS NULL OR r NOT IN ('OWNER'::public.user_role,'ADMIN'::public.user_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='WHATSAPP_PROVIDER_READ_DENIED';
  END IF;
  o:=public.outlet_settings_current_id();
  SELECT * INTO c FROM public.whatsapp_provider_connections WHERE outlet_id=o;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('outlet_id',o,'provider_key','QR_SESSION','connection_state','NOT_CONFIGURED',
      'connected_number_masked',NULL,'last_connected_at',NULL,'last_disconnected_at',NULL,'last_error_code',NULL,
      'last_heartbeat_at',NULL,'worker_active',false,'qr_expires_at',NULL);
  END IF;
  stale:=c.last_heartbeat_at IS NULL OR c.last_heartbeat_at<now()-interval '90 seconds';
  RETURN jsonb_build_object('outlet_id',o,'provider_key',c.provider_key,
    'connection_state',CASE WHEN stale AND c.connection_state IN ('CONNECTED','WAITING_QR','CONNECTING') THEN 'DISCONNECTED' ELSE c.connection_state END,
    'connected_number_masked',c.connected_number_masked,'last_connected_at',c.last_connected_at,
    'last_disconnected_at',c.last_disconnected_at,'last_error_code',CASE WHEN stale AND c.connection_state IN ('CONNECTED','WAITING_QR','CONNECTING') THEN 'WORKER_STALE' ELSE c.last_error_code END,
    'last_heartbeat_at',c.last_heartbeat_at,'worker_active',NOT stale,
    'qr_expires_at',CASE WHEN c.qr_expires_at>now() THEN c.qr_expires_at ELSE NULL END);
END $$;
ALTER FUNCTION public.whatsapp_provider_connection_read() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whatsapp_provider_connection_read() FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.whatsapp_provider_connection_read() TO authenticated;

CREATE FUNCTION public.whatsapp_provider_qr_read()
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid; c public.whatsapp_provider_connections%ROWTYPE;
BEGIN
  IF a IS NULL OR r IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='WHATSAPP_PROVIDER_QR_DENIED';
  END IF;
  o:=public.outlet_settings_current_id();
  SELECT * INTO c FROM public.whatsapp_provider_connections WHERE outlet_id=o FOR UPDATE;
  IF NOT FOUND OR c.connection_state<>'WAITING_QR' OR c.qr_expires_at<=now() OR c.qr_payload_encrypted IS NULL THEN
    IF FOUND AND c.qr_expires_at<=now() THEN
      UPDATE public.whatsapp_provider_connections SET connection_state='CONNECTING',qr_payload_encrypted=NULL,qr_expires_at=NULL,
        last_error_code='QR_EXPIRED',updated_at=now() WHERE outlet_id=o;
      UPDATE public.outlet_whatsapp_settings SET provider_state='CONNECTING',updated_at=now() WHERE outlet_id=o;
    END IF;
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object('encrypted_payload',c.qr_payload_encrypted,'expires_at',c.qr_expires_at);
END $$;
ALTER FUNCTION public.whatsapp_provider_qr_read() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whatsapp_provider_qr_read() FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.whatsapp_provider_qr_read() TO authenticated;

CREATE FUNCTION public.whatsapp_provider_control_request(p_command text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid; c public.whatsapp_provider_commands%ROWTYPE;
BEGIN
  IF a IS NULL OR r IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='WHATSAPP_PROVIDER_CONTROL_DENIED';
  END IF;
  IF p_command NOT IN ('CONNECT','DISCONNECT','RECONNECT') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='WHATSAPP_PROVIDER_COMMAND_INVALID';
  END IF;
  o:=public.outlet_settings_current_id();
  INSERT INTO public.whatsapp_provider_connections(outlet_id) VALUES(o) ON CONFLICT DO NOTHING;
  IF NOT EXISTS(SELECT 1 FROM public.whatsapp_provider_connections WHERE outlet_id=o
    AND worker_lease_expires_at>now()) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='WHATSAPP_PROVIDER_WORKER_OFFLINE';
  END IF;
  SELECT * INTO c FROM public.whatsapp_provider_commands WHERE outlet_id=o AND status IN ('QUEUED','CLAIMED')
    ORDER BY requested_at DESC LIMIT 1 FOR UPDATE;
  IF FOUND THEN
    IF c.command_type<>p_command THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='WHATSAPP_PROVIDER_COMMAND_IN_PROGRESS'; END IF;
    RETURN jsonb_build_object('command_id',c.id,'status',c.status);
  END IF;
  INSERT INTO public.whatsapp_provider_commands(outlet_id,command_type,requested_by)
    VALUES(o,p_command,a) RETURNING * INTO c;
  RETURN jsonb_build_object('command_id',c.id,'status',c.status);
END $$;
ALTER FUNCTION public.whatsapp_provider_control_request(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whatsapp_provider_control_request(text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.whatsapp_provider_control_request(text) TO authenticated;

CREATE FUNCTION public.whatsapp_provider_worker_context()
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE o uuid;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='WHATSAPP_WORKER_DENIED'; END IF;
  o:=public.outlet_settings_current_id();
  INSERT INTO public.whatsapp_provider_connections(outlet_id) VALUES(o) ON CONFLICT DO NOTHING;
  RETURN jsonb_build_object('outlet_id',o);
END $$;
ALTER FUNCTION public.whatsapp_provider_worker_context() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whatsapp_provider_worker_context() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.whatsapp_provider_worker_context() TO service_role;

CREATE FUNCTION public.whatsapp_provider_worker_heartbeat(p_outlet_id uuid,p_worker_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE c public.whatsapp_provider_connections%ROWTYPE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' OR p_worker_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='WHATSAPP_WORKER_DENIED'; END IF;
  SELECT * INTO c FROM public.whatsapp_provider_connections WHERE outlet_id=p_outlet_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='WHATSAPP_WORKER_OUTLET_INVALID'; END IF;
  IF c.worker_lease_expires_at>now() AND c.worker_lease_owner IS DISTINCT FROM p_worker_id THEN RETURN false; END IF;
  UPDATE public.whatsapp_provider_connections SET worker_lease_owner=p_worker_id,worker_lease_expires_at=now()+interval '90 seconds',
    last_heartbeat_at=now(),
    connection_state=CASE WHEN connection_state='WAITING_QR' AND qr_expires_at<=now() THEN 'CONNECTING' ELSE connection_state END,
    qr_payload_encrypted=CASE WHEN connection_state='WAITING_QR' AND qr_expires_at<=now() THEN NULL ELSE qr_payload_encrypted END,
    qr_expires_at=CASE WHEN connection_state='WAITING_QR' AND qr_expires_at<=now() THEN NULL ELSE qr_expires_at END,
    last_error_code=CASE WHEN connection_state='WAITING_QR' AND qr_expires_at<=now() THEN 'QR_EXPIRED' ELSE last_error_code END,
    updated_at=now() WHERE outlet_id=p_outlet_id;
  IF c.connection_state='WAITING_QR' AND c.qr_expires_at<=now() THEN
    UPDATE public.outlet_whatsapp_settings SET provider_state='CONNECTING',updated_at=now() WHERE outlet_id=p_outlet_id;
  END IF;
  RETURN true;
END $$;
ALTER FUNCTION public.whatsapp_provider_worker_heartbeat(uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whatsapp_provider_worker_heartbeat(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.whatsapp_provider_worker_heartbeat(uuid,uuid) TO service_role;

CREATE FUNCTION public.whatsapp_provider_worker_release(p_outlet_id uuid,p_worker_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='WHATSAPP_WORKER_DENIED'; END IF;
  UPDATE public.whatsapp_provider_connections SET worker_lease_owner=NULL,worker_lease_expires_at=NULL,last_heartbeat_at=NULL,updated_at=now()
    WHERE outlet_id=p_outlet_id AND worker_lease_owner=p_worker_id;
  RETURN FOUND;
END $$;
ALTER FUNCTION public.whatsapp_provider_worker_release(uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whatsapp_provider_worker_release(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.whatsapp_provider_worker_release(uuid,uuid) TO service_role;

CREATE FUNCTION public.whatsapp_provider_command_claim(p_outlet_id uuid,p_worker_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE c public.whatsapp_provider_commands%ROWTYPE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='WHATSAPP_WORKER_DENIED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.whatsapp_provider_connections WHERE outlet_id=p_outlet_id
    AND worker_lease_owner=p_worker_id AND worker_lease_expires_at>now()) THEN RETURN NULL; END IF;
  UPDATE public.whatsapp_provider_commands SET status='QUEUED',claimed_by=NULL,claimed_at=NULL
    WHERE outlet_id=p_outlet_id AND status='CLAIMED' AND claimed_at<now()-interval '90 seconds';
  SELECT * INTO c FROM public.whatsapp_provider_commands WHERE outlet_id=p_outlet_id AND status='QUEUED'
    ORDER BY requested_at,id LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN NULL; END IF;
  UPDATE public.whatsapp_provider_commands SET status='CLAIMED',claimed_by=p_worker_id,claimed_at=now() WHERE id=c.id;
  RETURN jsonb_build_object('id',c.id,'command_type',c.command_type);
END $$;
ALTER FUNCTION public.whatsapp_provider_command_claim(uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whatsapp_provider_command_claim(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.whatsapp_provider_command_claim(uuid,uuid) TO service_role;

CREATE FUNCTION public.whatsapp_provider_worker_state(p_outlet_id uuid,p_worker_id uuid,p_state text,
  p_qr_payload_encrypted text DEFAULT NULL,p_qr_expires_at timestamptz DEFAULT NULL,p_masked_number text DEFAULT NULL,p_error_code text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE c public.whatsapp_provider_connections%ROWTYPE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='WHATSAPP_WORKER_DENIED'; END IF;
  IF p_state NOT IN ('NOT_CONFIGURED','WAITING_QR','CONNECTING','CONNECTED','DISCONNECTED','ERROR')
    OR (p_state='WAITING_QR' AND (p_qr_payload_encrypted IS NULL OR p_qr_expires_at IS NULL OR p_qr_expires_at<=now() OR p_qr_expires_at>now()+interval '2 minutes'))
    OR (p_state<>'WAITING_QR' AND (p_qr_payload_encrypted IS NOT NULL OR p_qr_expires_at IS NOT NULL))
    OR p_error_code IS NOT NULL AND p_error_code NOT IN ('SESSION_LOGGED_OUT','QR_EXPIRED','NETWORK_ERROR','AUTH_FAILURE','WORKER_STALE','UNKNOWN_PROVIDER_ERROR') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='WHATSAPP_WORKER_STATE_INVALID';
  END IF;
  SELECT * INTO c FROM public.whatsapp_provider_connections WHERE outlet_id=p_outlet_id FOR UPDATE;
  IF NOT FOUND OR c.worker_lease_owner IS DISTINCT FROM p_worker_id OR c.worker_lease_expires_at<=now() THEN RETURN false; END IF;
  UPDATE public.whatsapp_provider_connections SET provider_key='QR_SESSION',connection_state=p_state,
    connected_number_masked=CASE WHEN p_state='CONNECTED' THEN p_masked_number ELSE NULL END,
    qr_payload_encrypted=p_qr_payload_encrypted,qr_expires_at=p_qr_expires_at,
    last_connected_at=CASE WHEN p_state='CONNECTED' AND c.connection_state<>'CONNECTED' THEN now() ELSE c.last_connected_at END,
    last_disconnected_at=CASE WHEN p_state='DISCONNECTED' AND c.connection_state<>'DISCONNECTED' THEN now() ELSE c.last_disconnected_at END,
    last_error_code=p_error_code,updated_at=now() WHERE outlet_id=p_outlet_id;
  INSERT INTO public.outlet_whatsapp_settings(outlet_id,provider_state,provider_key)
    VALUES(p_outlet_id,CASE WHEN p_state='NOT_CONFIGURED' THEN 'DISCONNECTED' ELSE p_state END,'QR_SESSION')
    ON CONFLICT(outlet_id) DO UPDATE SET provider_state=excluded.provider_state,provider_key='QR_SESSION',updated_at=now();
  RETURN true;
END $$;
ALTER FUNCTION public.whatsapp_provider_worker_state(uuid,uuid,text,text,timestamptz,text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whatsapp_provider_worker_state(uuid,uuid,text,text,timestamptz,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.whatsapp_provider_worker_state(uuid,uuid,text,text,timestamptz,text,text) TO service_role;

CREATE FUNCTION public.whatsapp_provider_command_complete(p_command_id uuid,p_worker_id uuid,p_success boolean,p_result_code text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='WHATSAPP_WORKER_DENIED'; END IF;
  UPDATE public.whatsapp_provider_commands SET status=CASE WHEN p_success THEN 'COMPLETED' ELSE 'FAILED' END,
    completed_at=now(),safe_result_code=p_result_code
  WHERE id=p_command_id AND status='CLAIMED' AND claimed_by=p_worker_id;
  RETURN FOUND;
END $$;
ALTER FUNCTION public.whatsapp_provider_command_complete(uuid,uuid,boolean,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whatsapp_provider_command_complete(uuid,uuid,boolean,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.whatsapp_provider_command_complete(uuid,uuid,boolean,text) TO service_role;

COMMIT;
