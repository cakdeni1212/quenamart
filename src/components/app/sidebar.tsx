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
  { label: "Pembelian", href: "/pembelian/barang-masuk", section: "pembelian", icon: "＋" },
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
          const active = pathname === item.href || (item.href !== "/dashboard" && pathname.startsWith(`${item.href}/`));
          return <Link key={item.href} href={item.href} className={`nav-item${active ? " nav-active" : ""}`}><span className="nav-icon" aria-hidden="true">{item.icon}</span>{item.label}{item.label === "Kasir" && <span className="nav-shortcut">F2</span>}</Link>;
        })}
      </nav>
      <div className="sidebar-bottom">
        <div className="help-card"><span className="help-badge">?</span><strong>Butuh bantuan?</strong><span>Hubungi tim Quena Mart</span></div>
        <div className="user-row"><div className="avatar">{(name?.[0] || role[0]).toUpperCase()}</div><div className="user-meta"><strong>{name || roleLabel[role]}</strong><span>{roleLabel[role]}</span></div><form action={logout}><button className="logout-button" aria-label="Keluar" title="Keluar">↪</button></form></div>
      </div>
    </aside>
  );
}
