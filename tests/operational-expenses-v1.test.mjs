import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { formatRupiah, parseCanonicalRupiah } from '../src/lib/money.ts';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const migration = read('supabase/migrations/20260929450000_operational_expenses_v1.sql');
const actions = read('src/app/actions/expenses.ts');
const page = read('app/(workspace)/pengeluaran/page.tsx');
const ui = read('src/components/expenses/expense-workspace.tsx');
const form = read('src/components/expenses/expense-form.tsx');
const dashboard = read('src/lib/dashboard/read.ts');

test('expense money uses the shared exact Rupiah contract', () => {
  assert.equal(parseCanonicalRupiah('120000'), '120000');
  assert.equal(parseCanonicalRupiah('1200000'), '1200000');
  assert.equal(formatRupiah('120000'), 'Rp 120.000');
  assert.equal(formatRupiah('1250000'), 'Rp 1.250.000');
  assert.match(form, /RupiahInput/);
  assert.match(actions, /parseCanonicalRupiah/);
  assert.match(actions, /supabase.rpc\("operational_expense_create"/);
});

test('expense ledger is separate, bounded, and only POSTED evidence contributes to totals', () => {
  assert.match(migration, /CREATE TABLE public\.operational_expenses/);
  assert.match(migration, /CREATE TABLE public\.operational_expense_events/);
  assert.match(migration, /CREATE TABLE public\.operational_expense_requests/);
  assert.match(migration, /FILTER\(WHERE status='POSTED'\)/);
  assert.match(migration, /status='POSTED';/);
  assert.match(migration, /status='CANCELLED'/);
  assert.match(migration, /LEAST\(greatest\(coalesce\(p_page_size,20\),1\),30\)/i);
  assert.doesNotMatch(migration, /CREATE TABLE public\.(?:supplier_expenses|purchase_expenses|general_ledger)/i);
  assert.doesNotMatch(migration.slice(migration.indexOf('CREATE FUNCTION public.owner_dashboard_operating_expense_read')), /supplier_(?:invoices|payables|payment_allocations)|purchase_(?:receipts|invoices)|cost_event|source_layer/i);
});

test('posted financial facts cannot be edited/deleted and cancellation retains reasoned history', () => {
  assert.match(migration, /EXPENSE_POSTED_IMMUTABLE/);
  assert.match(migration, /EXPENSE_HISTORY_IMMUTABLE/);
  assert.match(migration, /operational_expense_events_append_only/);
  assert.match(migration, /evidence jsonb NOT NULL/);
  assert.match(migration, /p_reason IS NULL OR btrim\(p_reason\)=''/);
  assert.match(actions, /Alasan pembatalan wajib diisi/);
});

test('expense contracts derive actor/outlet and enforce OWNER/ADMIN on every RPC', () => {
  for (const name of ['operational_expense_create','operational_expense_update_draft','operational_expense_post','operational_expense_cancel','operational_expenses_page','operational_expense_detail','owner_dashboard_operating_expense_read']) {
    const start = migration.indexOf(`CREATE FUNCTION public.${name}`);
    const end = migration.indexOf(`ALTER FUNCTION public.${name}`, start);
    const body = migration.slice(start, end);
    assert.ok(start >= 0 && end > start, `${name} exists`);
    assert.match(body, /SECURITY DEFINER SET search_path=pg_catalog/);
    assert.match(body, /auth\.uid\(\)/);
    assert.match(body, /role NOT IN \('OWNER'::public\.user_role,'ADMIN'::public\.user_role\)/);
  }
  assert.match(migration, /outlet:=public\.operational_expense_outlet\(\)/);
  assert.match(migration, /REVOKE ALL ON public\.operational_expenses FROM PUBLIC,anon,authenticated,service_role/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.operational_expense_create[\s\S]+TO authenticated/);
});

test('expense page uses Jakarta date helpers, canonical buttons, and no cost fields', () => {
  assert.match(page, /jakartaToday/);
  assert.match(ui, /workspace-primary-action\.module\.css/);
  assert.match(ui, /buttons\.secondary/);
  assert.match(page, /actions\.primary/);
  assert.match(ui, /formatRupiah/);
  const detailRead = migration.slice(migration.indexOf('CREATE FUNCTION public.operational_expense_detail'), migration.indexOf('ALTER FUNCTION public.operational_expense_detail'));
  assert.doesNotMatch(detailRead, /inventory_cost|source_layer|current_wac|cogs|hpp/i);
});

test('dashboard profit remains unavailable unless sale-time gross profit is resolved', () => {
  assert.match(migration, /profit_status='RESOLVED'/);
  assert.match(migration, /'operating_profit',CASE WHEN gross IS NULL THEN NULL/);
  assert.match(dashboard, /owner_dashboard_operating_expense_read/);
  assert.match(dashboard, /operating_profit === null/);
});
