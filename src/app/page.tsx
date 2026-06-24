"use client";

import { useState, useEffect } from "react";
import Link from "next/link";
import { formatCurrency } from "@/lib/utils";
import {
  TrendingUp,
  TrendingDown,
  Wallet,
  ArrowRightLeft,
  Building2,
  Loader2,
} from "lucide-react";
import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Legend,
} from "recharts";

interface DashboardData {
  totalIncome: number;
  totalExpense: number;
  netProfit: number;
  businesses: {
    id: string;
    name: string;
    slug: string;
    businessType: string;
    totalIncome: number;
    totalExpense: number;
    netProfit: number;
    transactionCount: number;
  }[];
  monthlyTrend: { month: string; income: number; expense: number }[];
  recentTransactions: {
    id: string;
    transactionType: string;
    description: string;
    amount: number;
    transactionDate: string;
    business: { name: string };
    category: { name: string } | null;
  }[];
}

export default function DashboardPage() {
  const [data, setData] = useState<DashboardData | null>(null);
  const [period, setPeriod] = useState("month");
  const [businessSlug, setBusinessSlug] = useState("");
  const [businesses, setBusinesses] = useState<{ slug: string; name: string }[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch("/api/businesses")
      .then((r) => r.ok ? r.json() : { businesses: [] })
      .then((d) => setBusinesses(d.businesses))
      .catch(() => {});
  }, []);

  useEffect(() => {
    fetchData();
  }, [period, businessSlug]);

  async function fetchData() {
    setLoading(true);
    try {
      const params = new URLSearchParams({ period });
      if (businessSlug) params.set("business", businessSlug);
      const res = await fetch(`/api/dashboard?${params}`);
      if (res.ok) setData(await res.json());
    } catch (e) {
      console.error(e);
    } finally {
      setLoading(false);
    }
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 className="w-8 h-8 animate-spin text-emerald-600" />
      </div>
    );
  }

  if (!data) return null;

  return (
    <div className="space-y-6 max-w-7xl">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Dashboard</h1>
          <p className="text-gray-500 text-sm mt-1">Ringkasan keuangan semua bisnis</p>
        </div>
        <div className="flex flex-wrap gap-2 items-center">
          <select
            value={businessSlug}
            onChange={(e) => setBusinessSlug(e.target.value)}
            className="px-3 py-1.5 text-sm border border-gray-300 rounded-lg bg-white focus:outline-none focus:ring-2 focus:ring-emerald-500"
          >
            <option value="">Semua Bisnis</option>
            {businesses.map((b) => (
              <option key={b.slug} value={b.slug}>{b.name}</option>
            ))}
          </select>
          {["today", "week", "month", "year"].map((p) => (
            <button
              key={p}
              onClick={() => setPeriod(p)}
              className={`px-3 py-1.5 text-sm rounded-lg font-medium transition-colors ${
                period === p
                  ? "bg-emerald-600 text-white"
                  : "bg-white text-gray-600 border border-gray-200 hover:bg-gray-50"
              }`}
            >
              {p === "today" ? "Hari Ini" : p === "week" ? "Minggu Ini" : p === "month" ? "Bulan Ini" : "Tahun Ini"}
            </button>
          ))}
        </div>
      </div>

      {/* Summary Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <div className="bg-white rounded-xl border border-gray-200 p-5">
          <div className="flex items-center gap-3 mb-3">
            <div className="w-10 h-10 rounded-lg bg-emerald-100 flex items-center justify-center">
              <TrendingUp className="w-5 h-5 text-emerald-600" />
            </div>
            <div>
              <p className="text-sm text-gray-500">Total Pemasukan</p>
              <p className="text-xl font-bold text-emerald-600">{formatCurrency(data.totalIncome)}</p>
            </div>
          </div>
        </div>
        <div className="bg-white rounded-xl border border-gray-200 p-5">
          <div className="flex items-center gap-3 mb-3">
            <div className="w-10 h-10 rounded-lg bg-red-100 flex items-center justify-center">
              <TrendingDown className="w-5 h-5 text-red-600" />
            </div>
            <div>
              <p className="text-sm text-gray-500">Total Pengeluaran</p>
              <p className="text-xl font-bold text-red-600">{formatCurrency(data.totalExpense)}</p>
            </div>
          </div>
        </div>
        <div className="bg-white rounded-xl border border-gray-200 p-5">
          <div className="flex items-center gap-3 mb-3">
            <div className="w-10 h-10 rounded-lg bg-blue-100 flex items-center justify-center">
              <Wallet className="w-5 h-5 text-blue-600" />
            </div>
            <div>
              <p className="text-sm text-gray-500">Laba / Rugi Bersih</p>
              <p className={`text-xl font-bold ${data.netProfit >= 0 ? "text-blue-600" : "text-red-600"}`}>
                {formatCurrency(data.netProfit)}
              </p>
            </div>
          </div>
        </div>
      </div>

      {/* Chart */}
      <div className="bg-white rounded-xl border border-gray-200 p-5">
        <h2 className="text-lg font-semibold text-gray-900 mb-4">Tren 12 Bulan Terakhir</h2>
        <ResponsiveContainer width="100%" height={300}>
          <AreaChart data={data.monthlyTrend}>
            <CartesianGrid strokeDasharray="3 3" stroke="#f0f0f0" />
            <XAxis dataKey="month" fontSize={12} tickLine={false} />
            <YAxis
              fontSize={12}
              tickLine={false}
              axisLine={false}
              tickFormatter={(v) => `${(v / 1000000).toFixed(0)}M`}
            />
            <Tooltip formatter={(v) => formatCurrency(Number(v))} />
            <Legend />
            <Area
              type="monotone"
              dataKey="income"
              stroke="#059669"
              fill="#d1fae5"
              name="Pemasukan"
              strokeWidth={2}
            />
            <Area
              type="monotone"
              dataKey="expense"
              stroke="#dc2626"
              fill="#fee2e2"
              name="Pengeluaran"
              strokeWidth={2}
            />
          </AreaChart>
        </ResponsiveContainer>
      </div>

      {/* Business Summary */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div className="bg-white rounded-xl border border-gray-200 p-5">
          <div className="flex items-center justify-between mb-4">
            <h2 className="text-lg font-semibold text-gray-900">Per Bisnis</h2>
            <Link
              href="/businesses"
              className="text-sm text-emerald-600 hover:underline flex items-center gap-1"
            >
              Lihat Semua
            </Link>
          </div>
          <div className="space-y-3">
            {data.businesses.map((b) => (
              <Link
                key={b.id}
                href={`/transactions?business=${b.slug}`}
                className="flex items-center justify-between p-3 rounded-lg hover:bg-gray-50 border border-gray-100 transition-colors"
              >
                <div className="flex items-center gap-3">
                  <div className="w-9 h-9 rounded-lg bg-gray-100 flex items-center justify-center">
                    <Building2 className="w-4 h-4 text-gray-600" />
                  </div>
                  <div>
                    <p className="text-sm font-medium text-gray-900">{b.name}</p>
                    <p className="text-xs text-gray-500">{b.transactionCount} transaksi</p>
                  </div>
                </div>
                <div className="text-right">
                  <p className={`text-sm font-semibold ${b.netProfit >= 0 ? "text-emerald-600" : "text-red-600"}`}>
                    {formatCurrency(b.netProfit)}
                  </p>
                  <div className="flex gap-2 text-xs text-gray-500">
                    <span className="text-emerald-600">+{formatCurrency(b.totalIncome)}</span>
                    <span className="text-red-600">-{formatCurrency(b.totalExpense)}</span>
                  </div>
                </div>
              </Link>
            ))}
          </div>
        </div>

        {/* Recent Transactions */}
        <div className="bg-white rounded-xl border border-gray-200 p-5">
          <div className="flex items-center justify-between mb-4">
            <h2 className="text-lg font-semibold text-gray-900">Transaksi Terbaru</h2>
            <Link
              href="/transactions"
              className="text-sm text-emerald-600 hover:underline flex items-center gap-1"
            >
              Lihat Semua
            </Link>
          </div>
          <div className="space-y-2">
            {data.recentTransactions.length === 0 && (
              <p className="text-sm text-gray-500 text-center py-6">Belum ada transaksi</p>
            )}
            {data.recentTransactions.map((t) => (
              <div
                key={t.id}
                className="flex items-center justify-between p-2.5 rounded-lg hover:bg-gray-50"
              >
                <div className="flex items-center gap-3 min-w-0">
                  <div
                    className={`w-8 h-8 rounded-lg flex items-center justify-center flex-shrink-0 ${
                      t.transactionType === "income" ? "bg-emerald-100" : "bg-red-100"
                    }`}
                  >
                    <ArrowRightLeft
                      className={`w-4 h-4 ${
                        t.transactionType === "income" ? "text-emerald-600" : "text-red-600"
                      }`}
                    />
                  </div>
                  <div className="min-w-0">
                    <p className="text-sm font-medium text-gray-900 truncate">
                      {t.category?.name || t.description || "Tanpa Kategori"}
                    </p>
                    <p className="text-xs text-gray-500 truncate">
                      {t.business.name}{t.description && ` · ${t.description}`}
                    </p>
                  </div>
                </div>
                <div className="text-right flex-shrink-0 ml-3">
                  <p
                    className={`text-sm font-semibold ${
                      t.transactionType === "income" ? "text-emerald-600" : "text-red-600"
                    }`}
                  >
                    {t.transactionType === "income" ? "+" : "-"}
                    {formatCurrency(t.amount)}
                  </p>
                  <p className="text-xs text-gray-400">
                    {new Date(t.transactionDate).toLocaleDateString("id-ID")}
                  </p>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
