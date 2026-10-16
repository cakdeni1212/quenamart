\set ON_ERROR_STOP on
CREATE FUNCTION pg_temp.assert_waha(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION '%',message; END IF; END $$;
\set outlet '10000000-0000-4000-8000-000000000001'
\set owner '10000000-0000-4000-8000-000000000010'
\set admin '10000000-0000-4000-8000-000000000011'

SELECT set_config('quena.test.actor',:'owner',false);
SELECT set_config('quena.test.role','OWNER',false);
SELECT set_config('request.jwt.claim.role','authenticated',false);
SET ROLE authenticated;
SELECT public.whatsapp_provider_control_request('CONNECT') AS connect_id \gset
SELECT public.whatsapp_provider_control_request('DISCONNECT') AS disconnect_id \gset
RESET ROLE;
SELECT pg_temp.assert_waha((SELECT count(*)=2 FROM public.whatsapp_provider_control_events
  WHERE outlet_id=:'outlet' AND actor_id=:'owner' AND command_type IN ('CONNECT','DISCONNECT')),
  'Owner control requests were not recorded');

SELECT set_config('quena.test.actor',:'admin',false);
SELECT set_config('quena.test.role','ADMIN',false);
SET ROLE authenticated;
DO $$ BEGIN
  PERFORM public.whatsapp_provider_control_request('CONNECT');
  RAISE EXCEPTION 'ADMIN requested provider control';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;

SELECT set_config('request.jwt.claim.role','anon',false);
SET ROLE anon;
DO $$ BEGIN
  PERFORM public.whatsapp_provider_control_request('CONNECT');
  RAISE EXCEPTION 'anonymous user requested provider control';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;

SELECT pg_temp.assert_waha(
  NOT has_table_privilege('anon','public.whatsapp_provider_control_events','SELECT')
  AND NOT has_table_privilege('authenticated','public.whatsapp_provider_control_events','SELECT')
  AND NOT has_table_privilege('authenticated','public.whatsapp_provider_control_events','INSERT')
  AND NOT has_function_privilege('anon','public.whatsapp_provider_control_request(text)','EXECUTE'),
  'Browser or anonymous role received direct audit access');
SELECT pg_temp.assert_waha(NOT EXISTS(SELECT 1 FROM public.notification_outbox WHERE status='SENT'),
  'WAHA connectivity audit mutated notification delivery');
SELECT 'WHATSAPP_WAHA_CONTROL_RUNTIME_PASS' AS result;
