\set ON_ERROR_STOP on
SELECT id outlet_id FROM public.outlets WHERE code='QUENA-MART-1' \gset
SELECT id product_id FROM public.products WHERE sku='CUTOVER-DECIMAL' \gset

-- Test-only helper. The runner targets a disposable PostgreSQL 15 cluster.
CREATE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION '%',message; END IF; END $$;

-- Fresh migration state does not activate the program. Only the Owner save does.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false);
SET ROLE authenticated;
SELECT pg_temp.assert_true(
  NOT (public.member_loyalty_settings_read()->>'program_enabled')::boolean
  AND NOT (public.member_loyalty_settings_read()->>'redeem_enabled')::boolean,
  'Fresh loyalty policy must be OFF');
SELECT public.member_loyalty_settings_update(
  '{"program_enabled":true,"rupiah_per_point":"10","redeem_enabled":true,"rupiah_per_redeem_point":"100","minimum_redeem_points":"1"}'::jsonb);
SELECT public.member_upsert(NULL,'Runtime Loyalty Member','081299991111',NULL,gen_random_uuid())->>'id' AS loyalty_member_id \gset
RESET ROLE;

INSERT INTO public.member_point_ledger(member_id,outlet_id,event_type,points_delta,source_type,source_reference,
  occurred_at,actor_id,note,request_id)
VALUES(:'loyalty_member_id',:'outlet_id','OPENING_BALANCE',5,'RUNTIME_TEST','LOYALTY-OPENING',clock_timestamp(),
  'a0000000-0000-4000-8000-000000000001','Synthetic disposable starting balance',gen_random_uuid());

SELECT effective_quantity stock_before FROM public.stock_balance_projection
WHERE outlet_id=:'outlet_id' AND product_id=:'product_id' \gset
SELECT inventory_value value_before,current_wac wac_before FROM public.inventory_cost_projections
WHERE outlet_id=:'outlet_id' AND product_id=:'product_id' \gset

-- Redeem one point (Rp100) from a Rp125 cart. Earn is based on final payable
-- Rp25, producing two points at Rp10/point, not twelve.
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',false);
SET ROLE authenticated;
SELECT public.pos_cart_create(gen_random_uuid())->>'cart_id' AS loyalty_cart_id \gset
SELECT public.pos_cart_member_set(:'loyalty_cart_id',:'loyalty_member_id',1,gen_random_uuid())->>'revision' AS member_cart_revision \gset
SELECT public.pos_cart_add_item(:'loyalty_cart_id',:'product_id',0.250,:'member_cart_revision'::bigint,gen_random_uuid())->>'revision' AS item_cart_revision \gset
SELECT public.pos_cart_redeem_points_set(:'loyalty_cart_id',1,:'item_cart_revision'::bigint,gen_random_uuid())->>'revision' AS redeem_cart_revision \gset
SELECT public.pos_checkout_complete('f4300000-0000-4000-8000-000000000221',:'loyalty_cart_id',
  :'redeem_cart_revision'::bigint,'CASH',25,NULL) AS loyalty_checkout_result \gset
SELECT public.pos_checkout_complete('f4300000-0000-4000-8000-000000000221',:'loyalty_cart_id',
  :'redeem_cart_revision'::bigint,'CASH',25,NULL) AS loyalty_checkout_replay \gset
SELECT (:'loyalty_checkout_result'::jsonb->>'sale_id') AS loyalty_sale_id \gset
SELECT public.pos_sale_receipt_read(:'loyalty_sale_id') AS loyalty_receipt \gset
SELECT pg_temp.assert_true(:'loyalty_checkout_replay'::jsonb=:'loyalty_checkout_result'::jsonb,
  'Same checkout request did not return its saved result');

SELECT pg_temp.assert_true(
  (:'loyalty_checkout_result'::jsonb->>'subtotal')::numeric=125
  AND (:'loyalty_checkout_result'::jsonb->>'discount_total')::numeric=100
  AND (:'loyalty_checkout_result'::jsonb->>'grand_total')::numeric=25
  AND (:'loyalty_checkout_result'::jsonb->>'points_redeemed')::bigint=1
  AND (:'loyalty_checkout_result'::jsonb->>'points_earned')::bigint=2
  AND (:'loyalty_checkout_result'::jsonb->>'point_balance')::bigint=6,
  'Combined redemption/earning arithmetic is wrong');
