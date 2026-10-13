import { randomInt, randomUUID } from "node:crypto";
import { spawn, execFileSync } from "node:child_process";

const host = "127.0.0.1";
const port = 55442;
const database = "quena_stock_staging";
const user = process.env.QUENA_C3B_USER ?? process.env.USER;
const actor = "a0000000-0000-4000-8000-000000000001";
const batchA = randomUUID();
const batchB = randomUUID();
const sourceTransaction = `${randomInt(700000, 999999)}/C3B/UTM/1026`;
const requestA = randomUUID();
const requestB = randomUUID();
const psqlArgs = ["-X", "-h", host, "-p", String(port), "-U", user, "-d", database, "-v", "ON_ERROR_STOP=1"];
const run = (sql) => execFileSync("psql", [...psqlArgs, "-f", "-"], { input: sql, encoding: "utf8" });
const guard = execFileSync("psql", [...psqlArgs, "-Atc", `SELECT current_database()='${database}' AND inet_server_port()=${port}
 AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1')
 AND current_setting('server_version_num')::integer/10000=15
 AND EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE status='WAC_ACTIVE')`], { encoding: "utf8" }).trim();
if (!user || guard !== "t") throw new Error("Refusing concurrent commit test outside disposable PostgreSQL 15 WAC_ACTIVE staging.");

const setup = `DO $guard$ BEGIN
 IF current_database()<>'${database}' OR inet_server_port()<>${port}
   OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
   OR current_setting('server_version_num')::integer/10000<>15
 THEN RAISE EXCEPTION 'Unsafe C3B concurrent test target'; END IF;
END $guard$;
BEGIN;
SELECT set_config('request.jwt.claim.sub','${actor}',true);
DO $setup$ DECLARE o uuid;p uuid;batch_id uuid;tx uuid;line uuid;ids uuid[]:=ARRAY['${batchA}'::uuid,'${batchB}'::uuid];i integer;
BEGIN
 SELECT id INTO STRICT o FROM public.outlets WHERE code='QUENA-MART-1';
 SELECT id INTO STRICT p FROM public.products WHERE sku='CUTOVER-MULTI';
 FOR i IN 1..2 LOOP
   batch_id:=ids[i];tx:=gen_random_uuid();line:=gen_random_uuid();
   INSERT INTO public.ipos_sales_import_batches(id,outlet_id,upload_request_id,original_filename,file_sha256,
     report_from,report_to,transaction_count,sale_line_count,total_quantity,total_amount,footer_totals,reconciliation,uploaded_by)
   VALUES(batch_id,o,gen_random_uuid(),'c3b-concurrent.xls',repeat(CASE WHEN i=1 THEN 'a' ELSE 'b' END,64),
     '2026-10-12','2026-10-12',1,1,.001,1,'{}','{"isReconciled":true,"differences":[]}','${actor}');
   INSERT INTO public.ipos_sales_import_transactions(id,batch_id,source_row_number,source_transaction_number,
     source_occurred_at,raw_transaction_total,raw_data)
   VALUES(tx,batch_id,20,'${sourceTransaction}','2026-10-12 12:00:00+07',1,'{}');
   INSERT INTO public.ipos_sales_import_lines(id,batch_id,transaction_id,source_row_number,raw_sku,raw_item_name,
     raw_quantity,raw_unit,raw_unit_price,raw_discount_percent,raw_line_total,raw_data)
   SELECT line,batch_id,tx,22,prod.sku,prod.name,.001,prod.unit_label,1000,0,1,'{}' FROM public.products prod WHERE prod.id=p;
   IF (public.ipos_sales_import_recheck(batch_id,gen_random_uuid())->>'status')<>'READY' THEN
     RAISE EXCEPTION 'Concurrent batch not READY: %',batch_id; END IF;
 END LOOP;
END $setup$;
CREATE FUNCTION public.c3b_test_pause_import() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN IF NEW.source_transaction_number='${sourceTransaction}' THEN PERFORM pg_sleep(3); END IF; RETURN NEW; END; $$;
CREATE TRIGGER c3b_test_pause_import BEFORE INSERT ON public.sales FOR EACH ROW EXECUTE FUNCTION public.c3b_test_pause_import();
COMMIT;
`;
run(setup);

