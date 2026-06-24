import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { getSession } from "@/lib/auth";

export async function GET(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const businessSlug = searchParams.get("business");
  const type = searchParams.get("type");
  const page = parseInt(searchParams.get("page") || "1");
  const limit = parseInt(searchParams.get("limit") || "20");
  const search = searchParams.get("search") || "";

  const where: Record<string, unknown> = {
    isDeleted: false,
  };

  if (businessSlug) {
    const business = await prisma.business.findFirst({
      where: { slug: businessSlug, ownerId: user.id },
    });
    if (business) {
      where.businessId = business.id;
    }
  } else {
    const userBusinesses = await prisma.business.findMany({
      where: { ownerId: user.id },
      select: { id: true },
    });
    where.businessId = { in: userBusinesses.map((b) => b.id) };
  }

  if (type && type !== "all") {
    where.transactionType = type;
  }

  if (search) {
    where.description = { contains: search };
  }

  const [transactions, total] = await Promise.all([
    prisma.transaction.findMany({
      where,
      include: {
        business: { select: { id: true, name: true, slug: true } },
        category: { select: { id: true, name: true } },
      },
      orderBy: { transactionDate: "desc" },
      skip: (page - 1) * limit,
      take: limit,
    }),
    prisma.transaction.count({ where }),
  ]);

  return NextResponse.json({
    transactions,
    pagination: { page, limit, total, totalPages: Math.ceil(total / limit) },
  });
}

export async function POST(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const body = await req.json();
  const { businessId, categoryId, transactionType, amount, transactionDate, description, notes, shift, cashierName } = body;

  if (!businessId || !transactionType || !amount) {
    return NextResponse.json(
      { error: "Bisnis, jenis, dan jumlah wajib diisi" },
      { status: 400 }
    );
  }

  const business = await prisma.business.findFirst({
    where: { id: businessId, ownerId: user.id },
  });

  if (!business) {
    return NextResponse.json({ error: "Bisnis tidak ditemukan" }, { status: 404 });
  }

  const transaction = await prisma.transaction.create({
    data: {
      businessId,
      categoryId: categoryId || null,
      createdById: user.id,
      transactionType,
      amount: parseFloat(amount),
      transactionDate: transactionDate ? new Date(transactionDate) : new Date(),
      description: description || "",
      notes: notes || null,
      shift: shift || null,
      cashierName: cashierName || null,
      isPersonal: business.businessType === "personal",
    },
    include: {
      business: { select: { id: true, name: true, slug: true } },
      category: { select: { id: true, name: true } },
    },
  });

  return NextResponse.json({ transaction }, { status: 201 });
}

export async function DELETE(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const id = searchParams.get("id");

  if (!id) return NextResponse.json({ error: "ID transaksi diperlukan" }, { status: 400 });

  const transaction = await prisma.transaction.findFirst({
    where: { id },
    include: { business: true },
  });

  if (!transaction || transaction.business.ownerId !== user.id) {
    return NextResponse.json({ error: "Transaksi tidak ditemukan" }, { status: 404 });
  }

  await prisma.transaction.update({
    where: { id },
    data: { isDeleted: true },
  });

  return NextResponse.json({ success: true });
}
