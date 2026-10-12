import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { ceilRupiah, compareRupiah, editRupiahInput, formatRupiah, formatRupiahInput, parseCanonicalRupiah, parseRupiahInput, subtractRupiah } from '../src/lib/money.ts';

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
  assert.equal(compareRupiah('120.000', '95.000'), 1);
  assert.equal(compareRupiah('95.000', '120.000'), -1);
  assert.equal(compareRupiah('120.000', '120.000'), 0);
});

test('empty, replacement, paste, deletion, and exact two-decimal values remain safe', () => {
  assert.equal(parseRupiahInput(''), '');
  assert.equal(formatRupiahInput(''), '');
  assert.equal(parseRupiahInput('Rp 200.000'), '200000');
  assert.equal(parseRupiahInput('200.000,50'), '200000.50');
  assert.equal(parseRupiahInput('200.000,5'), '200000.5');
  assert.equal(parseRupiahInput('200000,50'), '200000.50');
  assert.equal(parseCanonicalRupiah('200000.50'), '200000.50');
  assert.equal(formatRupiahInput('200000.50'), '200.000,50');
  assert.equal(parseRupiahInput('-200'), null);
  assert.equal(parseRupiahInput('Rp 12a.34'), null);
  assert.equal(formatRupiah('120000'), 'Rp 120.000');
  assert.equal(formatRupiah('120000.50'), 'Rp 120.000,5');
  assert.equal(formatRupiah('15.000'), 'Rp 15');
  assert.equal(compareRupiah('200000', '165000'), 1);
  assert.equal(subtractRupiah('200000', '165000'), '35000');
  assert.equal(ceilRupiah('165000.50'), '165001');
});

test('RupiahInput edit transition rebuilds full grouping for every typed digit', () => {
  const steps = [
    ['1', '1'], ['12', '12'], ['120', '120'], ['1200', '1.200'],
    ['12000', '12.000'], ['120000', '120.000'], ['1200000', '1.200.000'],
    ['12000000', '12.000.000'], ['120000000', '120.000.000'],
  ];
  let display = '';
  for (const [raw, expected] of steps) {
    const edit = editRupiahInput(display + raw.at(-1));
    assert.equal(edit.canonical, raw);
    assert.equal(edit.display, expected);
    display = edit.display;
  }
});

test('RupiahInput edit transition supports formatted paste, replacement, backspace, and empty', () => {
  for (const pasted of ['120000', '120.000', 'Rp 120.000']) {
    const edit = editRupiahInput(pasted);
    assert.equal(edit.canonical, '120000');
    assert.equal(edit.display, '120.000');
  }
  assert.deepEqual(editRupiahInput('1.200.000'), { canonical: '1200000', display: '1.200.000', incomplete: false });
  assert.deepEqual(editRupiahInput('15000000'), { canonical: '15000000', display: '15.000.000', incomplete: false });
  assert.deepEqual(editRupiahInput(''), { canonical: '', display: '', incomplete: false });

  let display = '120.000';
  for (const [expectedValue, expectedDisplay] of [['12000', '12.000'], ['1200', '1.200'], ['120', '120']]) {
    const edit = editRupiahInput(display.slice(0, -1));
    assert.equal(edit.canonical, expectedValue);
    assert.equal(edit.display, expectedDisplay);
    display = edit.display;
  }
  const typedAgain = editRupiahInput(`${display}0`);
  assert.equal(typedAgain.canonical, '1200');
  assert.equal(typedAgain.display, '1.200');
  const decimalStart = editRupiahInput('1200,');
  assert.equal(decimalStart.display, '1.200,');
  const decimalTenths = editRupiahInput(`${decimalStart.display}5`);
  assert.equal(decimalTenths.canonical, '1200.5');
  assert.equal(decimalTenths.display, '1.200,5');
  const decimalHundredths = editRupiahInput(`${decimalTenths.display}0`);
  assert.equal(decimalHundredths.canonical, '1200.50');
  assert.equal(decimalHundredths.display, '1.200,50');
});

test('shared component emits canonical value and keeps formatted text/caret controlled', async () => {
  const source = await readFile(new URL('../src/components/ui/rupiah-input.tsx', import.meta.url), 'utf8');
  assert.match(source, /type="text" inputMode="decimal"/);
  assert.match(source, /onValueChange\(edit\.canonical\)/);
  assert.match(source, /setSelectionRange\(caret, caret\)/);
  assert.match(source, /type="hidden" name=\{name\} value=\{value\}/);
  assert.match(source, /editRupiahInput\(next\)/);
  assert.match(source, /onChange=\{\(event\) => handleChange\(event\.currentTarget\.value, event\.currentTarget\.selectionStart\)\}/);
  assert.match(source, /currencyPrefix && <span aria-hidden="true">Rp<\/span>/);
});
