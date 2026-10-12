export const ROLES = ["OWNER", "ADMIN", "KASIR", "GUDANG"] as const;

export type UserRole = (typeof ROLES)[number];

export type Profile = {
  id: string;
  full_name: string | null;
  role: UserRole;
  is_active: boolean;
};

export type AppSection =
  | "dashboard"
  | "kasir"
  | "transaksi"
  | "produk"
  | "stok"
  | "audit-produk"
  | "hpp-awal"
  | "pembelian"
  | "tempo-supplier"
  | "member"
  | "laporan"
  | "pengaturan"
  | "import-ipos";

const sectionAccess: Record<AppSection, readonly UserRole[]> = {
  dashboard: ["OWNER", "ADMIN"],
  kasir: ["OWNER", "ADMIN", "KASIR"],
  transaksi: ["OWNER", "ADMIN", "KASIR"],
  produk: ["OWNER", "ADMIN", "GUDANG"],
  stok: ["OWNER", "ADMIN", "GUDANG"],
  "audit-produk": ["OWNER", "ADMIN", "GUDANG"],
  "hpp-awal": ["OWNER", "ADMIN"],
  pembelian: ["OWNER", "ADMIN", "GUDANG"],
  "tempo-supplier": ["OWNER", "ADMIN"],
  member: ["OWNER", "ADMIN", "KASIR"],
  laporan: ["OWNER", "ADMIN"],
  pengaturan: ["OWNER", "ADMIN"],
  "import-ipos": ["OWNER", "ADMIN", "GUDANG"],
};

export function canAccessSection(role: UserRole, section: AppSection) {
  return sectionAccess[section].includes(role);
}

export function landingPathForRole(role: UserRole) {
  if (role === "KASIR") return "/kasir";
  if (role === "GUDANG") return "/produk";
  return "/dashboard";
}

export function isUserRole(value: unknown): value is UserRole {
  return typeof value === "string" && ROLES.some((role) => role === value);
}
