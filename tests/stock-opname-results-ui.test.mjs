import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { canAccessSection } from '../src/lib/auth/roles.ts';
import {
  formatStockOpnameResultDifference,
  formatStockOpnameResultQuantity,
  hasCurrentMetadataFallback,
  parseStockOpnameResultsQuery,
  stockOpnameMetadataLabel,
  stockOpnameResultEventLabel,
  stockOpnameResultValues,
  stockOpnameResultsHref,
  STOCK_OPNAME_RESULTS_FILTERS,
} from '../src/lib/stock/opname-results-model.ts';

const component = readFileSync(new URL('../src/components/stock/stock-opname-posted-results.tsx', import.meta.url), 'utf8');
const route = readFileSync(new URL('../app/(workspace)/stok/opname/[id]/page.tsx', import.meta.url), 'utf8');
const countingReader = readFileSync(new URL('../src/lib/stock/opname-count-read.ts', import.meta.url), 'utf8');
const resultsReader = readFileSync(new URL('../src/lib/stock/opname-results-read.ts', import.meta.url), 'utf8');
const countingComponent = readFileSync(new URL('../src/components/stock/stock-opname-counting.tsx', import.meta.url), 'utf8');

test('POSTED route uses dedicated result reader and leaves other session states in counting workflow', () => {
  assert.match(route, /data\.session\?\.status === "POSTED"[\s\S]*readStockOpnamePostedResults[\s\S]*StockOpnamePostedResults/);
  assert.match(route, /<StockOpnameCounting data=\{data\}/);
  assert.match(countingReader, /session\.status === "POSTED"[\s\S]*\.\.\.empty\(query, null\)/);
  assert.match(countingReader, /POSTED results are read through the dedicated bounded results RPC/);
  assert.match(route, /canAccessSection\(profile\.role, "stok"\)/);
  assert.match(resultsReader, /canAccessSection\(profile\.role, "stok"\)/);
  assert.equal(canAccessSection('OWNER', 'stok'), true);
  assert.equal(canAccessSection('ADMIN', 'stok'), true);
  assert.equal(canAccessSection('GUDANG', 'stok'), true);
  assert.equal(canAccessSection('KASIR', 'stok'), false);
});

