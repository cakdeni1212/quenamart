-- Synthetic staging-only role identities. Never use production user IDs.
DO $guard$
BEGIN
  IF current_database() <> 'quena_stock_staging'
     OR coalesce(host(inet_server_addr()), '') NOT IN ('127.0.0.1', '::1')
     OR inet_server_port() <> 5432
     OR current_setting('server_version_num')::integer / 10000 <> 15
     OR current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'Refusing synthetic actor seed outside local UTF8 PostgreSQL 15 quena_stock_staging';
  END IF;
END;
$guard$;

BEGIN;
INSERT INTO auth.users(id) VALUES
  ('a0000000-0000-4000-8000-000000000001'),
  ('a0000000-0000-4000-8000-000000000002'),
  ('a0000000-0000-4000-8000-000000000003'),
  ('a0000000-0000-4000-8000-000000000004')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.profiles(id, full_name, role, is_active) VALUES
  ('a0000000-0000-4000-8000-000000000001', 'Stage Owner', 'OWNER', true),
  ('a0000000-0000-4000-8000-000000000002', 'Stage Admin', 'ADMIN', true),
  ('a0000000-0000-4000-8000-000000000003', 'Stage Gudang', 'GUDANG', true),
  ('a0000000-0000-4000-8000-000000000004', 'Stage Kasir', 'KASIR', true)
ON CONFLICT (id) DO NOTHING;
DO $check_roles$
BEGIN
  IF (SELECT count(*) FROM public.profiles p
      WHERE (p.id, p.role, p.is_active) IN (
        ('a0000000-0000-4000-8000-000000000001'::uuid, 'OWNER'::public.user_role, true),
        ('a0000000-0000-4000-8000-000000000002'::uuid, 'ADMIN'::public.user_role, true),
        ('a0000000-0000-4000-8000-000000000003'::uuid, 'GUDANG'::public.user_role, true),
        ('a0000000-0000-4000-8000-000000000004'::uuid, 'KASIR'::public.user_role, true)
      )) <> 4 THEN
    RAISE EXCEPTION 'Synthetic staging role identities do not match their expected roles';
  END IF;
END;
$check_roles$;
COMMIT;
