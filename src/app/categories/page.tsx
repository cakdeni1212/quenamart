"use client";

import { useState, useEffect } from "react";
import { Plus, Tags, Trash2, Loader2 } from "lucide-react";

interface Category {
  id: string;
  name: string;
  categoryType: string;
  code: string | null;
  isSystem: boolean;
  business: { id: string; name: string; slug: string };
  _count: { transactions: number };
}

interface Business {
  id: string;
  name: string;
}

export default function CategoriesPage() {
  const [categories, setCategories] = useState<Category[]>([]);
  const [businesses, setBusinesses] = useState<Business[]>([]);
  const [loading, setLoading] = useState(true);
  const [showAdd, setShowAdd] = useState(false);
  const [newName, setNewName] = useState("");
  const [newType, setNewType] = useState("expense");
  const [newBusinessId, setNewBusinessId] = useState("");
  const [saving, setSaving] = useState(false);

  async function fetchCategories() {
    const res = await fetch("/api/categories");
    const data = await res.json();
    setCategories(data.categories);
  }

  useEffect(() => {
    Promise.all([
      fetch("/api/businesses").then((r) => r.json()),
      fetch("/api/categories").then((r) => r.json()),
    ]).then(([bData, cData]) => {
      setBusinesses(bData.businesses);
      setCategories(cData.categories);
      setNewBusinessId(bData.businesses[0]?.id || "");
    }).finally(() => setLoading(false));
  }, []);

  async function handleAdd() {
    if (!newName.trim() || !newBusinessId) return;
    setSaving(true);
    await fetch("/api/categories", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ businessId: newBusinessId, name: newName, categoryType: newType }),
    });
    setNewName("");
    setShowAdd(false);
    await fetchCategories();
    setSaving(false);
  }

  async function handleDelete(id: string) {
    if (!confirm("Hapus kategori ini?")) return;
    await fetch(`/api/categories?id=${id}`, { method: "DELETE" });
    fetchCategories();
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 className="w-8 h-8 animate-spin text-emerald-600" />
      </div>
    );
  }

  return (
    <div className="space-y-6 max-w-5xl">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Kategori</h1>
          <p className="text-gray-500 text-sm mt-1">Atur kategori pemasukan dan pengeluaran</p>
        </div>
        <button
          onClick={() => setShowAdd(!showAdd)}
          className="flex items-center gap-2 px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700 transition-colors"
        >
          <Plus className="w-4 h-4" />
          Tambah Kategori
        </button>
      </div>

      {showAdd && (
        <div className="bg-white rounded-xl border border-gray-200 p-4 flex flex-col sm:flex-row gap-3">
          <select
            value={newBusinessId}
            onChange={(e) => setNewBusinessId(e.target.value)}
            className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
          >
            {businesses.map((b) => (
              <option key={b.id} value={b.id}>{b.name}</option>
            ))}
          </select>
          <select
            value={newType}
            onChange={(e) => setNewType(e.target.value)}
            className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
          >
            <option value="income">Pemasukan</option>
            <option value="expense">Pengeluaran</option>
          </select>
          <input
            type="text"
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
            placeholder="Nama kategori"
            className="flex-1 px-3 py-2 border border-gray-300 rounded-lg text-sm"
            onKeyDown={(e) => e.key === "Enter" && handleAdd()}
          />
          <button
            onClick={handleAdd}
            disabled={saving}
            className="px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700 disabled:opacity-50"
          >
            Simpan
          </button>
        </div>
      )}

      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        {["income", "expense"].map((type) => {
          const filtered = categories.filter((c) => c.categoryType === type);
          return (
            <div key={type} className="bg-white rounded-xl border border-gray-200 overflow-hidden">
              <div className={`px-4 py-3 font-semibold text-sm ${type === "income" ? "bg-emerald-50 text-emerald-700" : "bg-red-50 text-red-700"}`}>
                {type === "income" ? "PEMASUKAN" : "PENGELUARAN"}
              </div>
              <div className="divide-y divide-gray-100">
                {filtered.length === 0 && (
                  <p className="text-sm text-gray-400 text-center py-4">Belum ada kategori</p>
                )}
                {filtered.map((cat) => (
                  <div key={cat.id} className="flex items-center justify-between px-4 py-3">
                    <div className="flex items-center gap-3">
                      <Tags className="w-4 h-4 text-gray-400" />
                      <div>
                        <p className="text-sm font-medium text-gray-900">{cat.name}</p>
                        <p className="text-xs text-gray-500">
                          {cat.business.name} · {cat._count.transactions} transaksi
                        </p>
                      </div>
                    </div>
                    {!cat.isSystem && (
                      <button
                        onClick={() => handleDelete(cat.id)}
                        className="p-1 text-gray-400 hover:text-red-500 rounded"
                      >
                        <Trash2 className="w-4 h-4" />
                      </button>
                    )}
                  </div>
                ))}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