const first = `SELECT set_config('request.jwt.claim.sub','${actor}',false);
SELECT public.ipos_sales_import_commit('${batchA}'::uuid,
  (SELECT revision FROM public.ipos_sales_import_batches WHERE id='${batchA}'::uuid),'${requestA}'::uuid);`;
const second = `SELECT set_config('request.jwt.claim.sub','${actor}',false);
DO $second$ DECLARE error_text text;
BEGIN
  BEGIN PERFORM public.ipos_sales_import_commit('${batchB}'::uuid,
    (SELECT revision FROM public.ipos_sales_import_batches WHERE id='${batchB}'::uuid),'${requestB}'::uuid);
    RAISE EXCEPTION 'C3B_SECOND_COMMIT_UNEXPECTEDLY_SUCCEEDED';
  EXCEPTION WHEN SQLSTATE '23505' THEN
    GET STACKED DIAGNOSTICS error_text=MESSAGE_TEXT;
    IF error_text<>'IPOS_SALES_DUPLICATE_TRANSACTION' THEN RAISE; END IF;
    RAISE NOTICE 'C3B concurrent loser received deterministic IPOS_SALES_DUPLICATE_TRANSACTION';
  END;
END $second$;`;

const runPsql = (sql) => {
  const child = spawn("psql", [...psqlArgs, "-f", "-"], { stdio: ["pipe", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8").on("data", (chunk) => { stdout += chunk; });
  child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
  child.stdin.end(sql);
  return new Promise((resolve, reject) => child.on("close", (code) => {
    if (code !== 0) reject(new Error(`psql exited ${code}: ${stdout}${stderr}`));
    else resolve(stdout + stderr);
  }));
};
const p1 = runPsql(first);
await new Promise((resolve) => setTimeout(resolve, 300));
const p2 = runPsql(second);
const [firstResult, secondResult] = await Promise.all([p1, p2]);
if (!firstResult.includes('"status": "COMMITTED"') || !secondResult.includes("IPOS_SALES_DUPLICATE_TRANSACTION")) {
  throw new Error(`Concurrent commit outcome was unexpected. First: ${firstResult}\nSecond: ${secondResult}`);
}

const verify = run(`SELECT set_config('request.jwt.claim.sub','${actor}',false);
DO $verify$ DECLARE sales_n integer;moves_n integer;cost_n integer;batch_n integer;sku_id uuid;
BEGIN
 SELECT count(*) INTO sales_n FROM public.sales WHERE source_system='IPOS_IMPORT' AND source_transaction_number='${sourceTransaction}';
 SELECT count(*) INTO moves_n FROM public.stock_movements m JOIN public.ipos_sales_import_transactions t ON t.id=m.ipos_sales_import_transaction_id
   WHERE t.source_transaction_number='${sourceTransaction}';
 SELECT count(*) INTO cost_n FROM public.inventory_cost_events e WHERE e.source_entity_type='IPOS_IMPORT_INVENTORY_DEPLETION'
   AND e.source_entity_id IN (SELECT l.id FROM public.ipos_sales_import_lines l JOIN public.ipos_sales_import_transactions t ON t.id=l.transaction_id
     WHERE t.source_transaction_number='${sourceTransaction}');
 SELECT count(*) INTO batch_n FROM public.ipos_sales_import_batches WHERE id IN ('${batchA}','${batchB}') AND status='COMMITTED';
 IF sales_n<>1 OR moves_n<>1 OR cost_n<>1 OR batch_n<>1 THEN
   RAISE EXCEPTION 'Concurrent uniqueness failure: sales %, movement %, valuation %, committed batches %',sales_n,moves_n,cost_n,batch_n; END IF;
 RAISE NOTICE 'C3B concurrent commit PASS: exactly one of two overlapping READY batches committed one sale, stock OUT and valuation depletion';
END $verify$;
DROP TRIGGER c3b_test_pause_import ON public.sales;
DROP FUNCTION public.c3b_test_pause_import();
`);
process.stdout.write(firstResult + secondResult + verify);
