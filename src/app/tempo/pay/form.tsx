"use client";

import { useState, useEffect } from "react";
import { useSearchParams, useRouter } from "next/navigation";
import Link from "next/link";
import { ArrowLeft, Save, DollarSign, Truck, UserRound } from "lucide-react";
import { formatCurrency } from "@/lib/utils";

interface TempoDetail {
  id: string;
  description: string;
  totalAmount: number;
  paidAmount: number;
  dueDate: string;
  status: string;
  invoiceNo: string | null;
  supplier: { id: string; name: string; type: string };
  business: { id: string; name: string };
  payments: { id: string; amount: number; paymentDate: string; notes: string | null }[];
}

export function TempoPayForm() {
  const searchParams = useSearchParams();
  const router = useRouter();
  const tempoId = searchParams.get("id");

  const [tempo, setTempo] = useState<TempoDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [amount, setAmount] = useState("");
  const [paymentDate, setPaymentDate] = useState(new Date().toISOString().split("T")[0]);
  const [notes, setNotes] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    if (!tempoId) return;
    fetch(`/api/tempo`)
      .then((r) => r.json())
      .then((data) => {
        const found = data.tempos.find((t: TempoDetail) => t.id === tempoId);
        if (found) setTempo(found);
      })
      .finally(() => setLoading(false));
  }, [tempoId]);

  async function handlePay(e: React.FormEvent) {
    e.preventDefault();
    if (!tempo || !amount) return;
    setSaving(true);
    setError("");

    const res = await fetch("/api/payments", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        tempoId: tempo.id,
        amount: parseFloat(amount),
        paymentDate,
        notes: notes.trim() || null,
      }),
    });

    const data = await res.json();
    if (res.ok) {
      router.push("/tempo");
      router.refresh();
    } else {
      setError(data.error || "Gagal menyimpan pembayaran");
    }
    setSaving(false);
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="w-8 h-8 border-4 border-emerald-600 border-t-transparent rounded-full animate-spin" />
      </div>
    );
  }

  if (!tempo) {
    return (
      <div className="bg-white rounded-xl border border-gray-200 p-12 text-center">
        <p className="text-gray-500">Data tempo tidak ditemukan</p>
        <Link href="/tempo" className="text-emerald-600 text-sm mt-2 inline-block">Kembali ke daftar tempo</Link>
      </div>
    );
  }

  const remaining = tempo.totalAmount - tempo.paidAmount;
  const progress = tempo.totalAmount > 0 ? (tempo.paidAmount / tempo.totalAmount) * 100 : 0;

  return (
    <div className="max-w-lg space-y-6">
      <div className="flex items-center gap-3">
        <Link href="/tempo" className="text-gray-500 hover:text-gray-700">
          <ArrowLeft className="w-5 h-5" />
        </Link>
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Bayar Tempo</h1>
          <p className="text-gray-500 text-sm mt-1">Catat pembayaran cicilan tempo</p>
        </div>
      </div>

      <div className="bg-white rounded-xl border border-gray-200 p-5">
        <div className="flex items-center gap-3 mb-4">
          <div className={`w-10 h-10 rounded-lg flex items-center justify-center ${tempo.supplier.type === "sales" ? "bg-blue-100" : "bg-amber-100"}`}>
            {tempo.supplier.type === "sales" ? (
              <UserRound className="w-5 h-5 text-blue-600" />
            ) : (
              <Truck className="w-5 h-5 text-amber-600" />
            )}
          </div>
          <div>
            <p className="font-semibold text-gray-900">{tempo.description}</p>
            <p className="text-sm text-gray-500">
              {tempo.supplier.name} ({tempo.supplier.type === "sales" ? "Sales" : "Supplier"}) · {tempo.business.name}
            </p>
          </div>
        </div>

        <div className="grid grid-cols-2 gap-3 mb-4">
          <div className="bg-gray-50 rounded-lg p-3">
            <p className="text-xs text-gray-500">Total Tempo</p>
            <p className="text-lg font-bold text-gray-900">{formatCurrency(tempo.totalAmount)}</p>
          </div>
          <div className="bg-gray-50 rounded-lg p-3">
            <p className="text-xs text-gray-500">Sudah Dibayar</p>
            <p className="text-lg font-bold text-emerald-600">{formatCurrency(tempo.paidAmount)}</p>
          </div>
          <div className="bg-gray-50 rounded-lg p-3">
            <p className="text-xs text-gray-500">Sisa</p>
            <p className="text-lg font-bold text-red-600">{formatCurrency(remaining)}</p>
          </div>
          <div className="bg-gray-50 rounded-lg p-3">
            <p className="text-xs text-gray-500">Jatuh Tempo</p>
            <p className="text-sm font-semibold text-gray-900">{new Date(tempo.dueDate).toLocaleDateString("id-ID", { day: "numeric", month: "short", year: "numeric" })}</p>
          </div>
        </div>

        <div className="mb-4">
          <div className="flex justify-between text-xs text-gray-500 mb-1">
            <span>Progress</span>
            <span>{progress.toFixed(0)}%</span>
          </div>
          <div className="w-full bg-gray-200 rounded-full h-2.5">
            <div
              className="h-2.5 rounded-full bg-emerald-500"
              style={{ width: `${Math.min(progress, 100)}%` }}
            />
          </div>
        </div>
      </div>

      <form onSubmit={handlePay} className="bg-white rounded-xl border border-gray-200 p-6 space-y-4">
        {error && (
          <div className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-lg text-sm">{error}</div>
        )}

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Jumlah Pembayaran (Rp) *</label>
          <input
            type="number"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
            placeholder="0"
            min="1"
            max={remaining}
            required
          />
          <p className="text-xs text-gray-400 mt-1">Maksimal pembayaran: {formatCurrency(remaining)}</p>
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Tanggal Pembayaran</label>
          <input
            type="date"
            value={paymentDate}
            onChange={(e) => setPaymentDate(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Catatan</label>
          <textarea
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            rows={2}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500 resize-none"
            placeholder="Contoh: Transfer Bank, Tunai, dll"
          />
        </div>

        <button
          type="submit"
          disabled={saving}
          className="w-full flex items-center justify-center gap-2 bg-emerald-600 text-white py-3 rounded-lg font-medium hover:bg-emerald-700 disabled:opacity-50 transition-colors"
        >
          <DollarSign className="w-5 h-5" />
          {saving ? "Menyimpan..." : `Bayar ${amount ? formatCurrency(parseFloat(amount)) : ""}`}
        </button>
      </form>

      {tempo.payments.length > 0 && (
        <div className="bg-white rounded-xl border border-gray-200 p-5">
          <h3 className="font-semibold text-gray-900 mb-3">Riwayat Pembayaran</h3>
          <div className="space-y-2">
            {tempo.payments.map((p) => (
              <div key={p.id} className="flex items-center justify-between py-2 border-b border-gray-100 last:border-0">
                <div>
                  <p className="text-sm font-medium text-gray-900">{formatCurrency(p.amount)}</p>
                  <p className="text-xs text-gray-500">
                    {new Date(p.paymentDate).toLocaleDateString("id-ID", { day: "numeric", month: "long", year: "numeric" })}
                    {p.notes && ` · ${p.notes}`}
                  </p>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
