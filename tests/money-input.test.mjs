import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { ceilRupiah, compareRupiah, formatRupiah, formatRupiahInput, parseRupiahInput, subtractRupiah } from '../src/lib/money.ts';

test('canonical Rupiah input groups Indonesian thousands and preserves submitted strings', () => {
  assert.equal(parseRupiahInput('0'), '0');
  assert.equal(formatRupiahInput('0'), '0');
  assert.equal(formatRupiahInput('1200'), '1.200');
  assert.equal(formatRupiahInput('120000'), '120.000');
  assert.equal(formatRupiahInput('1250000'), '1.250.000');
  assert.equal(parseRupiahInput('120000'), '120000');
  assert.equal(parseRupiahInput('120.000'), '120000');
  assert.equal(parseRupiahInput('Rp 120.000'), '120000');
  assert.equal(parseRupiahInput('1.250.000'), '1250000');
  assert.equal(parseRupiahInput('Rp 1.250.000'), '1250000');
});

test('empty, replacement, paste, deletion, and exact two-decimal values remain safe', () => {
  assert.equal(parseRupiahInput(''), '');
  assert.equal(formatRupiahInput(''), '');
  assert.equal(parseRupiahInput('Rp 200.000'), '200000');
  assert.equal(parseRupiahInput('200.000,50'), '200000.50');
  assert.equal(parseRupiahInput('200000.50'), '200000.50');
  assert.equal(parseRupiahInput('-200'), null);
  assert.equal(parseRupiahInput('Rp 12.34.567'), null);
  assert.equal(formatRupiah('120000'), 'Rp 120.000');
  assert.equal(formatRupiah('120000.50'), 'Rp 120.000,5');
  assert.equal(formatRupiah('15.000'), 'Rp 15');
  assert.equal(compareRupiah('200000', '165000'), 1);
  assert.equal(subtractRupiah('200000', '165000'), '35000');
  assert.equal(ceilRupiah('165000.50'), '165001');
});

test('shared component emits canonical value and keeps formatted text/caret controlled', async () => {
  const source = await readFile(new URL('../src/components/ui/rupiah-input.tsx', import.meta.url), 'utf8');
  assert.match(source, /type="text" inputMode="decimal"/);
  assert.match(source, /onValueChange\(canonical\)/);
  assert.match(source, /setSelectionRange\(caret, caret\)/);
  assert.match(source, /type="hidden" name=\{name\} value=\{value\}/);
});
