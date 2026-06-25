import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { getSession, hashPassword } from "@/lib/auth";
import { initDatabase } from "@/lib/init-db";

export async function GET(req: NextRequest) {
  await initDatabase();
  const user = await getSession();
  if (!user || user.role !== "owner") return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const cashiers = await prisma.user.findMany({
    where: { role: "cashier" },
    select: { id: true, name: true, email: true, role: true, isActive: true, createdAt: true },
    orderBy: { createdAt: "desc" },
  });

  return NextResponse.json({ cashiers });
}

export async function POST(req: NextRequest) {
  await initDatabase();
  const user = await getSession();
  if (!user || user.role !== "owner") return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { name, email, password } = await req.json();

  if (!name || !email || !password) {
    return NextResponse.json({ error: "Nama, email, dan password wajib diisi" }, { status: 400 });
  }

  if (password.length < 4) {
    return NextResponse.json({ error: "Password minimal 4 karakter" }, { status: 400 });
  }

  const existing = await prisma.user.findUnique({ where: { email } });
  if (existing) {
    return NextResponse.json({ error: "Email sudah digunakan" }, { status: 409 });
  }

  const passwordHash = await hashPassword(password);
  const cashier = await prisma.user.create({
    data: { name: name.trim(), email: email.trim().toLowerCase(), passwordHash, role: "cashier" },
    select: { id: true, name: true, email: true, role: true, createdAt: true },
  });

  return NextResponse.json({ cashier }, { status: 201 });
}

export async function PUT(req: NextRequest) {
  await initDatabase();
  const user = await getSession();
  if (!user || user.role !== "owner") return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { id, name, email, password } = await req.json();

  if (!id) return NextResponse.json({ error: "ID kasir diperlukan" }, { status: 400 });

  const cashier = await prisma.user.findFirst({ where: { id, role: "cashier" } });
  if (!cashier) return NextResponse.json({ error: "Kasir tidak ditemukan" }, { status: 404 });

  const data: Record<string, unknown> = {};
  if (name) data.name = name.trim();
  if (email) data.email = email.trim().toLowerCase();
  if (password && password.length >= 4) data.passwordHash = await hashPassword(password);

  const updated = await prisma.user.update({
    where: { id },
    data,
    select: { id: true, name: true, email: true, role: true, isActive: true },
  });

  return NextResponse.json({ cashier: updated });
}

export async function DELETE(req: NextRequest) {
  await initDatabase();
  const user = await getSession();
  if (!user || user.role !== "owner") return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const id = searchParams.get("id");

  if (!id) return NextResponse.json({ error: "ID kasir diperlukan" }, { status: 400 });

  const cashier = await prisma.user.findFirst({ where: { id, role: "cashier" } });
  if (!cashier) return NextResponse.json({ error: "Kasir tidak ditemukan" }, { status: 404 });

  await prisma.user.update({ where: { id }, data: { isActive: false } });

  return NextResponse.json({ success: true });
}
