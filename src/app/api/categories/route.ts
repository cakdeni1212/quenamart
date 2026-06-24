import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { getSession } from "@/lib/auth";

export async function GET(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const businessId = searchParams.get("businessId");

  const where: Record<string, unknown> = {};

  if (businessId) {
    const business = await prisma.business.findFirst({
      where: { id: businessId, ownerId: user.id },
    });
    if (!business) return NextResponse.json({ error: "Bisnis tidak ditemukan" }, { status: 404 });
    where.businessId = businessId;
  } else {
    const userBusinesses = await prisma.business.findMany({
      where: { ownerId: user.id },
      select: { id: true },
    });
    where.businessId = { in: userBusinesses.map((b) => b.id) };
  }

  const categories = await prisma.category.findMany({
    where,
    include: {
      business: { select: { id: true, name: true, slug: true } },
      _count: { select: { transactions: true } },
    },
    orderBy: { sortOrder: "asc" },
  });

  return NextResponse.json({ categories });
}

export async function POST(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { businessId, name, categoryType, code } = await req.json();

  if (!businessId || !name) {
    return NextResponse.json({ error: "Bisnis dan nama kategori wajib diisi" }, { status: 400 });
  }

  const business = await prisma.business.findFirst({
    where: { id: businessId, ownerId: user.id },
  });

  if (!business) {
    return NextResponse.json({ error: "Bisnis tidak ditemukan" }, { status: 404 });
  }

  const category = await prisma.category.create({
    data: {
      businessId,
      name,
      categoryType: categoryType || "expense",
      code: code || null,
      sortOrder: 50,
    },
  });

  return NextResponse.json({ category }, { status: 201 });
}

export async function DELETE(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const id = searchParams.get("id");

  if (!id) return NextResponse.json({ error: "ID kategori diperlukan" }, { status: 400 });

  const category = await prisma.category.findFirst({
    where: { id },
    include: { business: true },
  });

  if (!category || !category.business || category.business.ownerId !== user.id) {
    return NextResponse.json({ error: "Kategori tidak ditemukan" }, { status: 404 });
  }

  await prisma.category.delete({ where: { id } });

  return NextResponse.json({ success: true });
}
