import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("receipt migration is hash-only, one identity per sale, and narrowly granted", async () => {
  const sql = await read("supabase/migrations/20260929479000_digital_receipt_v1.sql");
  assert.match(sql, /sale_id uuid NOT NULL UNIQUE/);
  assert.match(sql, /token_hash text UNIQUE/);
  assert.match(sql, /status IN \('UNISSUED','ACTIVE','REVOKED'\)/);
  assert.match(sql, /source_system='QUENA_POS'[\s\S]*status='COMPLETED'/);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION public\.customer_public_receipt_read\(text\) TO service_role/);
  assert.match(sql, /REVOKE ALL ON public\.sale_public_receipts FROM PUBLIC,anon,authenticated,service_role/);
  assert.doesNotMatch(sql, /GRANT\s+SELECT\s+ON\s+public\.(sales|sale_items|member_point_ledger)\s+TO\s+anon/i);
});

test("public receipt route is dynamic, generic on invalid token, and never renders the bearer token", async () => {
  const page = await read("app/struk/[token]/page.tsx");
  const missing = await read("app/struk/[token]/not-found.tsx");
  const config = await read("next.config.ts");
  assert.match(page, /force-dynamic/);
  assert.match(page, /readPublicCustomerReceipt\(token\)/);
  assert.match(page, /if \(!receipt\) notFound\(\)/);
  assert.match(missing, /Struk tidak ditemukan atau tautan sudah tidak berlaku/);
  assert.doesNotMatch(page, /\{token\}/);
  assert.match(config, /source: "\/struk\/:path\*"/);
  assert.match(config, /private, no-store/);
  assert.match(config, /Referrer-Policy.*no-referrer/);
});

test("customer projection is allow-listed and excludes private/internal fields", async () => {
  const helper = await read("src/lib/receipts/public-receipt.server.ts");
  const sql = await read("supabase/migrations/20260929479000_digital_receipt_v1.sql");
  const publicRead = sql.slice(sql.indexOf("CREATE FUNCTION public.customer_public_receipt_read"), sql.indexOf("CREATE FUNCTION public.customer_receipt_delivery_payload"));
  for (const forbidden of ["sale_id", "member_id", "email", "reference_text", "hpp", "cogs", "profit", "member_token"]) {
    assert.doesNotMatch(publicRead, new RegExp(`'${forbidden}'\\s*,`));
    assert.doesNotMatch(helper.slice(helper.indexOf("export type DigitalReceipt"), helper.indexOf("function isRecord")), new RegExp(`\\b${forbidden}\\??:`));
  }
  assert.match(publicRead, /'member',CASE WHEN s\.member_id IS NULL THEN NULL ELSE jsonb_build_object\('name',m\.full_name,'member_number',m\.member_number\) END/);
  assert.doesNotMatch(publicRead, /m\.phone|m\.email|member_token/);
  assert.match(sql, /policy_snapshot->>'balance_after_event'/);
});

test("staff token issuance uses cryptographic randomness and stores only SHA-256", async () => {
  const action = await read("src/app/actions/pos-cart.ts");
  assert.match(action, /randomBytes\(32\)\.toString\("base64url"\)/);
  assert.match(action, /createHash\("sha256"\)/);
  assert.match(action, /p_token_hash: tokenHash/);
  assert.doesNotMatch(action, /console\.(?:log|error).*token/i);
  assert.match(action, /protocol !== "https:"/);
});

test("WhatsApp payload is a server-only, consent-gated contract with no provider call", async () => {
  const helper = await read("src/lib/receipts/public-receipt.server.ts");
  const sql = await read("supabase/migrations/20260929479000_digital_receipt_v1.sql");
  assert.match(helper, /^import "server-only";/);
  assert.match(helper, /getCustomerReceiptDeliveryPayload/);
  assert.match(sql, /consent_type='MEMBERSHIP_SERVICE'/);
  assert.doesNotMatch(helper, /meta|whatsapp-web|fetch\(/i);
  assert.doesNotMatch(sql, /INSERT INTO public\..*(queue|outbox)/i);
});

test("transaction detail exposes staff link action only through its existing protected read", async () => {
  const detail = await read("app/(workspace)/transaksi/[id]/page.tsx");
  const component = await read("src/components/receipts/staff-digital-receipt-link.tsx");
  assert.match(detail, /requireProfile\(\)/);
  assert.match(detail, /readPosSaleReceipt\(id\)/);
  assert.match(detail, /StaffDigitalReceiptLink saleId=\{receipt\.sale_id\}/);
  assert.match(component, /issueDigitalReceiptLink\(saleId\)/);
  assert.match(component, /URL publik aplikasi belum dikonfigurasi/);
});
