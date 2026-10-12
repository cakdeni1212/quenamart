import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { NativeProductForm } from "@/components/products/native-product-form";

export default async function NativeProductCreatePage() {
  const profile = await getProfile();
  if (!profile) redirect("/login");
  if (profile.role !== "OWNER" && profile.role !== "ADMIN") redirect("/dashboard");

  const supabase = await createClient();
  const { data } = await supabase.from("products").select("category_label,unit_label,brand_label").limit(1000);
  const distinct = (key: "category_label" | "unit_label" | "brand_label") =>
    [...new Set((data ?? []).map((row) => row[key]).filter((value): value is string => Boolean(value?.trim())))].sort((a, b) => a.localeCompare(b, "id"));

  return <main className="page-content native-product-page">
    <div className="eyebrow">KATALOG PRODUK</div>
    <div className="page-heading"><div><h1>Tambah Produk</h1><p>Tambahkan produk Quena Mart beserta harga jual outlet.</p></div></div>
    <NativeProductForm requestId={randomUUID()} categories={distinct("category_label")} units={distinct("unit_label")} brands={distinct("brand_label")} />
  </main>;
}
