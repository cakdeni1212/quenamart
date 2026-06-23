# Master Category — Sistem Monitoring Keuangan Multi-Bisnis

## Tujuan

Membuat struktur kategori master yang bisa dipakai untuk semua aktivitas keuangan user:
- bisnis minimarket
- bisnis pertanian
- pengeluaran pribadi / keluarga
- bisnis baru di masa depan

Prinsip desain:
- konsisten
- mudah dipakai input harian
- bisa dipakai lintas bisnis
- cukup detail untuk analisis, tapi tidak terlalu ribet
- mendukung penambahan kategori baru tanpa merusak struktur utama

---

## 1. Struktur Besar Kategori

Paling aman memakai 3 layer:

- **Scope** → milik apa transaksi ini?
  - bisnis
  - pribadi

- **Account / Entity** → masuk ke bisnis yang mana atau keluarga/pribadi
  - minimarket
  - pertanian
  - rumah tangga
  - bisnis lain

- **Category** → jenis pemasukan atau pengeluaran
  - penjualan
  - upah
  - pupuk
  - listrik
  - makan keluarga
  - dll

Struktur ini bikin semua data tetap rapi walau bisnis bertambah.

---

## 2. Kategori Master Level 1

### A. Pemasukan
Digunakan untuk semua bisnis.

Subkategori:
- Penjualan Barang
- Penjualan Jasa
- Hasil Panen
- Komisi / Fee
- Pendapatan Lain-lain
- Piutang Masuk
- Modal Masuk
- Transfer Antar Rekening

### B. Pengeluaran Operasional Bisnis
Digunakan untuk minimarket, pertanian, dan bisnis lain.

Subkategori:
- Gaji / Upah
- Bahan Baku / Barang Dagang
- Transportasi
- Listrik / Air / Internet
- Sewa
- Perawatan / Reparasi
- Packaging / Kemasan
- ATK / Perlengkapan
- Marketing / Promosi
- Biaya Admin / Bank
- Pajak / Retribusi
- Operasional Lain-lain

### C. Pengeluaran Produksi Pertanian
Khusus untuk bisnis pertanian.

Subkategori:
- Bibit
- Pupuk
- Pestisida / Obat Tanaman
- Upah Kerja
- Sewa Lahan
- Pengolahan Lahan
- Irigasi / Air
- Panen
- Distribusi / Angkut
- Alat Pertanian
- Perawatan Tanaman
- Operasional Pertanian Lain-lain

### D. Pengeluaran Pribadi / Keluarga
Untuk kebutuhan rumah tangga.

Subkategori:
- Belanja Harian
- Makan / Minum
- Pendidikan
- Kesehatan
- Transportasi Pribadi
- Tagihan Rumah Tangga
- Cicilan Pribadi
- Hiburan
- Keperluan Anak
- Keperluan Rumah
- Sosial / Donasi
- Pengeluaran Pribadi Lain-lain

### E. Aset / Investasi / Modal
Kalau ada transaksi yang bukan biaya rutin.

Subkategori:
- Pembelian Aset Tetap
- Pembelian Alat
- Renovasi
- Tambahan Modal
- Investasi Baru
- Pencairan Investasi
- Transfer ke Bisnis Lain
- Transfer ke Pribadi

### F. Hutang / Piutang
Untuk tracking cashflow yang lebih rapi.

Subkategori:
- Hutang Usaha
- Piutang Usaha
- Hutang Pribadi
- Piutang Pribadi
- Pembayaran Hutang
- Pelunasan Piutang

---

## 3. Kategori Khusus per Domain

### A. Minimarket
Kategori operasional yang paling sering muncul:
- Penjualan Tunai
- Penjualan Non-Tunai
- Belanja Stok Barang
- Retur Supplier
- Ongkos Kirim / Distribusi
- Gaji Karyawan
- Bonus Karyawan
- Utilitas
- Sewa Toko
- Peralatan Toko
- Susut / Barang Hilang
- Promosi / Diskon
- Biaya Admin Payment Gateway / EDC