test('posted results reader calls the RPC with bounded DB-side search, filter and page parameters', () => {
  assert.match(resultsReader, /stock_opname_posted_results_page/);
  assert.match(resultsReader, /p_search: query\.search \|\| null/);
  assert.match(resultsReader, /p_result_filter: query\.filter/);
  assert.match(resultsReader, /p_page: query\.page/);
  assert.match(readFileSync(new URL('../src/lib/stock/opname-results-model.ts', import.meta.url), 'utf8'), /STOCK_OPNAME_RESULTS_PAGE_SIZE = 40/);
  assert.match(resultsReader, /summary: \{/);
  assert.match(component, /summary\.totalItems[\s\S]*summary\.counted[\s\S]*summary\.match[\s\S]*summary\.difference[\s\S]*summary\.increased[\s\S]*summary\.decreased[\s\S]*summary\.exceptions/);
  assert.doesNotMatch(component, /rows\.reduce|rows\.filter\(.*difference/);
});

test('quantity formatting preserves signs, zero, three decimals, and removes trailing zero noise', () => {
  assert.equal(formatStockOpnameResultDifference(10), '+10');
  assert.equal(formatStockOpnameResultDifference(-4), '-4');
  assert.equal(formatStockOpnameResultDifference(0), '0');
  assert.equal(formatStockOpnameResultQuantity('2.500'), '2,5');
  assert.equal(formatStockOpnameResultQuantity(1.234), '1,234');
});

test('exception values never render a NULL physical count as zero', () => {
  const values = stockOpnameResultValues({ exception: true, baseline: 10, physical: null, difference: null, after: null });
  assert.deepEqual(values, {
    before: '10', physical: 'Tidak dihitung', difference: '—',
    after: 'Tidak diubah oleh opname', adjustment: 'Tidak dilakukan',
  });
  assert.doesNotMatch(JSON.stringify(values), /physical.*0/);
  assert.match(component, /<strong>Alasan:<\/strong> \{row\.exceptionReason\?\.trim\(\) \|\| "Tidak tersedia"\}/);
  assert.match(component, /is-exception/);
});

test('counted historical result uses RPC baseline, physical, difference and after fields', () => {
  assert.deepEqual(stockOpnameResultValues({ exception: false, baseline: 10, physical: 8, difference: -2, after: 8 }), {
    before: '10', physical: '8', difference: '-2', after: '8', adjustment: null,
  });
  assert.match(component, /baseline: row\.baselineQuantity/);
  assert.match(component, /physical: row\.physicalQuantity/);
  assert.match(component, /difference: row\.difference/);
  assert.match(component, /after: row\.historicalAfterQuantity/);
  assert.doesNotMatch(resultsReader, /stock_balance_projection|stock_movements/);
});

test('metadata provenance displays snapshot, one current-fallback notice, and unavailable placeholders honestly', () => {
  assert.equal(stockOpnameMetadataLabel('AQUA 600 ML', 'POST_SNAPSHOT'), 'AQUA 600 ML');
  assert.equal(hasCurrentMetadataFallback('POST_SNAPSHOT', ['POST_SNAPSHOT']), false);
  assert.equal(hasCurrentMetadataFallback('CURRENT_FALLBACK', ['CURRENT_FALLBACK']), true);
  assert.equal(hasCurrentMetadataFallback('POST_SNAPSHOT', ['POST_SNAPSHOT', 'CURRENT_FALLBACK']), true);
  assert.equal(stockOpnameMetadataLabel(null, 'LEGACY_UNAVAILABLE'), 'Tidak tersedia');
  assert.match(component, /Metadata untuk opname lama ini menggunakan data produk atau outlet saat ini/);
  assert.match(component, /stockOpnameMetadataLabel\(row\.productName, row\.metadataProvenance\)/);
});

test('filters map exactly to the RPC contract and a filter change resets page to one', () => {
  assert.deepEqual(STOCK_OPNAME_RESULTS_FILTERS, ['ALL', 'DIFFERENCE', 'MATCH', 'INCREASE', 'DECREASE', 'EXCEPTION']);
  assert.equal(parseStockOpnameResultsQuery({ filter: 'increase', page: '4' }).filter, 'INCREASE');
  const href = stockOpnameResultsHref('/stok/opname/id', { search: 'aqua', filter: 'DECREASE', page: 4 }, { filter: 'MATCH', page: 1 });
  assert.equal(href, '/stok/opname/id?q=aqua&filter=MATCH');
  assert.match(component, /chooseFilter[\s\S]*filter, page: 1/);
  for (const [code, label] of Object.entries({ ALL: 'Semua', DIFFERENCE: 'Ada selisih', MATCH: 'Sesuai', INCREASE: 'Stok bertambah', DECREASE: 'Stok berkurang', EXCEPTION: 'Pengecualian' })) {
    assert.match(component, new RegExp(`${code}: "${label}"`));
  }
});

test('search is debounced and navigates to database search while retaining filter state', () => {
  assert.equal(parseStockOpnameResultsQuery({ q: '  Aqua  ', filter: 'MATCH', page: '3' }).search, 'Aqua');
  assert.match(component, /setTimeout\(\(\) => \{[\s\S]*search: normalized, page: 1[\s\S]*\}, 300\)/);
  assert.match(resultsReader, /p_search: query\.search \|\| null/);
  assert.match(component, /placeholder="Nama produk atau SKU"/);
});

test('pagination remains bounded and preserves search/filter query', () => {
  assert.equal(stockOpnameResultsHref('/results', { search: 'Indomie', filter: 'DIFFERENCE', page: 1 }, { page: 2 }), '/results?q=Indomie&filter=DIFFERENCE&page=2');
  assert.match(component, /Math\.ceil\(page\.totalMatching \/ page\.pageSize\)/);
  assert.match(component, /page\.page - 1/);
  assert.match(component, /page\.page \+ 1/);
  assert.match(readFileSync(new URL('../src/lib/stock/opname-results-model.ts', import.meta.url), 'utf8'), /STOCK_OPNAME_RESULTS_PAGE_SIZE = 40/);
});

test('bounded session timeline renders lifecycle labels and supplied timestamps only', () => {
  assert.equal(stockOpnameResultEventLabel('CREATED'), 'Dibuat');
  assert.equal(stockOpnameResultEventLabel('SUBMITTED_FOR_REVIEW'), 'Dikirim untuk review');
  assert.equal(stockOpnameResultEventLabel('RETURNED_TO_COUNTING'), 'Dikembalikan ke penghitungan');
  assert.equal(stockOpnameResultEventLabel('POSTED'), 'Selesai');
  assert.match(component, /Riwayat opname/);
  assert.match(component, /timeline\.map\(\(event\)/);
  assert.match(resultsReader, /actorId: text\(candidate\.actor_id\)/);
  assert.doesNotMatch(resultsReader, /stock_opname_count_events/);
});

test('COUNTING, REVIEW and CANCELLED retain the established non-results workflow and no financial fields are exposed', () => {
  assert.match(countingComponent, /session\.status === "COUNTING"/);
  assert.match(countingComponent, /session\.status === "REVIEW"/);
  assert.match(countingComponent, /session\.status === "CANCELLED"/);
  assert.match(countingComponent, /dibatalkan dan sekarang baca-saja/);
  assert.doesNotMatch(component + resultsReader, /\bhpp\b|cost|profit|margin|selling_price/i);
  assert.doesNotMatch(resultsReader, /stock_balance_projection|stock_movements/);
});

test('read and route failures remain user-safe without fabricated authoritative totals', () => {
  assert.match(resultsReader, /Hasil opname belum dapat dimuat\. Coba muat ulang halaman\./);
  assert.match(component, /data\.error \|\| !data\.header \|\| !data\.summary \|\| !data\.page/);
  assert.match(component, /Tidak ada item yang cocok\./);
  assert.match(component, /role="status"/);
  assert.doesNotMatch(resultsReader, /totalItems: 0|counted: 0|difference: 0/);
});
