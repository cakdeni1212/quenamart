#!/usr/bin/env bash
set -euo pipefail

readonly DB_HOST="localhost"
readonly DB_PORT="5432"
readonly DB_NAME="quena_stock_staging"
readonly DIAGNOSTIC="tests/staging/phase180000-function-security-diagnostic.sql"

if [[ ! -f "$DIAGNOSTIC" ]]; then
  printf 'Missing diagnostic SQL: %s\n' "$DIAGNOSTIC" >&2
  exit 1
fi

export PGOPTIONS='-c default_transaction_read_only=on'

identity="$(psql -X -w -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 -At -F '|' \
  -c "SELECT current_database(), current_setting('server_version_num')::integer / 10000")"
printf 'Read-only diagnostic target: %s\n' "$identity"
if [[ "$identity" != 'quena_stock_staging|15' ]]; then
  printf 'Refusing: expected localhost:5432/quena_stock_staging on PostgreSQL 15.\n' >&2
  exit 2
fi

psql -X -w -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 -P pager=off -f "$DIAGNOSTIC"
