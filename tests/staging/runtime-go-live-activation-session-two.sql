BEGIN;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT public.inventory_cost_activate_wac(
  (SELECT id FROM public.outlets WHERE code='QUENA-MART-1'),
  'f4300000-0000-4000-8000-000000000102',
  'ACTIVATE-WAC:'||(SELECT id::text FROM public.outlets WHERE code='QUENA-MART-1')||':f4300000-0000-4000-8000-000000000102');
COMMIT;
