import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { getSession } from "@/lib/auth";
import { initDatabase } from "@/lib/init-db";

export async function POST(req: NextRequest) {
  await initDatabase();
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { tempoId, amount, paymentDate, notes } = await req.json();

  if (!tempoId || !amount) {
    return NextResponse.json(
      { error: "Tempo dan jumlah pembayaran wajib diisi" },
      { status: 400 }
    );
  }

  const tempo = await prisma.supplierTempo.findFirst({
    where: { id: tempoId },
    include: { business: true, supplier: true },
  });

  if (!tempo || tempo.business.ownerId !== user.id) {
    return NextResponse.json({ error: "Data tempo tidak ditemukan" }, { status: 404 });
  }

  const payAmount = parseFloat(amount);
  const newPaidAmount = tempo.paidAmount + payAmount;
  let newStatus = tempo.status;

  if (newPaidAmount >= tempo.totalAmount) {
    newStatus = "paid";
  } else if (newPaidAmount > 0) {
    newStatus = "partial";
  }

  const payment = await prisma.tempoPayment.create({
    data: {
      tempoId,
      amount: payAmount,
      paymentDate: paymentDate ? new Date(paymentDate) : new Date(),
      notes: notes || null,
    },
  });

  await prisma.supplierTempo.update({
    where: { id: tempoId },
    data: {
      paidAmount: newPaidAmount,
      status: newStatus,
    },
  });

  const updatedTempo = await prisma.supplierTempo.findUnique({
    where: { id: tempoId },
    include: {
      supplier: { select: { id: true, name: true, type: true } },
      business: { select: { id: true, name: true } },
      payments: {
        select: { id: true, amount: true, paymentDate: true, notes: true },
        orderBy: { paymentDate: "desc" },
      },
    },
  });

  return NextResponse.json({ payment, tempo: updatedTempo }, { status: 201 });
}
