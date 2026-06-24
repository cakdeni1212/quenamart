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
  const type = searchParams.get("type");

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

  if (type) where.type = type;

  const suppliers = await prisma.supplier.findMany({
    where,
    include: {
      business: { select: { id: true, name: true } },
      tempos: {
        where: { status: { in: ["pending", "partial"] } },
        select: { id: true, totalAmount: true, paidAmount: true },
      },
    },
    orderBy: { name: "asc" },
  });

  return NextResponse.json({ suppliers });
}

export async function POST(req: NextRequest) {
  await initDatabase();
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { businessId, name, type, phone, address, notes } = await req.json();

  if (!businessId || !name) {
    return NextResponse.json({ error: "Bisnis dan nama supplier/sales wajib diisi" }, { status: 400 });
  }

  const business = await prisma.business.findFirst({
    where: { id: businessId, ownerId: user.id },
  });
  if (!business) return NextResponse.json({ error: "Bisnis tidak ditemukan" }, { status: 404 });

  const supplier = await prisma.supplier.create({
    data: {
      businessId,
      name: name.trim(),
      type: type || "supplier",
      phone: phone || null,
      address: address || null,
      notes: notes || null,
    },
    include: { business: { select: { id: true, name: true } } },
  });

  return NextResponse.json({ supplier }, { status: 201 });
}

export async function PUT(req: NextRequest) {
  await initDatabase();
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { id, name, type, phone, address, notes } = await req.json();

  if (!id) return NextResponse.json({ error: "ID supplier diperlukan" }, { status: 400 });

  const supplier = await prisma.supplier.findFirst({
    where: { id },
    include: { business: true },
  });

  if (!supplier || supplier.business.ownerId !== user.id) {
    return NextResponse.json({ error: "Supplier tidak ditemukan" }, { status: 404 });
  }

  const updated = await prisma.supplier.update({
    where: { id },
    data: {
      name: name ? name.trim() : undefined,
      type: type || undefined,
      phone: phone !== undefined ? phone : undefined,
      address: address !== undefined ? address : undefined,
      notes: notes !== undefined ? notes : undefined,
    },
    include: { business: { select: { id: true, name: true } } },
  });

  return NextResponse.json({ supplier: updated });
}

export async function DELETE(req: NextRequest) {
  await initDatabase();
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const id = searchParams.get("id");

  if (!id) return NextResponse.json({ error: "ID supplier diperlukan" }, { status: 400 });

  const supplier = await prisma.supplier.findFirst({
    where: { id },
    include: { business: true },
  });

  if (!supplier || supplier.business.ownerId !== user.id) {
    return NextResponse.json({ error: "Supplier tidak ditemukan" }, { status: 404 });
  }

  await prisma.supplier.update({
    where: { id },
    data: { isActive: false },
  });

  return NextResponse.json({ success: true });
}
