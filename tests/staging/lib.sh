#!/usr/bin/env bash
# Shared target guards for the local-only stock staging scripts.
set -euo pipefail

STAGING_HOST='localhost'
STAGING_PORT='5432'
STAGING_DATABASE='quena_stock_staging'
STAGING_USER="$(id -un)"
STAGING_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
umask 077
STAGING_PGPASSFILE="$(mktemp "${TMPDIR:-/tmp}/quena-stock-staging-pgpass.XXXXXX")"
chmod 600 "$STAGING_PGPASSFILE"

cleanup_local_pgpass() {
  rm -f -- "$STAGING_PGPASSFILE"
}

psql_local() {
  env \
    -u PGHOST -u PGHOSTADDR -u PGPORT -u PGDATABASE -u PGUSER \
    -u PGSERVICE -u PGSERVICEFILE -u PGPASSWORD -u PGPASSFILE -u PGOPTIONS \
    -u DATABASE_URL -u SUPABASE_DB_URL -u SUPABASE_URL \
    -u SUPABASE_SERVICE_ROLE_KEY -u SUPABASE_ACCESS_TOKEN \
    PGPASSFILE="$STAGING_PGPASSFILE" PGCONNECT_TIMEOUT=5 \
    psql -X -w -h "$STAGING_HOST" -p "$STAGING_PORT" \
      -U "$STAGING_USER" -d "$STAGING_DATABASE" \
      -v ON_ERROR_STOP=1 "$@"
}

guard_local_target() {
  local actual_db actual_addr actual_port version_num actual_user encoding
  actual_db="$(psql_local -Atqc 'SELECT current_database()')"
  if [[ "$actual_db" != "$STAGING_DATABASE" ]]; then
    printf 'REFUSED: current_database() is %q, expected %q\n' "$actual_db" "$STAGING_DATABASE" >&2
    return 20
  fi
  actual_addr="$(psql_local -Atqc "SELECT coalesce(host(inet_server_addr()), '')")"
  case "$actual_addr" in
    127.0.0.1|::1) ;;
    *) printf 'REFUSED: server address %q is not loopback\n' "$actual_addr" >&2; return 21 ;;
  esac
  actual_port="$(psql_local -Atqc 'SELECT inet_server_port()')"
  if [[ "$actual_port" != "$STAGING_PORT" ]]; then
    printf 'REFUSED: server port %q is not %s\n' "$actual_port" "$STAGING_PORT" >&2
    return 27
  fi
  version_num="$(psql_local -Atqc "SHOW server_version_num")"
  if [[ "$version_num" != 15* ]]; then
    printf 'REFUSED: expected PostgreSQL 15, got server_version_num=%q\n' "$version_num" >&2
    return 22
  fi
  encoding="$(psql_local -Atqc 'SHOW server_encoding')"
  if [[ "$encoding" != 'UTF8' ]]; then
    printf 'REFUSED: expected UTF8 database encoding, got %q\n' "$encoding" >&2
    return 26
  fi
  actual_user="$(psql_local -Atqc 'SELECT current_user')"
  printf 'Verified target: database=%s host=%s port=%s server=PostgreSQL %s user=%s\n' \
    "$actual_db" "$STAGING_HOST" "$STAGING_PORT" \
    "$(psql_local -Atqc 'SHOW server_version')" "$actual_user"
}

assert_local_staging_marker() {
  local marker
  marker="$(psql_local -Atqc "SELECT name FROM quena_staging.environment")"
  if [[ "$marker" != "$STAGING_DATABASE" ]]; then
    printf 'REFUSED: staging marker is missing or unexpected\n' >&2
    return 23
  fi
}
