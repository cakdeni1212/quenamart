#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
host=127.0.0.1
port=55441
database=quena_stock_staging
staging_user="${QUENA_GO_LIVE_STAGING_USER:-$(id -un)}"
psql_cmd=(psql -X -v ON_ERROR_STOP=1 -h "$host" -p "$port" -U "$staging_user" -d "$database")

# This runner intentionally rebuilds only the pinned disposable local database.
server_guard="$(psql -X -Atqc "SELECT current_database()='postgres' AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1') AND inet_server_port()=${port} AND current_setting('server_version_num')::integer/10000=15" -h "$host" -p "$port" -U "$staging_user" -d postgres)"
if [[ "$server_guard" != t ]]; then
  echo "Refusing: expected disposable localhost PostgreSQL 15 on port ${port}." >&2
  exit 2
fi

dropdb --if-exists -h "$host" -p "$port" -U "$staging_user" "$database"
createdb -h "$host" -p "$port" -U "$staging_user" "$database"
"${psql_cmd[@]}" -f "$repo_root/tests/staging/bootstrap-go-live-costing-controls.sql"

# Supabase migration ordering has the un-timestamped base schema first. The
# unrelated local/untracked 280000 performance experiment is deliberately skipped.
"${psql_cmd[@]}" -f "$repo_root/supabase/migrations/20260928_product_ipos_schema_v1.sql"
for migration in "$repo_root"/supabase/migrations/*.sql; do
  name="${migration##*/}"
  if [[ "$name" == 20260928_product_ipos_schema_v1.sql \
     || "$name" == 20260929280000_costing_hpp_acceptance_prepare_performance_v1.sql ]]; then
    continue
  fi
  printf 'Applying %s\n' "$name"
  "${psql_cmd[@]}" -f "$migration" >/dev/null
done

"${psql_cmd[@]}" -c "INSERT INTO public.stock_authority_periods(outlet_id,mode,created_reason)
  SELECT id,'IPOS_SNAPSHOT_PLUS_QUENA_MOVEMENTS','Initial disposable go-live test period'
  FROM public.outlets WHERE code='QUENA-MART-1'
    AND NOT EXISTS(SELECT 1 FROM public.stock_authority_periods p WHERE p.outlet_id=outlets.id AND p.ended_at IS NULL)"
"${psql_cmd[@]}" -f "$repo_root/tests/staging/runtime-go-live-costing-controls.sql"
"${psql_cmd[@]}" -f "$repo_root/tests/staging/runtime-go-live-activation-precheck.sql"
"${psql_cmd[@]}" -f "$repo_root/tests/staging/runtime-operational-expenses-pre-wac.sql"

first_log="$(mktemp)"
second_log="$(mktemp)"
trap 'rm -f "$first_log" "$second_log"' EXIT
("${psql_cmd[@]}" -f "$repo_root/tests/staging/runtime-go-live-activation-session-one.sql" >"$first_log" 2>&1) &
first_pid=$!
sleep 0.25
set +e
("${psql_cmd[@]}" -f "$repo_root/tests/staging/runtime-go-live-activation-session-two.sql" >"$second_log" 2>&1) &
second_pid=$!
wait "$first_pid"; first_status=$?
wait "$second_pid"; second_status=$?
set -e
if [[ "$first_status" -ne 0 || "$second_status" -eq 0 ]] \
  || ! rg -q 'GO_LIVE_BOOTSTRAP_READY_REQUIRED' "$second_log"; then
  cat "$first_log" "$second_log" >&2
  echo "WAC activation race did not serialize as expected." >&2
  exit 3
fi
activation_count="$("${psql_cmd[@]}" -Atqc "SELECT count(*) FROM public.go_live_wac_activation_confirmation")"
active_count="$("${psql_cmd[@]}" -Atqc "SELECT count(*) FROM public.inventory_costing_outlet_authority WHERE status='WAC_ACTIVE'")"
if [[ "$activation_count" != 1 || "$active_count" != 1 ]]; then
  echo "Expected one activation record and one WAC_ACTIVE outlet." >&2
  exit 4
fi
echo "Two-session activation race: exactly one WAC_ACTIVE transition persisted."

"${psql_cmd[@]}" -f "$repo_root/tests/staging/runtime-go-live-pos-e2e.sql"
"${psql_cmd[@]}" -f "$repo_root/tests/staging/runtime-operational-expenses-post-wac.sql"
echo "GO-LIVE COSTING CONTROLS POSTGRESQL 15 STAGING PASS"
