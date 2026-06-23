# PRD MVP — SaaS Sistem Keuangan untuk Bisnis F&B Multi-Investor

## 1. Ringkasan Produk

Produk ini adalah SaaS sistem keuangan untuk bisnis F&B yang memungkinkan owner dan beberapa investor memantau performa finansial bisnis secara transparan, rapi, dan real-time. MVP difokuskan untuk menyatukan data transaksi, biaya, laba rugi sederhana, dan pembagian akses investor tanpa membangun akuntansi penuh.

## 2. Masalah yang Ingin Diselesaikan

Bisnis F&B sering punya:
- pencatatan transaksi yang tersebar
- laporan keuangan yang lambat dibuat
- investor yang minta update rutin namun datanya manual
- sulitnya melihat performa outlet/cabang secara konsisten
- kurang transparansi terhadap cashflow, omset, dan profit

## 3. Tujuan MVP

- Menyediakan dashboard keuangan yang mudah dipahami owner dan investor
- Menampilkan omset, biaya, laba kotor, laba bersih sederhana, dan cashflow
- Memisahkan akses berdasarkan peran pengguna
- Menyimpan histori transaksi dan laporan per periode
- Mengurangi kerja manual rekap keuangan

## 4. Target Pengguna

### Persona 1: Owner / Founder
- butuh kontrol penuh atas data keuangan
- ingin monitor performa outlet dan investor
- ingin buat laporan cepat tanpa spreadsheet manual

### Persona 2: Investor
- ingin lihat performa bisnis secara transparan
- tidak perlu akses edit penuh
- fokus ke metrik investasi, return, dan ringkasan periodik

### Persona 3: Admin Keuangan / Operasional
- input data transaksi dan biaya
- update laporan harian / mingguan
- mengelola data operasional dasar

## 5. Ruang Lingkup MVP

### In Scope
- login dan role-based access
- multi-tenant sederhana per bisnis / perusahaan
- dashboard ringkas keuangan
- input transaksi penjualan
- input biaya operasional
- ringkasan laba rugi sederhana
- laporan per periode harian, mingguan, bulanan
- akses investor read-only
- export laporan PDF/CSV sederhana
- notifikasi ringkas jika laporan periode baru tersedia

### Out of Scope
- akuntansi lengkap double-entry
- integrasi POS kompleks
- integrasi bank otomatis
- pajak, invoice, dan billing lanjutan
- payroll lengkap
- forecasting AI
- waterfall profit sharing kompleks
- audit trail tingkat enterprise

## 6. Value Proposition

- Owner punya satu tempat untuk kontrol keuangan bisnis F&B
- Investor dapat melihat perkembangan investasi tanpa minta report manual
- Admin lebih cepat input data dan bikin laporan
- Data keuangan lebih konsisten antar cabang/outlet

## 7. Use Cases Utama

1. Owner membuat akun bisnis baru dan mengundang investor
2. Admin memasukkan transaksi penjualan harian
3. Admin memasukkan biaya operasional harian/bulanan
4. Sistem menghitung ringkasan laba rugi sederhana
5. Investor login dan melihat dashboard read-only
6. Owner mengekspor laporan bulanan untuk rapat investor

## 8. Fitur MVP

### 8.1 Authentication & Authorization
- login email/password
- role: owner, admin, investor
- investor hanya bisa lihat data yang diizinkan
- owner bisa mengundang user baru

### 8.2 Company / Business Workspace
- satu akun bisa punya satu atau beberapa bisnis
- tiap bisnis punya data finansial terpisah
- investor hanya terikat ke bisnis tertentu

### 8.3 Dashboard
Tampilan utama:
- total omzet periode berjalan
- total biaya periode berjalan
- gross profit
- net profit sederhana
- cash in / cash out
- trend bulanan
- ringkasan per outlet jika ada

### 8.4 Transaction Management
- input penjualan
- input biaya operasional
- kategori transaksi
- tanggal transaksi
- outlet/cabang
- catatan tambahan

### 8.5 Report & Analytics
- laporan harian, mingguan, bulanan
- filter berdasarkan outlet dan kategori
- ringkasan performa periode
- export CSV/PDF sederhana

### 8.6 Investor View
- akses read-only
- lihat ringkasan performa bisnis
- lihat histori laporan
- lihat pembagian kepemilikan / porsi investasi bila disimpan

### 8.7 Notifications
- notifikasi saat laporan bulanan selesai
- notifikasi jika ada update data penting

## 9. User Flow Utama

### Flow Owner
1. daftar / login
2. buat workspace bisnis
3. undang admin dan investor
4. input atau review transaksi
5. lihat dashboard dan laporan
6. export laporan untuk investor

### Flow Investor
1. terima undangan
2. login
3. lihat dashboard read-only
4. buka laporan bulanan
5. unduh laporan jika perlu

### Flow Admin Keuangan
1. login
2. pilih bisnis/outlet
3. input transaksi penjualan dan biaya
4. cek hasil ringkasan
5. submit laporan periode

## 10. Data Model MVP

Entitas minimum:
- User
- Business / Workspace
- Membership / Role
- Outlet / Branch
- Transaction
- Expense
- FinancialReport
- InvestmentShare atau InvestorAssignment
- Notification

Field inti yang dibutuhkan:
- user_id
- business_id
- role
- outlet_id
- amount
- category
- transaction_type
- transaction_date
- report_period
- notes

## 11. KPI Keberhasilan MVP

- owner aktif upload / input data mingguan
- investor login minimal 1x per periode laporan
- waktu pembuatan laporan turun signifikan dibanding manual
- data transaksi konsisten per outlet
- user non-teknis bisa memahami dashboard tanpa training berat

## 12. Non-Functional Requirements

- keamanan akses per role
- data terisolasi antar bisnis
- performa dashboard cepat untuk data bulanan
- tampilan mobile-friendly
- export laporan stabil
- backup data harian

## 13. Risiko & Mitigasi

- **Risiko:** scope melebar ke akuntansi penuh
  - **Mitigasi:** batasi MVP ke ringkasan keuangan sederhana
- **Risiko:** investor minta detail yang terlalu dalam
  - **Mitigasi:** sediakan role-based view dan roadmap bertahap
- **Risiko:** input data manual terasa berat
  - **Mitigasi:** mulai dengan form sederhana dan template upload CSV nanti

## 14. Roadmap Setelah MVP

### Phase 2
- import data dari POS
- rekonsiliasi kas
- approval flow pengeluaran
- chart lebih detail per outlet

### Phase 3
- investor portal lebih lengkap
- profit sharing otomatis
- integrasi bank
- analitik dan forecasting

## 15. Rekomendasi MVP Paling Realistis

Kalau targetnya cepat jadi dan bisa dipakai investor, MVP paling aman adalah:
- login + role akses
- workspace bisnis
- transaksi penjualan
- biaya operasional
- dashboard laba rugi sederhana
- laporan periodik
- investor read-only
- export laporan

## 16. Catatan Produk

Produk ini bukan software akuntansi penuh. Posisi terbaiknya adalah:
**“financial visibility platform untuk bisnis F&B multi-investor”**

Itu penting supaya scope tetap tajam dan produk cepat dipakai.
