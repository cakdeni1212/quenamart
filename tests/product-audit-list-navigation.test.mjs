import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const page = readFileSync(new URL('../app/(workspace)/produk/page.tsx', import.meta.url), 'utf8');
const css = readFileSync(new URL('../app/globals.css', import.meta.url), 'utf8');

test('product name remains linked to the read-only product detail route', () => {
  assert.match(page, /className="product-name" href=\{`\/produk\/\$\{product\.product_id\}`\}/);
});

test('each finding badge links to the focused audit detail and visibly says Periksa', () => {
  assert.match(page, /product\.finding_codes\.map\(\(code\) => <Link key=\{code\} href=\{`\/audit-produk\/\$\{product\.product_id\}\?finding=\$\{code\}&field=\$\{issueFields\[code\]\}`\} className="audit-badge audit-badge-link"/);
  assert.match(page, /<span className="audit-badge-action" aria-hidden="true">Periksa →<\/span>/);
  assert.match(page, /aria-label=\{`Buka pemeriksaan audit produk \$\{product\.name\}:/);
  assert.match(css, /\.audit-badge-link\{display:grid;min-height:34px/);
});

test('multiple findings share the same audit route and only add finding context', () => {
  const findingMap = page.slice(page.indexOf('product.finding_codes.map'), page.indexOf(': <span className="audit-ok">'));
  assert.match(findingMap, /href=\{`\/audit-produk\/\$\{product\.product_id\}\?finding=/);
  assert.equal((findingMap.match(/\/audit-produk\/\$\{product\.product_id\}/g) ?? []).length, 1);
});

test('clean products show non-clickable Bersih and no audit detail link', () => {
  assert.match(page, /: <span className="audit-ok">Bersih<\/span>/);
  const cleanBranch = page.slice(page.indexOf(': <span className="audit-ok">Bersih'), page.indexOf('</div></td>', page.indexOf(': <span className="audit-ok">Bersih')));
  assert.doesNotMatch(cleanBranch, /<Link|href=/);
});

test('filters, product read-only role guard, and manager-only HPP visibility are unchanged', () => {
  assert.match(page, /canAccessSection\(profile\.role, "produk"\)/);
  assert.match(page, /p_search: params\.q\?\.trim\(\)/);
  assert.match(page, /p_category: params\.category\?\.trim\(\)/);
  assert.match(page, /p_rack: params\.rack\?\.trim\(\)/);
  assert.match(page, /p_finding: issue/);
  assert.match(page, /const isManager = profile\.role === "OWNER" \|\| profile\.role === "ADMIN"/);
  assert.match(page, /\{isManager && <th>HPP<\/th>\}/);
  assert.match(page, /\{isManager && <td data-label="HPP">/);
});
