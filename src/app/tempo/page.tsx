"use client";

import { useState, useEffect } from "react";
import Link from "next/link";
import { Plus, Loader2, Truck, UserRound, Clock, CheckCircle, AlertTriangle, DollarSign, Calendar } from "lucide-react";
import { formatCurrency } from "@/lib/utils";

interface Tempo {
  id: string;
  description: string;
  totalAmount: number;
  paidAmount: number;
  dueDate: string;
  status: string;
  invoiceNo: string | null;
  notes: string | null;
  supplier: { id: string; name: string; type: string };
  business: { id: string; name: string };
  payments: { id: string; amount: number; paymentDate: string; notes: string | null }[];
}

interface Supplier {
  id: string;
  name: string;
  type: string;
  business: { id: string; name: string };
}

interface Business {
  id: string;
  name: string;
}

const statusConfig: Record<string, { label: string; color: string; icon: typeof Clock }> = {
  pending: { label: "Belum Dibayar", color: "bg-yellow-100 text-yellow-700", icon: Clock },
  partial: { label: "Dibayar Sebagian", color: "bg-blue-100 text-blue-700", icon: DollarSign },
  paid: { label: "Lunas", color: "bg-emerald-100 text-emerald-700", icon: CheckCircle },
  overdue: { label: "Jatuh Tempo", color: "bg-red-100 text-red-700", icon: AlertTriangle },
};

