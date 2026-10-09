import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { visibleHppActionError } from '../src/lib/costing/hpp-acceptance-presentation.ts';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const route = read('app/(workspace)/hpp-awal/page.tsx');
const readContract = read('src/lib/costing/hpp-acceptance-read.ts');
const actions = read('src/app/actions/hpp-acceptance.ts');
const workspace = read('src/components/costing/hpp-acceptance-workspace.tsx');
const presentation = read('src/lib/costing/hpp-acceptance-presentation.ts');
const roles = read('src/lib/auth/roles.ts');
const sidebar = read('src/components/app/sidebar.tsx');

test('HPP initial preparation route and navigation are restricted to OWNER and ADMIN', () => {
  assert.match(roles, /"hpp-awal": \["OWNER", "ADMIN"\]/);
  assert.match(route, /requireProfile\(\)/);
  assert.match(route, /canAccessSection\(profile\.role, "hpp-awal"\)/);
  assert.match(route, /redirect\("\/dashboard"\)/);
  assert.match(sidebar, /section: "hpp-awal"/);
});

test('preview is a bounded backend read and current counts are never hardcoded', () => {
  assert.match(readContract, /inventory_cost_initial_hpp_acceptance_preview/);
  assert.match(readContract, /p_page_size: PAGE_SIZE/);
  assert.match(readContract, /const PAGE_SIZE = 20/);
  assert.match(readContract, /\.range\(\(page - 1\) \* PAGE_SIZE, page \* PAGE_SIZE - 1\)/);
  assert.match(readContract, /p_search: search \|\| null/);
  assert.match(readContract, /from\("stock_balance_projection"\)/);
  assert.match(readContract, /\.in\("product_id", productIds\)/);
  assert.match(readContract, /: "EXCEPTIONS"/);
  assert.doesNotMatch(workspace, /3[,.]893|3[,.]912|312[,.]224[,.]318/);
});

test('preview diagnostics are development-only and contain timing plus safe request context', () => {
  assert.match(readContract, /performance\.now\(\)/);
  assert.match(readContract, /elapsedMs:/);
  assert.match(readContract, /error\?\.code/);
  assert.match(readContract, /error\?\.message/);
  assert.match(readContract, /error\?\.details/);
  assert.match(readContract, /error\?\.hint/);
  assert.match(readContract, /hasSearch: search\.length > 0/);
  assert.match(readContract, /view: filter/);
  assert.match(readContract, /pageSize: PAGE_SIZE/);
  assert.match(readContract, /process\.env\.NODE_ENV !== "production"/);
  assert.match(readContract, /preview read completed/);
  assert.match(readContract, /preview read failed/);
});

test('default workflow prioritizes exceptions, separates warnings, and humanizes blockers', () => {
  assert.match(readContract, /: "EXCEPTIONS"/);
  assert.match(workspace, /EXCEPTIONS: "Perlu Ditinjau"/);
  assert.match(workspace, /CANDIDATES: "Siap"/);
  assert.match(workspace, /WARNINGS: "Peringatan"/);
  assert.match(presentation, /HPP sama dengan harga jual/);
  assert.match(presentation, /Harga jual di bawah HPP/);
  assert.match(presentation, /HPP masih Rp0/);
  assert.match(presentation, /Pemeriksaan HPP belum selesai/);
  assert.match(presentation, /Margin sangat tipis/);
  assert.match(presentation, /Margin sangat tinggi/);
  assert.match(presentation, /HPP Rp1/);
  assert.match(workspace, /peringatan ini tidak menghalangi keputusan/i);
  assert.match(workspace, /view === "WARNINGS" \? "Informasi"/);
});

