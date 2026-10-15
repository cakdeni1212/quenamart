BEGIN;
-- The shared loyalty harness intentionally stubs only fields needed by prior tests;
-- add the canonical receipt evidence columns from the deployed POS schema here.
ALTER TABLE public.sale_items ADD COLUMN pos_cart_id uuid, ADD COLUMN pos_cart_item_id uuid,
  ADD COLUMN outlet_id uuid, ADD COLUMN product_id uuid, ADD COLUMN line_number integer,
  ADD COLUMN product_name_snapshot text, ADD COLUMN sku_snapshot text, ADD COLUMN unit_snapshot text,
  ADD COLUMN quantity numeric, ADD COLUMN unit_selling_price numeric,
  ADD COLUMN price_checked_at timestamptz;
ALTER TABLE public.sale_items ADD COLUMN line_subtotal numeric GENERATED ALWAYS AS (round(quantity*unit_selling_price,2)) STORED;
ALTER TABLE public.sale_payments ADD COLUMN id uuid DEFAULT gen_random_uuid();
INSERT INTO public.outlets(id,name,customer_display_name,is_active,address,city,province,postal_code,phone,whatsapp)
VALUES('10000000-0000-4000-8000-000000000001','Outlet','Quena Mart',true,'Jalan Toko','Kraksaan','Jawa Timur','67282','081299999999','081299999999');
INSERT INTO public.stock_authority_periods(outlet_id,started_at,ended_at)
VALUES('10000000-0000-4000-8000-000000000001',now(),NULL);
INSERT INTO auth.users(id) VALUES('10000000-0000-4000-8000-000000000010');
INSERT INTO public.profiles(id,full_name) VALUES('10000000-0000-4000-8000-000000000010','Ayu Kasir');
INSERT INTO public.products(id,name,sku,unit_label) VALUES('10000000-0000-4000-8000-000000000020','Aqua 600ml','SKU-AQUA','botol');
INSERT INTO public.pos_carts(id,outlet_id,created_by,status,revision)
VALUES('10000000-0000-4000-8000-000000000030','10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000010','ACTIVE',1);
INSERT INTO public.pos_cart_items(id,cart_id,outlet_id,product_id,quantity,observed_unit_price)
VALUES('10000000-0000-4000-8000-000000000040','10000000-0000-4000-8000-000000000030','10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000020',2,4000);
INSERT INTO public.members(id,outlet_id,member_number,full_name,phone,email,created_by,updated_by)
VALUES('10000000-0000-4000-8000-000000000050','10000000-0000-4000-8000-000000000001','QMEM-00000001','Deni','081234567890','private@example.invalid','10000000-0000-4000-8000-000000000010','10000000-0000-4000-8000-000000000010');
INSERT INTO public.member_consent_evidence(member_id,outlet_id,consent_type,granted,source,policy_version,actor_id,request_id)
VALUES('10000000-0000-4000-8000-000000000050','10000000-0000-4000-8000-000000000001','MEMBERSHIP_SERVICE',true,'POS_ENROLLMENT','test-v1','10000000-0000-4000-8000-000000000010','10000000-0000-4000-8000-000000000060');
UPDATE public.pos_carts SET member_id='10000000-0000-4000-8000-000000000050' WHERE id='10000000-0000-4000-8000-000000000030';

INSERT INTO public.pos_checkout_requests(request_id,actor_id,outlet_id,cart_id,expected_cart_revision,payment_payload_hash,state)
VALUES('10000000-0000-4000-8000-000000000060','10000000-0000-4000-8000-000000000010','10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000030',1,repeat('a',32),'PENDING');
INSERT INTO public.sales(id,outlet_id,cashier_id,completed_by,pos_cart_id,checkout_request_id,sale_number,source_system,status,
  subtotal,discount_total,grand_total,completed_at,member_id)
VALUES('10000000-0000-4000-8000-000000000070','10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000010',
  '10000000-0000-4000-8000-000000000010','10000000-0000-4000-8000-000000000030','10000000-0000-4000-8000-000000000060',
  'QPOS-20261015-00000001','QUENA_POS','COMPLETED',18500,5000,13500,'2026-10-15 08:42:00+07','10000000-0000-4000-8000-000000000050');
DO $$ BEGIN
  IF (SELECT member_id FROM public.sales WHERE id='10000000-0000-4000-8000-000000000070') IS DISTINCT FROM '10000000-0000-4000-8000-000000000050'::uuid THEN
    RAISE EXCEPTION 'test sale member association was not persisted: %', (SELECT member_id FROM public.sales WHERE id='10000000-0000-4000-8000-000000000070');
  END IF;
END $$;
INSERT INTO public.sale_items(sale_id,pos_cart_id,pos_cart_item_id,outlet_id,product_id,line_number,product_name_snapshot,sku_snapshot,
  unit_snapshot,quantity,unit_selling_price,price_checked_at)
