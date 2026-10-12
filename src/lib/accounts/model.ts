export const ACCOUNT_ROLES = ["ADMIN", "KASIR", "GUDANG"] as const;
export type ManagedRole = (typeof ACCOUNT_ROLES)[number];
export type AccountInputValidation =
  | { ok: true; value: { fullName: string; email: string; role: ManagedRole } }
  | { ok: false; error: string };

export const ACCOUNT_ROLE_DESCRIPTIONS: Record<ManagedRole, string> = {
  ADMIN: "Operasional toko dan pengelolaan yang diizinkan.",
  KASIR: "Kasir, transaksi, dan struk.",
  GUDANG: "Stok, barang masuk, audit dan opname.",
};

export function normalizeAccountEmail(value: string) {
  return value.trim().toLowerCase();
}

export function validateAccountInput(input: {
  fullName: string;
  email: string;
  role: string;
}): AccountInputValidation {
  const fullName = input.fullName.trim();
  const email = normalizeAccountEmail(input.email);
  if (!fullName || fullName.length > 120) return { ok: false, error: "Masukkan nama lengkap (maksimal 120 karakter)." };
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return { ok: false, error: "Masukkan email yang valid." };
  }
  if (!ACCOUNT_ROLES.some((role) => role === input.role)) return { ok: false, error: "Pilih hak akses yang tersedia." };
  return { ok: true, value: { fullName, email, role: input.role as ManagedRole } };
}

export function accountErrorMessage(code: string) {
  const messages: Record<string, string> = {
    ACCOUNT_UNAUTHORIZED: "Anda tidak memiliki izin mengelola akun.",
    ACCOUNT_INPUT_INVALID: "Periksa kembali nama dan hak akses akun.",
    ACCOUNT_EMAIL_EXISTS: "Email sudah digunakan.",
    ACCOUNT_INVITATION_PENDING: "Undangan untuk email ini sedang diproses.",
    ACCOUNT_REQUEST_CONFLICT: "Permintaan akun berubah. Muat ulang lalu coba kembali.",
    ACCOUNT_SELF_CHANGE_FORBIDDEN: "Akun yang sedang digunakan tidak dapat diubah dari halaman ini.",
    ACCOUNT_LAST_ACTIVE_OWNER: "Akun ini adalah satu-satunya Owner aktif dan tidak dapat dinonaktifkan.",
    ACCOUNT_OWNER_REQUIRES_ELEVATED_FLOW: "Perubahan akun Owner memerlukan proses khusus.",
    ACCOUNT_NOT_FOUND: "Akun tidak ditemukan.",
  };
  return messages[code] ?? "Perubahan akun belum berhasil. Coba lagi atau hubungi administrator sistem.";
}

export function accountDateTime(value: string | null) {
  if (!value) return "Belum tersedia";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Belum tersedia";
  return new Intl.DateTimeFormat("id-ID", {
    dateStyle: "medium",
    timeStyle: "short",
    timeZone: "Asia/Jakarta",
  }).format(date);
}
