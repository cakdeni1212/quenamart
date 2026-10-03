import { notFound, redirect } from "next/navigation";
import Link from "next/link";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { createClient } from "@/lib/supabase/server";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const STATUS_LABEL: Record<string, string> = {
  COUNTING: "Menghitung",
  REVIEW: "Menunggu posting",
  POSTED: "Selesai",
  CANCELLED: "Dibatalkan",
};

export default async function StockOpnameDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "stok")) redirect("/dashboard");
  const { id } = await params;
  if (!UUID_PATTERN.test(id)) notFound();

  const supabase = await createClient();
  const { data: session, error } = await supabase
    .from("stock_opname_sessions")
    .select("id, scope_type, status, created_at, outlets(name)")
    .eq("id", id)
    .maybeSingle();
  if (error) {
    console.error("[stock-opname-detail] session read failed", {
      operation: "stock_opname_session_detail",
      code: error.code?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 80),
      message: error.message.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240),
    });
    return <main className="page-content stock-opname-page"><div className="surface-card product-state product-error" role="alert"><strong>Detail opname belum dapat dimuat.</strong><span>Coba muat ulang halaman.</span></div></main>;
  }
  if (!session) notFound();

  const { count: itemCount, error: countError } = await supabase
    .from("stock_opname_items")
    .select("id", { count: "exact", head: true })
    .eq("session_id", id);
  if (countError) console.error("[stock-opname-detail] item count failed", {
    operation: "stock_opname_item_count",
    code: countError.code?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 80),
    message: countError.message.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240),
  });
  const row = session as unknown as {
    id: string;
    scope_type: "FULL" | "PARTIAL";
    status: keyof typeof STATUS_LABEL;
    created_at: string;
    outlets: { name: string } | null;
  };

  return <main className="page-content stock-opname-page">
    <Link className="stock-opname-back" href="/stok/opname">← Kembali ke daftar opname</Link>
    <div className="eyebrow">PERSEDIAAN OUTLET · BACA SAJA</div>
    <div className="page-heading stock-opname-heading"><div><h1>Opname #{id.slice(0, 8).toUpperCase()}</h1><p>Sesi opname berhasil dibuat. Pencatatan fisik belum tersedia pada checkpoint ini.</p></div><span className="stock-readonly-badge">Baca saja</span></div>
    <dl className="surface-card stock-opname-detail-grid">
      <div><dt>Outlet</dt><dd>{row.outlets?.name ?? "Outlet"}</dd></div>
      <div><dt>Ruang lingkup</dt><dd>{row.scope_type === "FULL" ? "Penuh" : "Sebagian"}</dd></div>
      <div><dt>Status</dt><dd>{STATUS_LABEL[row.status] ?? row.status}</dd></div>
      <div><dt>Dibuat</dt><dd><time dateTime={row.created_at}>{new Intl.DateTimeFormat("id-ID", { dateStyle: "medium", timeStyle: "short" }).format(new Date(row.created_at))}</time></dd></div>
      <div><dt>Jumlah produk dalam sesi</dt><dd>{countError ? "Belum dapat dimuat" : (itemCount ?? 0).toLocaleString("id-ID")}</dd></div>
    </dl>
    <p className="stock-opname-hint">Sesi dibuat melalui alur operasi stok resmi. Halaman ini belum menyediakan tindakan hitung atau perubahan stok.</p>
  </main>;
}
