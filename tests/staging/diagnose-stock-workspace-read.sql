-- Read-only diagnosis for the already-applied 190000 RPC on local staging.
\set ON_ERROR_STOP on

BEGIN READ ONLY;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true);

SELECT current_database() AS database_name,
       current_user AS database_role,
       auth.uid() AS simulated_actor,
       public.current_active_user_role() AS active_profile_role,
       public.current_active_user_role() = 'OWNER'::public.user_role AS owner_profile_ready;

SELECT expected.code AS expected_outlet_code,
       o.id AS visible_outlet_id,
       coalesce(o.is_active, false) AS outlet_active,
       EXISTS (
         SELECT 1 FROM public.stock_authority_periods AS ap
         WHERE ap.outlet_id = o.id AND ap.ended_at IS NULL
       ) AS active_authority_visible,
       (SELECT count(*) FROM public.product_inventory AS i WHERE i.outlet_id = o.id) AS inventory_memberships,
       (SELECT count(*)
        FROM public.product_inventory AS i
        JOIN public.stock_balance_projection AS bp
          ON bp.product_id = i.product_id AND bp.outlet_id = i.outlet_id
        WHERE i.outlet_id = o.id AND bp.effective_quantity IS NOT NULL) AS usable_projection_memberships
FROM (VALUES ('QUENA-MART-1'::text)) AS expected(code)
LEFT JOIN public.outlets AS o ON o.code = expected.code;

ROLLBACK;
