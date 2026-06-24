"use client";

import { useState, useEffect } from "react";
import { formatCurrency } from "@/lib/utils";
import {
  Plus,
  Boxes,
  Trash2,
  Pencil,
  Loader2,
  Save,
  X,
  Building2,
} from "lucide-react";

interface Asset {
  id: string;
  name: string;
  assetType: string;
  value: number;
  purchasePrice: number;
  purchaseDate: string | null;
  notes: string | null;
  business: { id: string; name: string; slug: string };
}

interface Business {
  id: string;
  name: string;
  slug: string;
}

const assetTypeLabels: Record<string, string> = {
  land: "Tanah / Lahan",
  building: "Bangunan",
  vehicle: "Kendaraan",
  equipment: "Peralatan",
  other: "Lainnya",
};

const assetTypes = [
  { value: "land", label: "Tanah / Lahan" },
  { value: "building", label: "Bangunan" },
  { value: "vehicle", label: "Kendaraan" },
  { value: "equipment", label: "Peralatan" },
  { value: "other", label: "Lainnya" },
];

export default function AssetsPage() {
  const [assets, setAssets] = useState<Asset[]>([]);
  const [businesses, setBusinesses] = useState<Business[]>([]);
  const [loading, setLoading] = useState(true);
  const [businessFilter, setBusinessFilter] = useState("");
  const [showAdd, setShowAdd] = useState(false);
  const [editing, setEditing] = useState<Asset | null>(null);

  // Add form
  const [newBusinessId, setNewBusinessId] = useState("");
  const [newName, setNewName] = useState("");
  const [newType, setNewType] = useState("equipment");
  const [newValue, setNewValue] = useState("");
  const [newPrice, setNewPrice] = useState("");
  const [newDate, setNewDate] = useState("");
  const [newNotes, setNewNotes] = useState("");
  const [saving, setSaving] = useState(false);

  // Edit form
  const [editName, setEditName] = useState("");
  const [editType, setEditType] = useState("");
  const [editValue, setEditValue] = useState("");
  const [editPrice, setEditPrice] = useState("");
  const [editDate, setEditDate] = useState("");
  const [editNotes, setEditNotes] = useState("");

  useEffect(() => {
    Promise.all([
      fetch("/api/businesses").then((r) => r.json()),
      fetch("/api/assets").then((r) => r.json()),
    ]).then(([bData, aData]) => {
      setBusinesses(bData.businesses);
      setAssets(aData.assets);
      setNewBusinessId(bData.businesses[0]?.id || "");
    }).finally(() => setLoading(false));
  }, []);

  async function fetchAssets() {
    const params = businessFilter ? `?business=${businessFilter}` : "";
    const res = await fetch(`/api/assets${params}`);
    const data = await res.json();
    setAssets(data.assets);
  }

  useEffect(() => {
    fetchAssets();
  }, [businessFilter]);

  async function handleAdd() {
    if (!newName.trim() || !newBusinessId) return;
    setSaving(true);
    await fetch("/api/assets", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        businessId: newBusinessId,
        name: newName.trim(),
        assetType: newType,
        value: newValue || "0",
        purchasePrice: newPrice || "0",
        purchaseDate: newDate || null,
        notes: newNotes.trim() || null,
      }),
    });
    setNewName(""); setNewValue(""); setNewPrice(""); setNewDate(""); setNewNotes("");
    setShowAdd(false);
    setSaving(false);
    fetchAssets();
  }

  function openEdit(a: Asset) {
    setEditing(a);
    setEditName(a.name);
    setEditType(a.assetType);
    setEditValue(String(a.value));
    setEditPrice(String(a.purchasePrice));
    setEditDate(a.purchaseDate ? a.purchaseDate.split("T")[0] : "");
    setEditNotes(a.notes || "");
  }

  async function handleSaveEdit() {
    if (!editing || !editName.trim()) return;
    setSaving(true);
    await fetch("/api/assets", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        id: editing.id,
        name: editName.trim(),
        assetType: editType,
        value: editValue || "0",
        purchasePrice: editPrice || "0",
        purchaseDate: editDate || null,
        notes: editNotes.trim() || null,
      }),
    });
    setEditing(null);
    setSaving(false);
    fetchAssets();
  }

  async function handleDelete(id: string) {
    if (!confirm("Hapus aset ini?")) return;
    await fetch(`/api/assets?id=${id}`, { method: "DELETE" });
    fetchAssets();
  }

  const totalValue = assets.reduce((sum, a) => sum + a.value, 0);
  const totalPurchase = assets.reduce((sum, a) => sum + a.purchasePrice, 0);

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
          <h1 className="text-2xl font-bold text-gray-900">Aset</h1>
          <p className="text-gray-500 text-sm mt-1">Catat dan pantau aset semua bisnis</p>
        </div>
        <button
          onClick={() => setShowAdd(!showAdd)}
          className="flex items-center gap-2 px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700 transition-colors"
        >
          <Plus className="w-4 h-4" />
          Tambah Aset
        </button>
      </div>

      {/* Filters */}
      <div className="flex gap-3">
        <select
          value={businessFilter}
          onChange={(e) => setBusinessFilter(e.target.value)}
          className="px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
        >
          <option value="">Semua Bisnis</option>
          {businesses.map((b) => (
            <option key={b.slug} value={b.slug}>{b.name}</option>
          ))}
        </select>
      </div>

      {/* Summary */}
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <div className="bg-white rounded-xl border border-gray-200 p-5">
          <p className="text-sm text-gray-500">Total Aset</p>
          <p className="text-2xl font-bold text-emerald-600">{assets.length}</p>
        </div>
        <div className="bg-white rounded-xl border border-gray-200 p-5">
          <p className="text-sm text-gray-500">Nilai Sekarang</p>
          <p className="text-2xl font-bold text-blue-600">{formatCurrency(totalValue)}</p>
        </div>
        <div className="bg-white rounded-xl border border-gray-200 p-5">
          <p className="text-sm text-gray-500">Harga Beli Total</p>
          <p className="text-2xl font-bold text-gray-600">{formatCurrency(totalPurchase)}</p>
        </div>
      </div>

      {/* Add Form */}
      {showAdd && (
        <div className="bg-white rounded-xl border border-gray-200 p-4 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
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
            {assetTypes.map((t) => (
              <option key={t.value} value={t.value}>{t.label}</option>
            ))}
          </select>
          <input
            type="text"
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
            placeholder="Nama aset"
            className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
            onKeyDown={(e) => e.key === "Enter" && handleAdd()}
          />
          <input
            type="number"
            value={newValue}
            onChange={(e) => setNewValue(e.target.value)}
            placeholder="Nilai sekarang (Rp)"
            className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
          />
          <input
            type="number"
            value={newPrice}
            onChange={(e) => setNewPrice(e.target.value)}
            placeholder="Harga beli (Rp)"
            className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
          />
          <input
            type="date"
            value={newDate}
            onChange={(e) => setNewDate(e.target.value)}
            className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
          />
          <input
            type="text"
            value={newNotes}
            onChange={(e) => setNewNotes(e.target.value)}
            placeholder="Catatan (opsional)"
            className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
          />
          <button
            onClick={handleAdd}
            disabled={saving}
            className="px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700 disabled:opacity-50"
          >
            {saving ? "..." : "Simpan"}
          </button>
        </div>
      )}

      {/* Assets List */}
      {assets.length === 0 ? (
        <div className="bg-white rounded-xl border border-gray-200 p-12 text-center">
          <Boxes className="w-12 h-12 text-gray-300 mx-auto mb-4" />
          <h3 className="text-lg font-semibold text-gray-900 mb-2">Belum ada aset</h3>
          <p className="text-gray-500 mb-4">Catat aset bisnis kamu seperti tanah, kendaraan, dan peralatan</p>
          <button
            onClick={() => setShowAdd(true)}
            className="inline-flex items-center gap-2 px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700"
          >
            <Plus className="w-4 h-4" />
            Tambah Aset
          </button>
        </div>
      ) : (
        <div className="bg-white rounded-xl border border-gray-200 overflow-hidden">
          <div className="divide-y divide-gray-100">
            {assets.map((a) => (
              <div key={a.id} className="flex items-center justify-between p-4 hover:bg-gray-50 transition-colors group">
                <div className="flex items-center gap-3 min-w-0">
                  <div className="w-9 h-9 rounded-lg bg-blue-100 flex items-center justify-center flex-shrink-0">
                    <Boxes className="w-4 h-4 text-blue-600" />
                  </div>
                  <div className="min-w-0">
                    <p className="text-sm font-medium text-gray-900 truncate">{a.name}</p>
                    <div className="flex flex-wrap gap-1 text-xs text-gray-500 mt-0.5">
                      <span className="px-1.5 py-0.5 bg-gray-100 rounded">{a.business.name}</span>
                      <span className="px-1.5 py-0.5 bg-gray-100 rounded">{assetTypeLabels[a.assetType] || a.assetType}</span>
                      {a.purchaseDate && (
                        <span>{new Date(a.purchaseDate).toLocaleDateString("id-ID")}</span>
                      )}
                    </div>
                  </div>
                </div>
                <div className="flex items-center gap-4">
                  <div className="text-right">
                    <p className="text-sm font-semibold text-gray-900">{formatCurrency(a.value)}</p>
                    {a.purchasePrice > 0 && (
                      <p className="text-xs text-gray-400">Beli {formatCurrency(a.purchasePrice)}</p>
                    )}
                  </div>
                  <div className="flex gap-1 opacity-0 group-hover:opacity-100 transition-all">
                    <button
                      onClick={() => openEdit(a)}
                      className="p-1.5 text-gray-400 hover:text-emerald-600 rounded"
                    >
                      <Pencil className="w-4 h-4" />
                    </button>
                    <button
                      onClick={() => handleDelete(a.id)}
                      className="p-1.5 text-gray-400 hover:text-red-500 rounded"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  </div>
                </div>
              </div>
            ))}
          </div>
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
              <h2 className="text-lg font-semibold text-gray-900">Edit Aset</h2>
              <button onClick={() => setEditing(null)} className="p-1 text-gray-400 hover:text-gray-600">
                <X className="w-5 h-5" />
              </button>
            </div>
            <div className="space-y-3">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">Nama Aset</label>
                <input
                  type="text"
                  value={editName}
                  onChange={(e) => setEditName(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">Jenis</label>
                <select
                  value={editType}
                  onChange={(e) => setEditType(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                >
                  {assetTypes.map((t) => (
                    <option key={t.value} value={t.value}>{t.label}</option>
                  ))}
                </select>
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">Nilai Sekarang (Rp)</label>
                <input
                  type="number"
                  value={editValue}
                  onChange={(e) => setEditValue(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">Harga Beli (Rp)</label>
                <input
                  type="number"
                  value={editPrice}
                  onChange={(e) => setEditPrice(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">Tanggal Beli</label>
                <input
                  type="date"
                  value={editDate}
                  onChange={(e) => setEditDate(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">Catatan</label>
                <textarea
                  value={editNotes}
                  onChange={(e) => setEditNotes(e.target.value)}
                  rows={2}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500 resize-none"
                />
              </div>
              <button
                onClick={handleSaveEdit}
                disabled={saving}
                className="w-full flex items-center justify-center gap-2 bg-emerald-600 text-white py-2.5 rounded-lg font-medium hover:bg-emerald-700 disabled:opacity-50"
              >
                <Save className="w-4 h-4" />
                {saving ? "Menyimpan..." : "Simpan"}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
