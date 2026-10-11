#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
database="${QUENA_CUTOVER_STAGING_DB:-quena_stock_cutover_clean}"
port="${QUENA_CUTOVER_STAGING_PORT:-55439}"
host="${QUENA_CUTOVER_STAGING_HOST:-127.0.0.1}"
user="${QUENA_CUTOVER_STAGING_USER:-${USER:-postgres}}"

if [[ "$database" != "quena_stock_cutover_clean" || "$host" != "127.0.0.1" || "$port" != "55439" ]]; then
  echo "Refusing: cutover staging must be the pinned disposable local PostgreSQL database/port." >&2
  exit 2
fi

psql_cmd=(psql -X -v ON_ERROR_STOP=1 -h "$host" -p "$port" -U "$user" -d "$database")
guard="$("${psql_cmd[@]}" -Atqc "SELECT current_database()='quena_stock_cutover_clean' AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1') AND inet_server_port()=55439 AND current_setting('server_version_num')::integer/10000=15 AND to_regprocedure('public.stock_opening_cutover(uuid,uuid,uuid,uuid,text)') IS NOT NULL")"
if [[ "$guard" != "t" ]]; then
  echo "Refusing: expected the disposable local PostgreSQL 15 database with migration 370000 installed." >&2
  exit 2
fi

"${psql_cmd[@]}" -f "$repo_root/tests/staging/runtime-stock-opening-cutover.sql"
QUENA_CUTOVER_STAGING_DB="$database" QUENA_CUTOVER_STAGING_PORT="$port" \
  QUENA_CUTOVER_STAGING_HOST="$host" QUENA_CUTOVER_STAGING_USER="$user" \
  bash "$repo_root/tests/staging/run-stock-opening-cutover-race.sh"
