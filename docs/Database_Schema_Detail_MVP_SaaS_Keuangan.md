# Database Schema Detail — MVP SaaS Keuangan Multi-Bisnis

## Prinsip Desain

Schema ini dibuat untuk:
- mendukung banyak bisnis dalam satu akun owner
- memisahkan data per bisnis / unit usaha
- mencatat berbagai jenis pengeluaran dan pemasukan
- fleksibel untuk minimarket, pertanian, dan pengeluaran pribadi
- mudah dikembangkan saat ada bisnis baru cukup create workspace/business baru di dashboard

## Konsep Inti

Struktur utama:
- **User**: orang yang login
- **Business**: entitas bisnis atau domain finansial
- **Membership**: relasi user ke business dengan role tertentu
- **Category Master**: kategori transaksi yang bisa disesuaikan per business
- **Account / Wallet**: kas, bank, dompet, atau sumber dana
- **Transaction**: catatan pemasukan dan pengeluaran
- **Transaction Item**: detail baris transaksi jika diperlukan
- **Attachment**: bukti foto/nota
- **Report Snapshot**: ringkasan per periode
- **Recurring Rule**: transaksi rutin opsional

---

# 1. Tabel Users

Menyimpan akun login.

### users
- id (uuid, pk)
- name (varchar)
- email (varchar, unique)
- password_hash (varchar)
- phone (varchar, nullable)
- status (enum: active, inactive, suspended)
- created_at (timestamp)
- updated_at (timestamp)

### Index
- unique(email)

---

# 2. Tabel Businesses

Satu user bisa punya banyak bisnis.

Contoh:
- Minimarket
- Pertanian
- Pribadi / Keluarga
- Bisnis baru nanti tinggal create business dari dashboard

### businesses
- id (uuid, pk)
- owner_user_id (uuid, fk -> users.id)
- name (varchar)
- business_type (varchar, nullable)  
  contoh: retail, agriculture, personal, services
- description (text, nullable)
- currency_code (char(3), default 'IDR')
- status (enum: active, archived)
- created_at (timestamp)
- updated_at (timestamp)

### Catatan
- `business_type` hanya label awal, bukan batasan sistem
- bisnis baru tinggal insert record baru di tabel ini

### Index
- index(owner_user_id)
- index(status)

---

# 3. Tabel Business Members

Untuk akses banyak user ke satu bisnis.

### business_members
- id (uuid, pk)
- business_id (uuid, fk -> businesses.id)
- user_id (uuid, fk -> users.id)
- role (enum: owner, admin, staff, viewer, investor)
- permissions_json (json, nullable)
- joined_at (timestamp)
- created_at (timestamp)
- updated_at (timestamp)

### Catatan Role
- **owner**: full access
- **admin**: input dan edit
- **staff**: input terbatas
- **viewer**: lihat saja
- **investor**: lihat dashboard dan laporan tertentu

### Index
- unique(business_id, user_id)
- index(role)

---

# 4. Tabel Business Units / Locations

Dipakai jika bisnis punya cabang, unit, atau area pencatatan.

Contoh:
- Minimarket Cabang A
- Lahan Sawah 1
- Kebun Durian
- Operasional Rumah Tangga

### business_units
- id (uuid, pk)
- business_id (uuid, fk -> businesses.id)
- name (varchar)
- unit_type (varchar, nullable)
- description (text, nullable)
- is_active (boolean, default true)
- created_at (timestamp)
- updated_at (timestamp)

### Index
- index(business_id)
- index(is_active)

---

# 5. Tabel Master Categories

Ini kategori transaksi utama. Bisa standar global dan bisa custom per bisnis.

Contoh kategori:
- Penjualan
- Upah Kerja
- Pupuk
- Bibit
- Sewa
- Listrik
- Transport
- Barang Dagang
- Sales
- Operasional
- Pribadi
- Keluarga

### categories
- id (uuid, pk)
- business_id (uuid, fk -> businesses.id, nullable)  
  null = kategori global
- parent_id (uuid, fk -> categories.id, nullable)
- name (varchar)
- type (enum: income, expense, transfer, adjustment)
- scope (enum: global, business)
- is_system (boolean, default false)
- is_active (boolean, default true)
- sort_order (int, default 0)
- created_at (timestamp)
- updated_at (timestamp)

### Catatan
- kategori global bisa dipakai sebagai template
- setiap business bisa override / tambah kategori sendiri
- cocok untuk beda kebutuhan minimarket vs pertanian vs pribadi

### Contoh Struktur Kategori
#### income
- Penjualan Minimarket
- Hasil Panen
- Pendapatan Lain-lain

