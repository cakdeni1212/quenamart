import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { getSession } from "@/lib/auth";

export async function GET(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const month = parseInt(searchParams.get("month") || String(new Date().getMonth() + 1));
  const year = parseInt(searchParams.get("year") || String(new Date().getFullYear()));

  const minimarket = await prisma.business.findFirst({
    where: {
      ownerId: user.id,
      isArchived: false,
      OR: [
        { businessType: "minimarket" },
        { name: { contains: "minimarket" } },
      ],
    },
  });

  if (!minimarket) {
    return NextResponse.json({ shifts: [], cashiers: [] });
  }

  const dateStart = new Date(year, month - 1, 1);
  const dateEnd = new Date(year, month, 0, 23, 59, 59);

  const transactions = await prisma.transaction.findMany({
    where: {
      businessId: minimarket.id,
      isDeleted: false,
      shift: { not: null },
      transactionDate: { gte: dateStart, lte: dateEnd },
    },
    orderBy: { transactionDate: "desc" },
  });

  // Group by date + shift
  const shiftMap: Record<string, Record<string, { income: number; expense: number; cashierName: string }>> = {};

  for (const t of transactions) {
    const dateKey = t.transactionDate.toISOString().split("T")[0];
    if (!shiftMap[dateKey]) shiftMap[dateKey] = {};

    const shift = t.shift || "pagi";
    if (!shiftMap[dateKey][shift]) {
      shiftMap[dateKey][shift] = { income: 0, expense: 0, cashierName: t.cashierName || "" };
    }

    if (t.transactionType === "income") {
      shiftMap[dateKey][shift].income += t.amount;
    } else {
      shiftMap[dateKey][shift].expense += t.amount;
    }

    if (t.cashierName && !shiftMap[dateKey][shift].cashierName) {
      shiftMap[dateKey][shift].cashierName = t.cashierName;
    }
  }

  const shifts: { date: string; shift: string; cashierName: string; income: number; expense: number }[] = [];

  for (const [date, sh] of Object.entries(shiftMap)) {
    for (const [shift, val] of Object.entries(sh)) {
      shifts.push({ date, shift, ...val });
    }
  }

  shifts.sort((a, b) => b.date.localeCompare(a.date));

  const cashiers = [...new Set(transactions.map((t) => t.cashierName).filter(Boolean))];

  return NextResponse.json({ shifts, cashiers });
}
