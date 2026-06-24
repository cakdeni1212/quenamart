"use client";

import { useState, useEffect } from "react";
import { Plus, Trash2, Pencil, Loader2, Save, X, Truck, UserRound, Phone, MapPin, FileText } from "lucide-react";
import { formatCurrency } from "@/lib/utils";

interface Supplier {
  id: string;
  name: string;
  type: string;
  phone: string | null;
  address: string | null;
  notes: string | null;
  business: { id: string; name: string };
  tempos: { id: string; totalAmount: number; paidAmount: number }[];
}

interface Business {
  id: string;
  name: string;
}

export default function SuppliersPage() {
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [businesses, setBusinesses] = useState<Business[]>([]);
  const [loading, setLoading] = useState(true);
  const [showAdd, setShowAdd] = useState(false);
  const [editing, setEditing] = useState<Supplier | null>(null);

  const [newBusinessId, setNewBusinessId] = useState("");
  const [newName, setNewName] = useState("");
  const [newType, setNewType] = useState("supplier");
  const [newPhone, setNewPhone] = useState("");
  const [newAddress, setNewAddress] = useState("");
  const [newNotes, setNewNotes] = useState("");
  const [saving, setSaving] = useState(false);

  const [editName, setEditName] = useState("");
  const [editType, setEditType] = useState("");
  const [editPhone, setEditPhone] = useState("");
  const [editAddress, setEditAddress] = useState("");
  const [editNotes, setEditNotes] = useState("");

  const [typeFilter, setTypeFilter] = useState("");

  async function fetchSuppliers() {
    const params = typeFilter ? `?type=${typeFilter}` : "";
    const res = await fetch(`/api/suppliers${params}`);
    const data = await res.json();
    setSuppliers(data.suppliers);
  }

  useEffect(() => {
    fetch("/api/businesses")
      .then((r) => r.json())
      .then((d) => {
        setBusinesses(d.businesses);
        const mm = d.businesses.find((b: Business) => b.businessType === "minimarket" || b.name.toLowerCase().includes("minimarket"));
        setNewBusinessId(mm?.id || d.businesses[0]?.id || "");
      });
  }, []);

  useEffect(() => {
    setLoading(true);
    fetchSuppliers().finally(() => setLoading(false));
  }, [typeFilter]);

  async function handleAdd() {
    if (!newName.trim() || !newBusinessId) return;
    setSaving(true);
    await fetch("/api/suppliers", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        businessId: newBusinessId,
        name: newName.trim(),
        type: newType,
        phone: newPhone.trim() || null,
        address: newAddress.trim() || null,
        notes: newNotes.trim() || null,
      }),
    });
    setNewName(""); setNewPhone(""); setNewAddress(""); setNewNotes("");
    setShowAdd(false);
    setSaving(false);
    fetchSuppliers();
  }

  function openEdit(s: Supplier) {
    setEditing(s);
    setEditName(s.name);
    setEditType(s.type);
    setEditPhone(s.phone || "");
    setEditAddress(s.address || "");
    setEditNotes(s.notes || "");
  }

  async function handleSaveEdit() {
    if (!editing || !editName.trim()) return;
    setSaving(true);
    await fetch("/api/suppliers", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        id: editing.id,
        name: editName.trim(),
        type: editType,
        phone: editPhone.trim() || null,
        address: editAddress.trim() || null,
        notes: editNotes.trim() || null,
      }),
    });
    setEditing(null);
    setSaving(false);
    fetchSuppliers();
  }

  async function handleDelete(id: string) {
    if (!confirm("Nonaktifkan supplier/sales ini?")) return;
    await fetch(`/api/suppliers?id=${id}`, { method: "DELETE" });
    fetchSuppliers();
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
          <h1 className="text-2xl font-bold text-gray-900">Supplier & Sales</h1>
          <p className="text-gray-500 text-sm mt-1">Kelola data supplier dan sales dengan tempo pembayaran</p>
        </div>
        <button
          onClick={() => setShowAdd(!showAdd)}
          className="flex items-center gap-2 px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700 transition-colors"
        >
          <Plus className="w-4 h-4" />
          Tambah
        </button>
      </div>

      <div className="flex gap-3">
        <select
          value={typeFilter}
          onChange={(e) => setTypeFilter(e.target.value)}
          className="px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
        >
          <option value="">Semua Tipe</option>
          <option value="supplier">Supplier</option>
          <option value="sales">Sales</option>
        </select>
      </div>

      {showAdd && (
        <div className="bg-white rounded-xl border border-gray-200 p-4 grid grid-cols-1 sm:grid-cols-2 gap-3">
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
            <option value="supplier">Supplier</option>
            <option value="sales">Sales</option>
          </select>
          <input
            type="text"
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
            placeholder="Nama supplier/sales"
            className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
            onKeyDown={(e) => e.key === "Enter" && handleAdd()}
          />
          <input
            type="text"
            value={newPhone}
            onChange={(e) => setNewPhone(e.target.value)}
            placeholder="No. Telepon"
            className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
          />
          <input
            type="text"
            value={newAddress}
            onChange={(e) => setNewAddress(e.target.value)}
            placeholder="Alamat"
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

      {suppliers.length === 0 ? (
        <div className="bg-white rounded-xl border border-gray-200 p-12 text-center">
          <Truck className="w-12 h-12 text-gray-300 mx-auto mb-4" />
          <h3 className="text-lg font-semibold text-gray-900 mb-2">Belum ada supplier / sales</h3>
          <p className="text-gray-500 mb-4">Tambah supplier dan sales untuk pencatatan tempo pembayaran</p>
          <button
            onClick={() => setShowAdd(true)}
            className="inline-flex items-center gap-2 px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700"
          >
            <Plus className="w-4 h-4" />
            Tambah
          </button>
        </div>
      ) : (
        <div className="bg-white rounded-xl border border-gray-200 overflow-hidden">
          <div className="divide-y divide-gray-100">
            {suppliers.map((s) => {
              const totalHutang = s.tempos.reduce((sum, t) => sum + (t.totalAmount - t.paidAmount), 0);
              return (
                <div key={s.id} className="flex items-center justify-between p-4 hover:bg-gray-50 transition-colors group">
                  <div className="flex items-center gap-3 min-w-0">
                    <div className={`w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0 ${s.type === "sales" ? "bg-blue-100" : "bg-amber-100"}`}>
                      {s.type === "sales" ? (
                        <UserRound className="w-4 h-4 text-blue-600" />
                      ) : (
                        <Truck className="w-4 h-4 text-amber-600" />
                      )}
                    </div>
                    <div className="min-w-0">
                      <p className="text-sm font-medium text-gray-900 truncate">{s.name}</p>
                      <div className="flex flex-wrap gap-1 text-xs text-gray-500 mt-0.5">
                        <span className={`px-1.5 py-0.5 rounded ${s.type === "sales" ? "bg-blue-100 text-blue-700" : "bg-amber-100 text-amber-700"}`}>
                          {s.type === "sales" ? "Sales" : "Supplier"}
                        </span>
                        <span className="px-1.5 py-0.5 bg-gray-100 rounded">{s.business.name}</span>
                        {s.phone && (
                          <span className="flex items-center gap-1"><Phone className="w-3 h-3" />{s.phone}</span>
                        )}
                      </div>
                    </div>
                  </div>
                  <div className="flex items-center gap-4">
                    <div className="text-right">
                      {totalHutang > 0 && (
                        <p className="text-sm font-semibold text-red-600">{formatCurrency(totalHutang)}</p>
                      )}
                      {s.tempos.length > 0 && (
                        <p className="text-xs text-gray-400">{s.tempos.length} tempo aktif</p>
                      )}
                    </div>
                    <div className="flex gap-1 opacity-0 group-hover:opacity-100 transition-all">
                      <button
                        onClick={() => openEdit(s)}
                        className="p-1.5 text-gray-400 hover:text-emerald-600 rounded"
                      >
                        <Pencil className="w-4 h-4" />
                      </button>
                      <button
                        onClick={() => handleDelete(s.id)}
                        className="p-1.5 text-gray-400 hover:text-red-500 rounded"
                      >
                        <Trash2 className="w-4 h-4" />
                      </button>
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}

      {editing && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50" onClick={() => setEditing(null)}>
          <div
            className="bg-white rounded-xl shadow-xl w-full max-w-md mx-4 p-6"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-lg font-semibold text-gray-900">Edit Supplier/Sales</h2>
              <button onClick={() => setEditing(null)} className="p-1 text-gray-400 hover:text-gray-600">
                <X className="w-5 h-5" />
              </button>
            </div>
            <div className="space-y-3">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">Nama</label>
                <input
                  type="text"
                  value={editName}
                  onChange={(e) => setEditName(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">Tipe</label>
                <select
                  value={editType}
                  onChange={(e) => setEditType(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                >
                  <option value="supplier">Supplier</option>
                  <option value="sales">Sales</option>
                </select>
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">No. Telepon</label>
                <input
                  type="text"
                  value={editPhone}
                  onChange={(e) => setEditPhone(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">Alamat</label>
                <input
                  type="text"
                  value={editAddress}
                  onChange={(e) => setEditAddress(e.target.value)}
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