#### expense
- Upah Kerja
- Pupuk
- Bibit
- Barang Dagang
- Gaji Sales
- Transport
- Pribadi
- Keluarga
- Listrik
- Air

### Index
- index(business_id)
- index(type)
- index(parent_id)
- unique(business_id, name) bila business_id not null

---

# 6. Tabel Accounts / Wallets

Untuk mencatat sumber uang.

Contoh:
- Kas Minimarket
- Rekening BCA
- Rekening Mandiri
- Dompet Pribadi
- Kas Pertanian

### accounts
- id (uuid, pk)
- business_id (uuid, fk -> businesses.id)
- unit_id (uuid, fk -> business_units.id, nullable)
- name (varchar)
- account_type (enum: cash, bank, ewallet, other)
- initial_balance (decimal(18,2), default 0)
- current_balance (decimal(18,2), default 0)
- is_active (boolean, default true)
- created_at (timestamp)
- updated_at (timestamp)

### Catatan
- current_balance bisa dihitung dari transaksi atau disimpan untuk percepatan
- cocok untuk tracking kas per bisnis

### Index
- index(business_id)
- index(account_type)

---

# 7. Tabel Transactions

Tabel paling penting untuk semua pemasukan, pengeluaran, dan transfer.

### transactions
- id (uuid, pk)
- business_id (uuid, fk -> businesses.id)
- unit_id (uuid, fk -> business_units.id, nullable)
- account_id (uuid, fk -> accounts.id, nullable)
- category_id (uuid, fk -> categories.id, nullable)
- transaction_type (enum: income, expense, transfer, adjustment)
- transaction_date (date)
- amount (decimal(18,2))
- description (text, nullable)
- reference_no (varchar, nullable)
- counterparty_name (varchar, nullable)
- created_by (uuid, fk -> users.id)
- approved_by (uuid, fk -> users.id, nullable)
- status (enum: draft, posted, void)
- tags_json (json, nullable)
- metadata_json (json, nullable)
- created_at (timestamp)
- updated_at (timestamp)

### Catatan
- semua pencatatan inti masuk ke sini
- transaksi pribadi keluarga juga bisa dicatat sebagai business khusus bernama `Pribadi / Keluarga`
- transfer antar account tetap bisa dicatat tanpa mengganggu laporan laba rugi

### Index
- index(business_id, transaction_date)
- index(category_id)
- index(account_id)
- index(transaction_type)
- index(status)

---

# 8. Tabel Transaction Splits / Items

Untuk transaksi yang perlu dipecah per kategori.

Contoh:
Satu pengeluaran beli barang bisa terdiri dari:
- stok barang
- ongkos kirim
- biaya admin

### transaction_items
- id (uuid, pk)
- transaction_id (uuid, fk -> transactions.id)
- category_id (uuid, fk -> categories.id)
- description (text, nullable)
- amount (decimal(18,2))
- created_at (timestamp)
- updated_at (timestamp)

### Catatan
- opsional di MVP, tapi berguna untuk detail
- kalau transaksi sederhana, transaksi header saja sudah cukup

### Index
- index(transaction_id)
- index(category_id)

---

# 9. Tabel Attachments

Untuk bukti nota, foto, invoice, atau kwitansi.

### attachments
- id (uuid, pk)
- business_id (uuid, fk -> businesses.id)
- transaction_id (uuid, fk -> transactions.id, nullable)
- file_name (varchar)
- file_path (varchar)
- mime_type (varchar)
- file_size (bigint)
- uploaded_by (uuid, fk -> users.id)
- created_at (timestamp)

### Index
- index(business_id)
- index(transaction_id)

---

# 10. Tabel Budget / Target

Bisa dipakai kalau ingin ada target sederhana.

### budgets
- id (uuid, pk)
- business_id (uuid, fk -> businesses.id)
- unit_id (uuid, fk -> business_units.id, nullable)
- category_id (uuid, fk -> categories.id, nullable)
- period_type (enum: monthly, weekly, yearly)
- period_start (date)
- period_end (date)
- target_amount (decimal(18,2))
- created_at (timestamp)
- updated_at (timestamp)

### Catatan
- ini opsional untuk MVP
- cocok untuk target biaya atau target omzet

---

# 11. Tabel Financial Report Snapshots

Menyimpan ringkasan laporan supaya dashboard cepat.

### financial_reports
- id (uuid, pk)
- business_id (uuid, fk -> businesses.id)
- unit_id (uuid, fk -> business_units.id, nullable)
- report_period_type (enum: daily, weekly, monthly)
- report_date (date)
- total_income (decimal(18,2), default 0)
- total_expense (decimal(18,2), default 0)
- gross_profit (decimal(18,2), default 0)
- net_profit (decimal(18,2), default 0)
- cash_in (decimal(18,2), default 0)
- cash_out (decimal(18,2), default 0)
- total_transactions (int, default 0)
- generated_at (timestamp)
- created_at (timestamp)
- updated_at (timestamp)

