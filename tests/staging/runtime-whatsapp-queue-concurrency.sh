#!/usr/bin/env bash
set -euo pipefail
PORT="$1" DB_USER="$2" DB_NAME="$3"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/quena-whatsapp-race.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
cat >"$TMP/a.sql" <<'SQL'
SELECT set_config('request.jwt.claim.role','service_role',false);
SET ROLE service_role;
BEGIN;
DO $$ DECLARE n integer; BEGIN
  SELECT count(*) INTO n FROM public.notification_outbox_claim(1);
  IF n<>1 THEN RAISE EXCEPTION 'worker A expected one claimed job, got %',n; END IF;
  PERFORM pg_sleep(2);
END $$;
COMMIT;
SQL
cat >"$TMP/b.sql" <<'SQL'
SELECT set_config('request.jwt.claim.role','service_role',false);
SET ROLE service_role;
DO $$ DECLARE n integer; BEGIN
  SELECT count(*) INTO n FROM public.notification_outbox_claim(1);
  IF n<>0 THEN RAISE EXCEPTION 'worker B claimed a job already locked by worker A'; END IF;
END $$;
SQL
psql -X -w -h 127.0.0.1 -p "$PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$TMP/a.sql" >"$TMP/a.log" &
PID=$!
sleep 0.4
psql -X -w -h 127.0.0.1 -p "$PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$TMP/b.sql" >"$TMP/b.log"
wait "$PID"
echo 'PASS: concurrent notification workers claim a job at most once (SKIP LOCKED)'
