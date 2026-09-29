import Link from "next/link";
import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { createClient } from "@/lib/supabase/server";

const labels: Record<string, string> = {
  MISSING_BARCODE: "Barcode kosong", MALFORMED_BARCODE: "Barcode tidak valid",
  ZERO_OR_MISSING_HPP: "HPP kosong / nol", SELLING_PRICE_BELOW_HPP: "Harga jual di bawah HPP",
  ZERO_STOCK: "Stok kosong", STOCK_AT_OR_BELOW_MINIMUM: "Stok pada / di bawah minimum",
  MISSING_RACK: "Rak belum diisi", DUPLICATE_PRODUCT_NAME: "Nama produk ganda",
};
export default async function AuditProdukPage() {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "audit-produk")) redirect("/dashboard");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("product_audit_overview");
  const counts = new Map<string, number>((data ?? []).map((item: { finding_code: string; finding_count: number }) => [item.finding_code, Number(item.finding_count)]));
  const manager = profile.role === "OWNER" || profile.role === "ADMIN";
  const codes = Object.keys(labels).filter((code) => manager || !["ZERO_OR_MISSING_HPP", "SELLING_PRICE_BELOW_HPP"].includes(code));
  return <main className="page-content"><div className="eyebrow">KUALITAS DATA</div><div className="page-heading"><div><h1>Audit Produk</h1><p>Temuan pada snapshot impor iPos terakhir yang tersimpan.</p></div><Link className="quiet-button" href="/produk">Lihat Produk →</Link></div>
    {error ? <div className="surface-card product-state product-error"><strong>Ringkasan audit belum dapat dimuat.</strong><span>Pastikan migration pembacaan workspace telah diterapkan dan coba lagi.</span></div> : <div className="audit-overview-grid">{codes.map((code) => <Link key={code} href={`/produk?issue=${code}`} className="surface-card audit-overview-card"><span className="audit-overview-icon">!</span><span className="audit-overview-label">{labels[code]}</span><strong>{(counts.get(code) ?? 0).toLocaleString("id-ID")}</strong><small>produk · lihat daftar →</small></Link>)}</div>}
    <p className="audit-caption">Satu produk dapat memiliki lebih dari satu temuan. Temuan HPP hanya tersedia untuk Owner dan Admin.</p>
  </main>;
}
