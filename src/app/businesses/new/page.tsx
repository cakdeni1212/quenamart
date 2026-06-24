"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { ArrowLeft, Save } from "lucide-react";

const businessTypes = [
  { value: "minimarket", label: "Minimarket / Retail" },
  { value: "farm", label: "Pertanian / Perkebunan" },
  { value: "fnb", label: "F&B / Kuliner" },
  { value: "trading", label: "Trading" },
  { value: "services", label: "Jasa" },
  { value: "personal", label: "Pribadi / Keluarga" },
  { value: "other", label: "Lainnya" },
];

export default function NewBusinessPage() {
  const router = useRouter();
  const [name, setName] = useState("");
  const [businessType, setBusinessType] = useState("other");
  const [description, setDescription] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!name.trim()) return;
    setLoading(true);
    setError("");

    try {
      const res = await fetch("/api/businesses", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: name.trim(), businessType, description: description.trim() || null }),
      });

      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Gagal membuat bisnis");
        return;
      }

      router.push("/businesses");
      router.refresh();
    } catch {
      setError("Terjadi kesalahan");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="max-w-lg space-y-6">
      <div className="flex items-center gap-3">
        <Link href="/businesses" className="text-gray-500 hover:text-gray-700">
          <ArrowLeft className="w-5 h-5" />
        </Link>
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Bisnis Baru</h1>
          <p className="text-gray-500 text-sm mt-1">Tambah unit bisnis baru</p>
        </div>
      </div>

      <form onSubmit={handleSubmit} className="bg-white rounded-xl border border-gray-200 p-6 space-y-4">
        {error && (
          <div className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-lg text-sm">
            {error}
          </div>
        )}

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Nama Bisnis *</label>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:border-transparent"
            placeholder="Contoh: Minimarket Jaya"
            required
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Jenis Bisnis</label>
          <select
            value={businessType}
            onChange={(e) => setBusinessType(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:border-transparent"
          >
            {businessTypes.map((t) => (
              <option key={t.value} value={t.value}>
                {t.label}
              </option>
            ))}
          </select>
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Deskripsi</label>
          <textarea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            rows={3}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:border-transparent resize-none"
            placeholder="Deskripsi singkat bisnis (opsional)"
          />
        </div>

        <button
          type="submit"
          disabled={loading}
          className="w-full flex items-center justify-center gap-2 bg-emerald-600 text-white py-2.5 rounded-lg font-medium hover:bg-emerald-700 disabled:opacity-50 transition-colors"
        >
          <Save className="w-4 h-4" />
          {loading ? "Menyimpan..." : "Simpan Bisnis"}
        </button>
      </form>
    </div>
  );
}
