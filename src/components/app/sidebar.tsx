"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState } from "react";
import type { UserRole } from "@/lib/auth/roles";
import { canAccessSection, type AppSection } from "@/lib/auth/roles";
import { logout } from "@/app/actions/auth";
import { sidebarTreeForPath, type SidebarTreeId } from "@/lib/navigation/sidebar-tree";

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

function SidebarTreeGroup({
  id,
  label,
  icon,
  active,
  pathname,
  links,
}: {
  id: SidebarTreeId;
  label: string;
  icon: string;
  active: boolean;
  pathname: string;
  links: { label: string; href: string; active: boolean }[];
}) {
  const [expanded, setExpanded] = useState(sidebarTreeForPath(pathname) === id);
  const childrenId = `nav-${id}-children`;

  return <div className="nav-tree-group">
    <button type="button" className={`nav-item nav-tree-toggle${active ? " nav-active" : ""}`} aria-expanded={expanded} aria-controls={childrenId} onClick={() => setExpanded((current) => !current)}>
      <span className="nav-icon" aria-hidden="true">{icon}</span>{label}<span className={`nav-chevron${expanded ? " nav-chevron-open" : ""}`} aria-hidden="true" />
    </button>
    <div id={childrenId} className="nav-sublist" aria-label={`Menu ${label}`} hidden={!expanded}>
      {links.map((link) => <Link key={link.href} href={link.href} className={`nav-item nav-subitem${link.active ? " nav-active" : ""}`} aria-current={link.active ? "page" : undefined}>{link.label}</Link>)}
    </div>
  </div>;
}

export function Sidebar({ role, name }: { role: UserRole; name: string | null }) {
  const pathname = usePathname();
  const routeTree = sidebarTreeForPath(pathname);

  const purchasingLinks = [
    { label: "Barang Masuk", href: "/pembelian/barang-masuk", visible: canAccessSection(role, "pembelian") },
    { label: "Retur Supplier", href: "/pembelian/retur-supplier", visible: canAccessSection(role, "pembelian") },
    { label: "Tempo Supplier", href: "/tempo-supplier", visible: canAccessSection(role, "tempo-supplier") },
    { label: "Supplier", href: "/pembelian/supplier", visible: canAccessSection(role, "pembelian") },
  ].filter((link) => link.visible);

  return (
    <aside className="sidebar">
      <Link href="/dashboard" className="brand"><span className="brand-mark">Q</span><span>quena<span className="brand-light">mart</span><small>RETAIL MANAGEMENT</small></span></Link>
      <div className="nav-label">MENU UTAMA</div>
      <nav className="nav-list" aria-label="Menu utama">
        {navigation.filter((item) => canAccessSection(role, item.section)).map((item) => {
          const isPurchasing = item.label === "Pembelian";
          const isTransactionTree = item.label === "Transaksi" && (role === "OWNER" || role === "ADMIN");
          const active = isPurchasing
            ? routeTree === "pembelian"
            : pathname === item.href || (item.href !== "/dashboard" && pathname.startsWith(`${item.href}/`));
          if (isPurchasing) {
            return <SidebarTreeGroup key={`pembelian:${pathname}`} id="pembelian" label={item.label} icon={item.icon} active={active} pathname={pathname} links={purchasingLinks.map((link) => ({
              ...link,
              active: pathname === link.href || pathname.startsWith(`${link.href}/`),
            }))} />;
          }
          if (isTransactionTree) {
            const historyActive = pathname === "/transaksi" || (pathname.startsWith("/transaksi/") && !pathname.startsWith("/transaksi/import-ipos"));
            const importActive = pathname === "/transaksi/import-ipos" || pathname.startsWith("/transaksi/import-ipos/");
            return <SidebarTreeGroup key={`transaksi:${pathname}`} id="transaksi" label={item.label} icon={item.icon} active={active} pathname={pathname} links={[
              { label: "Riwayat Transaksi", href: "/transaksi", active: historyActive },
              { label: "Import Penjualan iPos", href: "/transaksi/import-ipos", active: importActive },
            ]} />;
          }
          return <div key={item.href}>
            <Link href={item.href} className={`nav-item${active ? " nav-active" : ""}`} aria-current={pathname === item.href ? "page" : undefined}><span className="nav-icon" aria-hidden="true">{item.icon}</span>{item.label}{item.label === "Kasir" && <span className="nav-shortcut">F2</span>}</Link>
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
