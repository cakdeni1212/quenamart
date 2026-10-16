\set ON_ERROR_STOP on
CREATE FUNCTION pg_temp.assert_qr(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION '%',message; END IF; END $$;
\set outlet '10000000-0000-4000-8000-000000000001'
\set owner '10000000-0000-4000-8000-000000000010'
\set admin '10000000-0000-4000-8000-000000000011'
\set worker '50000000-0000-4000-8000-000000000001'
\set other_worker '50000000-0000-4000-8000-000000000002'
SELECT count(*) AS sent_before FROM public.notification_outbox WHERE status='SENT' \gset

SELECT pg_temp.assert_qr((SELECT count(*)=0 FROM public.whatsapp_provider_connections),
  'Migration or read unexpectedly created provider connection state');
CREATE TEMP TABLE whatsapp_settings_before AS SELECT outlet_id,whatsapp_transactions_enabled,automatic_receipt_enabled,
  include_points_earned,include_points_redeemed,include_points_balance,public_url_ready
  FROM public.outlet_whatsapp_settings WHERE outlet_id=:'outlet';
SELECT set_config('quena.test.actor',:'owner',false);
SELECT set_config('quena.test.role','OWNER',false);
SELECT set_config('request.jwt.claim.role','authenticated',false);
SET ROLE authenticated;
SELECT pg_temp.assert_qr(public.whatsapp_provider_connection_read()->>'connection_state'='NOT_CONFIGURED',
  'Owner does not see initial disconnected state');
RESET ROLE;
SELECT pg_temp.assert_qr((SELECT count(*)=0 FROM public.whatsapp_provider_connections),
  'Read path mutated provider state');
SET ROLE authenticated;
DO $$ BEGIN
  PERFORM public.whatsapp_provider_control_request('CONNECT');
  RAISE EXCEPTION 'Owner queued a command while worker was offline';
EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END $$;
RESET ROLE;

SELECT set_config('request.jwt.claim.role','service_role',false);
SET ROLE service_role;
SELECT pg_temp.assert_qr((public.whatsapp_provider_worker_context()->>'outlet_id')=:'outlet',
  'Worker context did not resolve active outlet');
SELECT pg_temp.assert_qr(public.whatsapp_provider_worker_heartbeat(:'outlet',:'worker'),
  'First worker could not acquire lease');
SELECT pg_temp.assert_qr(NOT public.whatsapp_provider_worker_heartbeat(:'outlet',:'other_worker'),
  'Second worker acquired an active outlet lease');
RESET ROLE;

SELECT set_config('quena.test.actor',:'owner',false);
SELECT set_config('quena.test.role','OWNER',false);
SELECT set_config('request.jwt.claim.role','authenticated',false);
SET ROLE authenticated;
SELECT (public.whatsapp_provider_control_request('CONNECT')->>'command_id') AS connect_id \gset
SELECT (public.whatsapp_provider_control_request('CONNECT')->>'command_id') AS duplicate_id \gset
SELECT pg_temp.assert_qr(:'connect_id'=:'duplicate_id','Duplicate owner click created a second command');
RESET ROLE;

SELECT set_config('request.jwt.claim.role','service_role',false);
SET ROLE service_role;
SELECT (public.whatsapp_provider_command_claim(:'outlet',:'worker')->>'id') AS claimed_id \gset
SELECT pg_temp.assert_qr(:'claimed_id'=:'connect_id','Worker did not consume CONNECT command');
SELECT pg_temp.assert_qr(public.whatsapp_provider_command_claim(:'outlet',:'worker') IS NULL,
  'Worker claimed the same command twice');
SELECT pg_temp.assert_qr(public.whatsapp_provider_worker_state(:'outlet',:'worker','WAITING_QR',
  'v1.dGVzdA.c2lnbmF0dXJl.ZW5jcnlwdGVk',now()+interval '45 seconds',NULL,NULL),
  'Worker could not publish temporary encrypted QR');
SELECT pg_temp.assert_qr(public.whatsapp_provider_command_complete(:'connect_id',:'worker',true,NULL),
  'Worker could not complete command');
RESET ROLE;

SELECT set_config('quena.test.actor',:'owner',false);
SELECT set_config('quena.test.role','OWNER',false);
SELECT set_config('request.jwt.claim.role','authenticated',false);
SET ROLE authenticated;
SELECT pg_temp.assert_qr(public.whatsapp_provider_qr_read()->>'encrypted_payload'='v1.dGVzdA.c2lnbmF0dXJl.ZW5jcnlwdGVk',
  'Owner did not receive only the temporary encrypted QR handoff');
RESET ROLE;

SELECT set_config('quena.test.actor',:'admin',false);
SELECT set_config('quena.test.role','ADMIN',false);
SET ROLE authenticated;
SELECT pg_temp.assert_qr(public.whatsapp_provider_connection_read()->>'connection_state'='WAITING_QR',
  'Admin status read was denied');
DO $$ BEGIN
  PERFORM public.whatsapp_provider_qr_read();
  RAISE EXCEPTION 'Admin retrieved pairing QR';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
DO $$ BEGIN
  PERFORM public.whatsapp_provider_control_request('CONNECT');
  RAISE EXCEPTION 'Admin requested provider control';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;

SELECT set_config('quena.test.actor',:'owner',false);
SELECT set_config('quena.test.role','OWNER',false);
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.role','authenticated',false);
RESET ROLE;
SELECT set_config('request.jwt.claim.role','service_role',false);
SET ROLE service_role;
SELECT pg_temp.assert_qr(public.whatsapp_provider_worker_state(:'outlet',:'worker','CONNECTED',NULL,NULL,'62••••••7890',NULL),
  'Worker could not set connected state');
RESET ROLE;
SELECT pg_temp.assert_qr((SELECT qr_payload_encrypted IS NULL AND qr_expires_at IS NULL AND connected_number_masked='62••••••7890'
  FROM public.whatsapp_provider_connections WHERE outlet_id=:'outlet'),'Connected state retained QR or lost masked number');
SELECT pg_temp.assert_qr(NOT EXISTS(SELECT 1 FROM public.outlet_whatsapp_settings s JOIN whatsapp_settings_before b USING(outlet_id)
  WHERE (s.whatsapp_transactions_enabled,s.automatic_receipt_enabled,s.include_points_earned,s.include_points_redeemed,s.include_points_balance,s.public_url_ready)
    IS DISTINCT FROM (b.whatsapp_transactions_enabled,b.automatic_receipt_enabled,b.include_points_earned,b.include_points_redeemed,b.include_points_balance,b.public_url_ready)),
  'Provider connection changed configured settings/public URL unexpectedly');
SET ROLE service_role;
SELECT pg_temp.assert_qr(public.whatsapp_provider_worker_state(:'outlet',:'worker','CONNECTING',NULL,NULL,NULL,'NETWORK_ERROR'),
  'Temporary disconnect state was not accepted');
RESET ROLE;
UPDATE public.whatsapp_provider_connections SET last_heartbeat_at=now()-interval '2 minutes',worker_lease_expires_at=now()-interval '2 minutes' WHERE outlet_id=:'outlet';

SELECT set_config('quena.test.actor',:'owner',false);
SELECT set_config('quena.test.role','OWNER',false);
SET ROLE authenticated;
SELECT pg_temp.assert_qr(public.whatsapp_provider_connection_read()->>'connection_state'='DISCONNECTED'
  AND public.whatsapp_provider_connection_read()->>'last_error_code'='WORKER_STALE',
  'Stale worker continued to appear connected');
DO $$ BEGIN
  PERFORM public.whatsapp_provider_control_request('DISCONNECT');
  RAISE EXCEPTION 'Owner queued a command while worker was stale';
EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END $$;
RESET ROLE;

SELECT set_config('request.jwt.claim.role','service_role',false);
SET ROLE service_role;
SELECT pg_temp.assert_qr(public.whatsapp_provider_worker_heartbeat(:'outlet',:'worker'),
  'Worker failed to renew its lease');
RESET ROLE;
SELECT set_config('quena.test.actor',:'owner',false);
SELECT set_config('quena.test.role','OWNER',false);
SELECT set_config('request.jwt.claim.role','authenticated',false);
SET ROLE authenticated;
SELECT (public.whatsapp_provider_control_request('DISCONNECT')->>'command_id') AS disconnect_id \gset
RESET ROLE;
SELECT set_config('request.jwt.claim.role','service_role',false);
SET ROLE service_role;
SELECT (public.whatsapp_provider_command_claim(:'outlet',:'worker')->>'id') AS disconnect_claim \gset
SELECT pg_temp.assert_qr(:'disconnect_claim'=:'disconnect_id','DISCONNECT command not claimed once');
SELECT pg_temp.assert_qr(public.whatsapp_provider_worker_state(:'outlet',:'worker','DISCONNECTED',NULL,NULL,NULL,'SESSION_LOGGED_OUT'),
  'Worker could not unlink session');
SELECT pg_temp.assert_qr(public.whatsapp_provider_command_complete(:'disconnect_id',:'worker',true,NULL),
  'Worker could not complete DISCONNECT');
RESET ROLE;
SELECT pg_temp.assert_qr((SELECT count(*)=:sent_before::integer FROM public.notification_outbox WHERE status='SENT'),
  'QR provider foundation changed the notification outbox SENT count');

SELECT pg_temp.assert_qr(NOT has_table_privilege('anon','public.whatsapp_provider_connections','SELECT')
  AND NOT has_table_privilege('authenticated','public.whatsapp_provider_connections','UPDATE')
  AND NOT has_table_privilege('service_role','public.whatsapp_provider_connections','UPDATE'),
  'Browser or service role received direct connection table access');
SELECT pg_temp.assert_qr((SELECT count(*)=2 FROM public.whatsapp_provider_commands WHERE requested_by=:'owner'),
  'Owner control actions were not retained as command audit evidence');
SELECT 'WHATSAPP_QR_SESSION_RUNTIME_PASS' AS result;
