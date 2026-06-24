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
  const status = searchParams.get("status");

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

  if (status) where.status = status;

  const tempos = await prisma.supplierTempo.findMany({
    where,
    include: {
      supplier: { select: { id: true, name: true, type: true } },
      business: { select: { id: true, name: true } },
      payments: {
        select: { id: true, amount: true, paymentDate: true, notes: true },
        orderBy: { paymentDate: "desc" },
      },
    },
    orderBy: { dueDate: "asc" },
  });

  return NextResponse.json({ tempos });
}

export async function POST(req: NextRequest) {
  await initDatabase();
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { businessId, supplierId, description, totalAmount, dueDate, invoiceNo, notes } = await req.json();

  if (!businessId || !supplierId || !description || !totalAmount || !dueDate) {
    return NextResponse.json(
      { error: "Bisnis, supplier, deskripsi, jumlah, dan tanggal tempo wajib diisi" },
      { status: 400 }
    );
  }

  const business = await prisma.business.findFirst({
    where: { id: businessId, ownerId: user.id },
  });
  if (!business) return NextResponse.json({ error: "Bisnis tidak ditemukan" }, { status: 404 });

  const supplier = await prisma.supplier.findFirst({
    where: { id: supplierId, businessId },
  });
  if (!supplier) return NextResponse.json({ error: "Supplier tidak ditemukan" }, { status: 404 });

  const now = new Date();
  const due = new Date(dueDate);

  const tempo = await prisma.supplierTempo.create({
    data: {
      businessId,
      supplierId,
      description: description.trim(),
      totalAmount: parseFloat(totalAmount),
      dueDate: due,
      invoiceNo: invoiceNo || null,
      notes: notes || null,
      status: due < now ? "overdue" : "pending",
    },
    include: {
      supplier: { select: { id: true, name: true, type: true } },
      business: { select: { id: true, name: true } },
    },
  });

  return NextResponse.json({ tempo }, { status: 201 });
}

export async function PUT(req: NextRequest) {
  await initDatabase();
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { id, description, totalAmount, dueDate, notes, status } = await req.json();

  if (!id) return NextResponse.json({ error: "ID tempo diperlukan" }, { status: 400 });

  const tempo = await prisma.supplierTempo.findFirst({
    where: { id },
    include: { business: true },
  });

  if (!tempo || tempo.business.ownerId !== user.id) {
    return NextResponse.json({ error: "Data tempo tidak ditemukan" }, { status: 404 });
  }

  const updated = await prisma.supplierTempo.update({
    where: { id },
    data: {
      description: description ? description.trim() : undefined,
      totalAmount: totalAmount ? parseFloat(totalAmount) : undefined,
      dueDate: dueDate ? new Date(dueDate) : undefined,
      notes: notes !== undefined ? notes : undefined,
      status: status || undefined,
    },
    include: {
      supplier: { select: { id: true, name: true, type: true } },
      business: { select: { id: true, name: true } },
    },
  });

  return NextResponse.json({ tempo: updated });
}

export async function DELETE(req: NextRequest) {
  await initDatabase();
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const id = searchParams.get("id");

  if (!id) return NextResponse.json({ error: "ID tempo diperlukan" }, { status: 400 });

  const tempo = await prisma.supplierTempo.findFirst({
    where: { id },
    include: { business: true },
  });

  if (!tempo || tempo.business.ownerId !== user.id) {
    return NextResponse.json({ error: "Data tempo tidak ditemukan" }, { status: 404 });
  }

  await prisma.supplierTempo.delete({ where: { id } });

  return NextResponse.json({ success: true });
}
