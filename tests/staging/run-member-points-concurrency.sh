#!/usr/bin/env bash
set -euo pipefail

host=127.0.0.1
port=55441
database=quena_stock_staging
db_user="${QUENA_GO_LIVE_STAGING_USER:-$(id -un)}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/quena-loyalty-concurrency.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
psql=(psql -X -v ON_ERROR_STOP=1 -h "$host" -p "$port" -U "$db_user" -d "$database")

server_guard="$(psql -X -Atqc "SELECT current_database()='postgres' AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1') AND inet_server_port()=${port} AND current_setting('server_version_num')::integer/10000=15" -h "$host" -p "$port" -U "$db_user" -d postgres)"
if [[ "$server_guard" != t ]]; then
  echo "Refusing: expected disposable localhost PostgreSQL 15 on port ${port}." >&2
  exit 2
fi

"${psql[@]}" -f "$(dirname "$0")/runtime-member-points-concurrency-setup.sql"
rows="$("${psql[@]}" -At -F '|' -c "SELECT cart_id,revision,request_id FROM public.runtime_member_points_concurrency ORDER BY request_id")"
row0="$(printf '%s\n' "$rows" | sed -n '1p')"
row1="$(printf '%s\n' "$rows" | sed -n '2p')"
if [[ -z "$row0" || -z "$row1" ]]; then echo "Expected two prepared checkout carts." >&2; exit 3; fi

IFS='|' read -r cart0 revision0 request0 <<<"$row0"
IFS='|' read -r cart1 revision1 request1 <<<"$row1"
(
  sleep 0.15
  "${psql[@]}" -c "SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',false); SET ROLE authenticated; SELECT public.pos_checkout_complete('${request0}','${cart0}',${revision0},'CASH',25,NULL);" >"$tmp/session-0.log" 2>&1
) &
pid0=$!
(
  sleep 0.15
  "${psql[@]}" -c "SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000003',false); SET ROLE authenticated; SELECT public.pos_checkout_complete('${request1}','${cart1}',${revision1},'CASH',25,NULL);" >"$tmp/session-1.log" 2>&1
) &
pid1=$!

status0=0; wait "$pid0" || status0=$?
status1=0; wait "$pid1" || status1=$?
successes=0; failures=0
[[ "$status0" -eq 0 ]] && successes=$((successes+1)) || failures=$((failures+1))
[[ "$status1" -eq 0 ]] && successes=$((successes+1)) || failures=$((failures+1))
if [[ "$successes" -ne 1 || "$failures" -ne 1 ]] \
  || ! rg -q 'POS_LOYALTY_INSUFFICIENT_POINTS' "$tmp/session-0.log" "$tmp/session-1.log"; then
  cat "$tmp/session-0.log" "$tmp/session-1.log" >&2
  echo "Concurrent redemption did not produce one successful checkout and one insufficient-balance rejection." >&2
  exit 4
fi

"${psql[@]}" <<'SQL'
DO $$ DECLARE v_member uuid; v_balance bigint; v_sales integer; v_redeems integer;
BEGIN
  SELECT id INTO v_member FROM public.members WHERE phone='081299991112';
  SELECT coalesce(sum(points_delta),0)::bigint INTO v_balance FROM public.member_point_ledger l WHERE l.member_id=v_member;
  SELECT count(*) INTO v_sales FROM public.sales s JOIN public.runtime_member_points_concurrency c ON c.cart_id=s.pos_cart_id;
  SELECT count(*) INTO v_redeems FROM public.member_point_ledger l JOIN public.sales s ON s.id=l.sale_id
    JOIN public.runtime_member_points_concurrency c ON c.cart_id=s.pos_cart_id WHERE l.event_type='SALE_REDEEM' AND l.points_delta=-1;
  IF v_balance<>0 OR v_sales<>1 OR v_redeems<>1 THEN
    RAISE EXCEPTION 'Concurrent checkout mutated balance/sales/ledger incorrectly: balance %, sales %, redeem events %',v_balance,v_sales,v_redeems;
  END IF;
END $$;
SQL

echo "Two-session redemption race passed: one checkout and ledger debit committed; the other was rejected for insufficient balance."