SELECT pg_temp.assert_true(
  (:'loyalty_checkout_result'::jsonb->>'point_balance')::bigint=6,
  'Authorized checkout response did not return the final member balance');
SELECT pg_temp.assert_true(
  (:'loyalty_receipt'::jsonb->'member'->>'member_number') IS NOT NULL
  AND (:'loyalty_receipt'::jsonb->'loyalty'->>'points_earned')::bigint=2
  AND (:'loyalty_receipt'::jsonb->'loyalty'->>'points_redeemed')::bigint=1
  AND (:'loyalty_receipt'::jsonb->'loyalty'->>'points_discount')::numeric=100,
  'Receipt loyalty snapshot is incomplete');
RESET ROLE;

SELECT pg_temp.assert_true(
  (SELECT count(*)=1 FROM public.inventory_cost_events WHERE operation_request_id='f4300000-0000-4000-8000-000000000221' AND event_type='SALE_COGS'),
  'Native sale-time COGS writer did not run exactly once');
SELECT pg_temp.assert_true(
  (SELECT count(*)=1 FROM public.member_point_ledger WHERE sale_id=:'loyalty_sale_id' AND event_type='SALE_REDEEM' AND points_delta=-1)
  AND (SELECT count(*)=1 FROM public.member_point_ledger WHERE sale_id=:'loyalty_sale_id' AND event_type='SALE_EARN' AND points_delta=2)
  AND public.member_point_balance(:'loyalty_member_id')=6,
  'Sale point ledger/balance evidence is not exactly once');
SELECT pg_temp.assert_true(
  (SELECT (policy_snapshot->>'eligible_spend')::numeric=25 FROM public.member_point_ledger WHERE sale_id=:'loyalty_sale_id' AND event_type='SALE_EARN')
  AND (SELECT (policy_snapshot->>'rupiah_per_point')::bigint=10 FROM public.member_point_ledger WHERE sale_id=:'loyalty_sale_id' AND event_type='SALE_EARN')
  AND (SELECT (policy_snapshot->>'rupiah_per_redeem_point')::bigint=100 FROM public.member_point_ledger WHERE sale_id=:'loyalty_sale_id' AND event_type='SALE_REDEEM'),
  'Historical policy/eligible-spend snapshot is missing');
SELECT pg_temp.assert_true(
  (SELECT sum(applied_amount)=25 FROM public.sale_payments WHERE sale_id=:'loyalty_sale_id')
  AND (SELECT grand_total=25 AND discount_total=100 FROM public.sales WHERE id=:'loyalty_sale_id'),
  'Payment evidence does not reconcile to final payable');
SELECT pg_temp.assert_true(
  (SELECT effective_quantity=:'stock_before'::numeric-0.250 FROM public.stock_balance_projection WHERE outlet_id=:'outlet_id' AND product_id=:'product_id')
  AND (SELECT inventory_value=:'value_before'::numeric-25 FROM public.inventory_cost_projections WHERE outlet_id=:'outlet_id' AND product_id=:'product_id')
  AND (SELECT current_wac=:'wac_before'::numeric FROM public.inventory_cost_projections WHERE outlet_id=:'outlet_id' AND product_id=:'product_id'),
  'Loyalty checkout quantity/value/WAC result is wrong');

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false);
SET ROLE authenticated;
SELECT pg_temp.assert_true(
  (public.owner_reports_read(timezone('Asia/Jakarta',now())::date,timezone('Asia/Jakarta',now())::date,
    timezone('Asia/Jakarta',now())::date,timezone('Asia/Jakarta',now())::date)->'kpis'->>'profit_status')='RESOLVED'
  AND (public.owner_reports_read(timezone('Asia/Jakarta',now())::date,timezone('Asia/Jakarta',now())::date,
    timezone('Asia/Jakarta',now())::date,timezone('Asia/Jakarta',now())::date)->'payment_reconciliation'->>'matches')::boolean,
  'Native official profit/payment report semantics changed');
RESET ROLE;
SELECT 'MEMBER_POINTS_CHECKOUT_RUNTIME_PASS' AS result;