export default function TempoPage() {
  const [tab, setTab] = useState<"list" | "create">("list");
  const [tempos, setTempos] = useState<Tempo[]>([]);
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [businesses, setBusinesses] = useState<Business[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  const [statusFilter, setStatusFilter] = useState("");

  const [newBusinessId, setNewBusinessId] = useState("");
  const [newSupplierId, setNewSupplierId] = useState("");
  const [newDescription, setNewDescription] = useState("");
  const [newTotalAmount, setNewTotalAmount] = useState("");
  const [newDueDate, setNewDueDate] = useState("");
  const [newInvoiceNo, setNewInvoiceNo] = useState("");
  const [newNotes, setNewNotes] = useState("");

  async function fetchTempos() {
    const params = new URLSearchParams();
    if (statusFilter) params.set("status", statusFilter);
    const res = await fetch(`/api/tempo?${params.toString()}`);
    const data = await res.json();
    setTempos(data.tempos);
  }

  async function fetchSuppliers(businessId?: string) {
    const params = businessId ? `?businessId=${businessId}` : "";
    const res = await fetch(`/api/suppliers${params}`);
    const data = await res.json();
    setSuppliers(data.suppliers);
  }

  useEffect(() => {
    fetch("/api/businesses")
      .then((r) => r.json())
      .then((d) => {
        setBusinesses(d.businesses);
        const bId = d.businesses[0]?.id || "";
        setNewBusinessId(bId);
        return Promise.all([fetchTempos(), fetchSuppliers(bId)]);
      })
      .finally(() => setLoading(false));
  }, []);

  useEffect(() => {
    setLoading(true);
    fetchTempos().finally(() => setLoading(false));
  }, [statusFilter]);

  useEffect(() => {
    if (newBusinessId) fetchSuppliers(newBusinessId);
  }, [newBusinessId]);

  async function handleCreate() {
    if (!newBusinessId || !newSupplierId || !newDescription || !newTotalAmount || !newDueDate) return;
    setSaving(true);
    const res = await fetch("/api/tempo", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        businessId: newBusinessId,
        supplierId: newSupplierId,
        description: newDescription.trim(),
        totalAmount: parseFloat(newTotalAmount),
        dueDate: newDueDate,
        invoiceNo: newInvoiceNo.trim() || null,
        notes: newNotes.trim() || null,
      }),
    });
    if (res.ok) {
      setNewSupplierId(""); setNewDescription(""); setNewTotalAmount(""); setNewDueDate("");
      setNewInvoiceNo(""); setNewNotes("");
      setTab("list");
      fetchTempos();
    }
    setSaving(false);
  }

  async function handleDelete(id: string) {
    if (!confirm("Hapus data tempo ini?")) return;
    await fetch(`/api/tempo?id=${id}`, { method: "DELETE" });
    fetchTempos();
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
          <h1 className="text-2xl font-bold text-gray-900">Tempo Pembayaran</h1>
          <p className="text-gray-500 text-sm mt-1">Catat hutang/pinjaman dari supplier dan sales</p>
        </div>
        <div className="flex bg-white border border-gray-200 rounded-lg p-1">
          <button
            onClick={() => setTab("list")}
            className={`px-4 py-1.5 text-sm rounded-md font-medium transition-colors ${
              tab === "list" ? "bg-emerald-600 text-white" : "text-gray-600 hover:bg-gray-50"
            }`}
          >
            Daftar Tempo
          </button>
          <button
            onClick={() => setTab("create")}
            className={`px-4 py-1.5 text-sm rounded-md font-medium transition-colors ${
              tab === "create" ? "bg-emerald-600 text-white" : "text-gray-600 hover:bg-gray-50"
            }`}
          >
            Tambah Tempo
          </button>
        </div>
      </div>

      {tab === "create" ? (
        <div className="bg-white rounded-xl border border-gray-200 p-6 space-y-4">
          <h2 className="font-semibold text-gray-900">Tambah Data Tempo Baru</h2>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Bisnis *</label>
              <select
                value={newBusinessId}
                onChange={(e) => setNewBusinessId(e.target.value)}
                className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
              >
                {businesses.map((b) => (
                  <option key={b.id} value={b.id}>{b.name}</option>
                ))}
              </select>
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Supplier / Sales *</label>
              <select
                value={newSupplierId}
                onChange={(e) => setNewSupplierId(e.target.value)}
                className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
              >
                <option value="">Pilih supplier/sales</option>
                {suppliers.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name} ({s.type === "sales" ? "Sales" : "Supplier"})
                  </option>
                ))}
              </select>
            </div>
            <div className="sm:col-span-2">
              <label className="block text-sm font-medium text-gray-700 mb-1">Deskripsi *</label>
              <input
                type="text"
                value={newDescription}
                onChange={(e) => setNewDescription(e.target.value)}
                placeholder="Contoh: Pembelian stok barang 20 karton"
                className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Jumlah Total (Rp) *</label>
              <input
                type="number"
                value={newTotalAmount}
                onChange={(e) => setNewTotalAmount(e.target.value)}
                placeholder="0"
                min="0"
                className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Jatuh Tempo *</label>
              <input
                type="date"
                value={newDueDate}
                onChange={(e) => setNewDueDate(e.target.value)}
                className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">No. Invoice</label>
              <input
                type="text"
                value={newInvoiceNo}
                onChange={(e) => setNewInvoiceNo(e.target.value)}
                placeholder="Opsional"
                className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Catatan</label>
              <input
                type="text"
                value={newNotes}
                onChange={(e) => setNewNotes(e.target.value)}
                placeholder="Opsional"
                className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
              />
            </div>
          </div>
          <button
            onClick={handleCreate}
            disabled={saving}
            className="w-full flex items-center justify-center gap-2 bg-emerald-600 text-white py-2.5 rounded-lg font-medium hover:bg-emerald-700 disabled:opacity-50 transition-colors"
          >
            <Plus className="w-4 h-4" />
            {saving ? "Menyimpan..." : "Simpan Tempo"}
          </button>
        </div>
      ) : (
        <>
          <div className="flex gap-3">
            <select
              value={statusFilter}
              onChange={(e) => setStatusFilter(e.target.value)}
              className="px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
            >
              <option value="">Semua Status</option>
              <option value="pending">Belum Dibayar</option>
              <option value="partial">Dibayar Sebagian</option>
              <option value="paid">Lunas</option>
              <option value="overdue">Jatuh Tempo</option>
            </select>
          </div>

          {tempos.length === 0 ? (
            <div className="bg-white rounded-xl border border-gray-200 p-12 text-center">
              <Calendar className="w-12 h-12 text-gray-300 mx-auto mb-4" />
              <h3 className="text-lg font-semibold text-gray-900 mb-2">Belum ada data tempo</h3>
              <p className="text-gray-500 mb-4">Catat tempo pembayaran dari supplier dan sales kamu</p>
              <button
                onClick={() => setTab("create")}
                className="inline-flex items-center gap-2 px-4 py-2 bg-emerald-600 text-white rounded-lg text-sm font-medium hover:bg-emerald-700"
              >
                <Plus className="w-4 h-4" />
                Tambah Tempo
              </button>
            </div>
          ) : (
            <div className="space-y-3">
              {tempos.map((t) => {
                const status = statusConfig[t.status] || statusConfig.pending;
                const StatusIcon = status.icon;
                const remaining = t.totalAmount - t.paidAmount;
                const progress = t.totalAmount > 0 ? (t.paidAmount / t.totalAmount) * 100 : 0;

                return (
                  <div key={t.id} className="bg-white rounded-xl border border-gray-200 p-4 hover:shadow-sm transition-shadow">
                    <div className="flex items-start justify-between mb-3">
                      <div className="flex items-center gap-3">
                        <div className={`w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0 ${t.supplier.type === "sales" ? "bg-blue-100" : "bg-amber-100"}`}>
                          {t.supplier.type === "sales" ? (
                            <UserRound className="w-4 h-4 text-blue-600" />
                          ) : (
                            <Truck className="w-4 h-4 text-amber-600" />
                          )}
                        </div>
                        <div>
                          <p className="text-sm font-semibold text-gray-900">{t.description}</p>
                          <p className="text-xs text-gray-500">
                            {t.supplier.name} · {t.business.name}
                            {t.invoiceNo && ` · #${t.invoiceNo}`}
                          </p>
                        </div>
                      </div>
                      <div className="flex items-center gap-2">
                        <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium ${status.color}`}>
                          <StatusIcon className="w-3 h-3" />
                          {status.label}
                        </span>
                        {t.status !== "paid" && (
                          <>
                            <Link
                              href={`/tempo/pay?id=${t.id}`}
                              className="px-2 py-1 bg-emerald-600 text-white rounded text-xs font-medium hover:bg-emerald-700"
                            >
                              Bayar
                            </Link>
                            <button
                              onClick={() => handleDelete(t.id)}
                              className="text-xs text-gray-400 hover:text-red-500"
                            >
                              Hapus
                            </button>
                          </>
                        )}
                      </div>
                    </div>

                    <div className="space-y-2">
                      <div className="flex justify-between text-sm">
                        <span className="text-gray-600">
                          {formatCurrency(t.paidAmount)} / {formatCurrency(t.totalAmount)}
                        </span>
                        <span className="text-gray-500">
                          Sisa: <span className={remaining > 0 ? "text-red-600 font-medium" : "text-emerald-600 font-medium"}>
                            {formatCurrency(remaining)}
                          </span>
                        </span>
                      </div>
                      <div className="w-full bg-gray-200 rounded-full h-2">
                        <div
                          className={`h-2 rounded-full ${
                            t.status === "paid" ? "bg-emerald-500" :
                            t.status === "overdue" ? "bg-red-500" :
                            "bg-emerald-500"
                          }`}
                          style={{ width: `${Math.min(progress, 100)}%` }}
                        />
                      </div>
                      <div className="flex justify-between text-xs text-gray-400">
                        <span>Jatuh tempo: {new Date(t.dueDate).toLocaleDateString("id-ID", { day: "numeric", month: "long", year: "numeric" })}</span>
                        <span>{t.payments.length} x pembayaran</span>
                      </div>
                    </div>

                    {t.payments.length > 0 && (
                      <div className="mt-3 pt-3 border-t border-gray-100">
                        <p className="text-xs font-medium text-gray-500 mb-2">Riwayat Pembayaran</p>
                        <div className="space-y-1">
                          {t.payments.slice(0, 3).map((p) => (
                            <div key={p.id} className="flex items-center justify-between text-xs text-gray-600">
                              <span>{new Date(p.paymentDate).toLocaleDateString("id-ID")}</span>
                              <span className="font-medium text-emerald-600">{formatCurrency(p.amount)}</span>
                              {p.notes && <span className="text-gray-400 truncate ml-2">- {p.notes}</span>}
                            </div>
                          ))}
                        </div>
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </>
      )}
    </div>
  );
}
