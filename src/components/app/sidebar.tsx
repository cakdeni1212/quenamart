"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { UserRole } from "@/lib/auth/roles";
import { canAccessSection, type AppSection } from "@/lib/auth/roles";
import { logout } from "@/app/actions/auth";

const navigation: { label: string; href: string; section: AppSection; icon: string }[] = [
  { label: "Dashboard", href: "/dashboard", section: "dashboard", icon: "⌂" },
  { label: "Kasir", href: "/kasir", section: "kasir", icon: "▣" },
  { label: "Transaksi", href: "/transaksi", section: "transaksi", icon: "↗" },
  { label: "Produk", href: "/produk", section: "produk", icon: "◫" },
  { label: "Stok", href: "/stok", section: "stok", icon: "▤" },
  { label: "Audit Produk", href: "/audit-produk", section: "audit-produk", icon: "⌕" },
  { label: "Persiapan HPP Awal", href: "/hpp-awal", section: "hpp-awal", icon: "◉" },
  { label: "Pembelian", href: "/pembelian/barang-masuk", section: "pembelian", icon: "＋" },
  { label: "Pengeluaran", href: "/pengeluaran", section: "expenses", icon: "−" },
  { label: "Member", href: "/member", section: "member", icon: "♧" },
  { label: "Laporan", href: "/laporan", section: "laporan", icon: "▥" },
  { label: "Pengaturan", href: "/pengaturan", section: "pengaturan", icon: "⚙" },
  { label: "Import iPos", href: "/import-ipos", section: "import-ipos", icon: "⇧" },
];

const roleLabel: Record<UserRole, string> = { OWNER: "Owner", ADMIN: "Admin", KASIR: "Kasir", GUDANG: "Gudang" };

export function Sidebar({ role, name }: { role: UserRole; name: string | null }) {
  const pathname = usePathname();
  return (
    <aside className="sidebar">
      <Link href="/dashboard" className="brand"><span className="brand-mark">Q</span><span>quena<span className="brand-light">mart</span><small>RETAIL MANAGEMENT</small></span></Link>
      <div className="nav-label">MENU UTAMA</div>
      <nav className="nav-list" aria-label="Menu utama">
        {navigation.filter((item) => canAccessSection(role, item.section)).map((item) => {
          const purchasing = item.label === "Pembelian";
          const active = purchasing
            ? pathname.startsWith("/pembelian") || pathname.startsWith("/tempo-supplier")
            : pathname === item.href || (item.href !== "/dashboard" && pathname.startsWith(`${item.href}/`));
          const purchasingLinks = [
            { label: "Barang Masuk", href: "/pembelian/barang-masuk", visible: canAccessSection(role, "pembelian") },
            { label: "Retur Supplier", href: "/pembelian/retur-supplier", visible: canAccessSection(role, "pembelian") },
            { label: "Tempo Supplier", href: "/tempo-supplier", visible: canAccessSection(role, "tempo-supplier") },
            { label: "Supplier", href: "/pembelian/supplier", visible: canAccessSection(role, "pembelian") },
          ];
          return <div key={item.href} className={purchasing ? "nav-purchasing-group" : undefined}>
            <Link href={item.href} className={`nav-item${active ? " nav-active" : ""}`} aria-current={pathname === item.href ? "page" : undefined}><span className="nav-icon" aria-hidden="true">{item.icon}</span>{item.label}{item.label === "Kasir" && <span className="nav-shortcut">F2</span>}</Link>
            {purchasing && <div className="nav-sublist" aria-label="Menu Pembelian">
              {purchasingLinks.filter((link) => link.visible).map((link) => {
                const current = pathname === link.href || pathname.startsWith(`${link.href}/`);
                return <Link key={link.href} href={link.href} className={`nav-item nav-subitem${current ? " nav-active" : ""}`} aria-current={current ? "page" : undefined}>{link.label}</Link>;
              })}
            </div>}
            {item.label === "Transaksi" && (role === "OWNER" || role === "ADMIN") && <div className="nav-sublist" aria-label="Menu Transaksi">
              <Link href="/transaksi" className={`nav-item nav-subitem${pathname === "/transaksi" || pathname.startsWith("/transaksi/") && !pathname.startsWith("/transaksi/import-ipos") ? " nav-active" : ""}`} aria-current={pathname === "/transaksi" ? "page" : undefined}>Riwayat Transaksi</Link>
              <Link href="/transaksi/import-ipos" className={`nav-item nav-subitem${pathname.startsWith("/transaksi/import-ipos") ? " nav-active" : ""}`} aria-current={pathname.startsWith("/transaksi/import-ipos") ? "page" : undefined}>Import Penjualan iPos</Link>
            </div>}
            {item.label === "Pengaturan" && canAccessSection(role, "akun") && <div className="nav-sublist" aria-label="Menu Pengaturan">
              <Link href="/pengaturan/akun" className={`nav-item nav-subitem${pathname.startsWith("/pengaturan/akun") ? " nav-active" : ""}`} aria-current={pathname.startsWith("/pengaturan/akun") ? "page" : undefined}>Akun &amp; Akses</Link>
            </div>}
          </div>;
        })}
      </nav>
      <div className="sidebar-bottom">
        <div className="help-card"><span className="help-badge">?</span><strong>Butuh bantuan?</strong><span>Hubungi tim Quena Mart</span></div>
        <div className="user-row"><div className="avatar">{(name?.[0] || role[0]).toUpperCase()}</div><div className="user-meta"><strong>{name || roleLabel[role]}</strong><span>{roleLabel[role]}</span></div><form action={logout}><button className="logout-button" aria-label="Keluar" title="Keluar">↪</button></form></div>
      </div>
    </aside>
  );
}
