-- PostgreSQL MVP Schema
-- Multi-business financial tracking for: minimarket, agriculture, personal/family expenses, and future new businesses.

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -----------------------------
-- 1) CORE ORG / ACCESS MODEL
-- -----------------------------

CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE,
  phone TEXT,
  password_hash TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE businesses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  business_type TEXT NOT NULL DEFAULT 'general',
  description TEXT,
  is_archived BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE business_memberships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'staff', 'viewer', 'investor')),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, user_id)
);

-- Optional investor relationship metadata
CREATE TABLE business_investors (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  ownership_pct NUMERIC(6,3),
  investment_amount NUMERIC(18,2),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, user_id)
);

-- -----------------------------
-- 2) MASTER DATA
-- -----------------------------

CREATE TABLE account_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES businesses(id) ON DELETE CASCADE,
  code TEXT,
  name TEXT NOT NULL,
  category_type TEXT NOT NULL CHECK (category_type IN ('income', 'expense', 'asset', 'liability', 'equity', 'transfer')),
  parent_id UUID REFERENCES account_categories(id) ON DELETE SET NULL,
  is_system BOOLEAN NOT NULL DEFAULT FALSE,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, code)
);

CREATE TABLE business_locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  location_type TEXT NOT NULL DEFAULT 'main',
  address TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE payment_methods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES businesses(id) ON DELETE CASCADE,
  code TEXT,
  name TEXT NOT NULL,
  method_type TEXT NOT NULL CHECK (method_type IN ('cash', 'bank_transfer', 'ewallet', 'credit_card', 'debit_card', 'other')),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, code)
);

CREATE TABLE counterparties (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  counterparty_type TEXT NOT NULL CHECK (counterparty_type IN ('customer', 'supplier', 'employee', 'worker', 'investor', 'other')),
  phone TEXT,
  notes TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE expense_templates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  default_category_id UUID REFERENCES account_categories(id) ON DELETE SET NULL,
  default_payment_method_id UUID REFERENCES payment_methods(id) ON DELETE SET NULL,
  notes TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------
-- 3) TRANSACTION LEDGER
-- -----------------------------

CREATE TABLE transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  location_id UUID REFERENCES business_locations(id) ON DELETE SET NULL,
  counterparty_id UUID REFERENCES counterparties(id) ON DELETE SET NULL,
  category_id UUID REFERENCES account_categories(id) ON DELETE SET NULL,
  payment_method_id UUID REFERENCES payment_methods(id) ON DELETE SET NULL,
  created_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,

  transaction_type TEXT NOT NULL CHECK (transaction_type IN ('income', 'expense', 'transfer', 'adjustment')),
  source_module TEXT NOT NULL DEFAULT 'manual' CHECK (source_module IN ('manual', 'import', 'pos', 'api', 'system')),

  reference_no TEXT,
  transaction_date DATE NOT NULL,
  description TEXT NOT NULL,
  notes TEXT,

  amount NUMERIC(18,2) NOT NULL CHECK (amount >= 0),
  tax_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  total_amount NUMERIC(18,2) GENERATED ALWAYS AS (amount + tax_amount) STORED,

  is_personal BOOLEAN NOT NULL DEFAULT FALSE,
  is_confirmed BOOLEAN NOT NULL DEFAULT TRUE,
  is_deleted BOOLEAN NOT NULL DEFAULT FALSE,

  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE transaction_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  item_name TEXT NOT NULL,
  category_id UUID REFERENCES account_categories(id) ON DELETE SET NULL,
  quantity NUMERIC(18,3) NOT NULL DEFAULT 1,
  unit_price NUMERIC(18,2) NOT NULL DEFAULT 0,
  amount NUMERIC(18,2) NOT NULL CHECK (amount >= 0),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- For simple cash movement tracking across businesses and personal use
CREATE TABLE cash_wallets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES businesses(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  wallet_type TEXT NOT NULL CHECK (wallet_type IN ('cash_box', 'bank_account', 'ewallet', 'personal_cash')),
  currency_code TEXT NOT NULL DEFAULT 'IDR',
  opening_balance NUMERIC(18,2) NOT NULL DEFAULT 0,
  current_balance NUMERIC(18,2) NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE cash_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  wallet_id UUID REFERENCES cash_wallets(id) ON DELETE SET NULL,
  transaction_id UUID REFERENCES transactions(id) ON DELETE SET NULL,
  movement_type TEXT NOT NULL CHECK (movement_type IN ('in', 'out', 'transfer_in', 'transfer_out', 'adjustment')),
  movement_date DATE NOT NULL,
  amount NUMERIC(18,2) NOT NULL CHECK (amount >= 0),
  description TEXT NOT NULL,
  created_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------
-- 4) PERIODIC REPORTS / SNAPSHOTS
-- -----------------------------

