\set ON_ERROR_STOP on
CREATE TABLE public.runtime_member_points_concurrency(
  cart_id uuid PRIMARY KEY, revision bigint NOT NULL, request_id uuid NOT NULL UNIQUE
);
GRANT SELECT,INSERT ON public.runtime_member_points_concurrency TO authenticated;
SELECT id AS outlet_id FROM public.outlets WHERE code='QUENA-MART-1' \gset
SELECT id AS product_id FROM public.products WHERE sku='CUTOVER-DECIMAL' \gset
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false);
SET ROLE authenticated;
SELECT public.member_loyalty_settings_update(
  '{"program_enabled":true,"rupiah_per_point":"999999999","redeem_enabled":true,"rupiah_per_redeem_point":"100","minimum_redeem_points":"1"}'::jsonb);
SELECT public.member_upsert(NULL,'Concurrent Loyalty Member','081299991112',NULL,gen_random_uuid())->>'id' AS concurrent_member_id \gset
RESET ROLE;
INSERT INTO public.member_point_ledger(member_id,outlet_id,event_type,points_delta,source_type,source_reference,
  occurred_at,actor_id,note,request_id)
VALUES(:'concurrent_member_id',:'outlet_id','OPENING_BALANCE',1,'RUNTIME_TEST','LOYALTY-CONCURRENT-OPENING',clock_timestamp(),
  'a0000000-0000-4000-8000-000000000001','Disposable concurrency fixture',gen_random_uuid());

SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',false);
SELECT set_config('quena.concurrent_member',:'concurrent_member_id',false);
SET ROLE authenticated;
DO $$
DECLARE cart_result jsonb; member_result jsonb; item_result jsonb; redeem_result jsonb;
  new_cart uuid; product uuid;
BEGIN
  SELECT id INTO product FROM public.products WHERE sku='CUTOVER-DECIMAL';
  FOR i IN 1..2 LOOP
    cart_result:=public.pos_cart_create(gen_random_uuid());new_cart:=(cart_result->>'cart_id')::uuid;
    member_result:=public.pos_cart_member_set(new_cart,current_setting('quena.concurrent_member')::uuid,
      (cart_result->>'revision')::bigint,gen_random_uuid());
    item_result:=public.pos_cart_add_item(new_cart,product,0.250,(member_result->>'revision')::bigint,gen_random_uuid());
    redeem_result:=public.pos_cart_redeem_points_set(new_cart,1,(item_result->>'revision')::bigint,gen_random_uuid());
    INSERT INTO public.runtime_member_points_concurrency(cart_id,revision,request_id)
      VALUES(new_cart,(redeem_result->>'revision')::bigint,
        CASE WHEN i=1 THEN 'f4300000-0000-4000-8000-000000000222'::uuid ELSE 'f4300000-0000-4000-8000-000000000223'::uuid END);
  END LOOP;
END $$;
RESET ROLE;
SELECT 'MEMBER_POINTS_CONCURRENCY_FIXTURE_READY' AS result;
