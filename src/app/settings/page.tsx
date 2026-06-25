"use client";

import { useState, useEffect } from "react";
import { Plus, Trash2, Loader2, FileText, Store, Shield, Pencil, X, Save } from "lucide-react";

interface CashierItem {
  id: string;
  name: string;
  business: { id: string; name: string };
}

interface ExpenseDesc {
  id: string;
  name: string;
  business: { id: string; name: string };
}

interface CashierUser {
  id: string;
  name: string;
  email: string;
  role: string;
  isActive: boolean;
  createdAt: string;
}

interface Business {
  id: string;
  name: string;
}

export default function SettingsPage() {
  const [tab, setTab] = useState<"cashiers" | "descriptions" | "accounts">("cashiers");
  const [loading, setLoading] = useState(true);

  const [businesses, setBusinesses] = useState<Business[]>([]);
  const [cashiers, setCashiers] = useState<CashierItem[]>([]);
  const [descriptions, setDescriptions] = useState<ExpenseDesc[]>([]);
  const [cashierUsers, setCashierUsers] = useState<CashierUser[]>([]);

  const [selectedBusinessId, setSelectedBusinessId] = useState("");
  const [newName, setNewName] = useState("");
  const [saving, setSaving] = useState(false);

  const [showAddAccount, setShowAddAccount] = useState(false);
  const [newAccountName, setNewAccountName] = useState("");
  const [newAccountEmail, setNewAccountEmail] = useState("");
  const [newAccountPassword, setNewAccountPassword] = useState("");

  const [editingUser, setEditingUser] = useState<CashierUser | null>(null);
  const [editName, setEditName] = useState("");
  const [editEmail, setEditEmail] = useState("");
  const [editPassword, setEditPassword] = useState("");

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

  async function fetchCashierUsers() {
    const res = await fetch("/api/cashier-users");
    const data = await res.json();
    setCashierUsers(data.cashiers || []);
  }

  useEffect(() => {
    fetch("/api/businesses")
      .then((r) => r.json())
      .then((d) => {
        setBusinesses(d.businesses);
        setSelectedBusinessId(d.businesses[0]?.id || "");
        return Promise.all([fetchCashiers(), fetchDescriptions(), fetchCashierUsers()]);
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

  async function handleAddAccount() {
    if (!newAccountName.trim() || !newAccountEmail.trim() || !newAccountPassword) return;
    setSaving(true);
    const res = await fetch("/api/cashier-users", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: newAccountName, email: newAccountEmail, password: newAccountPassword }),
    });
    const data = await res.json();
    if (!res.ok) {
      alert(data.error || "Gagal membuat akun");
      setSaving(false);
      return;
    }
    setNewAccountName(""); setNewAccountEmail(""); setNewAccountPassword("");
    setShowAddAccount(false);
    setSaving(false);
    fetchCashierUsers();
  }

  async function handleDeleteAccount(id: string) {
    if (!confirm("Nonaktifkan akun kasir ini?")) return;
    await fetch(`/api/cashier-users?id=${id}`, { method: "DELETE" });
    fetchCashierUsers();
  }

  function openEdit(u: CashierUser) {
    setEditingUser(u);
    setEditName(u.name);
    setEditEmail(u.email);
    setEditPassword("");
  }

  async function handleSaveEdit() {
    if (!editingUser) return;
    setSaving(true);
    await fetch("/api/cashier-users", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        id: editingUser.id,
        name: editName.trim() || undefined,
        email: editEmail.trim() || undefined,
        password: editPassword || undefined,
      }),
    });
    setEditingUser(null);
    setSaving(false);
    fetchCashierUsers();
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
        <p className="text-gray-500 text-sm mt-1">Atur nama kasir, deskripsi pengeluaran, dan akun kasir</p>
      </div>

      <div className="flex gap-2 bg-white border border-gray-200 rounded-lg p-1 w-fit flex-wrap">
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
        <button
          onClick={() => setTab("accounts")}
          className={`flex items-center gap-2 px-4 py-2 text-sm rounded-md font-medium transition-colors ${
            tab === "accounts" ? "bg-emerald-600 text-white" : "text-gray-600 hover:bg-gray-50"
          }`}
        >
          <Shield className="w-4 h-4" />
          Akun Kasir
        </button>
      </div>

      {(tab === "cashiers" || tab === "descriptions") && (
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
      )}

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
      ) : tab === "descriptions" ? (
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
      ) : (
        <div className="bg-white rounded-xl border border-gray-200 overflow-hidden">
          <div className="px-6 py-4 border-b border-gray-100 bg-gray-50 flex items-center justify-between">
            <div>
              <h2 className="font-semibold text-gray-900">Akun Kasir</h2>
              <p className="text-sm text-gray-500 mt-0.5">Buat akun login untuk kasir (hanya akses Minimarket, Supplier, Tempo)</p>
            </div>
            <button
              onClick={() => setShowAddAccount(!showAddAccount)}
              className="flex items-center gap-2 px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700"
            >
              <Plus className="w-4 h-4" />
              Tambah Akun
            </button>
          </div>

          {showAddAccount && (
            <div className="px-6 py-4 border-b border-gray-100 bg-emerald-50/50">
              <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
                <input
                  type="text"
                  value={newAccountName}
                  onChange={(e) => setNewAccountName(e.target.value)}
                  placeholder="Nama kasir"
                  className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
                />
                <input
                  type="email"
                  value={newAccountEmail}
                  onChange={(e) => setNewAccountEmail(e.target.value)}
                  placeholder="Email login"
                  className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
                />
                <input
                  type="password"
                  value={newAccountPassword}
                  onChange={(e) => setNewAccountPassword(e.target.value)}
                  placeholder="Password (min 4 karakter)"
                  className="px-3 py-2 border border-gray-300 rounded-lg text-sm"
                  onKeyDown={(e) => e.key === "Enter" && handleAddAccount()}
                />
              </div>
              <button
                onClick={handleAddAccount}
                disabled={saving}
                className="mt-3 flex items-center gap-2 px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700 disabled:opacity-50"
              >
                {saving ? "Menyimpan..." : "Buat Akun Kasir"}
              </button>
            </div>
          )}

          {cashierUsers.length === 0 && (
            <p className="text-sm text-gray-400 text-center py-8">Belum ada akun kasir</p>
          )}
          <div className="divide-y divide-gray-100">
            {cashierUsers.map((u) => (
              <div key={u.id} className="flex items-center justify-between px-6 py-3 hover:bg-gray-50">
                <div className="flex items-center gap-3">
                  <div className="w-8 h-8 rounded-full bg-amber-100 flex items-center justify-center">
                    <Shield className="w-4 h-4 text-amber-600" />
                  </div>
                  <div>
                    <p className="text-sm font-medium text-gray-900">{u.name}</p>
                    <p className="text-xs text-gray-500">{u.email}</p>
                  </div>
                </div>
                <div className="flex items-center gap-2">
                  <button
                    onClick={() => openEdit(u)}
                    className="p-1.5 text-gray-400 hover:text-emerald-600 rounded transition-colors"
                  >
                    <Pencil className="w-4 h-4" />
                  </button>
                  <button
                    onClick={() => handleDeleteAccount(u.id)}
                    className="p-1.5 text-gray-400 hover:text-red-500 rounded transition-colors"
                  >
                    <Trash2 className="w-4 h-4" />
                  </button>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {editingUser && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50" onClick={() => setEditingUser(null)}>
          <div
            className="bg-white rounded-xl shadow-xl w-full max-w-md mx-4 p-6"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-lg font-semibold text-gray-900">Edit Akun Kasir</h2>
              <button onClick={() => setEditingUser(null)} className="p-1 text-gray-400 hover:text-gray-600">
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
                <label className="block text-sm font-medium text-gray-700 mb-1">Email</label>
                <input
                  type="email"
                  value={editEmail}
                  onChange={(e) => setEditEmail(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">Password Baru (kosongkan jika tidak ganti)</label>
                <input
                  type="password"
                  value={editPassword}
                  onChange={(e) => setEditPassword(e.target.value)}
                  placeholder="Min 4 karakter"
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
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
