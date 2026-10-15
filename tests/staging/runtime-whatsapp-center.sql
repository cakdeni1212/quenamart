\set ON_ERROR_STOP on
\set outlet_id '10000000-0000-4000-8000-000000000001'
\set sale_id '10000000-0000-4000-8000-000000000070'
UPDATE public.sale_public_receipts SET status='UNISSUED',token_hash=NULL,revoked_at=NULL WHERE sale_id=:'sale_id';
CREATE FUNCTION pg_temp.assert_whatsapp(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION '%',message; END IF; END $$;

-- New settings never enable messaging. Member checkout already completed with
-- no notification side effect while the system default was OFF.
SELECT pg_temp.assert_whatsapp((SELECT count(*)=0 FROM public.notification_outbox),'Default-off checkout created a notification');
SELECT pg_temp.assert_whatsapp(NOT has_table_privilege('anon','public.notification_outbox','SELECT')
  AND NOT has_table_privilege('authenticated','public.notification_outbox','INSERT')
  AND NOT has_table_privilege('authenticated','public.notification_outbox','UPDATE'),
  'Browser roles gained direct outbox access');

SELECT set_config('quena.test.actor','10000000-0000-4000-8000-000000000010',false);
SELECT set_config('quena.test.role','OWNER',false);
SET ROLE authenticated;
SELECT pg_temp.assert_whatsapp((public.whatsapp_settings_read()->>'provider_state')='NOT_CONFIGURED'
  AND NOT (public.whatsapp_settings_read()->>'whatsapp_transactions_enabled')::boolean
  AND NOT (public.whatsapp_settings_read()->>'automatic_receipt_enabled')::boolean,
  'WhatsApp defaults are not safely disabled');
SELECT public.whatsapp_settings_update(:'outlet_id','{"whatsapp_transactions_enabled":true,"automatic_receipt_enabled":true,
 "include_points_earned":true,"include_points_redeemed":true,"include_points_balance":true}'::jsonb);
RESET ROLE;
SELECT pg_temp.assert_whatsapp((SELECT count(*)=1 FROM public.whatsapp_settings_events WHERE outlet_id=:'outlet_id'),
  'Settings change has no actor audit evidence');
UPDATE public.pos_checkout_requests SET state='PENDING' WHERE request_id='10000000-0000-4000-8000-000000000060';
UPDATE public.pos_checkout_requests SET state='COMPLETED' WHERE request_id='10000000-0000-4000-8000-000000000060';
SELECT pg_temp.assert_whatsapp(NOT EXISTS(SELECT 1 FROM public.notification_outbox WHERE aggregate_id=:'sale_id'),
  'Enabled automation created a misleading job while provider remained unconfigured');

-- Connected/readiness is infrastructure-owned and changed only in this disposable
-- cluster to exercise the positive enqueue branch. It cannot be set via the UI RPC.
UPDATE public.outlet_whatsapp_settings SET provider_state='CONNECTED',provider_key='FAKE_TEST_ADAPTER',public_url_ready=true
WHERE outlet_id=:'outlet_id';
UPDATE public.pos_checkout_requests SET state='PENDING' WHERE request_id='10000000-0000-4000-8000-000000000060';
UPDATE public.pos_checkout_requests SET state='COMPLETED' WHERE request_id='10000000-0000-4000-8000-000000000060';
SELECT pg_temp.assert_whatsapp((SELECT count(*)=1 FROM public.notification_outbox WHERE aggregate_id=:'sale_id'
  AND status='PENDING' AND channel='WHATSAPP' AND notification_type='DIGITAL_RECEIPT'),
  'Eligible native completed sale did not enqueue exactly one job');
SELECT pg_temp.assert_whatsapp(NOT ((SELECT payload_snapshot FROM public.notification_outbox WHERE aggregate_id=:'sale_id') ?| ARRAY['receipt_url','receipt_token','token_hash','phone','email','cogs','wac','hpp','profit']),
  'Delivery snapshot contains prohibited bearer or finance fields');
SELECT pg_temp.assert_whatsapp((SELECT payload_snapshot->>'contract_version'='DIGITAL_RECEIPT_V1'
  AND payload_snapshot->>'receipt_reference' IS NOT NULL FROM public.notification_outbox WHERE aggregate_id=:'sale_id'),
  'Delivery contract version or safe receipt reference missing');
UPDATE public.pos_checkout_requests SET state='PENDING' WHERE request_id='10000000-0000-4000-8000-000000000060';
UPDATE public.pos_checkout_requests SET state='COMPLETED' WHERE request_id='10000000-0000-4000-8000-000000000060';
SELECT pg_temp.assert_whatsapp((SELECT count(*)=1 FROM public.notification_outbox WHERE aggregate_id=:'sale_id'),
  'Checkout replay/state transition duplicated outbox job');
UPDATE public.pos_checkout_requests SET state='PENDING' WHERE request_id='10000000-0000-4000-8000-000000000063';
UPDATE public.pos_checkout_requests SET state='COMPLETED' WHERE request_id='10000000-0000-4000-8000-000000000063';
SELECT pg_temp.assert_whatsapp(NOT EXISTS(SELECT 1 FROM public.notification_outbox WHERE aggregate_id='10000000-0000-4000-8000-000000000071'),
  'IPOS_IMPORT sale created a WhatsApp receipt job');
INSERT INTO public.member_consent_evidence(member_id,outlet_id,consent_type,granted,source,policy_version,actor_id,request_id,occurred_at)
VALUES('10000000-0000-4000-8000-000000000050',:'outlet_id','MEMBERSHIP_SERVICE',false,'POS_ENROLLMENT','test-revoke-v1',
  '10000000-0000-4000-8000-000000000010',gen_random_uuid(),now()+interval '1 minute');
SELECT pg_temp.assert_whatsapp(NOT public.enqueue_whatsapp_digital_receipt(:'sale_id'),
  'Latest revoked service consent did not prevent new delivery intent');

SELECT set_config('quena.test.actor','10000000-0000-4000-8000-000000000011',false);
SELECT set_config('quena.test.role','ADMIN',false);
SET ROLE authenticated;
SELECT pg_temp.assert_whatsapp(public.whatsapp_settings_read()->>'provider_state'='CONNECTED',
  'ADMIN could not read WhatsApp settings');
DO $$ BEGIN
  PERFORM public.whatsapp_settings_update('10000000-0000-4000-8000-000000000001',
    '{"whatsapp_transactions_enabled":false,"automatic_receipt_enabled":false,"include_points_earned":true,"include_points_redeemed":true,"include_points_balance":true}'::jsonb);
  RAISE EXCEPTION 'ADMIN unexpectedly updated WhatsApp settings';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;

SELECT set_config('quena.test.actor','10000000-0000-4000-8000-000000000010',false);
SELECT set_config('quena.test.role','KASIR',false);
SET ROLE authenticated;
DO $$ BEGIN PERFORM public.whatsapp_settings_read(); RAISE EXCEPTION 'KASIR read management settings';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT 'WHATSAPP_CENTER_RUNTIME_PASS' AS result;
