# Database Schema MVP — Multi-Business Finance System

## 1. users
Stores login accounts.

- id (uuid, pk)
- name (varchar)
- email (varchar, unique)
- password_hash (varchar)
- phone (varchar, nullable)
- created_at (timestamp)
- updated_at (timestamp)

## 2. businesses
Represents each business workspace.

- id (uuid, pk)
- owner_user_id (uuid, fk -> users.id)
- name (varchar)
- business_type (varchar)
- description (text, nullable)
- start_date (date, nullable)
- is_active (boolean, default true)
- created_at (timestamp)
- updated_at (timestamp)

## 3. business_members
Maps users to businesses and roles.

- id (uuid, pk)
- business_id (uuid, fk -> businesses.id)
- user_id (uuid, fk -> users.id)
- role (enum: owner, admin, viewer, investor)
- created_at (timestamp)

Unique index:
- business_id + user_id

## 4. scopes
Represents whether a transaction belongs to business or personal/family.

- id (uuid, pk)
- user_id (uuid, fk -> users.id)
- scope_type (enum: business, personal)
- business_id (uuid, fk -> businesses.id, nullable)
- name (varchar)
- created_at (timestamp)
- updated_at (timestamp)

Notes:
- If scope_type = business, business_id is required
- If scope_type = personal, business_id is null

## 5. categories
Master categories for income and expense.

- id (uuid, pk)
- user_id (uuid, fk -> users.id)
- scope_type (enum: business, personal)
- business_id (uuid, fk -> businesses.id, nullable)
- name (varchar)
- category_type (enum: income, expense)
- parent_id (uuid, fk -> categories.id, nullable)
- created_at (timestamp)
- updated_at (timestamp)

Examples:
- Income
  - Sales Minimarket
  - Crop Sales
- Expense
  - Sales team salary
  - Labor
  - Fertilizer
  - Seeds
  - Household spending

## 6. transactions
Stores all financial records.

- id (uuid, pk)
- user_id (uuid, fk -> users.id)
- scope_type (enum: business, personal)
- business_id (uuid, fk -> businesses.id, nullable)
- scope_id (uuid, fk -> scopes.id, nullable)
- category_id (uuid, fk -> categories.id)
- transaction_type (enum: income, expense)
- amount (decimal(18,2))
- transaction_date (date)
- description (text, nullable)
- payment_method (varchar, nullable)
- created_by (uuid, fk -> users.id)
- created_at (timestamp)
- updated_at (timestamp)

## 7. attachments
Optional receipts or proof files.

- id (uuid, pk)
- transaction_id (uuid, fk -> transactions.id)
- file_url (text)
- file_type (varchar)
- created_at (timestamp)

## 8. report_snapshots
Stores monthly or daily summary snapshots.

- id (uuid, pk)
- business_id (uuid, fk -> businesses.id, nullable)
- scope_type (enum: business, personal)
- scope_id (uuid, fk -> scopes.id, nullable)
- period_start (date)
- period_end (date)
- total_income (decimal(18,2))
- total_expense (decimal(18,2))
- net_income (decimal(18,2))
- created_at (timestamp)

## 9. notifications
For alerts and report updates.

- id (uuid, pk)
- user_id (uuid, fk -> users.id)
- title (varchar)
- message (text)
- is_read (boolean, default false)
- created_at (timestamp)

## 10. audit_logs
Tracks important actions.

- id (uuid, pk)
- user_id (uuid, fk -> users.id)
- action (varchar)
- entity_type (varchar)
- entity_id (uuid)
- metadata (jsonb, nullable)
- created_at (timestamp)

---

# Relationship Summary

- One user can own many businesses
- One business can have many members
- One user can have business scopes and personal scope
- One scope has many transactions
- One category has many transactions
- Categories can have parent-child hierarchy
- Transactions can have attachments
- Reports are generated per business or personal scope

---

# Recommended MVP Simplification

If you want the first version to stay lean, use only:
- users
- businesses
- business_members
- categories
- transactions
- attachments
- report_snapshots

You can add scopes later if you want personal + business separation to be stricter.
