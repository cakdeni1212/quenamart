import Link from "next/link";
import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { createClient } from "@/lib/supabase/server";

const issues: Record<string, string> = {
  MISSING_BARCODE: "Barcode kosong", MALFORMED_BARCODE: "Barcode tidak valid",
  ZERO_OR_MISSING_HPP: "HPP kosong / nol", SELLING_PRICE_BELOW_HPP: "Harga jual di bawah HPP",
  ZERO_STOCK: "Stok kosong", STOCK_AT_OR_BELOW_MINIMUM: "Stok pada / di bawah minimum",
  MISSING_RACK: "Rak belum diisi", DUPLICATE_PRODUCT_NAME: "Nama produk ganda",
};
const issueFields: Record<string, string> = {
  MISSING_BARCODE: "barcode", MALFORMED_BARCODE: "barcode",
  ZERO_OR_MISSING_HPP: "hpp", SELLING_PRICE_BELOW_HPP: "selling_price",
  ZERO_STOCK: "quantity", STOCK_AT_OR_BELOW_MINIMUM: "minimum_quantity",
  MISSING_RACK: "rack_label", DUPLICATE_PRODUCT_NAME: "name",
};
type Search = { q?: string; category?: string; rack?: string; issue?: string; clear?: string; page?: string };
type Product = { product_id: string; sku: string; name: string; category_label: string | null; barcode: string | null; selling_price: number | null; hpp: number | null; quantity: number | null; minimum_quantity: number | null; rack_label: string | null; finding_codes: string[]; total_count: number };
const rupiah = (value: number | null) => value == null ? "—" : new Intl.NumberFormat("id-ID", { style: "currency", currency: "IDR", maximumFractionDigits: 0 }).format(value);

export default async function ProdukPage({ searchParams }: { searchParams: Promise<Search> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "produk")) redirect("/dashboard");
  const params = await searchParams;
  const page = Math.max(1, Number(params.page) || 1);
  const issue = params.issue && params.issue !== "NONE" ? params.issue : null;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("product_workspace_list", {
    p_search: params.q?.trim() || null, p_category: params.category?.trim() || null,
    p_rack: params.rack?.trim() || null, p_finding: issue, p_no_problems: params.issue === "NONE",
    p_page: page, p_page_size: 25,
  });
  const rows = (data ?? []) as Product[];
  const total = rows[0]?.total_count ?? 0;
  const pages = Math.max(1, Math.ceil(total / 25));
  const isManager = profile.role === "OWNER" || profile.role === "ADMIN";
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) if (key !== "page" && value) query.set(key, value);
  const hrefForPage = (n: number) => `/produk?${new URLSearchParams([...query.entries(), ["page", String(n)]]).toString()}`;
  return <main className="page-content">
    <div className="eyebrow">KATALOG & INVENTARIS</div><div className="page-heading"><div><h1>Produk</h1><p>Data produk ternormalisasi dari snapshot iPos terbaru.</p></div><Link className="quiet-button" href="/audit-produk">Ringkasan Audit →</Link></div>
    <form className="product-filters" action="/produk" method="get">
      <input name="q" defaultValue={params.q} placeholder="Cari nama, SKU, atau barcode" aria-label="Cari produk" />
      <input name="category" defaultValue={params.category} placeholder="Kategori (tepat)" aria-label="Filter kategori" />
      <input name="rack" defaultValue={params.rack} placeholder="Rak (tepat)" aria-label="Filter rak" />
      <select name="issue" defaultValue={params.issue ?? ""} aria-label="Filter masalah audit"><option value="">Semua kondisi</option><option value="NONE">Tanpa masalah</option>{Object.entries(issues).map(([code, label]) => <option key={code} value={code}>{label}</option>)}</select>
      <button type="submit">Terapkan</button>
      {(params.q || params.category || params.rack || params.issue) && <Link href="/produk">Hapus filter</Link>}
    </form>
    {error ? <div className="surface-card product-state product-error"><strong>Data produk belum dapat dimuat.</strong><span>{error.message.includes("product_workspace_list") ? "Fungsi pembacaan produk belum tersedia. Migration Phase 3A perlu ditinjau dan diterapkan oleh operator database." : "Terjadi kendala saat membaca data. Coba muat ulang halaman."}</span></div> : total === 0 ? <div className="surface-card product-state"><strong>{params.q || params.category || params.rack || params.issue ? "Produk tidak ditemukan" : "Belum ada data produk"}</strong><span>Ubah kata pencarian atau filter untuk melihat hasil.</span></div> : <>
      <div className="product-result-note">{total.toLocaleString("id-ID")} produk · Halaman {page} dari {pages}</div>
      <div className="surface-card product-table-wrap"><table className="product-table"><thead><tr><th>Produk</th><th>SKU</th><th>Barcode aktif</th><th>Kategori</th><th>Harga jual</th>{isManager && <th>HPP</th>}<th>Stok / Min.</th><th>Rak</th><th>Audit</th></tr></thead><tbody>{rows.map((product) => <tr key={product.product_id}>
        <td data-label="Produk"><Link className="product-name" href={`/produk/${product.product_id}`}>{product.name}</Link></td><td data-label="SKU">{product.sku}</td><td data-label="Barcode aktif">{product.barcode ?? "—"}</td><td data-label="Kategori">{product.category_label ?? "—"}</td><td data-label="Harga jual">{rupiah(product.selling_price)}</td>{isManager && <td data-label="HPP">{rupiah(product.hpp)}</td>}<td data-label="Stok / Min.">{product.quantity ?? "—"} / {product.minimum_quantity ?? "—"}</td><td data-label="Rak">{product.rack_label ?? "—"}</td><td data-label="Audit"><div className="audit-badges">{product.finding_codes.length ? product.finding_codes.map((code) => <Link key={code} href={`/audit-produk/${product.product_id}?finding=${code}&field=${issueFields[code]}`} className="audit-badge" title={issues[code] ?? code}>{issues[code] ?? code}</Link>) : <span className="audit-ok">Bersih</span>}</div></td>
      </tr>)}</tbody></table></div>
      <nav className="product-pagination" aria-label="Halaman produk"><span>{(page - 1) * 25 + 1}–{Math.min(page * 25, total)} dari {total}</span><div>{page > 1 && <Link href={hrefForPage(page - 1)}>← Sebelumnya</Link>}{page < pages && <Link href={hrefForPage(page + 1)}>Berikutnya →</Link>}</div></nav>
    </>}
  </main>;
}
