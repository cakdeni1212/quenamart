"use client";

import { useState, useEffect } from "react";
import { Plus, Trash2, Loader2, Settings, Store, FileText } from "lucide-react";

interface Cashier {
  id: string;
  name: string;
  business: { id: string; name: string };
}

interface ExpenseDesc {
  id: string;
  name: string;
  business: { id: string; name: string };
}

interface Business {
  id: string;
  name: string;
}

export default function SettingsPage() {
  const [tab, setTab] = useState<"cashiers" | "descriptions">("cashiers");
  const [loading, setLoading] = useState(true);

  const [businesses, setBusinesses] = useState<Business[]>([]);
  const [cashiers, setCashiers] = useState<Cashier[]>([]);
  const [descriptions, setDescriptions] = useState<ExpenseDesc[]>([]);

  const [selectedBusinessId, setSelectedBusinessId] = useState("");
  const [newName, setNewName] = useState("");
  const [saving, setSaving] = useState(false);

  async function fetchCashiers() {
    const res = await fetch("/api/cashiers");
    const data = await res.json();
    setCashiers(data.cashiers);
  }

  async function fetchDescriptions() {
    const res = await fetch("/api/expense-descriptions");
    const data = await res.json();
    setDescriptions(data.descriptions);
  }

  useEffect(() => {
    fetch("/api/businesses")
      .then((r) => r.json())
      .then((d) => {
        setBusinesses(d.businesses);
        setSelectedBusinessId(d.businesses[0]?.id || "");
        return Promise.all([fetchCashiers(), fetchDescriptions()]);
      })
      .finally(() => setLoading(false));
  }, []);

  async function handleAddCashier() {
    if (!newName.trim() || !selectedBusinessId) return;
    setSaving(true);
    await fetch("/api/cashiers", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ businessId: selectedBusinessId, name: newName }),
    });
    setNewName("");
    setSaving(false);
    fetchCashiers();
  }

  async function handleDeleteCashier(id: string) {
    if (!confirm("Nonaktifkan kasir ini?")) return;
    await fetch(`/api/cashiers?id=${id}`, { method: "DELETE" });
    fetchCashiers();
  }

  async function handleAddDescription() {
    if (!newName.trim() || !selectedBusinessId) return;
    setSaving(true);
    await fetch("/api/expense-descriptions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ businessId: selectedBusinessId, name: newName }),
    });
    setNewName("");
    setSaving(false);
    fetchDescriptions();
  }

  async function handleDeleteDescription(id: string) {
    if (!confirm("Nonaktifkan deskripsi ini?")) return;
    await fetch(`/api/expense-descriptions?id=${id}`, { method: "DELETE" });
    fetchDescriptions();
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 className="w-8 h-8 animate-spin text-emerald-600" />
      </div>
    );
  }

  const filteredCashiers = selectedBusinessId
    ? cashiers.filter((c) => c.business.id === selectedBusinessId)
    : cashiers;

  const filteredDescriptions = selectedBusinessId
    ? descriptions.filter((d) => d.business.id === selectedBusinessId)
    : descriptions;

  return (
    <div className="space-y-6 max-w-5xl">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">Pengaturan</h1>
        <p className="text-gray-500 text-sm mt-1">Atur nama kasir dan deskripsi pengeluaran</p>
      </div>

      <div className="flex gap-2 bg-white border border-gray-200 rounded-lg p-1 w-fit">
        <button
          onClick={() => setTab("cashiers")}
          className={`flex items-center gap-2 px-4 py-2 text-sm rounded-md font-medium transition-colors ${
            tab === "cashiers" ? "bg-emerald-600 text-white" : "text-gray-600 hover:bg-gray-50"
          }`}
        >
          <Store className="w-4 h-4" />
          Nama Kasir
        </button>
        <button
          onClick={() => setTab("descriptions")}
          className={`flex items-center gap-2 px-4 py-2 text-sm rounded-md font-medium transition-colors ${
            tab === "descriptions" ? "bg-emerald-600 text-white" : "text-gray-600 hover:bg-gray-50"
          }`}
        >
          <FileText className="w-4 h-4" />
          Deskripsi Pengeluaran
        </button>
      </div>

      <div className="flex gap-3">
        <select
          value={selectedBusinessId}
          onChange={(e) => setSelectedBusinessId(e.target.value)}
          className="px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
        >
          {businesses.map((b) => (
            <option key={b.id} value={b.id}>{b.name}</option>
          ))}
        </select>
      </div>

      {tab === "cashiers" ? (
        <div className="bg-white rounded-xl border border-gray-200 overflow-hidden">
          <div className="px-6 py-4 border-b border-gray-100 bg-gray-50">
            <h2 className="font-semibold text-gray-900">Daftar Nama Kasir</h2>
            <p className="text-sm text-gray-500 mt-0.5">Nama kasir yang tersedia untuk pencatatan sift minimarket</p>
          </div>

          {filteredCashiers.length === 0 && (
            <p className="text-sm text-gray-400 text-center py-8">Belum ada nama kasir</p>
          )}
          <div className="divide-y divide-gray-100">
            {filteredCashiers.map((c) => (
              <div key={c.id} className="flex items-center justify-between px-6 py-3 hover:bg-gray-50">
                <div className="flex items-center gap-3">
                  <div className="w-8 h-8 rounded-full bg-emerald-100 flex items-center justify-center">
                    <Store className="w-4 h-4 text-emerald-600" />
                  </div>
                  <span className="text-sm font-medium text-gray-900">{c.name}</span>
                </div>
                <button
                  onClick={() => handleDeleteCashier(c.id)}
                  className="p-1.5 text-gray-400 hover:text-red-500 rounded transition-colors"
                >
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            ))}
          </div>

          <div className="px-6 py-4 border-t border-gray-100 flex gap-3">
            <input
              type="text"
              value={newName}
              onChange={(e) => setNewName(e.target.value)}
              placeholder="Nama kasir baru"
              className="flex-1 px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
              onKeyDown={(e) => e.key === "Enter" && handleAddCashier()}
            />
            <button
              onClick={handleAddCashier}
              disabled={saving}
              className="flex items-center gap-2 px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700 disabled:opacity-50 transition-colors"
            >
              <Plus className="w-4 h-4" />
              Tambah
            </button>
          </div>
        </div>
      ) : (
        <div className="bg-white rounded-xl border border-gray-200 overflow-hidden">
          <div className="px-6 py-4 border-b border-gray-100 bg-gray-50">
            <h2 className="font-semibold text-gray-900">Deskripsi Pengeluaran</h2>
            <p className="text-sm text-gray-500 mt-0.5">Deskripsi yang tersedia sebagai pilihan saat mencatat pengeluaran</p>
          </div>

          {filteredDescriptions.length === 0 && (
            <p className="text-sm text-gray-400 text-center py-8">Belum ada deskripsi pengeluaran</p>
          )}
          <div className="divide-y divide-gray-100">
            {filteredDescriptions.map((d) => (
              <div key={d.id} className="flex items-center justify-between px-6 py-3 hover:bg-gray-50">
                <div className="flex items-center gap-3">
                  <div className="w-8 h-8 rounded-lg bg-red-100 flex items-center justify-center">
                    <FileText className="w-4 h-4 text-red-600" />
                  </div>
                  <span className="text-sm font-medium text-gray-900">{d.name}</span>
                </div>
                <button
                  onClick={() => handleDeleteDescription(d.id)}
                  className="p-1.5 text-gray-400 hover:text-red-500 rounded transition-colors"
                >
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            ))}
          </div>

          <div className="px-6 py-4 border-t border-gray-100 flex gap-3">
            <input
              type="text"
              value={newName}
              onChange={(e) => setNewName(e.target.value)}
              placeholder="Deskripsi pengeluaran baru"
              className="flex-1 px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
              onKeyDown={(e) => e.key === "Enter" && handleAddDescription()}
            />
            <button
              onClick={handleAddDescription}
              disabled={saving}
              className="flex items-center gap-2 px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700 disabled:opacity-50 transition-colors"
            >
              <Plus className="w-4 h-4" />
              Tambah
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
