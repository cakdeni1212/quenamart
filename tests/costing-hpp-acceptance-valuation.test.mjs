import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { compareRupiahValues, formatRupiah, openingHppDisplayValue } from '../src/lib/costing/hpp-acceptance-presentation.ts';
import { readAllPreparedValuationItems, summarizePreparedOpeningValue } from '../src/lib/costing/hpp-acceptance-valuation.ts';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const reader = read('src/lib/costing/hpp-acceptance-read.ts');
const workspace = read('src/components/costing/hpp-acceptance-workspace.tsx');
const actions = read('src/app/actions/hpp-acceptance.ts');
const foundation = read('supabase/migrations/20260929260000_costing_initial_hpp_acceptance_v1.sql');
const globalStyles = read('app/globals.css');

const preparedRow = (overrides = {}) => ({
  preparedEvidence: true,
  disposition: 'OPENING_HPP_OVERRIDE',
  acceptedHpp: '100000',
  currentHpp: '11500',
  blockers: ['HPP_NOT_BELOW_SELLING_PRICE'],
  ...overrides,
});

test('prepared table keeps source HPP separate from the saved opening HPP', () => {
  assert.equal(formatRupiah('11500'), 'Rp11.500');
  assert.equal(openingHppDisplayValue(preparedRow()), 'Rp100.000');
  assert.match(workspace, /<th>HPP Sumber<\/th><th>HPP Awal<\/th>/);
  assert.match(workspace, /formatRupiah\(row\.currentHpp\).*openingHppDisplayValue\(row\)/);
  assert.match(globalStyles, /\.hpp-mobile-grid\{display:grid;grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/);
  assert.match(reader, /acceptedHpp: scalar\(row\.accepted_opening_hpp\)/);
  assert.match(reader, /currentHpp: scalar\(row\.current_hpp\)/);
});

test('opening display handles every saved disposition without changing source evidence', () => {
  assert.equal(openingHppDisplayValue(preparedRow({ disposition: 'ACCEPT_CURRENT_HPP', acceptedHpp: '11500' })), 'Rp11.500');
  assert.equal(openingHppDisplayValue(preparedRow({ disposition: 'LEAVE_UNVALUED', acceptedHpp: null })), 'Belum dinilai');
  assert.equal(openingHppDisplayValue(preparedRow({ disposition: 'AUTHORITATIVE_ZERO', acceptedHpp: '0' })), 'Rp0');
  assert.equal(openingHppDisplayValue(preparedRow({ preparedEvidence: false, disposition: null, acceptedHpp: null, blockers: [] })), 'Rp11.500');
  assert.equal(openingHppDisplayValue(preparedRow({ preparedEvidence: false, disposition: null, acceptedHpp: null })), 'Belum ditinjau');
  assert.match(foundation, /accepted_opening_hpp=CASE WHEN p_disposition='OPENING_HPP_OVERRIDE' THEN p_opening_hpp[\s\S]*?current_hpp ELSE NULL END/);
  assert.doesNotMatch(foundation.slice(foundation.indexOf('CREATE FUNCTION public.resolve_initial_hpp_acceptance_exception'), foundation.indexOf('ALTER FUNCTION public.resolve_initial_hpp_acceptance_exception')), /SET\s+current_hpp\s*=/);
});

test('resolved modal remounts per selected product and reloads saved disposition, amount, and reason', () => {
  assert.match(workspace, /<ResolutionDialog key=\{selected\?\.productId \?\? "closed"\}/);
  assert.match(workspace, /useState<Disposition>\(row\?\.resolved \? row\.disposition as Disposition : "ACCEPT_CURRENT_HPP"\)/);
  assert.match(workspace, /useState\(row\?\.disposition === "OPENING_HPP_OVERRIDE" \? String\(row\.acceptedHpp \?\? ""\) : ""\)/);
  assert.match(workspace, /useState\(row\?\.reason \?\? ""\)/);
});

test('override input gives exact Rupiah preview, submits the unchanged raw value, and warns above selling price', () => {
  assert.equal(formatRupiah('10000'), 'Rp10.000');
  assert.equal(compareRupiahValues('100000', '11500'), 1);
  assert.match(workspace, /Nilai yang akan disimpan: \{formatRupiah\(openingHpp\)\}/);
  assert.match(workspace, /HPP awal yang dimasukkan lebih tinggi daripada harga jual/);
  assert.match(workspace, /openingHpp: disposition === "OPENING_HPP_OVERRIDE" \? openingHpp : null/);
  assert.match(actions, /p_opening_hpp: openingHpp/);
  assert.doesNotMatch(actions, /Number\(.*openingHpp|parseFloat\(.*openingHpp/);
});

test('prepared summary uses saved decisions exactly and labels candidate-only preview separately', () => {
  const result = summarizePreparedOpeningValue([
    { disposition: 'ACCEPT_CURRENT_HPP', acceptedOpeningHpp: '11500', quantity: '2.000' },
    { disposition: 'OPENING_HPP_OVERRIDE', acceptedOpeningHpp: '10000', quantity: '2.000' },
    { disposition: 'AUTHORITATIVE_ZERO', acceptedOpeningHpp: '0', quantity: '4.000' },
    { disposition: 'LEAVE_UNVALUED', acceptedOpeningHpp: null, quantity: '3.000' },
    { disposition: null, acceptedOpeningHpp: null, quantity: '1.000' },
    { disposition: 'OPENING_HPP_OVERRIDE', acceptedOpeningHpp: '123.45', quantity: '1.250' },
  ]);
  assert.deepEqual(result, { openingValue: '43154.3125', valuedProducts: 4, unvaluedProducts: 2 });
  assert.match(reader, /summarizePreparedOpeningValue\(summaryRead\.items\.map/);
  assert.match(reader, /SUMMARY_READ_PAGE_SIZE = 1000/);
  assert.match(reader, /"PREPARED_PROPOSAL"/);
  assert.match(reader, /"CANDIDATE_ESTIMATE"/);
  assert.match(reader, /batch\.approvedValue \?\? preparedValuation\.openingValue/);
  assert.match(workspace, /produk belum dinilai atau ditinjau/);
  assert.match(workspace, /Nilai Kandidat HPP/);
});

test('prepared valuation rejects malformed or over-precision evidence instead of rounding silently', () => {
  assert.throws(() => summarizePreparedOpeningValue([
    { disposition: 'OPENING_HPP_OVERRIDE', acceptedOpeningHpp: '10.001', quantity: '2.000' },
  ]));
});

test('prepared summary reads and values all 3,912 items across 1,000-row pages regardless of visible table page', async () => {
  const items = Array.from({ length: 3912 }, () => ({
    disposition: 'ACCEPT_CURRENT_HPP',
    acceptedOpeningHpp: '100',
    quantity: '1.000',
  }));
  items[1000] = { disposition: 'OPENING_HPP_OVERRIDE', acceptedOpeningHpp: '200', quantity: '1.000' };
  items[2000] = { disposition: 'LEAVE_UNVALUED', acceptedOpeningHpp: null, quantity: '1.000' };
  items[3000] = { disposition: null, acceptedOpeningHpp: null, quantity: '1.000' };
  items[3001] = { disposition: 'AUTHORITATIVE_ZERO', acceptedOpeningHpp: '0', quantity: '1.000' };

  const requestedRanges = [];
  const readSummary = async (visibleTablePage) => {
    assert.ok(visibleTablePage === 1 || visibleTablePage === 2);
    const visibleRows = items.slice((visibleTablePage - 1) * 20, visibleTablePage * 20);
    assert.equal(visibleRows.length, 20);
    const result = await readAllPreparedValuationItems(3912, 1000, async (from, to) => {
      requestedRanges.push([from, to]);
      return { data: items.slice(from, to + 1), error: null };
    });
    assert.equal(result.complete, true);
    assert.equal(result.items.length, 3912);
    return summarizePreparedOpeningValue(result.items);
  };

  const firstVisiblePageSummary = await readSummary(1);
  assert.deepEqual(requestedRanges.slice(0, 4), [[0, 999], [1000, 1999], [2000, 2999], [3000, 3999]]);
  const secondVisiblePageSummary = await readSummary(2);

  assert.deepEqual(firstVisiblePageSummary, { openingValue: '391000', valuedProducts: 3910, unvaluedProducts: 2 });
  assert.deepEqual(secondVisiblePageSummary, firstVisiblePageSummary);
  assert.equal(requestedRanges.length, 8);
  assert.match(reader, /readAllPreparedValuationItems\(\s*summaryItemCount,\s*SUMMARY_READ_PAGE_SIZE/);
  assert.match(reader, /\.order\("product_id"\)[\s\S]*?\.range\(start, end\)/);
  assert.match(reader, /const summaryItemCount = batch\.candidates \+ batch\.exceptions/);
});