CREATE TABLE financial_periods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  period_type TEXT NOT NULL CHECK (period_type IN ('daily', 'weekly', 'monthly', 'custom')),
  period_start DATE NOT NULL,
  period_end DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'reopened')),
  closed_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  closed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, period_type, period_start, period_end)
);

CREATE TABLE financial_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  period_id UUID NOT NULL REFERENCES financial_periods(id) ON DELETE CASCADE,
  report_type TEXT NOT NULL CHECK (report_type IN ('summary', 'income_statement', 'cashflow', 'custom')),
  total_income NUMERIC(18,2) NOT NULL DEFAULT 0,
  total_expense NUMERIC(18,2) NOT NULL DEFAULT 0,
  gross_profit NUMERIC(18,2) NOT NULL DEFAULT 0,
  net_profit NUMERIC(18,2) NOT NULL DEFAULT 0,
  total_cash_in NUMERIC(18,2) NOT NULL DEFAULT 0,
  total_cash_out NUMERIC(18,2) NOT NULL DEFAULT 0,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  generated_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  generated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE report_exports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  report_id UUID REFERENCES financial_reports(id) ON DELETE CASCADE,
  export_type TEXT NOT NULL CHECK (export_type IN ('pdf', 'csv', 'xlsx')),
  file_name TEXT NOT NULL,
  file_path TEXT NOT NULL,
  generated_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  generated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------
-- 5) NOTIFICATIONS / AUDIT
-- -----------------------------

CREATE TABLE notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES businesses(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  body TEXT,
  notification_type TEXT NOT NULL DEFAULT 'info' CHECK (notification_type IN ('info', 'warning', 'success', 'error')),
  is_read BOOLEAN NOT NULL DEFAULT FALSE,
  read_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES businesses(id) ON DELETE CASCADE,
  actor_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  entity_type TEXT NOT NULL,
  entity_id UUID,
  action TEXT NOT NULL,
  before_data JSONB,
  after_data JSONB,
  ip_address INET,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------
-- 6) INDEXES
-- -----------------------------

CREATE INDEX idx_businesses_owner_user_id ON businesses(owner_user_id);
CREATE INDEX idx_business_memberships_business_id ON business_memberships(business_id);
CREATE INDEX idx_business_memberships_user_id ON business_memberships(user_id);
CREATE INDEX idx_business_investors_business_id ON business_investors(business_id);
CREATE INDEX idx_categories_business_id ON account_categories(business_id);
CREATE INDEX idx_locations_business_id ON business_locations(business_id);
CREATE INDEX idx_payment_methods_business_id ON payment_methods(business_id);
CREATE INDEX idx_counterparties_business_id ON counterparties(business_id);
CREATE INDEX idx_transactions_business_date ON transactions(business_id, transaction_date DESC);
CREATE INDEX idx_transactions_category_id ON transactions(category_id);
CREATE INDEX idx_transactions_location_id ON transactions(location_id);
CREATE INDEX idx_transactions_personal ON transactions(is_personal);
CREATE INDEX idx_cash_movements_business_date ON cash_movements(business_id, movement_date DESC);
CREATE INDEX idx_financial_periods_business_start_end ON financial_periods(business_id, period_start, period_end);
CREATE INDEX idx_financial_reports_period_id ON financial_reports(period_id);
CREATE INDEX idx_notifications_user_read ON notifications(user_id, is_read);
CREATE INDEX idx_audit_logs_business_created_at ON audit_logs(business_id, created_at DESC);

-- -----------------------------
-- 7) SEED MASTER CATEGORIES (MVP EXAMPLE)
-- -----------------------------

INSERT INTO account_categories (business_id, code, name, category_type, is_system, sort_order)
VALUES
  (NULL, 'INC-SALES', 'Pendapatan Penjualan', 'income', TRUE, 1),
  (NULL, 'INC-OTHER', 'Pendapatan Lainnya', 'income', TRUE, 2),
  (NULL, 'EXP-SALES', 'Biaya Sales / Marketing', 'expense', TRUE, 10),
  (NULL, 'EXP-WAGES', 'Upah Kerja', 'expense', TRUE, 11),
  (NULL, 'EXP-FERTILIZER', 'Pupuk', 'expense', TRUE, 12),
  (NULL, 'EXP-SEED', 'Bibit', 'expense', TRUE, 13),
  (NULL, 'EXP-OPERATION', 'Operasional', 'expense', TRUE, 14),
  (NULL, 'EXP-UTILITIES', 'Listrik / Air / Internet', 'expense', TRUE, 15),
  (NULL, 'EXP-PERSONAL', 'Pengeluaran Pribadi / Keluarga', 'expense', TRUE, 16)
ON CONFLICT DO NOTHING;
