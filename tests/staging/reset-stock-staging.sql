-- Destructive staging-only reset. Run only through reset-stock-staging.sh.
-- Removes database-local harness/migration/fixture schemas; cluster roles remain.
\set ON_ERROR_STOP on
BEGIN;

DO $guard$
DECLARE
  unexpected_schema text;
BEGIN
  IF current_database() <> 'quena_stock_staging'
     OR coalesce(host(inet_server_addr()), '') NOT IN ('127.0.0.1', '::1')
     OR inet_server_port() <> 5432
     OR current_setting('server_version_num')::integer / 10000 <> 15
     OR current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'Refusing reset outside local UTF8 PostgreSQL 15 quena_stock_staging on loopback port 5432';
  END IF;
  IF to_regclass('quena_staging.environment') IS NULL
     OR to_regclass('quena_staging.applied_migrations') IS NULL THEN
    RAISE EXCEPTION 'Refusing reset: local staging harness marker/ledger is absent';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM quena_staging.environment e
    WHERE e.name = 'quena_stock_staging'
  ) THEN
    RAISE EXCEPTION 'Refusing reset: staging marker does not match target database';
  END IF;
  IF EXISTS (
    SELECT 1 FROM quena_staging.applied_migrations m
    WHERE m.version NOT IN (
      '20260928', '20260928115000', '20260928143000', '20260929100000',
      '20260929130000', '20260929150000', '20260929160000',
      '20260929170000', '20260929171000', '20260929180000'
    )
  ) THEN
    RAISE EXCEPTION 'Refusing reset: unexpected migration version exists in staging ledger';
  END IF;
  SELECT n.nspname INTO unexpected_schema
  FROM pg_catalog.pg_namespace n
  WHERE n.nspname NOT IN ('public', 'auth', 'storage', 'quena_staging', 'information_schema')
    AND n.nspname NOT LIKE 'pg\_%' ESCAPE '\'
  LIMIT 1;
  IF unexpected_schema IS NOT NULL THEN
    RAISE EXCEPTION 'Refusing reset: unexpected non-system schema % exists', unexpected_schema;
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_extension e WHERE e.extname <> 'plpgsql'
  ) THEN
    RAISE EXCEPTION 'Refusing reset: unexpected PostgreSQL extension exists';
  END IF;
END;
$guard$;

DROP SCHEMA public CASCADE;
CREATE SCHEMA public AUTHORIZATION postgres;
GRANT USAGE ON SCHEMA public TO PUBLIC;
DROP SCHEMA storage CASCADE;
DROP SCHEMA auth CASCADE;
DROP SCHEMA quena_staging CASCADE;

COMMIT;
