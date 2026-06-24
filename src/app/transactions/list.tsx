"use client";

import { useState, useEffect, useCallback } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { formatCurrency } from "@/lib/utils";
import {
  Plus,
  Search,
  Trash2,
  ArrowLeftRight,
  Loader2,
  ChevronLeft,
  ChevronRight,
} from "lucide-react";

interface Transaction {
  id: string;
  transactionType: string;
  description: string;
  amount: number;
  transactionDate: string;
  notes: string | null;
  business: { id: string; name: string; slug: string };
  category: { id: string; name: string } | null;
}

export function TransactionsList() {
  const searchParams = useSearchParams();
  const [transactions, setTransactions] = useState<Transaction[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [typeFilter, setTypeFilter] = useState(searchParams.get("type") || "all");
  const [businessFilter, setBusinessFilter] = useState(searchParams.get("business") || "");
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [businesses, setBusinesses] = useState<{ id: string; slug: string; name: string }[]>([]);

  const fetchTransactions = useCallback(async () => {
    setLoading(true);
    const params = new URLSearchParams();
    if (typeFilter !== "all") params.set("type", typeFilter);
    if (businessFilter) params.set("business", businessFilter);
    if (search) params.set("search", search);
    params.set("page", String(page));
    params.set("limit", "20");

    try {
      const res = await fetch(`/api/transactions?${params}`);
      const data = await res.json();
      setTransactions(data.transactions);
      setTotalPages(data.pagination.totalPages);
    } catch (e) {
      console.error(e);
    } finally {
      setLoading(false);
    }
  }, [typeFilter, businessFilter, search, page]);

  useEffect(() => {
    fetch("/api/businesses")
      .then((res) => res.ok ? res.json() : { businesses: [] })
      .then((data) => setBusinesses(data.businesses))
      .catch(() => {});
  }, []);

  useEffect(() => {
    fetchTransactions();
  }, [fetchTransactions]);

  async function handleDelete(id: string) {
    if (!confirm("Hapus transaksi ini?")) return;
    await fetch(`/api/transactions?id=${id}`, { method: "DELETE" });
    fetchTransactions();
  }

  return (
    <div className="space-y-6 max-w-5xl">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Transaksi</h1>
          <p className="text-gray-500 text-sm mt-1">Catat pemasukan dan pengeluaran</p>
        </div>
        <Link
          href={`/transactions/new${businessFilter ? `?business=${businessFilter}` : ""}`}
          className="flex items-center gap-2 px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700 transition-colors"
        >
          <Plus className="w-4 h-4" />
          Transaksi Baru
        </Link>
      </div>

      <div className="flex flex-col sm:flex-row gap-3">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
          <input
            type="text"
            value={search}
            onChange={(e) => { setSearch(e.target.value); setPage(1); }}
            placeholder="Cari transaksi..."
            className="w-full pl-10 pr-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:border-transparent text-sm"
          />
        </div>
        <select
          value={typeFilter}
          onChange={(e) => { setTypeFilter(e.target.value); setPage(1); }}
          className="px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
        >
          <option value="all">Semua Jenis</option>
          <option value="income">Pemasukan</option>
          <option value="expense">Pengeluaran</option>
        </select>
        <select
          value={businessFilter}
          onChange={(e) => { setBusinessFilter(e.target.value); setPage(1); }}
          className="px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
        >
          <option value="">Semua Bisnis</option>
          {businesses.map((b) => (
            <option key={b.id} value={b.slug}>
              {b.name}
            </option>
          ))}
        </select>
      </div>

      {loading ? (
        <div className="flex items-center justify-center h-64">
          <Loader2 className="w-8 h-8 animate-spin text-emerald-600" />
        </div>
      ) : transactions.length === 0 ? (
        <div className="bg-white rounded-xl border border-gray-200 p-12 text-center">
          <ArrowLeftRight className="w-12 h-12 text-gray-300 mx-auto mb-4" />
          <h3 className="text-lg font-semibold text-gray-900 mb-2">Belum ada transaksi</h3>
          <p className="text-gray-500 mb-4">Mulai catat pemasukan atau pengeluaran pertamamu</p>
          <Link
            href="/transactions/new"
            className="inline-flex items-center gap-2 px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700"
          >
            <Plus className="w-4 h-4" />
            Transaksi Baru
          </Link>
        </div>
      ) : (
        <>
          <div className="bg-white rounded-xl border border-gray-200 overflow-hidden">
            <div className="divide-y divide-gray-100">
              {transactions.map((t) => (
                <div
                  key={t.id}
                  className="flex items-center justify-between p-4 hover:bg-gray-50 transition-colors group"
                >
                  <div className="flex items-center gap-3 min-w-0">
                    <div
                      className={`w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0 ${
                        t.transactionType === "income" ? "bg-emerald-100" : "bg-red-100"
                      }`}
                    >
                      <ArrowLeftRight
                        className={`w-4 h-4 ${
                          t.transactionType === "income" ? "text-emerald-600" : "text-red-600"
                        }`}
                      />
                    </div>
                    <div className="min-w-0">
                      <p className="text-sm font-medium text-gray-900 truncate">
                        {t.category?.name || t.description || "Tanpa Kategori"}
                      </p>
                      <div className="flex flex-wrap gap-1 text-xs text-gray-500 mt-0.5">
                        <span className="px-1.5 py-0.5 bg-gray-100 rounded">{t.business.name}</span>
                        {t.description && (
                          <span className="text-gray-400 truncate">{t.description}</span>
                        )}
                        <span>{new Date(t.transactionDate).toLocaleDateString("id-ID")}</span>
                      </div>
                    </div>
                  </div>
                  <div className="flex items-center gap-4">
                    <p
                      className={`text-sm font-semibold ${
                        t.transactionType === "income" ? "text-emerald-600" : "text-red-600"
                      }`}
                    >
                      {t.transactionType === "income" ? "+" : "-"}
                      {formatCurrency(t.amount)}
                    </p>
                    <button
                      onClick={() => handleDelete(t.id)}
                      className="p-1.5 text-gray-400 hover:text-red-500 rounded-lg hover:bg-red-50 transition-colors opacity-0 group-hover:opacity-100"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  </div>
                </div>
              ))}
            </div>
          </div>

          {totalPages > 1 && (
            <div className="flex items-center justify-center gap-2">
              <button
                onClick={() => setPage(Math.max(1, page - 1))}
                disabled={page === 1}
                className="p-2 rounded-lg border border-gray-200 hover:bg-gray-50 disabled:opacity-50"
              >
                <ChevronLeft className="w-4 h-4" />
              </button>
              <span className="text-sm text-gray-600">
                {page} / {totalPages}
              </span>
              <button
                onClick={() => setPage(Math.min(totalPages, page + 1))}
                disabled={page === totalPages}
                className="p-2 rounded-lg border border-gray-200 hover:bg-gray-50 disabled:opacity-50"
              >
                <ChevronRight className="w-4 h-4" />
              </button>
            </div>
          )}
        </>
      )}
    </div>
  );
}
