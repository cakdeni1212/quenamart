import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { getSession } from "@/lib/auth";

export async function GET(req: NextRequest) {
  const user = await getSession();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const year = parseInt(searchParams.get("year") || String(new Date().getFullYear()));
  const month = parseInt(searchParams.get("month") || String(new Date().getMonth() + 1));
  const businessSlug = searchParams.get("business") || "";
  const format = searchParams.get("format") || "json";

  const businesses = await prisma.business.findMany({
    where: { ownerId: user.id, isArchived: false },
    select: { id: true, name: true, slug: true, businessType: true },
  });

  const targetBusinesses = businessSlug
    ? businesses.filter((b) => b.slug === businessSlug)
    : businesses;

  const dateStart = new Date(year, month - 1, 1);
  const dateEnd = new Date(year, month, 0, 23, 59, 59);

  const businessIds = targetBusinesses.map((b) => b.id);

  const transactions = await prisma.transaction.findMany({
    where: {
      businessId: { in: businessIds },
      isDeleted: false,
      transactionDate: { gte: dateStart, lte: dateEnd },
    },
    include: {
      business: { select: { name: true } },
      category: { select: { name: true } },
    },
    orderBy: { transactionDate: "asc" },
  });

  // Group by business
  const byBusiness: Record<string, {
    name: string;
    income: number;
    expense: number;
    transactions: typeof transactions;
  }> = {};

  for (const t of transactions) {
    if (!byBusiness[t.businessId]) {
      byBusiness[t.businessId] = {
        name: t.business.name,
        income: 0,
        expense: 0,
        transactions: [],
      };
    }
    if (t.transactionType === "income") {
      byBusiness[t.businessId].income += t.amount;
    } else {
      byBusiness[t.businessId].expense += t.amount;
    }
    byBusiness[t.businessId].transactions.push(t);
  }

  // Group by category
  const byCategory: Record<string, { name: string; total: number; count: number }> = {};
  for (const t of transactions) {
    const key = t.category?.name || "Tanpa Kategori";
    if (!byCategory[key]) byCategory[key] = { name: key, total: 0, count: 0 };
    byCategory[key].total += t.amount;
    byCategory[key].count += 1;
  }

  // Daily breakdown
  const dailyMap: Record<string, { income: number; expense: number }> = {};
  for (const t of transactions) {
    const day = t.transactionDate.toISOString().split("T")[0];
    if (!dailyMap[day]) dailyMap[day] = { income: 0, expense: 0 };
    if (t.transactionType === "income") dailyMap[day].income += t.amount;
    else dailyMap[day].expense += t.amount;
  }

  const daily = Object.entries(dailyMap)
    .map(([date, val]) => ({ date: new Date(date).toLocaleDateString("id-ID", { day: "numeric", month: "short" }), ...val }))
    .sort((a, b) => new Date(a.date).getTime() - new Date(b.date).getTime());

  const totalIncome = transactions.filter((t) => t.transactionType === "income").reduce((s, t) => s + t.amount, 0);
  const totalExpense = transactions.filter((t) => t.transactionType === "expense").reduce((s, t) => s + t.amount, 0);

  if (format === "csv") {
    const rows = [
      ["Tanggal", "Bisnis", "Jenis", "Kategori", "Deskripsi", "Jumlah"].join(","),
      ...transactions.map((t) =>
        [
          t.transactionDate.toISOString().split("T")[0],
          t.business.name,
          t.transactionType === "income" ? "Pemasukan" : "Pengeluaran",
          t.category?.name || "-",
          `"${t.description}"`,
          t.amount,
        ].join(",")
      ),
    ].join("\n");

    return new NextResponse(rows, {
      headers: {
        "Content-Type": "text/csv",
        "Content-Disposition": `attachment; filename=laporan-${year}-${month}.csv`,
      },
    });
  }

  return NextResponse.json({
    period: { year, month, start: dateStart, end: dateEnd },
    summary: { totalIncome, totalExpense, netProfit: totalIncome - totalExpense },
    byBusiness: Object.entries(byBusiness).map(([id, val]) => ({
      id,
      ...val,
      netProfit: val.income - val.expense,
      transactionCount: val.transactions.length,
    })),
    byCategory: Object.entries(byCategory)
      .map(([, val]) => val)
      .sort((a, b) => b.total - a.total),
    daily,
    transactions,
  });
}
