"use client";

import { useState, useEffect } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import Link from "next/link";
import { ArrowLeft, Save } from "lucide-react";

interface Business {
  id: string;
  name: string;
  slug: string;
  businessType: string;
}

interface Category {
  id: string;
  name: string;
  categoryType: string;
}

export function NewTransactionForm() {
  const router = useRouter();
  const searchParams = useSearchParams();

  const [businesses, setBusinesses] = useState<Business[]>([]);
  const [categories, setCategories] = useState<Category[]>([]);
  const [businessId, setBusinessId] = useState("");
  const [transactionType, setTransactionType] = useState("expense");
  const [categoryId, setCategoryId] = useState("");
  const [amount, setAmount] = useState("");
  const [description, setDescription] = useState("");
  const [notes, setNotes] = useState("");
  const [transactionDate, setTransactionDate] = useState(
    new Date().toISOString().split("T")[0]
  );
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    fetch("/api/businesses")
      .then((res) => res.json())
      .then((data) => {
        setBusinesses(data.businesses);
        const slug = searchParams.get("business");
        if (slug) {
          const b = data.businesses.find((b: Business) => b.slug === slug);
          if (b) {
            setBusinessId(b.id);
            if (b.businessType === "personal") setTransactionType("expense");
          }
        }
      });
  }, [searchParams]);

  useEffect(() => {
    if (businessId) {
      fetch(`/api/categories?businessId=${businessId}`)
        .then((res) => res.json())
        .then((data) => {
          setCategories(data.categories);
          const filtered = data.categories
            .filter((c: Category) => c.categoryType === transactionType)
            .shift();
          setCategoryId(filtered?.id || "");
        });
    }
  }, [businessId, transactionType]);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!businessId || !amount || !description) return;
    setLoading(true);
    setError("");

    try {
      const res = await fetch("/api/transactions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          businessId,
          categoryId: categoryId || null,
          transactionType,
          amount: parseFloat(amount),
          transactionDate,
          description,
          notes: notes.trim() || null,
        }),
      });

      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Gagal menyimpan");
        return;
      }

      router.push("/transactions");
      router.refresh();
    } catch {
      setError("Terjadi kesalahan");
    } finally {
      setLoading(false);
    }
  }

  const filteredCategories = categories.filter(
    (c) => c.categoryType === transactionType
  );

  return (
    <div className="max-w-lg space-y-6">
      <div className="flex items-center gap-3">
        <Link href="/transactions" className="text-gray-500 hover:text-gray-700">
          <ArrowLeft className="w-5 h-5" />
        </Link>
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Transaksi Baru</h1>
          <p className="text-gray-500 text-sm mt-1">Catat pemasukan atau pengeluaran</p>
        </div>
      </div>

      <form onSubmit={handleSubmit} className="bg-white rounded-xl border border-gray-200 p-6 space-y-4">
        {error && (
          <div className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-lg text-sm">
            {error}
          </div>
        )}

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Bisnis *</label>
          <select
            value={businessId}
            onChange={(e) => setBusinessId(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:border-transparent"
            required
          >
            <option value="">Pilih Bisnis</option>
            {businesses.map((b) => (
              <option key={b.id} value={b.id}>
                {b.name}
              </option>
            ))}
          </select>
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Jenis *</label>
          <div className="flex gap-2">
            <button
              type="button"
              onClick={() => setTransactionType("income")}
              className={`flex-1 py-2 px-4 rounded-lg text-sm font-medium transition-colors ${
                transactionType === "income"
                  ? "bg-emerald-600 text-white"
                  : "bg-gray-100 text-gray-600 hover:bg-gray-200"
              }`}
            >
              Pemasukan
            </button>
            <button
              type="button"
              onClick={() => setTransactionType("expense")}
              className={`flex-1 py-2 px-4 rounded-lg text-sm font-medium transition-colors ${
                transactionType === "expense"
                  ? "bg-red-600 text-white"
                  : "bg-gray-100 text-gray-600 hover:bg-gray-200"
              }`}
            >
              Pengeluaran
            </button>
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Kategori</label>
          <select
            value={categoryId}
            onChange={(e) => setCategoryId(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:border-transparent"
          >
            <option value="">Tanpa Kategori</option>
            {filteredCategories.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Jumlah (Rp) *</label>
          <input
            type="number"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:border-transparent"
            placeholder="0"
            min="0"
            required
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Tanggal *</label>
          <input
            type="date"
            value={transactionDate}
            onChange={(e) => setTransactionDate(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:border-transparent"
            required
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Deskripsi</label>
          <input
            type="text"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:border-transparent"
            placeholder="Contoh: Penjualan harian, Beli pupuk, dll"
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Catatan</label>
          <textarea
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            rows={2}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:border-transparent resize-none"
            placeholder="Catatan tambahan (opsional)"
          />
        </div>

        <button
          type="submit"
          disabled={loading}
          className="w-full flex items-center justify-center gap-2 bg-emerald-600 text-white py-2.5 rounded-lg font-medium hover:bg-emerald-700 disabled:opacity-50 transition-colors"
        >
          <Save className="w-4 h-4" />
          {loading ? "Menyimpan..." : "Simpan Transaksi"}
        </button>
      </form>
    </div>
  );
}
