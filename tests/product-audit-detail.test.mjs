import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseAuditContext, isUuid } from '../src/lib/product-audit/context.ts';

const loader = readFileSync(new URL('../src/lib/product-audit/read.ts', import.meta.url), 'utf8');
const page = readFileSync(new URL('../app/(workspace)/audit-produk/[productId]/page.tsx', import.meta.url), 'utf8');
const productList = readFileSync(new URL('../app/(workspace)/produk/page.tsx', import.meta.url), 'utf8');

test('focused audit route requires an active profile and audit-section role access', () => {
  assert.match(loader, /await requireProfile\(\)/);
  assert.match(loader, /canAccessSection\(profile\.role, "audit-produk"\)/);
  assert.match(loader, /redirect\("\/dashboard"\)/);
  assert.match(loader, /if \(!isUuid\(productId\)\) return \{ kind: "not-found" \}/);
  assert.match(page, /readProductFieldAudit\(productId\)/);
});

test('GUDANG loader shape excludes all financial values and does not query the costs table', () => {
  assert.match(loader, /const manager = profile\.role === "OWNER" \|\| profile\.role === "ADMIN"/);
  assert.match(loader, /manager\s*\?\s*supabase\.rpc\("read_product_financial_field_source"/);
  assert.match(loader, /\.\.\.\(manager \? \{ financial:/);
  assert.doesNotMatch(loader, /\.from\("product_costs"\)/);
  assert.doesNotMatch(loader, /createAdminClient|SUPABASE_SERVICE_ROLE_KEY/);
  assert.match(loader, /financial\?: \{/);
  assert.match(loader, /\.\.\.\(manager \? \{ financial:[\s\S]*?\} : \{\}\)/);
});

test('OWNER and ADMIN financial data loads only through the manager-only source RPC', () => {
  const call = loader.indexOf('manager\n      ? supabase.rpc("read_product_financial_field_source"');
  const returnFinancial = loader.indexOf('...(manager ? { financial:');
  assert.ok(call >= 0);
  assert.ok(returnFinancial > call);
  assert.match(loader, /financialSourceResult\.error/);
  assert.match(loader, /hpp: displayScalar\(detail\.hpp\)/);
  assert.match(loader, /sellingPrice: displayScalar\(detail\.selling_price\)/);
});

test('source, current values, human review, overrides, and reconciliation remain separate fields', () => {
  assert.match(loader, /sourceValue: ReadValue/);
  assert.match(loader, /currentValue: ReadValue/);
  assert.match(loader, /review: \{/);
  assert.match(loader, /override: \{/);
  assert.match(loader, /reconciliation: \{/);
  assert.match(loader, /product_field_audit_reviews/);
  assert.match(loader, /product_field_overrides/);
  assert.match(loader, /product_field_reconciliation_events/);
  assert.match(page, /Verifikasi tidak menutup temuan sumber/);
  assert.match(page, /record\.review/);
  assert.match(page, /record\.reconciliation/);
});

test('invalid, repeated, inactive, and mismatched query context is rejected', () => {
  const active = ['MISSING_BARCODE', 'MISSING_RACK'];
  assert.deepEqual(parseAuditContext('MISSING_BARCODE', undefined, active), {
    finding: 'MISSING_BARCODE', field: 'barcode', invalid: false,
  });
  assert.equal(parseAuditContext('NO_SUCH_CODE', undefined, active).invalid, true);
  assert.equal(parseAuditContext(['MISSING_BARCODE', 'MISSING_RACK'], undefined, active).invalid, true);
  assert.equal(parseAuditContext('MISSING_BARCODE', 'hpp', active).invalid, true);
  assert.equal(parseAuditContext('ZERO_STOCK', undefined, active).invalid, true);
  assert.equal(parseAuditContext(undefined, 'not-a-field', active).invalid, true);
});

test('focused queue links preserve validated issue and field context; product UUID validation is strict', () => {
  assert.match(productList, /\/audit-produk\/\$\{product\.product_id\}\?finding=\$\{code\}&field=\$\{issueFields\[code\]\}/);
  assert.equal(isUuid('2fdb6fbb-e383-4bed-9eb7-7a55627eb995'), true);
  assert.equal(isUuid('not-a-uuid'), false);
});
