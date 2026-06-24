"use client";

import { useState, useEffect } from "react";
import Link from "next/link";
import { Plus, Building2, Pencil, Archive, Loader2, Save, X } from "lucide-react";

interface Business {
  id: string;
  name: string;
  slug: string;
  businessType: string;
  description: string | null;
  _count: { transactions: number };
}

const typeLabels: Record<string, string> = {
  minimarket: "Minimarket",
  farm: "Pertanian",
  personal: "Pribadi",
  fnb: "F&B",
  trading: "Trading",
  services: "Jasa",
  general: "Umum",
  other: "Lainnya",
};

const businessTypes = [
  { value: "minimarket", label: "Minimarket / Retail" },
  { value: "farm", label: "Pertanian / Perkebunan" },
  { value: "fnb", label: "F&B / Kuliner" },
  { value: "trading", label: "Trading" },
  { value: "services", label: "Jasa" },
  { value: "personal", label: "Pribadi / Keluarga" },
  { value: "other", label: "Lainnya" },
];

export default function BusinessesPage() {
  const [businesses, setBusinesses] = useState<Business[]>([]);
  const [loading, setLoading] = useState(true);
  const [editing, setEditing] = useState<Business | null>(null);
  const [editName, setEditName] = useState("");
  const [editType, setEditType] = useState("");
  const [editDesc, setEditDesc] = useState("");
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    fetch("/api/businesses")
      .then((res) => res.json())
      .then((data) => setBusinesses(data.businesses))
      .finally(() => setLoading(false));
  }, []);

  function openEdit(b: Business) {
    setEditing(b);
    setEditName(b.name);
    setEditType(b.businessType);
    setEditDesc(b.description || "");
  }

  async function handleSaveEdit() {
    if (!editing || !editName.trim()) return;
    setSaving(true);
    const res = await fetch("/api/businesses", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        id: editing.id,
        name: editName.trim(),
        businessType: editType,
        description: editDesc.trim() || null,
      }),
    });
    if (res.ok) {
      const data = await res.json();
      setBusinesses(businesses.map((b) => (b.id === editing.id ? { ...b, ...data.business } : b)));
    }
    setEditing(null);
    setSaving(false);
  }

  async function handleArchive(id: string) {
    if (!confirm("Arsipkan bisnis ini?")) return;
    await fetch("/api/businesses", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id, isArchived: true }),
    });
    setBusinesses(businesses.filter((b) => b.id !== id));
  }

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
          <h1 className="text-2xl font-bold text-gray-900">Bisnis</h1>
          <p className="text-gray-500 text-sm mt-1">Kelola semua unit bisnis kamu</p>
        </div>
        <Link
          href="/businesses/new"
          className="flex items-center gap-2 px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700 transition-colors"
        >
          <Plus className="w-4 h-4" />
          Bisnis Baru
        </Link>
      </div>

      {businesses.length === 0 ? (
        <div className="bg-white rounded-xl border border-gray-200 p-12 text-center">
          <Building2 className="w-12 h-12 text-gray-300 mx-auto mb-4" />
          <h3 className="text-lg font-semibold text-gray-900 mb-2">Belum ada bisnis</h3>
          <p className="text-gray-500 mb-4">Buat bisnis pertamamu untuk mulai mencatat keuangan</p>
          <Link
            href="/businesses/new"
            className="inline-flex items-center gap-2 px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700"
          >
            <Plus className="w-4 h-4" />
            Bisnis Baru
          </Link>
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {businesses.map((b) => (
            <div
              key={b.id}
              className="bg-white rounded-xl border border-gray-200 p-5 hover:border-emerald-200 transition-colors group"
            >
              <div className="flex items-start justify-between">
                <Link href={`/transactions?business=${b.slug}`} className="flex-1 min-w-0">
                  <div className="flex items-center gap-3 mb-2">
                    <div className="w-10 h-10 rounded-lg bg-emerald-100 flex items-center justify-center">
                      <Building2 className="w-5 h-5 text-emerald-600" />
                    </div>
                    <div className="min-w-0">
                      <h3 className="font-semibold text-gray-900 truncate">{b.name}</h3>
                      <span className="text-xs px-2 py-0.5 bg-gray-100 rounded-full text-gray-600">
                        {typeLabels[b.businessType] || b.businessType}
                      </span>
                    </div>
                  </div>
                  {b.description && (
                    <p className="text-sm text-gray-500 line-clamp-1 ml-13">{b.description}</p>
                  )}
                </Link>
                <div className="flex gap-1 opacity-0 group-hover:opacity-100 transition-all">
                  <button
                    onClick={() => openEdit(b)}
                    className="p-1.5 rounded-lg text-gray-400 hover:text-emerald-600 hover:bg-emerald-50"
                  >
                    <Pencil className="w-4 h-4" />
                  </button>
                  <button
                    onClick={() => handleArchive(b.id)}
                    className="p-1.5 rounded-lg text-gray-400 hover:text-red-500 hover:bg-red-50"
                  >
                    <Archive className="w-4 h-4" />
                  </button>
                </div>
              </div>
              <div className="flex items-center gap-4 mt-3 pt-3 border-t border-gray-100 text-sm text-gray-500">
                <Link href={`/transactions?business=${b.slug}`} className="hover:text-emerald-600">
                  {b._count.transactions} transaksi
                </Link>
                <Link href={`/transactions/new?business=${b.slug}`} className="text-emerald-600 hover:underline">
                  + Catat Baru
                </Link>
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Edit Modal */}
      {editing && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50" onClick={() => setEditing(null)}>
          <div
            className="bg-white rounded-xl shadow-xl w-full max-w-md mx-4 p-6"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-lg font-semibold text-gray-900">Edit Bisnis</h2>
              <button onClick={() => setEditing(null)} className="p-1 text-gray-400 hover:text-gray-600">
                <X className="w-5 h-5" />
              </button>
            </div>
            <div className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">Nama Bisnis</label>
                <input
                  type="text"
                  value={editName}
                  onChange={(e) => setEditName(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:border-transparent"
                  onKeyDown={(e) => e.key === "Enter" && handleSaveEdit()}
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">Jenis Bisnis</label>
                <select
                  value={editType}
                  onChange={(e) => setEditType(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:border-transparent"
                >
                  {businessTypes.map((t) => (
                    <option key={t.value} value={t.value}>{t.label}</option>
                  ))}
                </select>
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">Deskripsi</label>
                <textarea
                  value={editDesc}
                  onChange={(e) => setEditDesc(e.target.value)}
                  rows={2}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:border-transparent resize-none"
                />
              </div>
              <button
                onClick={handleSaveEdit}
                disabled={saving}
                className="w-full flex items-center justify-center gap-2 bg-emerald-600 text-white py-2.5 rounded-lg font-medium hover:bg-emerald-700 disabled:opacity-50 transition-colors"
              >
                <Save className="w-4 h-4" />
                {saving ? "Menyimpan..." : "Simpan Perubahan"}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
