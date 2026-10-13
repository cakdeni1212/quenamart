import { notFound, redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection, type AppSection } from "@/lib/auth/roles";

const labels: Record<string, { title: string; section: AppSection; description: string }> = {
  transaksi: { title: "Transaksi", section: "transaksi", description: "Riwayat dan pengelolaan transaksi penjualan." },
  stok: { title: "Stok", section: "stok", description: "Pemantauan persediaan dan pergerakan stok." },
  "audit-produk": { title: "Audit Produk", section: "audit-produk", description: "Pemeriksaan kelengkapan dan kondisi data produk." },
  pembelian: { title: "Pembelian", section: "pembelian", description: "Pencatatan pembelian barang dari supplier." },
  pengeluaran: { title: "Pengeluaran", section: "expenses", description: "Catat dan pantau biaya operasional Quena Mart." },
  "tempo-supplier": { title: "Tempo Supplier", section: "tempo-supplier", description: "Pemantauan tagihan dan pembayaran supplier." },
  member: { title: "Member", section: "member", description: "Data pelanggan dan aktivitas keanggotaan." },
  laporan: { title: "Laporan", section: "laporan", description: "Ringkasan dan analisis performa toko." },
  pengaturan: { title: "Pengaturan", section: "pengaturan", description: "Konfigurasi ruang kerja dan akses tim." },
};

interface SectionPageProps {
  params: Promise<{ section: string }>;
}

export default async function SectionPage({ params }: SectionPageProps) {
  const { section } = await params;
  const item = labels[section];
  if (!item) notFound();
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, item.section)) redirect("/dashboard");
  return <main className="page-content"><div className="eyebrow">RUANG KERJA</div><h1>{item.title}</h1><p className="page-lead">{item.description}</p><div className="surface-card module-placeholder"><span>✳</span><strong>Modul {item.title.toLowerCase()} sedang disiapkan</strong><p>Halaman ini telah masuk dalam kerangka aplikasi Quena Mart.</p></div></main>;
}