### B. Pertanian
Kategori yang paling sering muncul:
- Penjualan Hasil Panen
- Bibit
- Pupuk
- Pestisida
- Upah Harian
- Upah Borongan
- Sewa Lahan
- Traktor / Olah Tanah
- Perawatan Tanaman
- Panen
- Transportasi Hasil
- Alat Tani
- Irigasi

### C. Pribadi / Keluarga
Kategori yang sering dipakai:
- Makan Rumah
- Belanja Bulanan
- Sekolah Anak
- Uang Saku
- BPJS / Kesehatan
- Listrik Rumah
- Air / Gas
- Internet Rumah
- Cicilan
- Tamu / Sosial
- Liburan
- Darurat

---

## 4. Struktur Tagging yang Disarankan

Supaya fleksibel, satu transaksi sebaiknya punya:

- **type**: income / expense / transfer / asset / liability
- **scope**: business / personal
- **business_id**: minimarket / pertanian / lainnya
- **category_id**: kategori master
- **sub_category_id**: rincian lebih spesifik
- **payment_method**: cash / transfer / QRIS / debit / e-wallet
- **counterparty**: supplier / employee / customer / keluarga / dll
- **notes**: catatan bebas

Contoh:

1. Upah kerja sawah
- type: expense
- scope: business
- business: pertanian
- category: pengeluaran produksi pertanian
- subcategory: upah kerja

2. Belanja beras keluarga
- type: expense
- scope: personal
- business: pribadi / keluarga
- category: pengeluaran pribadi / keluarga
- subcategory: belanja harian

3. Penjualan minimarket tunai
- type: income
- scope: business
- business: minimarket
- category: pemasukan
- subcategory: penjualan barang

---

## 5. Rekomendasi Master Category Final untuk MVP

Kalau mau cepat tapi tetap rapi, MVP cukup pakai 6 grup ini:

1. **Income**
2. **Business Operating Expense**
3. **Agriculture Production Expense**
4. **Personal / Family Expense**
5. **Asset / Investment / Capital**
6. **Debt / Receivable**

Lalu tiap grup punya subkategori seperti daftar di atas.

---

## 6. Aturan Desain Kategori

- jangan campur transaksi bisnis dan pribadi di satu kategori tanpa label scope
- jangan terlalu banyak kategori di awal
- kategori bisa ditambah, tapi struktur level 1 harus stabil
- semua bisnis baru harus bisa memakai struktur yang sama
- kategori besar lebih penting daripada kategori super detail
- jika ragu, pakai kategori `Lain-lain` tapi tetap beri notes

---

## 7. Saran Praktis untuk Sistem

Biar sistem enak dipakai:

- bikin **template kategori default** saat bisnis baru dibuat
- izinkan user custom kategori tambahan per bisnis
- simpan kategori master global, lalu bisnis boleh override label
- pengeluaran pribadi jangan tercampur dengan dashboard bisnis, tapi tetap bisa dipantau di satu dashboard pusat

---

## 8. Output yang Disarankan di Dashboard

Dashboard pusat bisa dibagi:

- total pemasukan semua bisnis
- total pengeluaran semua bisnis
- total pengeluaran pribadi
- profit per bisnis
- cashflow keluarga
- aset / modal yang ditanam
- hutang / piutang yang masih berjalan

---

## 9. Next Step

Setelah master category ini, langkah berikutnya yang paling pas:

1. bikin **struktur database kategori master**
2. bikin **daftar category seed data**
3. bikin **alur input transaksi harian**
4. bikin **dashboard ringkas**

---

## 10. Kesimpulan

Untuk kasus user yang punya:
- minimarket
- pertanian
- pengeluaran pribadi / keluarga
- potensi bisnis baru

struktur terbaik adalah sistem keuangan multi-scope dengan kategori master yang seragam, lalu dibedakan berdasarkan bisnis, pribadi, dan jenis transaksi.

Dengan cara ini, semua keuangan bisa dimonitor dari satu sistem tanpa bikin data berantakan.
