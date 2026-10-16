BEGIN;

-- WAHA owns connection/session state. Quena retains only owner control audit
-- evidence; no QR, session credential, worker lease, or queue is stored here.
CREATE TABLE public.whatsapp_provider_control_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id uuid NOT NULL REFERENCES public.outlets(id) ON DELETE RESTRICT,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  command_type text NOT NULL CHECK (command_type IN ('CONNECT','DISCONNECT','RECONNECT')),
  requested_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.whatsapp_provider_control_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.whatsapp_provider_control_events FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.whatsapp_provider_control_events FROM PUBLIC,anon,authenticated,service_role;
CREATE INDEX whatsapp_provider_control_events_outlet_time_idx
  ON public.whatsapp_provider_control_events(outlet_id,requested_at DESC);

CREATE FUNCTION public.whatsapp_provider_control_request(p_command text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE a uuid:=auth.uid(); r public.user_role:=public.current_active_user_role(); o uuid; event_id uuid;
BEGIN
  IF a IS NULL OR r IS DISTINCT FROM 'OWNER'::public.user_role THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='WHATSAPP_PROVIDER_CONTROL_DENIED';
  END IF;
  IF p_command NOT IN ('CONNECT','DISCONNECT','RECONNECT') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='WHATSAPP_PROVIDER_COMMAND_INVALID';
  END IF;
  o:=public.outlet_settings_current_id();
  INSERT INTO public.whatsapp_provider_control_events(outlet_id,actor_id,command_type)
    VALUES(o,a,p_command) RETURNING id INTO event_id;
  RETURN event_id;
END $$;
ALTER FUNCTION public.whatsapp_provider_control_request(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whatsapp_provider_control_request(text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.whatsapp_provider_control_request(text) TO authenticated;

COMMIT;
