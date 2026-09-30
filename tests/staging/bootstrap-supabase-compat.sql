-- STAGING-ONLY bootstrap for native PostgreSQL 15.
-- Never apply this file to production or include it in supabase/migrations.
BEGIN;
DO $guard$
BEGIN
  IF current_database() <> 'quena_stock_staging'
     OR coalesce(host(inet_server_addr()), '') NOT IN ('127.0.0.1', '::1')
     OR inet_server_port() <> 5432
     OR current_setting('server_version_num')::integer / 10000 <> 15
     OR current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'Refusing staging bootstrap: expected local UTF8 PostgreSQL 15 database quena_stock_staging';
  END IF;
  IF to_regnamespace('auth') IS NOT NULL
     OR to_regnamespace('storage') IS NOT NULL
     OR to_regnamespace('quena_staging') IS NOT NULL
     OR to_regtype('public.user_role') IS NOT NULL
     OR to_regclass('public.profiles') IS NOT NULL
     OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_class c
       JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm')
     ) THEN
    RAISE EXCEPTION 'Refusing bootstrap: database is not an empty native staging database';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles r
    WHERE (r.rolname IN ('anon', 'authenticated')
        AND (r.rolcanlogin OR r.rolsuper OR r.rolbypassrls))
       OR (r.rolname = 'service_role'
        AND (r.rolcanlogin OR r.rolsuper OR NOT r.rolbypassrls))
  ) THEN
    RAISE EXCEPTION 'Refusing bootstrap: an existing application role has unexpected login/superuser/BYPASSRLS attributes';
  END IF;
END;
$guard$;

DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'postgres') THEN
    EXECUTE 'CREATE ROLE postgres SUPERUSER NOLOGIN';
  ELSIF NOT (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = 'postgres') THEN
    RAISE EXCEPTION 'Existing postgres role is not a superuser; refusing staging bootstrap';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'CREATE ROLE anon NOLOGIN';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'CREATE ROLE authenticated NOLOGIN';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'CREATE ROLE service_role NOLOGIN BYPASSRLS';
  END IF;
END;
$roles$;

CREATE SCHEMA auth;
CREATE TABLE auth.users (
  id uuid PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path = pg_catalog
AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
ALTER FUNCTION auth.uid() OWNER TO postgres;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;

CREATE TYPE public.user_role AS ENUM ('OWNER', 'ADMIN', 'GUDANG', 'KASIR');
CREATE TABLE public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE RESTRICT,
  full_name text,
  role public.user_role NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.profiles FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.profiles TO authenticated;
CREATE POLICY profiles_select_own
  ON public.profiles FOR SELECT TO authenticated
  USING (id = (SELECT auth.uid()));

CREATE SCHEMA storage;
CREATE TABLE storage.buckets (
  id text PRIMARY KEY,
  name text NOT NULL,
  public boolean NOT NULL,
  file_size_limit bigint,
  allowed_mime_types text[]
);
CREATE TABLE storage.objects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id text,
  name text
);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;

CREATE SCHEMA quena_staging;
REVOKE ALL ON SCHEMA quena_staging FROM PUBLIC, anon, authenticated, service_role;
CREATE TABLE quena_staging.environment (
  name text PRIMARY KEY CHECK (name = 'quena_stock_staging'),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE quena_staging.applied_migrations (
  ordinal integer PRIMARY KEY,
  version text NOT NULL UNIQUE,
  filename text NOT NULL UNIQUE,
  applied_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE quena_staging.fixture_runs (
  fixture_key text PRIMARY KEY CHECK (fixture_key = 'stock_foundation_v1'),
  seeded_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO quena_staging.environment(name) VALUES ('quena_stock_staging');
COMMIT;
