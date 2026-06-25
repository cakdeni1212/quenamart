"use client";

import { useState, useEffect } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import {
  LayoutDashboard,
  Building2,
  ArrowLeftRight,
  Tags,
  BarChart3,
  User,
  Store,
  LogOut,
  Menu,
  X,
  Plus,
  Boxes,
  Settings,
  Truck,
  Calendar,
  Shield,
} from "lucide-react";

interface SidebarProps {
  user: { id: string; name: string; email: string; role: string } | null;
}

const ownerLinks = [
  { href: "/", label: "Dashboard", icon: LayoutDashboard },
  { href: "/businesses", label: "Bisnis", icon: Building2 },
  { href: "/minimarket", label: "Minimarket", icon: Store },
  { href: "/transactions", label: "Transaksi", icon: ArrowLeftRight },
  { href: "/categories", label: "Kategori", icon: Tags },
  { href: "/suppliers", label: "Supplier/Sales", icon: Truck },
  { href: "/tempo", label: "Tempo", icon: Calendar },
  { href: "/assets", label: "Aset", icon: Boxes },
  { href: "/reports", label: "Laporan", icon: BarChart3 },
  { href: "/personal", label: "Pribadi", icon: User },
  { href: "/settings", label: "Pengaturan", icon: Settings },
];

const cashierLinks = [
  { href: "/minimarket", label: "Minimarket", icon: Store },
  { href: "/suppliers", label: "Supplier/Sales", icon: Truck },
  { href: "/tempo", label: "Tempo", icon: Calendar },
];

export function Sidebar({ user }: SidebarProps) {
  const pathname = usePathname();
  const [collapsed, setCollapsed] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);

  useEffect(() => {
    setMobileOpen(false);
  }, [pathname]);

  const isCashier = user?.role === "cashier";
  const links = isCashier ? cashierLinks : ownerLinks;

  const isActive = (href: string) => {
    if (href === "/") return pathname === "/";
    return pathname.startsWith(href);
  };

  async function handleLogout() {
    await fetch("/api/auth/logout", { method: "POST" });
    window.location.href = "/login";
  }

  return (
    <>
      <button
        onClick={() => setMobileOpen(true)}
        className="fixed top-4 left-4 z-50 lg:hidden p-2 rounded-lg bg-white border border-gray-200 shadow-sm"
      >
        <Menu className="w-5 h-5" />
      </button>

      {mobileOpen && (
        <div
          className="fixed inset-0 bg-black/50 z-40 lg:hidden"
          onClick={() => setMobileOpen(false)}
        />
      )}

      <aside
        className={`fixed inset-y-0 left-0 z-40 bg-white border-r border-gray-200 flex flex-col transition-all duration-300
          ${mobileOpen ? "translate-x-0" : "-translate-x-full"} 
          lg:translate-x-0 lg:static
          ${collapsed ? "w-20" : "w-64"}`}
      >
        <div className="flex items-center justify-between p-4 border-b border-gray-100">
          {!collapsed && (
            <Link href="/" className="text-lg font-bold text-emerald-700">
              QuenaMart
            </Link>
          )}
          <button
            onClick={() => setCollapsed(!collapsed)}
            className="p-1.5 rounded-lg hover:bg-gray-100 hidden lg:block"
          >
            {collapsed ? <Menu className="w-4 h-4" /> : <X className="w-4 h-4" />}
          </button>
          <button
            onClick={() => setMobileOpen(false)}
            className="p-1.5 rounded-lg hover:bg-gray-100 lg:hidden"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        <nav className="flex-1 p-3 space-y-1 overflow-y-auto">
          {links.map((link) => (
            <Link
              key={link.href}
              href={link.href}
              className={`flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-colors
                ${isActive(link.href)
                  ? "bg-emerald-50 text-emerald-700"
                  : "text-gray-600 hover:bg-gray-50 hover:text-gray-900"
                }`}
            >
              <link.icon className="w-5 h-5 flex-shrink-0" />
              {!collapsed && <span>{link.label}</span>}
            </Link>
          ))}
        </nav>

        {user && (
          <div className="p-3 border-t border-gray-100">
            <div className={`flex items-center gap-3 px-3 py-2 ${collapsed && "justify-center"}`}>
              <div className={`w-8 h-8 rounded-full flex items-center justify-center flex-shrink-0 ${isCashier ? "bg-amber-100" : "bg-emerald-100"}`}>
                {isCashier ? (
                  <Shield className="w-4 h-4 text-amber-600" />
                ) : (
                  <span className="text-sm font-semibold text-emerald-700">
                    {user.name.charAt(0).toUpperCase()}
                  </span>
                )}
              </div>
              {!collapsed && (
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium text-gray-900 truncate">{user.name}</p>
                  <p className="text-xs text-gray-500 truncate">
                    {isCashier ? "Kasir" : user.email}
                  </p>
                </div>
              )}
            </div>
            {!collapsed && (
              <button
                onClick={handleLogout}
                className="mt-2 w-full flex items-center gap-2 px-3 py-2 text-sm text-red-600 hover:bg-red-50 rounded-lg transition-colors"
              >
                <LogOut className="w-4 h-4" />
                Keluar
              </button>
            )}
          </div>
        )}
      </aside>
    </>
  );
}
