#!/usr/bin/env bash
set -euo pipefail

database="${QUENA_CUTOVER_STAGING_DB:-quena_stock_cutover_clean}"
port="${QUENA_CUTOVER_STAGING_PORT:-55439}"
host="${QUENA_CUTOVER_STAGING_HOST:-127.0.0.1}"
user="${QUENA_CUTOVER_STAGING_USER:-${USER:-postgres}}"
if [[ "$database" != "quena_stock_cutover_clean" || "$host" != "127.0.0.1" || "$port" != "55439" ]]; then
  echo "Refusing: cutover race must run only in the pinned disposable local database." >&2
  exit 2
fi

psql_cmd=(psql -X -v ON_ERROR_STOP=1 -h "$host" -p "$port" -U "$user" -d "$database")
guard="$("${psql_cmd[@]}" -Atqc "SELECT current_database()='quena_stock_cutover_clean' AND inet_server_port()=55439 AND current_setting('server_version_num')::integer/10000=15 AND to_regprocedure('public.stock_opening_cutover(uuid,uuid,uuid,uuid,text)') IS NOT NULL")"
[[ "$guard" == t ]] || { echo "Refusing: staging database guard failed." >&2; exit 2; }
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
"${psql_cmd[@]}" -f "$repo_root/tests/staging/prepare-stock-opening-cutover-race.sql"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/quena-cutover-race.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
outlet='a0000000-0000-4000-8000-000000000200'
commit='a0000000-0000-4000-8000-000000000204'
period='a0000000-0000-4000-8000-000000000206'
request_a='a0000000-0000-4000-8000-000000000207'
request_b='a0000000-0000-4000-8000-000000000208'
confirmation="OPENING-STOCK-CUTOVER:${outlet}:${commit}"

"${psql_cmd[@]}" -c "BEGIN; SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true); SELECT pg_advisory_xact_lock(hashtextextended('COST_BOOTSTRAP_OUTLET:${outlet}',73190411)); SELECT pg_sleep(0.5); SELECT public.stock_opening_cutover('${outlet}','${commit}','${period}','${request_a}','${confirmation}'); COMMIT" >"$tmp_dir/a.out" 2>&1 &
pid_a=$!
sleep 0.1
set +e
"${psql_cmd[@]}" -c "SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',false); SELECT public.stock_opening_cutover('${outlet}','${commit}','${period}','${request_b}','${confirmation}')" >"$tmp_dir/b.out" 2>&1
status_b=$?
wait "$pid_a"
status_a=$?
set -e
if [[ $status_a -ne 0 || $status_b -eq 0 ]] || ! rg -q 'STOCK_CUTOVER_ALREADY_COMPLETED' "$tmp_dir/b.out"; then
  cat "$tmp_dir/a.out" "$tmp_dir/b.out" >&2
  echo "Expected one winner and one STOCK_CUTOVER_ALREADY_COMPLETED loser." >&2
  exit 1
fi

result="$("${psql_cmd[@]}" -Atqc "SELECT (SELECT count(*) FROM public.stock_opening_cutover_requests WHERE outlet_id='${outlet}')=1 AND (SELECT count(*) FROM public.stock_authority_periods WHERE outlet_id='${outlet}' AND ended_at IS NULL)=1 AND (SELECT effective_quantity=7.5 AND unreconciled_movement_delta=0 FROM public.stock_balance_projection WHERE product_id='a0000000-0000-4000-8000-000000000201' AND outlet_id='${outlet}')")"
[[ "$result" == t ]] || { echo "Concurrent cutover state invariant failed." >&2; exit 1; }
echo "PASS: independent PostgreSQL sessions serialized; one cutover committed, the other was rejected."
