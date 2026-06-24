import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { getSession } from "@/lib/auth";
import { initDatabase } from "@/lib/init-db";

export async function GET(req: NextRequest) {
  await initDatabase();
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const businessId = searchParams.get("businessId");

  const where: Record<string, unknown> = { isActive: true };

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

  const descriptions = await prisma.expenseDescription.findMany({
    where,
    include: {
      business: { select: { id: true, name: true } },
    },
    orderBy: [{ sortOrder: "asc" }, { name: "asc" }],
  });

  return NextResponse.json({ descriptions });
}

export async function POST(req: NextRequest) {
  await initDatabase();
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { businessId, name } = await req.json();

  if (!businessId || !name) {
    return NextResponse.json({ error: "Bisnis dan deskripsi wajib diisi" }, { status: 400 });
  }

  const business = await prisma.business.findFirst({
    where: { id: businessId, ownerId: user.id },
  });
  if (!business) return NextResponse.json({ error: "Bisnis tidak ditemukan" }, { status: 404 });

  try {
    const desc = await prisma.expenseDescription.create({
      data: { businessId, name: name.trim() },
      include: { business: { select: { id: true, name: true } } },
    });
    return NextResponse.json({ description: desc }, { status: 201 });
  } catch {
    return NextResponse.json({ error: "Deskripsi sudah ada" }, { status: 409 });
  }
}

export async function DELETE(req: NextRequest) {
  await initDatabase();
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const id = searchParams.get("id");

  if (!id) return NextResponse.json({ error: "ID deskripsi diperlukan" }, { status: 400 });

  const desc = await prisma.expenseDescription.findFirst({
    where: { id },
    include: { business: true },
  });

  if (!desc || desc.business.ownerId !== user.id) {
    return NextResponse.json({ error: "Deskripsi tidak ditemukan" }, { status: 404 });
  }

  await prisma.expenseDescription.update({
    where: { id },
    data: { isActive: false },
  });

  return NextResponse.json({ success: true });
}
