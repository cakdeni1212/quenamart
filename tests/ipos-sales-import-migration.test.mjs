import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync(new URL("../supabase/migrations/20260929471000_pos_daily_ipos_sales_import_v1.sql", import.meta.url), "utf8");

test("iPos import permits repeated transaction identities to persist as a preflight blocker", () => {
  assert.doesNotMatch(migration, /ipos_sales_import_transaction_once UNIQUE\(batch_id,source_transaction_number\)/i);
  assert.match(migration, /same_batch\.batch_id=p_batch_id[\s\S]*same_batch\.source_transaction_number=t\.source_transaction_number\)>1/i);
  assert.match(migration, /count\(DISTINCT t\.source_transaction_number\)[\s\S]*t\.duplicate/i);
});

test("SKU recheck uses exact product SKU only and commit revalidates transaction uniqueness", () => {
  const recheck = migration.slice(migration.indexOf("CREATE FUNCTION public.ipos_sales_import_recheck"), migration.indexOf("CREATE FUNCTION public.ipos_sales_import_batch_read"));
  const commit = migration.slice(migration.indexOf("CREATE FUNCTION public.ipos_sales_import_commit"));
  assert.match(recheck, /p\.sku=l\.raw_sku/);
  assert.doesNotMatch(recheck, /p\.name|product_barcodes|similarity\s*\(/i);
  assert.match(recheck, /same_batch\.source_transaction_number=t\.source_transaction_number/);
  assert.match(recheck, /p\.effective_quantity IS NULL OR p\.effective_quantity<l\.q/i);
  assert.match(commit, /t\.source_transaction_number=s\.source_transaction_number/);
  assert.match(commit, /p\.effective_quantity IS NULL OR p\.effective_quantity<x\.q/i);
  assert.match(commit, /IPOS_SALES_DUPLICATE_TRANSACTION/);
});

test("business transaction uniqueness is outlet + source transaction number, independent of file hash or timestamp", () => {
  assert.match(migration, /CREATE UNIQUE INDEX sales_ipos_source_transaction_once ON public\.sales\(outlet_id,source_transaction_number\)\s+WHERE source_system='IPOS_IMPORT'/);
  assert.match(migration, /CREATE UNIQUE INDEX sales_ipos_import_transaction_once ON public\.sales\(source_import_transaction_id\)/);
  assert.match(migration, /UNIQUE\(outlet_id,file_sha256\)/);
  assert.doesNotMatch(migration, /UNIQUE\(outlet_id,source_transaction_number,completed_at\)/i);
});
