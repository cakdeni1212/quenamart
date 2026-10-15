\set ON_ERROR_STOP on
CREATE FUNCTION pg_temp.assert_whatsapp(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION '%',message; END IF; END $$;
SELECT id AS notification_id FROM public.notification_outbox WHERE aggregate_id='10000000-0000-4000-8000-000000000070' \gset
SELECT set_config('request.jwt.claim.role','service_role',false);
SET ROLE service_role;
SELECT pg_temp.assert_whatsapp(public.notification_outbox_record_result(:'notification_id','RETRY','TEMPORARY_ERROR','Simulated transient error'),'Transient result was not recorded');
RESET ROLE;
SELECT pg_temp.assert_whatsapp((SELECT status='RETRY' AND attempt_count=1 AND next_attempt_at>now()
  FROM public.notification_outbox WHERE id=:'notification_id'),'Retry state/backoff was not recorded');
UPDATE public.notification_outbox SET next_attempt_at=now() WHERE id=:'notification_id';
SELECT set_config('request.jwt.claim.role','service_role',false);
SET ROLE service_role;
DO $$ DECLARE n integer; BEGIN
  SELECT count(*) INTO n FROM public.notification_outbox_claim(1);
  IF n<>1 THEN RAISE EXCEPTION 'retry job was not claimable after its scheduled time'; END IF;
END $$;
SELECT pg_temp.assert_whatsapp(public.notification_outbox_record_result(:'notification_id','SENT',NULL,NULL,'fake-test-message-id'),'Successful result was not recorded');
RESET ROLE;
SELECT pg_temp.assert_whatsapp((SELECT status='SENT' AND attempt_count=2 AND sent_at IS NOT NULL
  FROM public.notification_outbox WHERE id=:'notification_id'),'Successful attempt did not reach terminal SENT');
SELECT set_config('request.jwt.claim.role','service_role',false);
SET ROLE service_role;
SELECT pg_temp.assert_whatsapp((SELECT count(*)=0 FROM public.notification_outbox_claim(10)),
  'SENT notification was claimed again');
RESET ROLE;
SELECT pg_temp.assert_whatsapp((SELECT count(*)=2 FROM public.notification_delivery_attempts WHERE notification_id=:'notification_id'),
  'Delivery attempt evidence missing');
SELECT 'WHATSAPP_QUEUE_LIFECYCLE_PASS' AS result;
