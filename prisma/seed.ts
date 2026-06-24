import { PrismaLibSql } from "@prisma/adapter-libsql";
import { PrismaClient } from "../src/generated/prisma/client";
import path from "node:path";
import bcrypt from "bcryptjs";

const dbPath = path.join(process.cwd(), "dev.db");
const dbUrl = process.env.TURSO_DATABASE_URL ?? process.env.DATABASE_URL ?? `file:${dbPath}`;

const prisma = new PrismaClient({
  adapter: new PrismaLibSql({
    url: dbUrl,
    authToken: process.env.TURSO_AUTH_TOKEN,
  }),
});

async function main() {
  const passwordHash = await bcrypt.hash("admin123", 12);

  const user = await prisma.user.upsert({
    where: { email: "owner@quenamart.com" },
    update: {},
    create: {
      name: "Owner QuenaMart",
      email: "owner@quenamart.com",
      passwordHash,
      phone: "081234567890",
    },
  });

  const personal = await prisma.business.upsert({
    where: { slug: "pribadi" },
    update: {},
    create: {
      ownerId: user.id,
      name: "Pribadi / Keluarga",
      slug: "pribadi",
      businessType: "personal",
      description: "Pengeluaran pribadi dan keluarga",
    },
  });

  const minimarket = await prisma.business.upsert({
    where: { slug: "minimarket" },
    update: {},
    create: {
      ownerId: user.id,
      name: "QuenaMart Minimarket",
      slug: "minimarket",
      businessType: "minimarket",
      description: "Bisnis minimarket harian",
    },
  });

  const pertanian = await prisma.business.upsert({
    where: { slug: "pertanian" },
    update: {},
    create: {
      ownerId: user.id,
      name: "Tani Makmur",
      slug: "pertanian",
      businessType: "farm",
      description: "Bisnis pertanian dan perkebunan",
    },
  });

  const personalCategories = [
    { code: "PERS-BELANJA", name: "Belanja Harian", categoryType: "expense", sortOrder: 1 },
    { code: "PERS-MAKAN", name: "Makan / Minum", categoryType: "expense", sortOrder: 2 },
    { code: "PERS-PENDIDIKAN", name: "Pendidikan", categoryType: "expense", sortOrder: 3 },
    { code: "PERS-KESEHATAN", name: "Kesehatan", categoryType: "expense", sortOrder: 4 },
    { code: "PERS-TRANSPORT", name: "Transportasi Pribadi", categoryType: "expense", sortOrder: 5 },
    { code: "PERS-TAGIHAN", name: "Tagihan Rumah Tangga", categoryType: "expense", sortOrder: 6 },
    { code: "PERS-CICILAN", name: "Cicilan Pribadi", categoryType: "expense", sortOrder: 7 },
    { code: "PERS-HIBURAN", name: "Hiburan", categoryType: "expense", sortOrder: 8 },
    { code: "PERS-ANAK", name: "Keperluan Anak", categoryType: "expense", sortOrder: 9 },
    { code: "PERS-RUMAH", name: "Keperluan Rumah", categoryType: "expense", sortOrder: 10 },
    { code: "PERS-SOSIAL", name: "Sosial / Donasi", categoryType: "expense", sortOrder: 11 },
    { code: "PERS-LAIN", name: "Pengeluaran Pribadi Lain-lain", categoryType: "expense", sortOrder: 99 },
  ];

  for (const cat of personalCategories) {
    await prisma.category.upsert({
      where: { businessId_code: { businessId: personal.id, code: cat.code } },
      create: { businessId: personal.id, ...cat, appliesTo: "personal", isSystem: true },
      update: {},
    });
  }

  const minimarketCategories = [
    { code: "MIN-INCOME", name: "Penjualan Harian", categoryType: "income", sortOrder: 1 },
    { code: "MIN-INC-OTHER", name: "Pendapatan Lain-lain", categoryType: "income", sortOrder: 2 },
    { code: "MIN-STOK", name: "Pembelian Stok Barang", categoryType: "expense", sortOrder: 10 },
    { code: "MIN-GAJI", name: "Gaji Karyawan / Sales", categoryType: "expense", sortOrder: 11 },
    { code: "MIN-BONUS", name: "Bonus Karyawan", categoryType: "expense", sortOrder: 12 },
    { code: "MIN-LISTRIK", name: "Listrik", categoryType: "expense", sortOrder: 13 },
    { code: "MIN-AIR", name: "Air", categoryType: "expense", sortOrder: 14 },
    { code: "MIN-INTERNET", name: "Internet", categoryType: "expense", sortOrder: 15 },
    { code: "MIN-SEWA", name: "Sewa Toko", categoryType: "expense", sortOrder: 16 },
    { code: "MIN-TRANSPORT", name: "Transportasi / Ongkir", categoryType: "expense", sortOrder: 17 },
    { code: "MIN-ALAT", name: "Peralatan Toko", categoryType: "expense", sortOrder: 18 },
    { code: "MIN-PROMOSI", name: "Promosi / Marketing", categoryType: "expense", sortOrder: 19 },
    { code: "MIN-ADMIN", name: "Biaya Admin / Bank", categoryType: "expense", sortOrder: 20 },
    { code: "MIN-PAJAK", name: "Pajak / Retribusi", categoryType: "expense", sortOrder: 21 },
    { code: "MIN-LAIN", name: "Operasional Lain-lain", categoryType: "expense", sortOrder: 99 },
  ];

  for (const cat of minimarketCategories) {
    await prisma.category.upsert({
      where: { businessId_code: { businessId: minimarket.id, code: cat.code } },
      create: { businessId: minimarket.id, ...cat, appliesTo: "minimarket", isSystem: true },
      update: {},
    });
  }

  const pertanianCategories = [
    { code: "FARM-INCOME", name: "Penjualan Hasil Panen", categoryType: "income", sortOrder: 1 },
    { code: "FARM-INC-OTHER", name: "Pendapatan Lain-lain", categoryType: "income", sortOrder: 2 },
    { code: "FARM-UPAH", name: "Upah Kerja", categoryType: "expense", sortOrder: 10 },
    { code: "FARM-UPAH-BORONG", name: "Upah Borongan", categoryType: "expense", sortOrder: 11 },
    { code: "FARM-BIBIT", name: "Bibit", categoryType: "expense", sortOrder: 12 },
    { code: "FARM-PUPUK", name: "Pupuk", categoryType: "expense", sortOrder: 13 },
    { code: "FARM-PESTISIDA", name: "Pestisida / Obat Tanaman", categoryType: "expense", sortOrder: 14 },
    { code: "FARM-SEWA-LAHAN", name: "Sewa Lahan", categoryType: "expense", sortOrder: 15 },
    { code: "FARM-OLAH-TANAH", name: "Pengolahan Tanah / Traktor", categoryType: "expense", sortOrder: 16 },
    { code: "FARM-IRIGASI", name: "Irigasi / Air", categoryType: "expense", sortOrder: 17 },
    { code: "FARM-PANEN", name: "Biaya Panen", categoryType: "expense", sortOrder: 18 },
    { code: "FARM-TRANSPORT", name: "Transportasi / Distribusi", categoryType: "expense", sortOrder: 19 },
    { code: "FARM-ALAT", name: "Alat Pertanian", categoryType: "expense", sortOrder: 20 },
    { code: "FARM-PERAWATAN", name: "Perawatan Tanaman", categoryType: "expense", sortOrder: 21 },
    { code: "FARM-LAIN", name: "Operasional Pertanian Lain-lain", categoryType: "expense", sortOrder: 99 },
  ];

  for (const cat of pertanianCategories) {
    await prisma.category.upsert({
      where: { businessId_code: { businessId: pertanian.id, code: cat.code } },
      create: { businessId: pertanian.id, ...cat, appliesTo: "farm", isSystem: true },
      update: {},
    });
  }

  console.log("Seed completed!");
  console.log(`User: ${user.email} / admin123`);
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
