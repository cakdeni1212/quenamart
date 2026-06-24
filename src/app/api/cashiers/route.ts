import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { getSession } from "@/lib/auth";

export async function GET(req: NextRequest) {
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

  const cashiers = await prisma.cashier.findMany({
    where,
    include: {
      business: { select: { id: true, name: true } },
    },
    orderBy: { name: "asc" },
  });

  return NextResponse.json({ cashiers });
}

export async function POST(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { businessId, name } = await req.json();

  if (!businessId || !name) {
    return NextResponse.json({ error: "Bisnis dan nama kasir wajib diisi" }, { status: 400 });
  }

  const business = await prisma.business.findFirst({
    where: { id: businessId, ownerId: user.id },
  });
  if (!business) return NextResponse.json({ error: "Bisnis tidak ditemukan" }, { status: 404 });

  try {
    const cashier = await prisma.cashier.create({
      data: { businessId, name: name.trim() },
      include: { business: { select: { id: true, name: true } } },
    });
    return NextResponse.json({ cashier }, { status: 201 });
  } catch {
    return NextResponse.json({ error: "Nama kasir sudah ada" }, { status: 409 });
  }
}

export async function DELETE(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const id = searchParams.get("id");

  if (!id) return NextResponse.json({ error: "ID kasir diperlukan" }, { status: 400 });

  const cashier = await prisma.cashier.findFirst({
    where: { id },
    include: { business: true },
  });

  if (!cashier || cashier.business.ownerId !== user.id) {
    return NextResponse.json({ error: "Kasir tidak ditemukan" }, { status: 404 });
  }

  await prisma.cashier.update({
    where: { id },
    data: { isActive: false },
  });

  return NextResponse.json({ success: true });
}