VALUES('10000000-0000-4000-8000-000000000070','10000000-0000-4000-8000-000000000030','10000000-0000-4000-8000-000000000040',
  '10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000020',1,'Aqua 600ml','SKU-AQUA','botol',2,4000,'2026-10-15 08:42:00+07');
INSERT INTO public.sale_payments(sale_id,outlet_id,method,applied_amount,received_amount,change_amount,reference_text,recorded_by)
VALUES('10000000-0000-4000-8000-000000000070','10000000-0000-4000-8000-000000000001','QRIS',13500,NULL,NULL,'PRIVATE-REF','10000000-0000-4000-8000-000000000010');
INSERT INTO public.member_point_ledger(member_id,outlet_id,event_type,points_delta,source_type,source_reference,occurred_at,actor_id,note,
  request_id,sale_id,policy_snapshot,checkout_request_id)
VALUES
 ('10000000-0000-4000-8000-000000000050','10000000-0000-4000-8000-000000000001','SALE_REDEEM',-100,'QUENA_POS_SALE','QPOS-20261015-00000001','2026-10-15 08:42:00+07','10000000-0000-4000-8000-000000000010','redeem','10000000-0000-4000-8000-000000000061','10000000-0000-4000-8000-000000000070','{"discount_amount":"5000","balance_after_event":20}', '10000000-0000-4000-8000-000000000060'),
 ('10000000-0000-4000-8000-000000000050','10000000-0000-4000-8000-000000000001','SALE_EARN',1,'QUENA_POS_SALE','QPOS-20261015-00000001','2026-10-15 08:42:00+07','10000000-0000-4000-8000-000000000010','earn','10000000-0000-4000-8000-000000000062','10000000-0000-4000-8000-000000000070','{"awarded_points":1,"balance_after_event":21}', '10000000-0000-4000-8000-000000000060');

UPDATE public.pos_checkout_requests SET sale_id='10000000-0000-4000-8000-000000000070',result='{"cashier_label":"Ayu"}',
  state='COMPLETED',completed_at=now() WHERE request_id='10000000-0000-4000-8000-000000000060';
DO $$ BEGIN
  IF (SELECT count(*) FROM public.sale_public_receipts WHERE sale_id='10000000-0000-4000-8000-000000000070' AND status='UNISSUED')<>1 THEN
    RAISE EXCEPTION 'completed native sale did not receive one unissued receipt identity';
  END IF;
END $$;
UPDATE public.pos_checkout_requests SET result='{"cashier_label":"Ayu"}' WHERE request_id='10000000-0000-4000-8000-000000000060';
DO $$ BEGIN
  IF (SELECT count(*) FROM public.sale_public_receipts WHERE sale_id='10000000-0000-4000-8000-000000000070')<>1 THEN
    RAISE EXCEPTION 'checkout replay/update duplicated receipt identity';
  END IF;
END $$;
INSERT INTO public.pos_carts(id,outlet_id,created_by,status,revision)
VALUES('10000000-0000-4000-8000-000000000031','10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000010','ACTIVE',1);
INSERT INTO public.pos_checkout_requests(request_id,actor_id,outlet_id,cart_id,expected_cart_revision,payment_payload_hash,state)
VALUES('10000000-0000-4000-8000-000000000063','10000000-0000-4000-8000-000000000010','10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000031',1,repeat('c',32),'PENDING');
INSERT INTO public.sales(id,outlet_id,cashier_id,completed_by,pos_cart_id,checkout_request_id,sale_number,source_system,status,
  subtotal,discount_total,grand_total,completed_at)
VALUES('10000000-0000-4000-8000-000000000071','10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000010',
  '10000000-0000-4000-8000-000000000010','10000000-0000-4000-8000-000000000031','10000000-0000-4000-8000-000000000063',
  'QPOS-20261015-00000002','IPOS_IMPORT','COMPLETED',100,0,100,'2026-10-15 09:00:00+07');
UPDATE public.pos_checkout_requests SET sale_id='10000000-0000-4000-8000-000000000071',state='COMPLETED'
WHERE request_id='10000000-0000-4000-8000-000000000063';
DO $$ BEGIN
  IF EXISTS(SELECT 1 FROM public.sale_public_receipts WHERE sale_id='10000000-0000-4000-8000-000000000071') THEN
    RAISE EXCEPTION 'IPOS_IMPORT sale received public receipt identity';
  END IF;
END $$;

