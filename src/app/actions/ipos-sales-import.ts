"use server";

import "server-only";
import { createHash, randomUUID } from "node:crypto";
import { createAdminClient } from "@/lib/supabase/admin";
import { createClient } from "@/lib/supabase/server";
import { getProfile } from "@/lib/auth/session";
import { parseIposSalesWorkbook } from "@/lib/ipos-sales/parser";
import { projectIposSalesBatch } from "@/lib/ipos-sales/ui-payload";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_BYTES = 25 * 1024 * 1024;
type Json = Record<string, unknown>;

function isRecord(value: unknown): value is Json { return Boolean(value) && typeof value === "object" && !Array.isArray(value); }
async function permitted() {
  const profile = await getProfile();
  return profile && (profile.role === "OWNER" || profile.role === "ADMIN") ? profile : null;
}
function friendlyError(error: { code?: string | null; message?: string | null } | null) {
  const message = error?.message ?? "";
  if (error?.code === "42501" || message.includes("IPOS_SALES_IMPORT_UNAUTHORIZED")) return "Hanya OWNER atau ADMIN yang dapat mengelola import penjualan iPos.";
  if (message.includes("IPOS_SALES_IMPORT_POSTED_OPNAME_CONFLICT")) return "Ada penjualan iPos yang beririsan dengan opname yang sudah diposting. Laporan belum diimport agar stok tetap akurat.";
  if (message.includes("IPOS_SALES_DUPLICATE_TRANSACTION")) return "Data berubah sejak pemeriksaan terakhir. Lakukan Cek Ulang sebelum mencoba import kembali.";
  if (message.includes("IPOS_SALES_IMPORT_NOT_READY") || message.includes("IPOS_SALES_IMPORT_SKU_UNRESOLVED") || message.includes("IPOS_SALES_STOCK_INSUFFICIENT")) return "Data berubah sejak pemeriksaan terakhir. Lakukan Cek Ulang sebelum mencoba import kembali.";
  if (message.includes("IPOS_SALES_IMPORT_BATCH_NOT_RECHECKABLE")) return "Laporan ini sudah selesai diproses atau tidak dapat diperiksa ulang.";
  if (message.includes("IPOS_SALES_IMPORT_STOCK_AUTHORITY")) return "Stok Quena belum siap menerima laporan ini. Periksa kesiapan stok terlebih dahulu.";
  if (message.includes("IPOS_SALES_IMPORT_OUTLET_UNAVAILABLE")) return "Outlet aktif belum siap untuk import penjualan.";
  return "Permintaan belum dapat diproses. Muat ulang halaman dan lakukan Cek Ulang.";
}

async function readBatch(batchId: string) {
  const supabase = await createClient();
  const result = await supabase.rpc("ipos_sales_import_batch_read", { p_batch_id: batchId });
  return { ...result, data: result.data ? projectIposSalesBatch(result.data) : null };
}

export async function uploadIposSales(formData: FormData) {
  const profile = await permitted();
  if (!profile) return { error: "Hanya OWNER atau ADMIN yang dapat mengelola import penjualan iPos." };
  const entry = formData.get("file");
  if (!(entry instanceof File) || entry.size === 0) return { error: "Pilih file laporan Penjualan Detail iPos terlebih dahulu." };
  if (!/\.(xls|xlsx)$/i.test(entry.name)) return { error: "Format file belum didukung. Pilih file .xls atau .xlsx." };
  if (entry.size > MAX_BYTES) return { error: "Ukuran file maksimal 25 MB." };
  const filename = entry.name.split(/[\\/]/).pop()?.replace(/[\u0000-\u001f\u007f]/g, "").slice(0, 240) || "laporan-ipos.xls";
  let bytes: Uint8Array;
  let parsed;
  try {
    bytes = new Uint8Array(await entry.arrayBuffer());
    parsed = parseIposSalesWorkbook(bytes);
  }
  catch (error) {
    const message = error instanceof Error ? error.message : "";
    if (message.includes("judul laporan") || message.includes("sheet bernama") || message.includes("periode laporan")) return { error: "File bukan laporan Penjualan Detail iPos." };
    if (message.includes("Format") || message.includes("berupa laporan Excel")) return { error: "Format file belum didukung." };
    return { error: "Laporan tidak dapat dibaca. Pastikan file berasal dari ekspor Penjualan Detail iPos." };
  }
  const hash = createHash("sha256").update(bytes).digest("hex");
  const admin = createAdminClient();
  const { data, error } = await admin.rpc("ipos_sales_import_upload", {
    p_actor_id: profile.id,
    p_upload_request_id: randomUUID(),
    p_original_filename: filename,
    p_file_sha256: hash,
    p_payload: parsed,
  });
  if (error || !isRecord(data)) return { error: friendlyError(error) };
  const batchId = typeof data.batchId === "string" ? data.batchId : "";
  if (!UUID.test(batchId)) return { error: "Laporan belum dapat disimpan. Coba kembali." };
  if (data.ok === true) {
    const supabase = await createClient();
    const { error: recheckError } = await supabase.rpc("ipos_sales_import_recheck", { p_batch_id: batchId, p_request_id: randomUUID() });
    if (recheckError) return { error: friendlyError(recheckError), batchId };
  }
  const result = await readBatch(batchId);
  if (result.error || !result.data) return { error: "Laporan tersimpan, tetapi ringkasannya belum dapat dimuat.", batchId };
  return { batch: result.data, batchId, duplicateFile: data.ok !== true };
}

export async function recheckIposSales(batchId: string) {
  if (!await permitted() || !UUID.test(batchId)) return { error: "Akses atau laporan tidak valid." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("ipos_sales_import_recheck", { p_batch_id: batchId, p_request_id: randomUUID() });
  if (error) return { error: friendlyError(error) };
  const result = await supabase.rpc("ipos_sales_import_batch_read", { p_batch_id: batchId });
  if (result.error || !result.data) return { error: "Pemeriksaan diperbarui, tetapi ringkasan belum dapat dimuat." };
  return { batch: projectIposSalesBatch(result.data), batchId };
}

export async function commitIposSales(batchId: string, revision: number) {
  if (!await permitted() || !UUID.test(batchId) || !Number.isSafeInteger(revision) || revision < 1) return { error: "Akses atau laporan tidak valid." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("ipos_sales_import_commit", {
    p_batch_id: batchId, p_expected_revision: revision, p_request_id: randomUUID(),
  });
  if (error) return { error: friendlyError(error) };
  if (!isRecord(data) || data.status !== "COMMITTED") return { error: "Import belum dapat diselesaikan. Lakukan Cek Ulang." };
  const result = await supabase.rpc("ipos_sales_import_batch_read", { p_batch_id: batchId });
  return { success: true, batch: result.data ? projectIposSalesBatch(result.data) : null, batchId, result: data };
}
