"use client";

import { useState, useEffect } from "react";
import { formatCurrency } from "@/lib/utils";
import {
  BarChart3,
  Download,
  Loader2,
  TrendingUp,
  TrendingDown,
  Calendar,
} from "lucide-react";
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from "recharts";

interface ReportData {
  period: { year: number; month: number };
  summary: { totalIncome: number; totalExpense: number; netProfit: number };
  byBusiness: {
    id: string;
    name: string;
    income: number;
    expense: number;
    netProfit: number;
    transactionCount: number;
  }[];
  byCategory: { name: string; total: number; count: number }[];
  daily: { date: string; income: number; expense: number }[];
}

export default function ReportsPage() {
  const now = new Date();
  const [year, setYear] = useState(now.getFullYear());
  const [month, setMonth] = useState(now.getMonth() + 1);
  const [business, setBusiness] = useState("");
  const [data, setData] = useState<ReportData | null>(null);
  const [loading, setLoading] = useState(true);
  const [businesses, setBusinesses] = useState<{ slug: string; name: string }[]>([]);

  useEffect(() => {
    fetch("/api/businesses")
      .then((r) => r.json())
      .then((d) => setBusinesses(d.businesses));
  }, []);

  useEffect(() => {
    fetchData();
  }, [year, month, business]);

  async function fetchData() {
    setLoading(true);
    const params = new URLSearchParams({ year: String(year), month: String(month) });
    if (business) params.set("business", business);
    const res = await fetch(`/api/reports?${params}`);
    setData(await res.json());
    setLoading(false);
  }

  function exportCSV() {
    if (!business) return;
    window.open(`/api/reports?year=${year}&month=${month}&business=${business}&format=csv`);
  }

  const monthNames = [
    "Januari", "Februari", "Maret", "April", "Mei", "Juni",
    "Juli", "Agustus", "September", "Oktober", "November", "Desember",
  ];

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 className="w-8 h-8 animate-spin text-emerald-600" />
      </div>
    );
  }

  return (
    <div className="space-y-6 max-w-6xl">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Laporan</h1>
          <p className="text-gray-500 text-sm mt-1">Analisis keuangan per periode</p>
        </div>
        <div className="flex items-center gap-2">
          {business && (
            <button
              onClick={exportCSV}
              className="flex items-center gap-2 px-3 py-2 border border-gray-200 rounded-lg text-sm hover:bg-gray-50"
            >
              <Download className="w-4 h-4" />
              CSV
            </button>
          )}
        </div>
      </div>

      {/* Filters */}
      <div className="flex flex-col sm:flex-row gap-3 bg-white rounded-xl border border-gray-200 p-4">
        <select
          value={year}
          onChange={(e) => setYear(parseInt(e.target.value))}
          className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
        >
          {Array.from({ length: 5 }, (_, i) => now.getFullYear() - 2 + i).map((y) => (
            <option key={y} value={y}>{y}</option>
          ))}
        </select>
        <select
          value={month}
          onChange={(e) => setMonth(parseInt(e.target.value))}
          className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
        >
          {monthNames.map((m, i) => (
            <option key={i + 1} value={i + 1}>{m}</option>
          ))}
        </select>
        <select
          value={business}
          onChange={(e) => setBusiness(e.target.value)}
          className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
        >
          <option value="">Semua Bisnis</option>
          {businesses.map((b) => (
            <option key={b.slug} value={b.slug}>{b.name}</option>
          ))}
        </select>
      </div>

      {data && (
        <>
          {/* Summary */}
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
            <div className="bg-white rounded-xl border border-gray-200 p-5">
              <p className="text-sm text-gray-500">Total Pemasukan</p>
              <p className="text-2xl font-bold text-emerald-600">{formatCurrency(data.summary.totalIncome)}</p>
            </div>
            <div className="bg-white rounded-xl border border-gray-200 p-5">
              <p className="text-sm text-gray-500">Total Pengeluaran</p>
              <p className="text-2xl font-bold text-red-600">{formatCurrency(data.summary.totalExpense)}</p>
            </div>
            <div className="bg-white rounded-xl border border-gray-200 p-5">
              <p className="text-sm text-gray-500">Laba / Rugi</p>
              <p className={`text-2xl font-bold ${data.summary.netProfit >= 0 ? "text-emerald-600" : "text-red-600"}`}>
                {formatCurrency(data.summary.netProfit)}
              </p>
            </div>
          </div>

          {/* Daily Chart */}
          <div className="bg-white rounded-xl border border-gray-200 p-5">
            <h2 className="text-lg font-semibold text-gray-900 mb-4">Pemasukan & Pengeluaran Harian</h2>
            <ResponsiveContainer width="100%" height={280}>
              <BarChart data={data.daily}>
                <CartesianGrid strokeDasharray="3 3" stroke="#f0f0f0" />
                <XAxis dataKey="date" fontSize={12} tickLine={false} />
                <YAxis fontSize={12} tickFormatter={(v) => `${(v / 1000000).toFixed(0)}M`} />
                <Tooltip formatter={(v) => formatCurrency(Number(v))} />
                <Bar dataKey="income" fill="#059669" name="Pemasukan" radius={[4, 4, 0, 0]} />
                <Bar dataKey="expense" fill="#dc2626" name="Pengeluaran" radius={[4, 4, 0, 0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>

          {/* By Business */}
          <div className="bg-white rounded-xl border border-gray-200 p-5">
            <h2 className="text-lg font-semibold text-gray-900 mb-4">Rincian Per Bisnis</h2>
            <div className="space-y-3">
              {data.byBusiness.map((b) => (
                <div key={b.id} className="flex items-center justify-between p-3 rounded-lg border border-gray-100">
                  <div>
                    <p className="text-sm font-medium text-gray-900">{b.name}</p>
                    <p className="text-xs text-gray-500">{b.transactionCount} transaksi</p>
                  </div>
                  <div className="text-right">
                    <p className={`text-sm font-semibold ${b.netProfit >= 0 ? "text-emerald-600" : "text-red-600"}`}>
                      {formatCurrency(b.netProfit)}
                    </p>
                    <div className="flex gap-2 text-xs">
                      <span className="text-emerald-600">+{formatCurrency(b.income)}</span>
                      <span className="text-red-600">-{formatCurrency(b.expense)}</span>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </div>

          {/* By Category */}
          <div className="bg-white rounded-xl border border-gray-200 p-5">
            <h2 className="text-lg font-semibold text-gray-900 mb-4">Pengeluaran Per Kategori</h2>
            <div className="space-y-2">
              {data.byCategory.map((cat) => (
                <div key={cat.name} className="flex items-center justify-between py-2">
                  <div className="flex items-center gap-3">
                    <div
                      className="h-2 rounded-full bg-red-400"
                      style={{
                        width: `${Math.max(
                          4,
                          (cat.total / Math.max(...data.byCategory.map((c) => c.total))) * 200
                        )}px`,
                      }}
                    />
                    <span className="text-sm text-gray-700">{cat.name}</span>
                  </div>
                  <div className="flex items-center gap-3 text-sm">
                    <span className="text-gray-500">{cat.count}x</span>
                    <span className="font-medium text-gray-900">{formatCurrency(cat.total)}</span>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </>
      )}
    </div>
  );
}
