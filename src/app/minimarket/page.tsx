"use client";

import { useState, useEffect } from "react";
import Link from "next/link";
import { formatCurrency } from "@/lib/utils";
import {
  Plus,
  Save,
  Store,
  Sun,
  Moon,
  Users,
  TrendingUp,
  TrendingDown,
  Loader2,
} from "lucide-react";
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Legend,
} from "recharts";

interface ShiftData {
  date: string;
  shift: string;
  cashierName: string;
  income: number;
  expense: number;
}

export default function MinimarketPage() {
  const [tab, setTab] = useState<"record" | "report">("record");
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  // Record form
  const [date, setDate] = useState(new Date().toISOString().split("T")[0]);
  const [shift, setShift] = useState<"pagi" | "sore">("pagi");
  const [cashierName, setCashierName] = useState("");
  const [salesAmount, setSalesAmount] = useState("");
  const [expenses, setExpenses] = useState<{ desc: string; amount: string; cat: string }[]>([]);
  const [newExpDesc, setNewExpDesc] = useState("");
  const [newExpAmount, setNewExpAmount] = useState("");

  // Report data
  const [reportData, setReportData] = useState<ShiftData[]>([]);
  const [reportLoading, setReportLoading] = useState(false);
  const [reportMonth, setReportMonth] = useState(new Date().getMonth() + 1);
  const [reportYear, setReportYear] = useState(new Date().getFullYear());

  // Saved cashiers for autocomplete
  const [cashiers, setCashiers] = useState<string[]>([]);

  // Categories for minimarket
  const [categories, setCategories] = useState<{ id: string; name: string }[]>([]);
  const [businessId, setBusinessId] = useState("");

  useEffect(() => {
    fetch("/api/businesses")
      .then((r) => r.ok ? r.json() : { businesses: [] })
      .then((d) => {
        const minimarket = d.businesses.find(
          (b: { businessType: string; name: string }) =>
            b.businessType === "minimarket" || b.name.toLowerCase().includes("minimarket")
        );
        if (minimarket) {
          setBusinessId(minimarket.id);
          fetch(`/api/categories?businessId=${minimarket.id}`)
            .then((r) => r.ok ? r.json() : { categories: [] })
            .then((cat) => setCategories(cat.categories.filter((c: { categoryType: string }) => c.categoryType === "expense")));
        }
      })
      .catch(() => {});
  }, []);

  useEffect(() => {
    if (tab === "report") fetchReport();
  }, [tab, reportMonth, reportYear]);

  async function fetchReport() {
    setReportLoading(true);
    try {
      const res = await fetch(`/api/minimarket?month=${reportMonth}&year=${reportYear}`);
      if (res.ok) {
        const data = await res.json();
        setReportData(data.shifts);
        setCashiers(data.cashiers);
      }
    } finally {
      setReportLoading(false);
    }
  }

  function addExpense() {
    if (!newExpDesc || !newExpAmount) return;
    setExpenses([...expenses, { desc: newExpDesc, amount: newExpAmount, cat: "" }]);
    setNewExpDesc("");
    setNewExpAmount("");
  }

  function removeExpense(i: number) {
    setExpenses(expenses.filter((_, idx) => idx !== i));
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!businessId || !salesAmount || !cashierName.trim()) {
      setError("Omset, nama kasir, dan bisnis wajib diisi");
      return;
    }
    setSaving(true);
    setError("");

    try {
      // Record sales income
      const salesCat = categories.find((c) => c.name.toLowerCase().includes("penjualan"));
      const res1 = await fetch("/api/transactions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          businessId,
          categoryId: salesCat?.id || null,
          transactionType: "income",
          amount: parseFloat(salesAmount),
          transactionDate: date,
          description: `Omset shift ${shift}`,
          notes: `Kasir: ${cashierName.trim()}`,
          shift,
          cashierName: cashierName.trim(),
        }),
      });
      if (!res1.ok) throw new Error("Gagal simpan omset");

      // Record expenses
      for (const exp of expenses) {
        await fetch("/api/transactions", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            businessId,
            transactionType: "expense",
            amount: parseFloat(exp.amount),
            transactionDate: date,
            description: exp.desc,
            notes: `Kasir: ${cashierName.trim()} · Shift ${shift}`,
            shift,
            cashierName: cashierName.trim(),
          }),
        });
      }

      // Reset form
      setSalesAmount("");
      setExpenses([]);
      setCashierName("");
      setError("");

      // Switch to report tab
      setTab("report");
      fetchReport();
    } catch {
      setError("Gagal menyimpan transaksi");
    } finally {
      setSaving(false);
    }
  }

  // Filter expenses by shift date range
  const totalExpense = expenses.reduce((s, e) => s + (parseFloat(e.amount) || 0), 0);
  const totalSales = parseFloat(salesAmount) || 0;

  return (
    <div className="space-y-6 max-w-5xl">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Minimarket</h1>
          <p className="text-gray-500 text-sm mt-1">Catatan sift & omset harian</p>
        </div>
        <div className="flex bg-white border border-gray-200 rounded-lg p-1">
          <button
            onClick={() => setTab("record")}
            className={`px-4 py-1.5 text-sm rounded-md font-medium transition-colors ${
              tab === "record" ? "bg-emerald-600 text-white" : "text-gray-600 hover:bg-gray-50"
            }`}
          >
            Catat Sift
          </button>
          <button
            onClick={() => setTab("report")}
            className={`px-4 py-1.5 text-sm rounded-md font-medium transition-colors ${
              tab === "report" ? "bg-emerald-600 text-white" : "text-gray-600 hover:bg-gray-50"
            }`}
          >
            Laporan Sift
          </button>
        </div>
      </div>

      {tab === "record" ? (
        <form onSubmit={handleSubmit} className="bg-white rounded-xl border border-gray-200 p-6 space-y-5">
          {error && (
            <div className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-lg text-sm">{error}</div>
          )}

          {/* Shift & Kasir */}
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Tanggal</label>
              <input
                type="date"
                value={date}
                onChange={(e) => setDate(e.target.value)}
                className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                required
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Sift</label>
              <div className="flex gap-2">
                <button
                  type="button"
                  onClick={() => setShift("pagi")}
                  className={`flex-1 flex items-center justify-center gap-1.5 py-2 px-3 rounded-lg text-sm font-medium transition-colors ${
                    shift === "pagi"
                      ? "bg-amber-100 text-amber-700 border border-amber-300"
                      : "bg-gray-50 text-gray-500 border border-gray-200 hover:bg-gray-100"
                  }`}
                >
                  <Sun className="w-4 h-4" /> Pagi
                </button>
                <button
                  type="button"
                  onClick={() => setShift("sore")}
                  className={`flex-1 flex items-center justify-center gap-1.5 py-2 px-3 rounded-lg text-sm font-medium transition-colors ${
                    shift === "sore"
                      ? "bg-indigo-100 text-indigo-700 border border-indigo-300"
                      : "bg-gray-50 text-gray-500 border border-gray-200 hover:bg-gray-100"
                  }`}
                >
                  <Moon className="w-4 h-4" /> Sore
                </button>
              </div>
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Nama Kasir</label>
              <input
                type="text"
                value={cashierName}
                onChange={(e) => setCashierName(e.target.value)}
                placeholder="Nama kasir"
                className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                list="cashier-list"
                required
              />
              <datalist id="cashier-list">
                {cashiers.map((c) => (
                  <option key={c} value={c} />
                ))}
              </datalist>
            </div>
          </div>

          {/* Omset */}
          <div className="bg-emerald-50 rounded-xl p-4 border border-emerald-200">
            <div className="flex items-center gap-2 mb-3">
              <TrendingUp className="w-5 h-5 text-emerald-600" />
              <span className="font-semibold text-emerald-700">Omset Penjualan</span>
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Total Omset (Rp)</label>
              <input
                type="number"
                value={salesAmount}
                onChange={(e) => setSalesAmount(e.target.value)}
                className="w-full px-3 py-3 border border-emerald-300 rounded-lg text-lg font-semibold text-emerald-700 focus:outline-none focus:ring-2 focus:ring-emerald-500"
                placeholder="0"
                min="0"
                required
              />
            </div>
          </div>

          {/* Pengeluaran */}
          <div className="bg-red-50 rounded-xl p-4 border border-red-200">
            <div className="flex items-center gap-2 mb-3">
              <TrendingDown className="w-5 h-5 text-red-600" />
              <span className="font-semibold text-red-700">Pengeluaran Sift</span>
              <span className="text-xs text-red-500 ml-auto">
                Total: {formatCurrency(totalExpense)}
              </span>
            </div>

            {expenses.length > 0 && (
              <div className="space-y-2 mb-3">
                {expenses.map((exp, i) => (
                  <div key={i} className="flex items-center gap-2 bg-white rounded-lg px-3 py-2 text-sm">
                    <span className="flex-1 text-gray-700">{exp.desc}</span>
                    <span className="font-medium text-red-600">{formatCurrency(parseFloat(exp.amount) || 0)}</span>
                    <button type="button" onClick={() => removeExpense(i)} className="text-gray-400 hover:text-red-500 text-xs">✕</button>
                  </div>
                ))}
              </div>
            )}

            <div className="flex gap-2">
              <input
                type="text"
                value={newExpDesc}
                onChange={(e) => setNewExpDesc(e.target.value)}
                placeholder="Deskripsi pengeluaran"
                className="flex-1 px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-red-400"
                onKeyDown={(e) => e.key === "Enter" && (e.preventDefault(), addExpense())}
              />
              <input
                type="number"
                value={newExpAmount}
                onChange={(e) => setNewExpAmount(e.target.value)}
                placeholder="Rp"
                className="w-32 px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-red-400"
                onKeyDown={(e) => e.key === "Enter" && (e.preventDefault(), addExpense())}
              />
              <button
                type="button"
                onClick={addExpense}
                className="px-3 py-2 bg-red-500 text-white rounded-lg text-sm font-medium hover:bg-red-600 transition-colors"
              >
                <Plus className="w-4 h-4" />
              </button>
            </div>
          </div>

          {/* Summary */}
          <div className="flex items-center justify-between bg-gray-50 rounded-lg px-4 py-3">
            <div className="flex gap-4 text-sm">
              <span className="text-emerald-600 font-medium">+{formatCurrency(totalSales)}</span>
              <span className="text-red-600 font-medium">-{formatCurrency(totalExpense)}</span>
            </div>
            <div className="text-sm">
              <span className="font-bold text-gray-900">
                Bersih: {formatCurrency(totalSales - totalExpense)}
              </span>
            </div>
          </div>

          <button
            type="submit"
            disabled={saving}
            className="w-full flex items-center justify-center gap-2 bg-emerald-600 text-white py-3 rounded-lg font-medium hover:bg-emerald-700 disabled:opacity-50 transition-colors text-lg"
          >
            <Save className="w-5 h-5" />
            {saving ? "Menyimpan..." : `Simpan Sift ${shift === "pagi" ? "Pagi" : "Sore"}`}
          </button>
        </form>
      ) : (
        /* Report Tab */
        <div className="space-y-6">
          {/* Month filter */}
          <div className="flex items-center gap-2 bg-white rounded-xl border border-gray-200 p-3">
            <select
              value={reportMonth}
              onChange={(e) => setReportMonth(parseInt(e.target.value))}
              className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
            >
              {["Jan","Feb","Mar","Apr","Mei","Jun","Jul","Agu","Sep","Okt","Nov","Des"].map((m, i) => (
                <option key={i + 1} value={i + 1}>{m}</option>
              ))}
            </select>
            <select
              value={reportYear}
              onChange={(e) => setReportYear(parseInt(e.target.value))}
              className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
            >
              {Array.from({ length: 5 }, (_, i) => new Date().getFullYear() - 2 + i).map((y) => (
                <option key={y} value={y}>{y}</option>
              ))}
            </select>
          </div>

          {reportLoading ? (
            <div className="flex justify-center py-12"><Loader2 className="w-8 h-8 animate-spin text-emerald-600" /></div>
          ) : (
            <>
              {/* Shift Summary */}
              {["pagi", "sore"].map((s) => {
                const shiftData = reportData.filter((d) => d.shift === s);
                const totalIncome = shiftData.reduce((sum, d) => sum + d.income, 0);
                const totalExpense = shiftData.reduce((sum, d) => sum + d.expense, 0);
                return (
                  <div key={s} className={`rounded-xl border p-5 ${s === "pagi" ? "bg-amber-50 border-amber-200" : "bg-indigo-50 border-indigo-200"}`}>
                    <div className="flex items-center gap-2 mb-3">
                      {s === "pagi" ? <Sun className="w-5 h-5 text-amber-600" /> : <Moon className="w-5 h-5 text-indigo-600" />}
                      <span className={`font-semibold ${s === "pagi" ? "text-amber-700" : "text-indigo-700"}`}>
                        Sift {s === "pagi" ? "Pagi" : "Sore"}
                      </span>
                      <span className="text-xs text-gray-500 ml-auto">{shiftData.length} hari</span>
                    </div>
                    <div className="grid grid-cols-3 gap-4 mb-4">
                      <div>
                        <p className="text-xs text-gray-500">Omset</p>
                        <p className="text-lg font-bold text-emerald-600">{formatCurrency(totalIncome)}</p>
                      </div>
                      <div>
                        <p className="text-xs text-gray-500">Pengeluaran</p>
                        <p className="text-lg font-bold text-red-600">{formatCurrency(totalExpense)}</p>
                      </div>
                      <div>
                        <p className="text-xs text-gray-500">Bersih</p>
                        <p className={`text-lg font-bold ${totalIncome - totalExpense >= 0 ? "text-emerald-600" : "text-red-600"}`}>
                          {formatCurrency(totalIncome - totalExpense)}
                        </p>
                      </div>
                    </div>
                    {/* Per Cashier */}
                    <div className="space-y-1">
                      <p className="text-xs text-gray-500 mb-2">Per Kasir</p>
                      {Object.entries(
                        shiftData.reduce((acc: Record<string, { income: number; expense: number; days: number }>, d) => {
                          const name = d.cashierName || "-";
                          if (!acc[name]) acc[name] = { income: 0, expense: 0, days: 0 };
                          acc[name].income += d.income;
                          acc[name].expense += d.expense;
                          acc[name].days += 1;
                          return acc;
                        }, {})
                      ).map(([name, val]) => (
                        <div key={name} className="flex items-center justify-between text-sm py-1 px-2 rounded hover:bg-white/50">
                          <span className="flex items-center gap-1.5">
                            <Users className="w-3.5 h-3.5 text-gray-400" />
                            {name}
                            <span className="text-xs text-gray-400">({val.days}x)</span>
                          </span>
                          <span className={`font-medium ${val.income - val.expense >= 0 ? "text-emerald-600" : "text-red-600"}`}>
                            {formatCurrency(val.income - val.expense)}
                          </span>
                        </div>
                      ))}
                    </div>
                  </div>
                );
              })}

              {/* Daily Chart */}
              <div className="bg-white rounded-xl border border-gray-200 p-5">
                <h2 className="text-lg font-semibold text-gray-900 mb-4">Omset Harian per Sift</h2>
                <ResponsiveContainer width="100%" height={300}>
                  <BarChart data={
                    Array.from(new Set(reportData.map(d => d.date))).map(date => {
                      const pagi = reportData.find(d => d.date === date && d.shift === "pagi");
                      const sore = reportData.find(d => d.date === date && d.shift === "sore");
                      return {
                        date: new Date(date).toLocaleDateString("id-ID", { day: "numeric", month: "short" }),
                        Pagi: pagi?.income || 0,
                        Sore: sore?.income || 0,
                      };
                    })
                  }>
                    <CartesianGrid strokeDasharray="3 3" stroke="#f0f0f0" />
                    <XAxis dataKey="date" fontSize={12} />
                    <YAxis fontSize={12} tickFormatter={(v) => `${(v / 1000).toFixed(0)}K`} />
                    <Tooltip formatter={(v) => formatCurrency(Number(v))} />
                    <Legend />
                    <Bar dataKey="Pagi" fill="#f59e0b" radius={[4, 4, 0, 0]} />
                    <Bar dataKey="Sore" fill="#6366f1" radius={[4, 4, 0, 0]} />
                  </BarChart>
                </ResponsiveContainer>
              </div>
            </>
          )}
        </div>
      )}
    </div>
  );
}
