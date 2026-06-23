# PRD Refined — Sistem Pencatatan Keuangan Multi-Bisnis

## 1. Latar Belakang

User memiliki beberapa sumber keuangan yang perlu dicatat secara rapi:
- bisnis minimarket: pendapatan harian, pengeluaran operasional, pengeluaran untuk sales
- bisnis pertanian: upah kerja, pupuk, bibit, obat, alat, dan biaya operasional lain
- pengeluaran pribadi keluarga: kebutuhan rumah tangga, pendidikan, kesehatan, dan lainnya
- kemungkinan ada bisnis baru di masa depan yang perlu dimasukkan ke sistem yang sama

Masalah utamanya adalah semua pencatatan masih berpotensi tersebar, sulit direkap, dan susah dimonitor secara konsisten.

## 2. Tujuan Produk

Membangun satu sistem pusat untuk:
- mencatat semua transaksi keuangan lintas bisnis dan pribadi
- memisahkan data per unit usaha / akun / kategori
- memantau performa masing-masing bisnis
- tetap bisa melihat gambaran total kekayaan / arus kas pribadi
- memudahkan ekspansi ke bisnis baru tanpa bikin sistem baru lagi

## 3. Prinsip Desain Produk

1. **Satu platform, banyak entitas**
   - setiap bisnis, lahan, toko, atau akun pribadi dianggap sebagai entitas yang bisa dipantau

2. **Transaksi harus selalu punya konteks**
   - setiap pemasukan / pengeluaran wajib tahu milik entitas apa

3. **Pemisahan bisnis dan pribadi jelas**
   - supaya laporan bisnis tidak tercampur dengan kebutuhan keluarga

4. **Fleksibel untuk pertumbuhan**
   - sistem harus siap menampung bisnis baru tanpa ubah struktur besar

## 4. Ruang Lingkup Sistem

### 4.1 Entitas yang Didukung
- Minimarket
- Pertanian
- Pengeluaran pribadi / keluarga
- Bisnis lain di masa depan

### 4.2 Jenis Pencatatan
- pemasukan
- pengeluaran
- transfer internal
- modal masuk
- penarikan pribadi
- utang/piutang sederhana jika dibutuhkan nanti

## 5. Use Case Utama

### Minimarket
- catat pendapatan harian
- catat pengeluaran untuk sales
- catat pembelian stok, operasional, listrik, sewa, dll
- lihat laba harian/bulanan

### Pertanian
- catat upah kerja
- catat pembelian pupuk, bibit, obat, alat
- catat hasil panen atau pemasukan lain
- lihat total biaya per lahan / per musim

### Pribadi / Keluarga
- catat kebutuhan rumah tangga
- catat sekolah, kesehatan, transportasi, dll
- pisahkan dari uang usaha
- lihat cashflow pribadi

### Ekspansi Bisnis Baru
- bikin entitas baru kapan saja
- pilih template kategori sesuai jenis bisnis
- laporan tetap konsisten

## 6. Struktur Modul MVP

### Modul A — Master Akun / Entitas
Fungsi:
- tambah entitas baru
- tipe entitas: bisnis, lahan, pribadi, proyek
- aktif/nonaktifkan entitas
- pilih mata uang jika perlu nanti

### Modul B — Pencatatan Transaksi
Fungsi:
- input pemasukan
- input pengeluaran
- pilih entitas
- pilih kategori
- isi tanggal, nominal, catatan
- lampiran foto struk opsional

### Modul C — Kategori Transaksi
Kategori bisa berbeda per entitas, tetapi struktur umumnya seragam.
Contoh:
- minimarket: penjualan, pembelian stok, gaji/sales, listrik, sewa, transport, lain-lain
- pertanian: penjualan hasil panen, upah kerja, pupuk, bibit, obat, alat, transport, lain-lain
- pribadi: rumah tangga, pendidikan, kesehatan, cicilan, transport, hiburan, darurat

### Modul D — Dashboard Monitoring
Fungsi:
- ringkasan total semua entitas
- ringkasan per entitas
- trend pemasukan vs pengeluaran
- saldo kas
- profit/loss sederhana

### Modul E — Laporan
Fungsi:
- harian
- mingguan
- bulanan
- per entitas
- per kategori
- export PDF / Excel / CSV

### Modul F — Akses & Role
- owner: akses penuh
- admin/keuangan: input dan edit transaksi
- viewer: hanya lihat laporan

## 7. Alur Penggunaan

### Alur 1: Menambah bisnis baru
1. user klik tambah entitas
2. pilih tipe entitas
3. isi nama dan detail dasar
4. sistem buat template kategori
5. entitas siap dipakai untuk transaksi

### Alur 2: Mencatat transaksi harian
1. user pilih entitas
2. pilih pemasukan atau pengeluaran
3. isi kategori dan nominal
4. simpan
5. sistem update dashboard otomatis

### Alur 3: Lihat kondisi total
1. user buka dashboard
2. pilih rentang tanggal
3. lihat ringkasan semua bisnis + pribadi
4. drill down ke entitas tertentu

## 8. Data yang Harus Disimpan

Minimal:
- entitas
- transaksi
- kategori
- user
- role
- lampiran
- tag / label opsional

Field transaksi minimal:
- id
- entity_id
- type: income / expense / transfer
- category_id
- amount
- date
- note
- created_by
- attachment_url

## 9. Aturan Bisnis

- setiap transaksi wajib terkait ke 1 entitas
- transaksi pribadi tidak boleh tercampur ke bisnis kecuali ditandai sebagai penarikan modal / owner draw
- transaksi transfer internal tidak dihitung sebagai pendapatan atau biaya
- kategori harus bisa disesuaikan per jenis entitas

## 10. MVP Paling Penting

Kalau mau cepat jalan, MVP inti adalah:
- bikin entitas
- input transaksi
- kategori khusus per entitas
- dashboard total dan per entitas
- laporan harian/bulanan
- pemisahan bisnis vs pribadi

## 11. Hal yang Bisa Menyusul Setelah MVP

- stok minimarket
- inventory pertanian
- invoice dan tagihan
- utang/piutang
- foto bukti transaksi
- approval pengeluaran
- multi-user lebih kompleks
- mobile app
- sinkronisasi offline

## 12. Kesimpulan

Sistem ini sebaiknya tidak dipikir sebagai "aplikasi keuangan biasa", tapi sebagai:

**platform monitoring seluruh aset, bisnis, dan cashflow pribadi dalam satu tempat**

Dengan begitu, bisnis baru tinggal ditambahkan sebagai entitas baru, bukan bikin sistem baru lagi.
