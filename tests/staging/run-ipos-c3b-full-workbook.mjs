import { createHash, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { parseIposSalesWorkbook } from "../../src/lib/ipos-sales/parser.ts";

const require = createRequire(import.meta.url);
const XLSX = require("xlsx");
const host = process.env.QUENA_C3B_HOST ?? "127.0.0.1";
const port = Number(process.env.QUENA_C3B_PORT ?? 55442);
const database = process.env.QUENA_C3B_DATABASE ?? "quena_stock_staging";
const user = process.env.QUENA_C3B_USER ?? process.env.USER;
if (host !== "127.0.0.1" || port !== 55442 || database !== "quena_stock_staging" || !user) {
  throw new Error("C3B runner is pinned to disposable localhost PostgreSQL 15 staging on port 55442.");
}

const workbookBytes = readFileSync(new URL("../../fixtures/ipos/QUENAEX.xls", import.meta.url));
const parsed = parseIposSalesWorkbook(workbookBytes);
if (!parsed.reconciliation.isReconciled || parsed.summary.transactionCount !== 217 || parsed.summary.saleLineCount !== 489
  || parsed.summary.totalQuantity !== "633" || parsed.summary.uniqueSkuCount !== 379 || parsed.summary.totalAmount !== "7077400") {
  throw new Error("Locked QUENAEX parser contract changed; refusing the staging runtime fixture.");
}
const payload = JSON.stringify(parsed);
const alternateWorkbook = XLSX.write(XLSX.read(workbookBytes, { type: "buffer", raw: true }), { type: "buffer", bookType: "biff8" });
const alternateParsed = parseIposSalesWorkbook(alternateWorkbook);
if (alternateParsed.summary.transactionCount !== parsed.summary.transactionCount
  || alternateParsed.summary.saleLineCount !== parsed.summary.saleLineCount
  || alternateParsed.summary.totalQuantity !== parsed.summary.totalQuantity
  || alternateParsed.summary.totalAmount !== parsed.summary.totalAmount
  || alternateParsed.transactions.some((tx, index) => tx.sourceTransactionNumber !== parsed.transactions[index]?.sourceTransactionNumber)) {
  throw new Error("Re-encoded workbook changed source identities or financial totals.");
}
const alternatePayload = JSON.stringify(alternateParsed);
const fileHash = createHash("sha256").update(workbookBytes).digest("hex");
const alternateFileHash = createHash("sha256").update(alternateWorkbook).digest("hex");
if (fileHash === alternateFileHash) throw new Error("Alternate workbook representation has the same file hash.");
const fixtureProducts = JSON.stringify([...new Map(parsed.transactions.flatMap((tx) => tx.lines)
  .map((line) => [line.rawSku, { sku: line.rawSku, name: line.rawItemName, unit: line.rawUnit ?? "PCS" }])).values()]);
const payloadSql = `DO $guard$ BEGIN
 IF current_database()<>'quena_stock_staging' OR inet_server_port()<>55442
   OR coalesce(host(inet_server_addr()),'') NOT IN ('127.0.0.1','::1')
   OR current_setting('server_version_num')::integer/10000<>15
   OR NOT EXISTS(SELECT 1 FROM public.inventory_costing_outlet_authority WHERE status='WAC_ACTIVE')
 THEN RAISE EXCEPTION 'Refusing C3B full-workbook runtime outside disposable PostgreSQL 15 WAC_ACTIVE staging'; END IF;
END $guard$;
BEGIN;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
CREATE TEMP TABLE c3b_payload(value jsonb) ON COMMIT DROP;
INSERT INTO c3b_payload VALUES ($payload$${payload}$payload$::jsonb);
CREATE FUNCTION pg_temp.c3b_fingerprint(p_batch uuid) RETURNS text LANGUAGE sql STABLE AS $$
 SELECT md5(coalesce((SELECT string_agg((to_jsonb(t)-'sale_id'-'duplicate')::text,'|' ORDER BY t.source_row_number,t.id)
   FROM public.ipos_sales_import_transactions t WHERE t.batch_id=p_batch),'')||'::'||
   coalesce((SELECT string_agg((to_jsonb(l)-'product_id'-'resolution'-'sale_item_id')::text,'|' ORDER BY l.source_row_number,l.id)
   FROM public.ipos_sales_import_lines l WHERE l.batch_id=p_batch),''))
$$;
CREATE TEMP TABLE c3b_products(value jsonb) ON COMMIT DROP;
INSERT INTO c3b_products VALUES ($products$${fixtureProducts}$products$::jsonb);
SELECT public.ipos_sales_import_upload('a0000000-0000-4000-8000-000000000001'::uuid,
  '${randomUUID()}'::uuid,'QUENAEX.xls','${fileHash}',
  (SELECT value FROM c3b_payload))->>'batchId' AS batch_id \\gset
SELECT set_config('c3b.batch',:'batch_id',true);
SELECT set_config('c3b.base_revenue',coalesce((SELECT sum(grand_total)::text FROM public.sales
  WHERE (completed_at AT TIME ZONE 'Asia/Jakarta')::date='2026-10-12'), '0'),true);
SELECT set_config('c3b.base_transactions',(SELECT count(*)::text FROM public.sales
  WHERE (completed_at AT TIME ZONE 'Asia/Jakarta')::date='2026-10-12'),true);
DO $products$ DECLARE o uuid;period_id uuid;actor uuid:='a0000000-0000-4000-8000-000000000001';x record;p uuid;r jsonb;
BEGIN
 SELECT id INTO STRICT o FROM public.outlets WHERE code='QUENA-MART-1';
 SELECT id INTO STRICT period_id FROM public.stock_authority_periods WHERE outlet_id=o AND ended_at IS NULL AND mode='QUENA_MOVEMENT_LEDGER';
 INSERT INTO public.products(sku,name,unit_label,created_by,updated_by)
 SELECT e.value->>'sku',e.value->>'name',e.value->>'unit',actor,actor FROM c3b_products c
 CROSS JOIN LATERAL jsonb_array_elements(c.value) e ON CONFLICT(sku) DO NOTHING;
 INSERT INTO public.stock_balance_projection(product_id,outlet_id,authority_period_id,baseline_quantity,unreconciled_movement_delta)
 SELECT p.id,o,period_id,NULL,0 FROM public.products p JOIN c3b_products c ON EXISTS
   (SELECT 1 FROM jsonb_array_elements(c.value) e WHERE e.value->>'sku'=p.sku)
 ON CONFLICT(product_id,outlet_id) DO NOTHING;
 FOR x IN SELECT l.raw_sku,sum(l.raw_quantity)::numeric(32,3) AS needed
   FROM public.ipos_sales_import_lines l WHERE l.batch_id=current_setting('c3b.batch')::uuid GROUP BY l.raw_sku
 LOOP
   SELECT id INTO STRICT p FROM public.products WHERE sku=x.raw_sku;
   IF (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p) IS NULL THEN
     r:=public.enroll_post_wac_product(gen_random_uuid(),p,x.needed+1,'VALUED',5000,
       '2026-10-11 15:00:00+00','Disposable full-workbook staging opening stock fixture.');
   ELSIF (SELECT effective_quantity FROM public.stock_balance_projection WHERE outlet_id=o AND product_id=p)<x.needed THEN
     RAISE EXCEPTION 'Existing fixture stock is insufficient for SKU %',x.raw_sku;
   END IF;
 END LOOP;
END $products$;
SELECT set_config('c3b.raw_hash',pg_temp.c3b_fingerprint(current_setting('c3b.batch')::uuid),true);
DO $preflight$ DECLARE r jsonb;BEGIN r:=public.ipos_sales_import_recheck(current_setting('c3b.batch')::uuid,gen_random_uuid());
 IF r->>'status'<>'READY' THEN RAISE EXCEPTION 'Full QUENAEX batch did not preflight READY: %',r; END IF; END $preflight$;
SELECT public.ipos_sales_import_commit(current_setting('c3b.batch')::uuid,
  (SELECT revision FROM public.ipos_sales_import_batches WHERE id=current_setting('c3b.batch')::uuid),'${randomUUID()}'::uuid) AS result \\gset
SELECT set_config('c3b.commit_result',:'result',true);
DO $verify$ DECLARE b uuid:=current_setting('c3b.batch')::uuid;result jsonb;raw_after text;dupe jsonb;err text;report jsonb;
BEGIN
 result:=current_setting('c3b.commit_result')::jsonb;
 IF result->>'status'<>'COMMITTED' OR (result->>'transactionCount')::integer<>217 OR (result->>'saleLineCount')::integer<>489
   OR (result->>'movementCount')::integer<>489 THEN RAISE EXCEPTION 'Full workbook commit result wrong: %',result; END IF;
 IF (SELECT count(*) FROM public.sales WHERE source_import_batch_id=b)<>217
   OR (SELECT count(*) FROM public.sale_items si JOIN public.sales s ON s.id=si.sale_id WHERE s.source_import_batch_id=b)<>489
   OR (SELECT sum(si.quantity) FROM public.sale_items si JOIN public.sales s ON s.id=si.sale_id WHERE s.source_import_batch_id=b)<>633
   OR (SELECT sum(grand_total) FROM public.sales WHERE source_import_batch_id=b)<>7077400
   OR (SELECT count(*) FROM public.stock_movements m JOIN public.stock_movement_batches mb ON mb.id=m.batch_id
     WHERE mb.ipos_sales_import_batch_id=b)<>489
   OR (SELECT sum(m.quantity_delta) FROM public.stock_movements m JOIN public.stock_movement_batches mb ON mb.id=m.batch_id
     WHERE mb.ipos_sales_import_batch_id=b)<>-633
   OR (SELECT count(*) FROM public.inventory_cost_events e WHERE e.source_entity_type='IPOS_IMPORT_INVENTORY_DEPLETION'
     AND e.source_entity_id IN (SELECT id FROM public.ipos_sales_import_lines WHERE batch_id=b))<>489
   OR (SELECT sum(e.inventory_value_delta) FROM public.inventory_cost_events e WHERE e.source_entity_type='IPOS_IMPORT_INVENTORY_DEPLETION'
     AND e.source_entity_id IN (SELECT id FROM public.ipos_sales_import_lines WHERE batch_id=b))<>-3165000
   OR EXISTS(SELECT 1 FROM public.ipos_sales_import_lines l JOIN public.products p ON p.id=l.product_id
     JOIN public.stock_balance_projection sp ON sp.product_id=p.id AND sp.outlet_id=(SELECT outlet_id FROM public.ipos_sales_import_batches WHERE id=b)
     JOIN public.inventory_cost_projections cp ON cp.product_id=p.id AND cp.outlet_id=sp.outlet_id
     WHERE l.batch_id=b GROUP BY p.id,sp.effective_quantity,cp.physical_quantity,cp.valued_quantity,cp.inventory_value,cp.current_wac
     HAVING sp.effective_quantity<>1 OR cp.physical_quantity<>1 OR cp.valued_quantity<>1 OR cp.inventory_value<>5000 OR cp.current_wac<>5000)
   OR EXISTS(SELECT 1 FROM public.sales s JOIN public.ipos_sales_import_transactions t ON t.id=s.source_import_transaction_id
     WHERE s.source_import_batch_id=b AND (s.completed_at IS DISTINCT FROM t.source_occurred_at OR s.imported_at IS NULL
       OR s.imported_at<t.source_occurred_at))
   OR EXISTS(SELECT 1 FROM public.inventory_cost_events e WHERE e.event_type='SALE_COGS'
     AND e.source_entity_id IN (SELECT si.id FROM public.sale_items si JOIN public.sales s ON s.id=si.sale_id
       WHERE s.source_import_batch_id=b))
 THEN RAISE EXCEPTION 'Full workbook sale/line/qty/revenue/movement/COGS evidence did not reconcile'; END IF;
 IF EXISTS(SELECT 1 FROM public.ipos_sales_import_lines l WHERE l.batch_id=b AND l.sale_item_id IS NULL)
 THEN RAISE EXCEPTION 'Full workbook committed with unlinked sale lines'; END IF;
 IF EXISTS(SELECT 1 FROM public.sale_payments sp JOIN public.sales s ON s.id=sp.sale_id WHERE s.source_import_batch_id=b)
 THEN RAISE EXCEPTION 'Full workbook fabricated payment-method evidence'; END IF;
 report:=public.owner_reports_read('2026-10-12','2026-10-12','2026-10-11','2026-10-11');
 IF (report#>>'{kpis,revenue}')::numeric<>current_setting('c3b.base_revenue')::numeric+7077400
   OR (report#>>'{kpis,transactions}')::integer<>current_setting('c3b.base_transactions')::integer+217
   OR report#>>'{kpis,profit_status}'<>'INCOMPLETE' OR report#>'{kpis,gross_profit}' IS DISTINCT FROM 'null'::jsonb
   OR report#>'{kpis,gross_margin}' IS DISTINCT FROM 'null'::jsonb
   OR report#>'{kpis,operating_profit}' IS DISTINCT FROM 'null'::jsonb
 THEN RAISE EXCEPTION 'Imported revenue or unavailable COGS reporting semantics were wrong: %',report->'kpis'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public' AND indexname='sales_ipos_source_transaction_once'
   AND indexdef ILIKE '%UNIQUE INDEX%ON public.sales USING btree (outlet_id, source_transaction_number)%'
   AND indexdef ILIKE '%WHERE (source_system = ''IPOS_IMPORT''::pos_sale_source)%')
 THEN RAISE EXCEPTION 'Authoritative source transaction uniqueness index is missing or changed'; END IF;
 raw_after:=pg_temp.c3b_fingerprint(b);
 IF raw_after IS DISTINCT FROM current_setting('c3b.raw_hash') THEN RAISE EXCEPTION 'Cek Ulang/commit changed raw source evidence'; END IF;
 dupe:=public.ipos_sales_import_upload('a0000000-0000-4000-8000-000000000001'::uuid,gen_random_uuid(),
   'QUENAEX.xls','${fileHash}',(SELECT value FROM c3b_payload));
 IF dupe->>'code'<>'IPOS_SALES_DUPLICATE_FILE' OR (dupe->>'batchId')::uuid<>b
   OR (SELECT count(*) FROM public.ipos_sales_import_batches WHERE file_sha256='${fileHash}')<>1 THEN
   RAISE EXCEPTION 'Exact-file upload did not resolve the existing batch: %',dupe; END IF;
 RAISE NOTICE 'C3B full QUENAEX PASS: 217 transactions / 489 lines / qty 633 / revenue Rp7,077,400; exact-file duplicate returned original batch';
END $verify$;
-- Different bytes/hash, same business transaction identities: entire batch blocks.
SELECT public.ipos_sales_import_upload('a0000000-0000-4000-8000-000000000001'::uuid,
  '${randomUUID()}'::uuid,'QUENAEX-reencoded.xls','${alternateFileHash}',
  $alternate$${alternatePayload}$alternate$::jsonb)->>'batchId' AS duplicate_batch \\gset
SELECT set_config('c3b.duplicate_batch',:'duplicate_batch',true);
DO $different_hash$ DECLARE b uuid:=current_setting('c3b.duplicate_batch')::uuid;r jsonb;rev integer;err text;before_sales bigint;before_moves bigint;before_cost bigint;
BEGIN
 SELECT count(*) INTO before_sales FROM public.sales;
 SELECT count(*) INTO before_moves FROM public.stock_movements;
 SELECT count(*) INTO before_cost FROM public.inventory_cost_events;
 r:=public.ipos_sales_import_recheck(b,gen_random_uuid());
 IF r->>'status'<>'PREFLIGHT_BLOCKED' OR (r->>'duplicateTransactionCount')::integer<>217
 THEN RAISE EXCEPTION 'Different-hash duplicate transaction batch not blocked: %',r; END IF;
 SELECT revision INTO rev FROM public.ipos_sales_import_batches WHERE id=b;err:=NULL;
 BEGIN PERFORM public.ipos_sales_import_commit(b,rev,gen_random_uuid()); EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err=MESSAGE_TEXT; END;
 IF err IS NULL OR err NOT LIKE '%IPOS_SALES_IMPORT_NOT_READY%' OR (SELECT count(*) FROM public.sales)<>before_sales
   OR (SELECT count(*) FROM public.stock_movements)<>before_moves OR (SELECT count(*) FROM public.inventory_cost_events)<>before_cost
 THEN RAISE EXCEPTION 'Duplicate-transaction blocked commit mutated evidence: %',err; END IF;
 RAISE NOTICE 'C3B different hash / same source transactions PASS: all 217 duplicates block with zero sale/stock/cost mutation';
END $different_hash$;
ROLLBACK;
`;

const guardSql = `SELECT current_database()='${database}' AND inet_server_port()=${port}
 AND coalesce(host(inet_server_addr()),'') IN ('127.0.0.1','::1')
 AND current_setting('server_version_num')::integer/10000=15 AS ok`;
const psqlArgs = ["-X", "-h", host, "-p", String(port), "-U", user, "-d", database, "-v", "ON_ERROR_STOP=1"];
const identity = execFileSync("psql", [...psqlArgs, "-Atc", guardSql], { encoding: "utf8" }).trim();
if (identity !== "t") throw new Error("Disposable PostgreSQL 15 target guard failed.");
execFileSync("psql", [...psqlArgs, "-f", "-"], { input: payloadSql, stdio: ["pipe", "inherit", "inherit"] });