### Catatan
- hasil agregasi dari transactions
- mempercepat dashboard dan laporan

---

# 12. Tabel Recurring Rules

Untuk transaksi rutin seperti gaji, sewa, atau biaya bulanan.

### recurring_rules
- id (uuid, pk)
- business_id (uuid, fk -> businesses.id)
- unit_id (uuid, fk -> business_units.id, nullable)
- category_id (uuid, fk -> categories.id)
- account_id (uuid, fk -> accounts.id, nullable)
- transaction_type (enum: income, expense)
- amount (decimal(18,2))
- description (text, nullable)
- frequency (enum: daily, weekly, monthly, yearly)
- start_date (date)
- end_date (date, nullable)
- next_run_date (date, nullable)
- is_active (boolean, default true)
- created_at (timestamp)
- updated_at (timestamp)

---

# 13. Tabel Notifications

Untuk reminder laporan atau aktivitas penting.

### notifications
- id (uuid, pk)
- user_id (uuid, fk -> users.id)
- business_id (uuid, fk -> businesses.id, nullable)
- title (varchar)
- body (text)
- type (varchar)
- is_read (boolean, default false)
- created_at (timestamp)
- read_at (timestamp, nullable)

---

# 14. Tabel Audit Logs

Berguna untuk tracking perubahan data.

### audit_logs
- id (uuid, pk)
- business_id (uuid, fk -> businesses.id)
- user_id (uuid, fk -> users.id)
- entity_type (varchar)
- entity_id (uuid)
- action (varchar)
- old_data (json, nullable)
- new_data (json, nullable)
- created_at (timestamp)

---

# 15. Relasi Utama

## User
- punya banyak businesses lewat ownership atau membership

## Business
- punya banyak members
- punya banyak units
- punya banyak categories
- punya banyak accounts
- punya banyak transactions
- punya banyak reports

## Transaction
- milik satu business
- optional terkait unit, account, category
- bisa punya many items
- bisa punya attachments

## Category
- bisa global atau business-specific
- bisa parent-child

## Account
- sumber uang / tempat uang
- transaksi bisa masuk ke satu account

---

# 16. Contoh Implementasi Bisnis

## Bisnis 1: Minimarket
Business:
- Minimarket Deni Mart

Units:
- Outlet Utama
- Gudang

Categories:
- Penjualan Barang
- Gaji Karyawan
- Barang Dagang
- Listrik
- Transport
- Sewa

Accounts:
- Kas Toko
- BCA
- Mandiri

## Bisnis 2: Pertanian
Business:
- Kebun Sawit / Cabai / Padi

Units:
- Lahan 1
- Lahan 2

Categories:
- Hasil Panen
- Upah Kerja
- Pupuk
- Bibit
- Obat Tanaman
- Solar / Transport

## Bisnis 3: Pribadi / Keluarga
Business:
- Keluarga Deni

Categories:
- Belanja Rumah
- Sekolah Anak
- Makan Harian
- Kesehatan
- Cicilan
- Lain-lain

Dengan cara ini, semua tercatat rapi tapi tetap terpisah.

---

# 17. Saran MVP Paling Aman

Untuk MVP, saya sarankan mulai dengan tabel inti berikut:
- users
- businesses
- business_members
- business_units
- categories
- accounts
- transactions
- transaction_items
- attachments
- financial_reports

Sisanya bisa menyusul tahap berikutnya.

---

# 18. Logika “Tambah Bisnis Baru” di Dashboard

Saat owner klik **Create Business**:
1. insert ke `businesses`
2. auto-create default categories
3. auto-create default account placeholder
4. auto-assign owner ke `business_members`
5. dashboard siap dipakai untuk bisnis baru

Jadi benar, nanti kalau ada bisnis baru tinggal create aja dari dashboard.

---

# 19. Rekomendasi Teknis

Kalau pakai PostgreSQL, schema ini sudah cocok untuk:
- relational queries
- reporting cepat
- multi-tenant data isolation
- expand ke analytics nanti

Untuk tipe data penting:
- pakai `uuid` untuk primary key
- pakai `decimal(18,2)` untuk uang
- pakai `json/jsonb` untuk metadata fleksibel
- pakai index pada tanggal, business_id, category_id

---

# 20. Next Step

Setelah schema ini, langkah paling tepat berikutnya adalah:
1. bikin **ERD diagram**
2. bikin **SQL migration awal**
3. bikin **API spec MVP**
4. bikin **flow dashboard UI**
