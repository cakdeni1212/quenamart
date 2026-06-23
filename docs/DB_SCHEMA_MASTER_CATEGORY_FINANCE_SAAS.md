# Database Schema — Master Category for Multi-Business Finance SaaS

## 1. Design Principles

- Support multiple businesses under one owner account
- Allow each business to have multiple account types:
  - minimarket
  - agriculture/farm
  - personal/family
  - future new business lines
- Keep categories flexible with a master-category approach
- Support hierarchical categories and subcategories
- Make reporting consistent across all business types
- Separate business data from personal/family spending, while still visible in one dashboard

---

## 2. Core Concept

### Entity levels
- **Organization/User Owner**: the controlling account
- **Business**: one commercial unit or activity
- **Category Master**: global category definition
- **Category Group**: high-level grouping for reporting
- **Transaction**: income/expense records
- **Transaction Item**: optional detail line for one transaction
- **Ledger Source**: where the transaction belongs

### Example business scopes
- Minimarket A
- Farm / Agriculture
- Personal / Family
- New business in the future

---

## 3. Recommended Approach

Use **one flexible transaction table** with a `type` field and a `category_id` link.

This allows:
- income and expense in one structure
- easy filtering by business
- future expansion into transfers, adjustments, and split transactions

---

## 4. Tables

## 4.1 users
Stores login accounts.

- id (PK)
- name
- email (unique)
- password_hash
- phone
- status
- created_at
- updated_at

## 4.2 businesses
Stores all business units, including personal/family ledger if needed.

- id (PK)
- owner_user_id (FK -> users.id)
- name
- business_type
  - `minimarket`
  - `farm`
  - `personal`
  - `other`
- description
- is_active
- created_at
- updated_at

## 4.3 business_members
If later there are staff, family, admin, or investor access.

- id (PK)
- business_id (FK)
- user_id (FK)
- role
  - `owner`
  - `admin`
  - `staff`
  - `viewer`
  - `investor`
- created_at
- updated_at

## 4.4 category_groups
High-level category grouping for reporting.

Examples:
- Pendapatan
- Pengeluaran Operasional
- Pengeluaran Produksi
- Pengeluaran Pribadi
- Aset
- Liabilitas

Fields:
- id (PK)
- business_id (FK, nullable if global)
- name
- direction
  - `income`
  - `expense`
  - `asset`
  - `liability`
  - `equity`
- sort_order
- is_system
- created_at
- updated_at

## 4.5 categories_master
Master category table. This is the most important table for your use case.

Examples:
- Penjualan Harian
- Belanja Barang Dagangan
- Upah Kerja
- Pupuk
- Bibit
- Transportasi
- Listrik
- Gaji Karyawan
- Belanja Keluarga
- Kebutuhan Anak
- Pribadi Lainnya

Fields:
- id (PK)
- business_id (FK, nullable)
- category_group_id (FK -> category_groups.id)
- parent_id (FK -> categories_master.id, nullable)
- name
- code
- direction
  - `income`
  - `expense`
- applies_to
  - `minimarket`
  - `farm`
  - `personal`
  - `all`
- is_active
- is_system
- created_at
- updated_at

### Notes
- `parent_id` allows hierarchy
- `applies_to` helps reuse one category for several business types
- if `business_id` is null, category is global template

## 4.6 accounts
Optional cash/bank/wallet accounts.

Examples:
- Cash Minimarket
- Bank BCA
- Cash Farm
- E-wallet pribadi

Fields:
- id (PK)
- business_id (FK)
- name
- account_type
  - `cash`
  - `bank`
  - `ewallet`
  - `other`
- currency
- opening_balance
- is_active
- created_at
- updated_at

## 4.7 transactions
Main financial records.

Fields:
- id (PK)
- business_id (FK)
- account_id (FK, nullable)
- category_id (FK -> categories_master.id)
- transaction_type
  - `income`
  - `expense`
  - `transfer`
  - `adjustment`
- transaction_date
- amount
- description
- reference_no
- created_by (FK -> users.id)
- created_at
- updated_at

### Examples
- Minimarket: penjualan harian
- Farm: upah kerja, pupuk, bibit
- Personal: belanja keluarga

## 4.8 transaction_details
Optional line-item detail if one transaction has multiple breakdowns.

Fields:
- id (PK)
- transaction_id (FK)
- category_id (FK)
- description
- amount
- qty
- unit_price
- created_at

## 4.9 attachments
For receipts, invoices, or proof of transaction.

Fields:
- id (PK)
- transaction_id (FK)
- file_url
- file_type
- uploaded_by (FK)
- created_at

## 4.10 reports
Stored monthly/period summaries.

Fields:
- id (PK)
- business_id (FK)
- period_start
- period_end
- total_income
- total_expense
- net_profit
- notes
- created_by
- created_at

---

## 5. Relationships

- one user can own many businesses
- one business can have many members
- one business has many categories
- categories can be nested using `parent_id`
- one business has many transactions
- one transaction belongs to one category
- one transaction can have many transaction details
- one transaction can have many attachments

---

## 6. Master Category Structure Example

### Group: Pendapatan
- Penjualan Minyak / Barang Dagangan
- Penjualan Harian
- Pendapatan Lain-lain

### Group: Pengeluaran Operasional Minimarket
- Pembelian Stok Barang
- Gaji Karyawan
- Listrik
- Air
- Internet
- Transportasi
- Maintenance

### Group: Pengeluaran Pertanian
- Upah Kerja
- Pupuk
- Bibit
- Pestisida
- Sewa Lahan
- Transportasi
- Peralatan

### Group: Pengeluaran Pribadi
- Belanja Keluarga
- Kebutuhan Rumah Tangga
- Pendidikan Anak
- Kesehatan
- Hiburan

---

## 7. Reporting Logic

With this schema, you can filter by:
- business
- business type
- category group
- category
- date range
- income vs expense
- personal vs business

This makes it possible to answer questions like:
- berapa omzet minimarket per hari?
- berapa biaya pertanian minggu ini?
- berapa pengeluaran pribadi keluarga bulan ini?
- bisnis mana yang paling sehat?

---

## 8. Recommended MVP Database Scope

For the first version, build only:
- users
- businesses
- business_members
- category_groups
- categories_master
- accounts
- transactions
- transaction_details
- attachments
- reports

You can add later:
- budgets
- recurring transactions
- cashflow forecast
- profit sharing
- investor distributions
- approvals

---

## 9. Suggested Enum Values

### business_type
- minimarket
- farm
- personal
- other

### direction
- income
- expense
- asset
- liability
- equity

### transaction_type
- income
- expense
- transfer
- adjustment

### applies_to
- minimarket
- farm
- personal
- all

### account_type
- cash
- bank
- ewallet
- other

---

## 10. MVP Notes

Kalau tujuan utama kamu adalah monitoring semua bisnis + personal dalam satu tempat, maka struktur paling penting adalah:
- **business** sebagai pemisah data
- **categories_master** sebagai master kategori lintas bisnis
- **transactions** sebagai catatan utama
- **accounts** untuk sumber uang

Ini akan cukup kuat untuk:
- minimarket harian
- pertanian dengan biaya operasional
- pengeluaran keluarga
- penambahan bisnis baru tanpa rombak besar
