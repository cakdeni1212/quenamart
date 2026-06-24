import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { getSession } from "@/lib/auth";

export async function GET() {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const businesses = await prisma.business.findMany({
    where: { ownerId: user.id, isArchived: false },
    orderBy: { createdAt: "desc" },
    include: {
      _count: { select: { transactions: true } },
    },
  });

  return NextResponse.json({ businesses });
}

export async function POST(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { name, businessType, description } = await req.json();

  if (!name) {
    return NextResponse.json({ error: "Nama bisnis wajib diisi" }, { status: 400 });
  }

  const slug = name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");

  const business = await prisma.business.create({
    data: {
      ownerId: user.id,
      name,
      slug,
      businessType: businessType || "other",
      description: description || null,
    },
  });

  // Create default categories based on business type
  const categories = getDefaultCategories(businessType || "other");
  await prisma.category.createMany({
    data: categories.map((cat) => ({
      businessId: business.id,
      ...cat,
      appliesTo: businessType || "other",
      isSystem: true,
    })),
  });

  return NextResponse.json({ business }, { status: 201 });
}

export async function PUT(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { id, isArchived, name, businessType, description } = await req.json();

  if (!id) {
    return NextResponse.json({ error: "ID bisnis diperlukan" }, { status: 400 });
  }

  const business = await prisma.business.findFirst({
    where: { id, ownerId: user.id },
  });

  if (!business) {
    return NextResponse.json({ error: "Bisnis tidak ditemukan" }, { status: 404 });
  }

  const updated = await prisma.business.update({
    where: { id },
    data: {
      ...(isArchived !== undefined && { isArchived }),
      ...(name !== undefined && { name }),
      ...(businessType !== undefined && { businessType }),
      ...(description !== undefined && { description }),
    },
  });

  return NextResponse.json({ business: updated });
}

function getDefaultCategories(businessType: string) {
  const type = businessType || "other";

  switch (type) {
    case "minimarket":
      return [
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

    case "farm":
      return [
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

    case "personal":
      return [
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

    case "fnb":
      return [
        { code: "FNB-SALES", name: "Penjualan Makanan & Minuman", categoryType: "income", sortOrder: 1 },
        { code: "FNB-INC-OTHER", name: "Pendapatan Lain-lain", categoryType: "income", sortOrder: 2 },
        { code: "FNB-BAHAN", name: "Bahan Baku", categoryType: "expense", sortOrder: 10 },
        { code: "FNB-GAJI", name: "Gaji Karyawan", categoryType: "expense", sortOrder: 11 },
        { code: "FNB-SEWA", name: "Sewa Tempat", categoryType: "expense", sortOrder: 12 },
        { code: "FNB-LISTRIK", name: "Listrik / Gas", categoryType: "expense", sortOrder: 13 },
        { code: "FNB-KEMASAN", name: "Packaging / Kemasan", categoryType: "expense", sortOrder: 14 },
        { code: "FNB-TRANSPORT", name: "Transportasi", categoryType: "expense", sortOrder: 15 },
        { code: "FNB-ALAT", name: "Peralatan Dapur", categoryType: "expense", sortOrder: 16 },
        { code: "FNB-PROMOSI", name: "Promosi / Marketing", categoryType: "expense", sortOrder: 17 },
        { code: "FNB-LAIN", name: "Operasional Lain-lain", categoryType: "expense", sortOrder: 99 },
      ];

    case "trading":
      return [
        { code: "TRD-SALES", name: "Penjualan Barang", categoryType: "income", sortOrder: 1 },
        { code: "TRD-INC-OTHER", name: "Pendapatan Lain-lain", categoryType: "income", sortOrder: 2 },
        { code: "TRD-STOK", name: "Pembelian Stok", categoryType: "expense", sortOrder: 10 },
        { code: "TRD-ONGKIR", name: "Ongkos Kirim", categoryType: "expense", sortOrder: 11 },
        { code: "TRD-PACKING", name: "Packing", categoryType: "expense", sortOrder: 12 },
        { code: "TRD-IKLAN", name: "Iklan / Ads", categoryType: "expense", sortOrder: 13 },
        { code: "TRD-ADMIN", name: "Biaya Platform / Admin", categoryType: "expense", sortOrder: 14 },
        { code: "TRD-LAIN", name: "Operasional Lain-lain", categoryType: "expense", sortOrder: 99 },
      ];

    case "services":
      return [
        { code: "SRV-INCOME", name: "Pendapatan Jasa", categoryType: "income", sortOrder: 1 },
        { code: "SRV-INC-OTHER", name: "Pendapatan Lain-lain", categoryType: "income", sortOrder: 2 },
        { code: "SRV-GAJI", name: "Gaji / Upah Tim", categoryType: "expense", sortOrder: 10 },
        { code: "SRV-ALAT", name: "Peralatan", categoryType: "expense", sortOrder: 11 },
        { code: "SRV-TRANSPORT", name: "Transportasi", categoryType: "expense", sortOrder: 12 },
        { code: "SRV-SEWA", name: "Sewa Tempat", categoryType: "expense", sortOrder: 13 },
        { code: "SRV-PROMOSI", name: "Marketing / Promosi", categoryType: "expense", sortOrder: 14 },
        { code: "SRV-LAIN", name: "Operasional Lain-lain", categoryType: "expense", sortOrder: 99 },
      ];

    default:
      return [
        { code: "INC-01", name: "Pendapatan Utama", categoryType: "income", sortOrder: 1 },
        { code: "INC-99", name: "Pendapatan Lain-lain", categoryType: "income", sortOrder: 99 },
        { code: "EXP-01", name: "Biaya Operasional", categoryType: "expense", sortOrder: 10 },
        { code: "EXP-99", name: "Pengeluaran Lain-lain", categoryType: "expense", sortOrder: 99 },
      ];
  }
}
