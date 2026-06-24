import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { getSession } from "@/lib/auth";

export async function GET(req: NextRequest) {
  const user = await getSession();
  if (!user) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const { searchParams } = new URL(req.url);
  const period = searchParams.get("period") || "month";
  const businessSlug = searchParams.get("business") || "";
  const year = parseInt(searchParams.get("year") || String(new Date().getFullYear()));
  const month = parseInt(searchParams.get("month") || String(new Date().getMonth() + 1));

  let dateFilter: { gte: Date; lte: Date } = { gte: new Date(), lte: new Date() };
  const now = new Date();

  if (period === "month") {
    dateFilter = {
      gte: new Date(year, month - 1, 1),
      lte: new Date(year, month, 0, 23, 59, 59),
    };
  } else if (period === "year") {
    dateFilter = {
      gte: new Date(year, 0, 1),
      lte: new Date(year, 11, 31, 23, 59, 59),
    };
  } else if (period === "week") {
    const dayOfWeek = now.getDay();
    const diff = now.getDate() - dayOfWeek + (dayOfWeek === 0 ? -6 : 1);
    dateFilter = {
      gte: new Date(now.getFullYear(), now.getMonth(), diff),
      lte: new Date(now.getFullYear(), now.getMonth(), diff + 6, 23, 59, 59),
    };
  } else if (period === "today") {
    const today = new Date();
    dateFilter = {
      gte: new Date(today.getFullYear(), today.getMonth(), today.getDate()),
      lte: new Date(today.getFullYear(), today.getMonth(), today.getDate(), 23, 59, 59),
    };
  }

  // Get all user businesses, or filter by slug
  const allBusinesses = await prisma.business.findMany({
    where: {
      ownerId: user.id,
      isArchived: false,
      ...(businessSlug ? { slug: businessSlug } : {}),
    },
  });

  const businessIds = allBusinesses.map((b) => b.id);

  // Per-business summaries
  const businessSummaries = await Promise.all(
    allBusinesses.map(async (b) => {
      const transactions = await prisma.transaction.findMany({
        where: {
          businessId: b.id,
          isDeleted: false,
          transactionDate: {
            gte: dateFilter.gte,
            lte: dateFilter.lte,
          },
        },
      });

      const totalIncome = transactions
        .filter((t) => t.transactionType === "income")
        .reduce((sum, t) => sum + t.amount, 0);

      const totalExpense = transactions
        .filter((t) => t.transactionType === "expense")
        .reduce((sum, t) => sum + t.amount, 0);

      return {
        id: b.id,
        name: b.name,
        slug: b.slug,
        businessType: b.businessType,
        totalIncome,
        totalExpense,
        netProfit: totalIncome - totalExpense,
        transactionCount: transactions.length,
      };
    })
  );

  // Monthly trend (last 12 months) for filtered businesses
  const monthlyTrend: { month: string; income: number; expense: number }[] = [];
  for (let i = 11; i >= 0; i--) {
    const m = new Date(now.getFullYear(), now.getMonth() - i, 1);
    const monthEnd = new Date(now.getFullYear(), now.getMonth() - i + 1, 0, 23, 59, 59);

    const transactions = await prisma.transaction.findMany({
      where: {
        businessId: { in: businessIds },
        isDeleted: false,
        transactionDate: {
          gte: m,
          lte: monthEnd,
        },
      },
    });

    monthlyTrend.push({
      month: m.toLocaleDateString("id-ID", { month: "short", year: "numeric" }),
      income: transactions.filter((t) => t.transactionType === "income").reduce((sum, t) => sum + t.amount, 0),
      expense: transactions.filter((t) => t.transactionType === "expense").reduce((sum, t) => sum + t.amount, 0),
    });
  }

  // Recent transactions for filtered businesses
  const allTransactions = await prisma.transaction.findMany({
    where: {
      businessId: { in: businessIds },
      isDeleted: false,
      transactionDate: {
        gte: dateFilter.gte,
        lte: dateFilter.lte,
      },
    },
    orderBy: { transactionDate: "desc" },
    take: 10,
    include: {
      business: { select: { name: true } },
      category: { select: { name: true } },
    },
  });

  const totalAllIncome = businessSummaries.reduce((sum, b) => sum + b.totalIncome, 0);
  const totalAllExpense = businessSummaries.reduce((sum, b) => sum + b.totalExpense, 0);

  return NextResponse.json({
    period: { type: period, year, month, gte: dateFilter.gte, lte: dateFilter.lte },
    totalIncome: totalAllIncome,
    totalExpense: totalAllExpense,
    netProfit: totalAllIncome - totalAllExpense,
    businesses: businessSummaries,
    monthlyTrend,
    recentTransactions: allTransactions,
  });
}
