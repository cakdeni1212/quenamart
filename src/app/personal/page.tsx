"use client";

import { useState, useEffect, useCallback } from "react";
import Link from "next/link";
import { formatCurrency } from "@/lib/utils";
import { Plus, User, TrendingDown, Loader2 } from "lucide-react";

interface Transaction {
  id: string;
  transactionType: string;
  description: string;
  amount: number;
  transactionDate: string;
  notes: string | null;
  category: { name: string } | null;
}

export default function PersonalPage() {
  const [transactions, setTransactions] = useState<Transaction[]>([]);
  const [loading, setLoading] = useState(true);
  const [totalExpense, setTotalExpense] = useState(0);
  const [month, setMonth] = useState(new Date().getMonth() + 1);
  const [year, setYear] = useState(new Date().getFullYear());

  const fetchData = useCallback(async () => {
    setLoading(true);
    try {
      const res = await fetch(`/api/personal?month=${month}&year=${year}`);
      const data = await res.json();
      setTransactions(data.transactions);
      setTotalExpense(data.totalExpense);
    } finally {
      setLoading(false);
    }
  }, [month, year]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

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
    <div className="space-y-6 max-w-4xl">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Pribadi / Keluarga</h1>
          <p className="text-gray-500 text-sm mt-1">Catat pengeluaran pribadi dan keluarga</p>
        </div>
        <Link
          href="/transactions/new?business=pribadi"
          className="flex items-center gap-2 px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700 transition-colors"
        >
          <Plus className="w-4 h-4" />
          Catat Pengeluaran
        </Link>
      </div>

      {/* Month selector */}
      <div className="flex items-center gap-2 bg-white rounded-xl border border-gray-200 p-3">
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
          value={year}
          onChange={(e) => setYear(parseInt(e.target.value))}
          className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
        >
          {Array.from({ length: 5 }, (_, i) => new Date().getFullYear() - 2 + i).map((y) => (
            <option key={y} value={y}>{y}</option>
          ))}
        </select>
      </div>

      {/* Summary */}
      <div className="bg-white rounded-xl border border-gray-200 p-5">
        <div className="flex items-center gap-3">
          <div className="w-12 h-12 rounded-xl bg-red-100 flex items-center justify-center">
            <TrendingDown className="w-6 h-6 text-red-600" />
          </div>
          <div>
            <p className="text-sm text-gray-500">Total Pengeluaran {monthNames[month - 1]} {year}</p>
            <p className="text-2xl font-bold text-red-600">{formatCurrency(totalExpense)}</p>
          </div>
        </div>
      </div>

      {/* Transactions */}
      <div className="bg-white rounded-xl border border-gray-200 overflow-hidden">
        <div className="px-4 py-3 border-b border-gray-100">
          <h2 className="font-semibold text-gray-900">Riwayat Pengeluaran</h2>
        </div>
        {transactions.length === 0 ? (
          <div className="p-8 text-center">
            <User className="w-10 h-10 text-gray-300 mx-auto mb-3" />
            <p className="text-gray-500 text-sm">Belum ada pengeluaran bulan ini</p>
          </div>
        ) : (
          <div className="divide-y divide-gray-100">
            {transactions.map((t) => (
              <div key={t.id} className="flex items-center justify-between px-4 py-3">
                <div className="min-w-0">
                  <p className="text-sm font-medium text-gray-900 truncate">{t.description}</p>
                  <div className="flex gap-2 text-xs text-gray-500 mt-0.5">
                    {t.category && <span>{t.category.name}</span>}
                    <span>{new Date(t.transactionDate).toLocaleDateString("id-ID")}</span>
                  </div>
                </div>
                <p className="text-sm font-semibold text-red-600 flex-shrink-0 ml-3">
                  -{formatCurrency(t.amount)}
                </p>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
