export const IPOS_SALES_MAX_FILE_BYTES = 25 * 1024 * 1024;

export function validateIposSalesUpload(filename: string, size: number): string | null {
  if (!/\.(xls|xlsx)$/i.test(filename)) return "Format file belum didukung. Pilih file .xls atau .xlsx.";
  if (!Number.isSafeInteger(size) || size <= 0) return "Pilih file laporan Penjualan Detail iPos terlebih dahulu.";
  if (size > IPOS_SALES_MAX_FILE_BYTES) return "Ukuran file maksimal 25 MB.";
  return null;
}
