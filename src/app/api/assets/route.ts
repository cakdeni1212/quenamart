import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { getSession } from "@/lib/auth";

export async function GET(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const businessSlug = searchParams.get("business") || "";

  const where: Record<string, unknown> = {
    business: { ownerId: user.id, isArchived: false },
    isActive: true,
  };

  if (businessSlug) {
    where.business = { ...(where.business as object), slug: businessSlug };
  }

  const assets = await prisma.asset.findMany({
    where,
    include: {
      business: { select: { id: true, name: true, slug: true } },
    },
    orderBy: { createdAt: "desc" },
  });

  return NextResponse.json({ assets });
}

export async function POST(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const body = await req.json();
  const { businessId, name, assetType, value, purchasePrice, purchaseDate, notes } = body;

  if (!businessId || !name) {
    return NextResponse.json({ error: "Bisnis dan nama aset wajib diisi" }, { status: 400 });
  }

  const business = await prisma.business.findFirst({
    where: { id: businessId, ownerId: user.id },
  });

  if (!business) {
    return NextResponse.json({ error: "Bisnis tidak ditemukan" }, { status: 404 });
  }

  const asset = await prisma.asset.create({
    data: {
      businessId,
      name,
      assetType: assetType || "equipment",
      value: value ? parseFloat(value) : 0,
      purchasePrice: purchasePrice ? parseFloat(purchasePrice) : 0,
      purchaseDate: purchaseDate ? new Date(purchaseDate) : null,
      notes: notes || null,
    },
    include: {
      business: { select: { id: true, name: true, slug: true } },
    },
  });

  return NextResponse.json({ asset }, { status: 201 });
}

export async function PUT(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const body = await req.json();
  const { id, name, assetType, value, purchasePrice, purchaseDate, notes } = body;

  if (!id) return NextResponse.json({ error: "ID aset diperlukan" }, { status: 400 });

  const asset = await prisma.asset.findFirst({
    where: { id },
    include: { business: true },
  });

  if (!asset || asset.business.ownerId !== user.id) {
    return NextResponse.json({ error: "Aset tidak ditemukan" }, { status: 404 });
  }

  const updated = await prisma.asset.update({
    where: { id },
    data: {
      ...(name !== undefined && { name }),
      ...(assetType !== undefined && { assetType }),
      ...(value !== undefined && { value: parseFloat(value) }),
      ...(purchasePrice !== undefined && { purchasePrice: parseFloat(purchasePrice) }),
      ...(purchaseDate !== undefined && { purchaseDate: purchaseDate ? new Date(purchaseDate) : null }),
      ...(notes !== undefined && { notes }),
    },
    include: {
      business: { select: { id: true, name: true, slug: true } },
    },
  });

  return NextResponse.json({ asset: updated });
}

export async function DELETE(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const id = searchParams.get("id");

  if (!id) return NextResponse.json({ error: "ID aset diperlukan" }, { status: 400 });

  const asset = await prisma.asset.findFirst({
    where: { id },
    include: { business: true },
  });

  if (!asset || asset.business.ownerId !== user.id) {
    return NextResponse.json({ error: "Aset tidak ditemukan" }, { status: 404 });
  }

  await prisma.asset.delete({ where: { id } });

  return NextResponse.json({ success: true });
}
