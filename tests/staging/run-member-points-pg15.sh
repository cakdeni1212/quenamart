#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/quena-member-points-pg15.XXXXXX")"
DATA="$TMP/data" SOCKET="$TMP/socket" PORT=55444
mkdir -p "$SOCKET"
CREATED=0
cleanup() { if [[ "$CREATED" == 1 ]]; then pg_ctl -D "$DATA" -m immediate stop >/dev/null 2>&1 || true; fi; rm -rf -- "$TMP"; }
trap cleanup EXIT
initdb -D "$DATA" --auth=trust --no-locale --encoding=UTF8 >/dev/null
pg_ctl -D "$DATA" -o "-h 127.0.0.1 -p $PORT -k $SOCKET -c shared_memory_type=mmap" -w start >/dev/null
CREATED=1
psql -X -w -h 127.0.0.1 -p "$PORT" -U "$USER" -d postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE postgres SUPERUSER LOGIN;
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role;
CREATE DATABASE quena_member_loyalty_runtime;
SQL
PSQL=(psql -X -w -h 127.0.0.1 -p "$PORT" -U "$USER" -d quena_member_loyalty_runtime -v ON_ERROR_STOP=1)
"${PSQL[@]}" <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA auth;
CREATE TABLE auth.users(id uuid PRIMARY KEY);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('quena.test.actor',true),'')::uuid $$;
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.role',true),'') $$;
CREATE TYPE public.user_role AS ENUM('OWNER','ADMIN','KASIR','GUDANG');
CREATE TYPE public.pos_sale_source AS ENUM('QUENA_POS','IPOS_IMPORT');
CREATE TYPE public.pos_sale_status AS ENUM('COMPLETED');
CREATE TABLE public.outlets(id uuid PRIMARY KEY,name text);
CREATE TABLE public.stock_authority_periods(outlet_id uuid NOT NULL,started_at timestamptz NOT NULL,ended_at timestamptz);
CREATE TABLE public.pos_carts(id uuid PRIMARY KEY,outlet_id uuid NOT NULL,created_by uuid NOT NULL,status text NOT NULL DEFAULT 'ACTIVE',revision bigint NOT NULL DEFAULT 1,updated_at timestamptz NOT NULL DEFAULT now(),UNIQUE(id,outlet_id));
CREATE TABLE public.sales(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),outlet_id uuid NOT NULL,pos_cart_id uuid NOT NULL,source_system public.pos_sale_source NOT NULL,status public.pos_sale_status NOT NULL DEFAULT 'COMPLETED',completed_at timestamptz NOT NULL DEFAULT now(),grand_total numeric NOT NULL DEFAULT 0);
CREATE TABLE public.sale_items(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),sale_id uuid NOT NULL,completed_at timestamptz NOT NULL DEFAULT now());
CREATE FUNCTION public.current_active_user_role() RETURNS public.user_role LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('quena.test.role',true),'')::public.user_role $$;
CREATE FUNCTION public.pos_cart_context() RETURNS TABLE(actor_id uuid,outlet_id uuid,actor_role public.user_role) LANGUAGE sql STABLE AS $$ SELECT auth.uid(),(SELECT outlet_id FROM public.stock_authority_periods WHERE ended_at IS NULL LIMIT 1),public.current_active_user_role() $$;
SQL
"${PSQL[@]}" -f "$ROOT/supabase/migrations/20260929476000_member_core_v1.sql" >/dev/null
"${PSQL[@]}" -f "$ROOT/tests/staging/member-points-runtime-prerequisites.sql" >/dev/null
"${PSQL[@]}" -f "$ROOT/supabase/migrations/20260929477000_member_loyalty_policy_v1.sql" >"$TMP/migration.log"
"${PSQL[@]}" -f "$ROOT/supabase/migrations/20260929478000_member_public_access_foundation_v1.sql" >"$TMP/access-migration.log"
"${PSQL[@]}" -f "$ROOT/tests/staging/runtime-member-points-policy.sql" >"$TMP/runtime.log"
"${PSQL[@]}" -f "$ROOT/tests/staging/runtime-member-public-access.sql" >"$TMP/access-runtime.log"
cat "$TMP/migration.log" "$TMP/access-migration.log" "$TMP/runtime.log" "$TMP/access-runtime.log"
echo 'PASS: 476000 + 477000 + 478000 apply and loyalty/public-access matrices ran on disposable PostgreSQL 15; cluster removed on exit'