test('initial read has no action-error banner, but an action failure remains visible on its route', () => {
  const initialRoute = 'EXCEPTIONS:1:';
  assert.equal(visibleHppActionError(null, initialRoute), '');
  assert.equal(visibleHppActionError({ message: 'Action failed', routeKey: initialRoute }, initialRoute), 'Action failed');
  assert.equal(visibleHppActionError({ message: 'Old action failed', routeKey: 'CANDIDATES:1:' }, initialRoute), '');
  assert.match(workspace, /const \[actionError, setActionError\] = useState<\{ message: string; routeKey: string \} \| null>\(null\)/);
  assert.match(workspace, /<HppAcceptanceWorkspaceRoute key=\{routeKey\}/);
  assert.match(workspace, /error && <div className="hpp-notice hpp-notice-error"/);
  assert.match(workspace, /data\.error && <div className="hpp-notice hpp-notice-error"/);
  assert.match(workspace, /setActionError\(\{ message: result\.message, routeKey \}\)/);
  assert.match(actions, /Tindakan belum dapat diselesaikan/);
});

test('the unfiltered /hpp-awal view defaults to exceptions and explicit tabs remain URL-driven', () => {
  assert.match(readContract, /const VIEWS: HppAcceptanceView\[\] = \["EXCEPTIONS", "CANDIDATES", "WARNINGS"\]/);
  assert.match(readContract, /return VIEWS\.includes\(text as HppAcceptanceView\) \? text as HppAcceptanceView : "EXCEPTIONS"/);
  assert.match(workspace, /params\.set\("view", view\)/);
  assert.match(workspace, /navigateView\(view\)/);
});

test('prepare is explicit, retry-bound, and does not happen while opening the page', () => {
  assert.match(actions, /prepare_initial_hpp_acceptance/);
  assert.match(workspace, /Siapkan HPP Awal/);
  assert.match(workspace, /hpp-awal:prepare:/);
  assert.doesNotMatch(readContract, /prepare_initial_hpp_acceptance/);
});

test('resolution requires a reason and maps only the four approved dispositions', () => {
  for (const disposition of ['ACCEPT_CURRENT_HPP', 'OPENING_HPP_OVERRIDE', 'LEAVE_UNVALUED', 'AUTHORITATIVE_ZERO']) {
    assert.ok(workspace.includes(disposition));
    assert.ok(actions.includes(disposition));
  }
  assert.match(workspace, /if \(!reason\.trim\(\)\)/);
  assert.match(actions, /if \(!reason\)/);
  assert.match(workspace, /const isZeroHpp = currentHppText/);
  assert.match(workspace, /\{isZeroHpp && <label>/);
  assert.match(actions, /OPENING_HPP_OVERRIDE/);
  assert.match(actions, /p_reason: reason/);
});

test('ADMIN can resolve but only OWNER gets a final approval action', () => {
  assert.match(actions, /authorizedProfile\(true\)/);
  assert.match(actions, /profile\.role !== "OWNER"/);
  assert.match(workspace, /const owner = role === "OWNER"/);
  assert.match(workspace, /owner && prepared && batch\.unresolved === 0/);
  assert.match(workspace, /Persetujuan akhir dilakukan oleh Owner/);
  assert.match(workspace, /Proses ini belum menjalankan WAC dan tidak mengubah stok/);
});

test('stale and approved states are read-only and approval uses only Checkpoint A', () => {
  assert.match(readContract, /INVALIDATED/);
  assert.match(workspace, /Data HPP berubah/);
  assert.match(workspace, /Perbarui Persiapan/);
  assert.match(workspace, /HPP Awal Sudah Disetujui/);
  assert.match(actions, /approve_initial_hpp_acceptance/);
  assert.doesNotMatch(`${actions}\n${readContract}\n${workspace}`, /inventory_cost_bootstrap|inventory_cost_(?:apply|post)|\.from\("(?:product_costs|product_cost_history)"\)\.select/);
  assert.doesNotMatch(`${actions}\n${readContract}\n${workspace}`, /supabase\.from\([^)]*\)\.(?:insert|update|delete|upsert)\(/);
  assert.match(readContract, /from\("stock_balance_projection"\)\s*\.select\("product_id,effective_quantity"\)/);
});

test('phone layout has separate cards, usable action controls, and no table overflow requirement', () => {
  assert.match(workspace, /HppMobileCard/);
  assert.match(workspace, /hpp-mobile-list/);
  assert.match(workspace, /hpp-mobile-action/);
  assert.match(read('app/globals.css'), /\.hpp-table-wrap\{display:none\}/);
  assert.match(read('app/globals.css'), /\.hpp-mobile-list\{display:grid/);
});
