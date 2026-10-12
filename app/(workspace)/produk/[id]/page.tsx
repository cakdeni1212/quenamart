import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { createClient } from "@/lib/supabase/server";

export default async function ProductDetailPage({ params, searchParams }: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ created?: string }>;
}) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "produk")) redirect("/dashboard");
  const [{ id }, query] = await Promise.all([params, searchParams]);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("product_workspace_detail", { p_product_id: id });
  if (error) return <main className="page-content"><div className="surface-card product-state product-error">Detail produk belum dapat dimuat. Coba kembali nanti.</div></main>;
  const item = (data ?? [])[0];
  if (!item) notFound();
  return <main className="page-content">
    <Link className="quiet-button" href="/produk">← Kembali ke produk</Link>
    {query.created === "1" && <div className="native-product-success" role="status">Produk berhasil ditambahkan.</div>}
    <div className="eyebrow" style={{ marginTop: 24 }}>DETAIL PRODUK · BACA SAJA</div>
    <h1>{item.name}</h1><p className="page-lead">Informasi produk dan harga jual outlet aktif.</p>
    <dl className="surface-card product-detail-grid">{([ ["SKU", item.sku], ["Barcode aktif", item.barcode ?? "—"], ["Kategori", item.category_label ?? "—"], ["Harga jual", item.selling_price ?? "—"], ...(profile.role === "OWNER" || profile.role === "ADMIN" ? [["HPP", item.hpp ?? "—"]] : []), ["Stok", item.quantity ?? "—"], ["Stok minimum", item.minimum_quantity ?? "—"], ["Rak", item.rack_label ?? "—"]] as [string, string | number][]).map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl>
    <h2 className="product-detail-subhead">Indikator audit</h2>
    <div className="audit-badges">{item.finding_codes.length ? item.finding_codes.map((code: string) => <Link className="audit-badge" key={code} href={`/produk?issue=${code}`}>{code}</Link>) : <span className="audit-ok">Tidak ada temuan terbuka</span>}</div>
  </main>;
}
