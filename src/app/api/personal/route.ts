import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { getSession } from "@/lib/auth";

export async function GET(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const month = parseInt(searchParams.get("month") || String(new Date().getMonth() + 1));
  const year = parseInt(searchParams.get("year") || String(new Date().getFullYear()));

  const personalBusiness = await prisma.business.findFirst({
    where: { ownerId: user.id, businessType: "personal", isArchived: false },
  });

  if (!personalBusiness) {
    return NextResponse.json({ transactions: [], totalExpense: 0 });
  }

  const dateStart = new Date(year, month - 1, 1);
  const dateEnd = new Date(year, month, 0, 23, 59, 59);

  const transactions = await prisma.transaction.findMany({
    where: {
      businessId: personalBusiness.id,
      isDeleted: false,
      transactionDate: { gte: dateStart, lte: dateEnd },
    },
    include: {
      category: { select: { name: true } },
    },
    orderBy: { transactionDate: "desc" },
  });

  const totalExpense = transactions.reduce((sum, t) => sum + t.amount, 0);

  return NextResponse.json({ transactions, totalExpense });
}