SELECT set_config('quena.test.actor','10000000-0000-4000-8000-000000000010',true);
SELECT set_config('quena.test.role','OWNER',true);
SELECT public.pos_sale_public_receipt_issue('10000000-0000-4000-8000-000000000070',repeat('b',64));
DO $$ BEGIN
  IF (SELECT token_hash FROM public.sale_public_receipts WHERE sale_id='10000000-0000-4000-8000-000000000070')<>repeat('b',64) THEN
    RAISE EXCEPTION 'receipt token hash not stored';
  END IF;
  IF has_table_privilege('anon','public.sale_public_receipts','SELECT')
     OR has_table_privilege('anon','public.sales','SELECT')
     OR has_table_privilege('anon','public.sale_items','SELECT')
     OR has_table_privilege('anon','public.member_point_ledger','SELECT') THEN
    RAISE EXCEPTION 'anon acquired direct receipt/accounting table access';
  END IF;
  IF has_function_privilege('anon','public.customer_public_receipt_read(text)','EXECUTE')
     OR has_function_privilege('authenticated','public.customer_public_receipt_read(text)','EXECUTE')
     OR NOT has_function_privilege('service_role','public.customer_public_receipt_read(text)','EXECUTE') THEN
    RAISE EXCEPTION 'public receipt read grants are incorrect';
  END IF;
END $$;

SELECT set_config('request.jwt.claim.role','service_role',true);
DO $$
DECLARE receipt jsonb;
BEGIN
  receipt:=public.customer_public_receipt_read(repeat('b',64));
  IF receipt IS NULL OR receipt->'sale'->>'number'<>'QPOS-20261015-00000001'
     OR receipt->'totals'->>'grand_total'<>'13500'
     OR receipt->'items'->0->>'name'<>'Aqua 600ml'
     OR receipt->'payments'->0->>'method'<>'QRIS'
     OR receipt->'member'->>'member_number'<>'QMEM-00000001'
     OR receipt->'loyalty'->>'points_earned'<>'1'
     OR receipt->'loyalty'->>'points_redeemed'<>'100'
     OR receipt->'loyalty'->>'points_discount'<>'5000'
     OR receipt->'loyalty'->>'balance_after'<>'21' THEN
    RAISE EXCEPTION 'safe receipt or persisted loyalty evidence is incomplete: %',receipt;
  END IF;
  IF receipt ? 'sale_id' OR receipt->'member' ? 'phone' OR receipt->'member' ? 'email'
     OR receipt->'member' ? 'id' OR receipt->'payments'->0 ? 'reference_text'
     OR receipt::text LIKE '%private@example.invalid%' OR receipt::text LIKE '%081234567890%'
     OR receipt::text LIKE '%10000000-0000-4000-8000-000000000050%' THEN
    RAISE EXCEPTION 'private identifiers leaked in public receipt';
  END IF;
  IF public.customer_public_receipt_read(repeat('c',64)) IS NOT NULL
     OR public.customer_public_receipt_read('invalid') IS NOT NULL THEN
    RAISE EXCEPTION 'unknown token did not fail closed';
  END IF;
END $$;

SELECT public.pos_sale_public_receipt_issue('10000000-0000-4000-8000-000000000070',repeat('d',64));
DO $$ BEGIN
  IF public.customer_public_receipt_read(repeat('b',64)) IS NOT NULL
     OR public.customer_public_receipt_read(repeat('d',64)) IS NULL THEN
    RAISE EXCEPTION 'rotated token was not exclusive';
  END IF;
END $$;
SELECT public.customer_receipt_delivery_payload('10000000-0000-4000-8000-000000000070',repeat('e',64));
DO $$ DECLARE payload jsonb; BEGIN
  payload:=public.customer_receipt_delivery_payload('10000000-0000-4000-8000-000000000070',repeat('e',64));
  IF payload->>'destination_whatsapp'<>'6281234567890'
     OR payload ? 'member_id' OR payload ? 'receipt_token'
     OR public.customer_public_receipt_read(repeat('d',64)) IS NOT NULL THEN
    RAISE EXCEPTION 'delivery contract is not normalized, scoped, or token-safe: payload=% old_receipt=%',payload,public.customer_public_receipt_read(repeat('d',64));
  END IF;
END $$;

-- Simulate a legacy completed sale whose optional identity was not initialized.
DELETE FROM public.sale_public_receipts WHERE sale_id='10000000-0000-4000-8000-000000000070';
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('quena.test.role','KASIR',true);
SELECT public.pos_sale_public_receipt_issue('10000000-0000-4000-8000-000000000070',repeat('f',64));
DO $$ BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.sale_public_receipts WHERE sale_id='10000000-0000-4000-8000-000000000070' AND status='ACTIVE') THEN
    RAISE EXCEPTION 'authorized staff could not issue legacy receipt link on demand';
  END IF;
  IF has_function_privilege('anon','public.pos_sale_public_receipt_issue(uuid,text)','EXECUTE') THEN
    RAISE EXCEPTION 'anon can issue staff receipt token';
  END IF;
END $$;
UPDATE public.sale_public_receipts SET status='REVOKED',token_hash=NULL,revoked_at=now()
WHERE sale_id='10000000-0000-4000-8000-000000000070';
SELECT set_config('request.jwt.claim.role','service_role',true);
DO $$ BEGIN
  IF public.customer_public_receipt_read(repeat('f',64)) IS NOT NULL THEN
    RAISE EXCEPTION 'revoked receipt token still resolved';
  END IF;
END $$;

ROLLBACK;
