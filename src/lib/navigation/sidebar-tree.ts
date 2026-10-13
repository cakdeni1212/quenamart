export type SidebarTreeId = "transaksi" | "pembelian";

function matchesRoute(pathname: string, route: string) {
  return pathname === route || pathname.startsWith(`${route}/`);
}

export function sidebarTreeForPath(pathname: string | null): SidebarTreeId | null {
  if (!pathname) return null;
  if (matchesRoute(pathname, "/transaksi")) return "transaksi";
  if (matchesRoute(pathname, "/pembelian") || matchesRoute(pathname, "/tempo-supplier")) return "pembelian";
  return null;
}
