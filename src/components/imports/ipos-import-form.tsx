"use client";

import { useMemo, useRef, useState, useSyncExternalStore, type DragEvent } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";

const BUCKET = "quena-ipos-imports";
const OUTLET_CODE = "QUENA-MART-1";
const XLSX_MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
const MAX_FILE_SIZE = 25 * 1024 * 1024;
const PENDING_UPLOAD_KEY = "quena-mart:ipos-pending-upload";
const PENDING_UPLOAD_EVENT = "quena-ipos-pending-upload-change";
let pendingUploadMemory: string | null = null;

type UploadedFile = {
  fileName: string;
  storagePath: string;
  uploaderId: string;
};

type CreatedRequest = {
  id: string;
  state: string | null;
  createdAt: string | null;
  fileName: string;
};

function validateFile(file: File | null) {
  if (!file) return "Pilih file XLSX terlebih dahulu.";
  if (!file.name.toLowerCase().endsWith(".xlsx")) return "Format file harus .xlsx.";
  if (file.size > MAX_FILE_SIZE) return "Ukuran file melebihi batas 25 MiB.";
  return null;
}

function describeError(message: string) {
  const normalized = message.toLowerCase();
  if (normalized.includes("not authorized") || normalized.includes("permission") || normalized.includes("row-level security")) {
    return "Akun ini tidak memiliki izin untuk membuat permintaan import.";
  }
  if (normalized.includes("jwt") || normalized.includes("session") || normalized.includes("auth session missing")) {
    return "Sesi login tidak ditemukan atau sudah berakhir. Masuk kembali, lalu coba lagi.";
  }
  return message;
}

function formatSize(size: number) {
  return `${(size / (1024 * 1024)).toFixed(2)} MiB`;
}

function savePendingUpload(upload: UploadedFile) {
  pendingUploadMemory = JSON.stringify(upload);
  try {
    sessionStorage.setItem(PENDING_UPLOAD_KEY, pendingUploadMemory);
  } catch {
    // The in-memory retry remains available if browser storage is unavailable.
  }
  window.dispatchEvent(new Event(PENDING_UPLOAD_EVENT));
}

function clearPendingUpload() {
  pendingUploadMemory = null;
  try {
    sessionStorage.removeItem(PENDING_UPLOAD_KEY);
  } catch {
    // A stale local retry marker must not change a successful database result.
  }
  window.dispatchEvent(new Event(PENDING_UPLOAD_EVENT));
}

function subscribeToPendingUpload(callback: () => void) {
  window.addEventListener(PENDING_UPLOAD_EVENT, callback);
  window.addEventListener("storage", callback);
  return () => {
    window.removeEventListener(PENDING_UPLOAD_EVENT, callback);
    window.removeEventListener("storage", callback);
  };
}

function getPendingUploadSnapshot() {
  try {
    return sessionStorage.getItem(PENDING_UPLOAD_KEY) ?? pendingUploadMemory;
  } catch {
    return pendingUploadMemory;
  }
}

function getServerPendingUploadSnapshot() {
  return null;
}

function parsePendingUpload(raw: string | null): UploadedFile | null {
  if (!raw) return null;
  try {
    const pending = JSON.parse(raw) as Partial<UploadedFile>;
    if (
      typeof pending.fileName === "string"
      && typeof pending.storagePath === "string"
      && typeof pending.uploaderId === "string"
    ) {
      return {
        fileName: pending.fileName,
        storagePath: pending.storagePath,
        uploaderId: pending.uploaderId,
      };
    }
  } catch {
    return null;
  }
  return null;
}

function statusLabel(state: string | null) {
  if (!state) return "Belum dapat dibaca";
  const labels: Record<string, string> = {
    QUEUED: "Menunggu diproses",
    PROCESSING: "Sedang diproses",
    COMPLETED: "Selesai",
    FAILED: "Gagal",
  };
  return `${labels[state] ?? state} (${state})`;
}

export function IposImportForm() {
  const inputRef = useRef<HTMLInputElement>(null);
  const pendingUploadRaw = useSyncExternalStore(
    subscribeToPendingUpload,
    getPendingUploadSnapshot,
    getServerPendingUploadSnapshot,
  );
  const uploadedFile = useMemo(() => parsePendingUpload(pendingUploadRaw), [pendingUploadRaw]);
  const [file, setFile] = useState<File | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [busyLabel, setBusyLabel] = useState("Mengunggah file...");
  const [dragActive, setDragActive] = useState(false);
  const [request, setRequest] = useState<CreatedRequest | null>(null);

  function chooseFile(nextFile: File | null) {
    if (uploadedFile) {
      setError("Buat atau pulihkan permintaan untuk file yang sudah diunggah sebelum memilih file lain.");
      return;
    }
    setError(null);
    setRequest(null);
    const validationError = validateFile(nextFile);
    if (validationError && nextFile) {
      setFile(null);
      setError(validationError);
      return;
    }
    setFile(nextFile);
  }

  async function createRequest(upload: UploadedFile, userId: string) {
    if (upload.uploaderId !== userId || !upload.storagePath.startsWith(`incoming/${userId}/`)) {
      setError("Sesi akun berubah. Masuk kembali dengan akun pengunggah untuk melanjutkan permintaan.");
      return;
    }

    const supabase = createClient();
    setBusy(true);
    setBusyLabel("Membuat permintaan import...");
    setError(null);

    try {
      // A previous RPC may have committed even if its response was interrupted.
      const { data: existing, error: existingError } = await supabase
        .from("ipos_import_requests")
        .select("id, state, created_at")
        .eq("storage_path", upload.storagePath)
        .maybeSingle();

      if (existingError) throw existingError;

      let requestId = existing?.id as string | undefined;
      if (!requestId) {
        const { data: outlet, error: outletError } = await supabase
          .from("outlets")
          .select("id")
          .eq("code", OUTLET_CODE)
          .eq("is_active", true)
          .single();

        if (outletError || !outlet?.id) {
          throw new Error(outletError?.message ?? "Outlet Quena Mart tidak ditemukan atau tidak aktif.");
        }

        const { data, error: requestError } = await supabase.rpc("request_ipos_import", {
          p_outlet_id: outlet.id,
          p_storage_path: upload.storagePath,
          p_original_filename: upload.fileName,
        });

        if (requestError) throw requestError;
        if (typeof data !== "string") throw new Error("Respons permintaan import tidak valid.");
        requestId = data;
      }

      const { data: requestData, error: readError } = await supabase
        .from("ipos_import_requests")
        .select("state, created_at")
        .eq("id", requestId)
        .maybeSingle();

      setRequest({
        id: requestId,
        state: readError ? null : (requestData?.state as string | undefined) ?? null,
        createdAt: readError ? null : (requestData?.created_at as string | undefined) ?? null,
        fileName: upload.fileName,
      });
      clearPendingUpload();
      if (readError || !requestData) {
        setError("Permintaan berhasil dibuat, tetapi statusnya belum dapat dibaca. Muat ulang halaman atau periksa kembali nanti.");
      }
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : "Terjadi kesalahan saat membuat permintaan import.";
      setError(describeError(message));
    } finally {
      setBusy(false);
    }
  }

  async function handleSubmit() {
    setError(null);

    if (uploadedFile) {
      setBusy(true);
      try {
        const supabase = createClient();
        const { data: { user }, error: authError } = await supabase.auth.getUser();
        if (authError || !user) {
          throw new Error("Sesi login tidak ditemukan atau sudah berakhir. Masuk kembali untuk membuat permintaan atas file yang sudah diunggah.");
        }
        await createRequest(uploadedFile, user.id);
      } catch (caught) {
        const message = caught instanceof Error ? caught.message : "Permintaan import gagal dibuat.";
        setError(describeError(message));
      } finally {
        setBusy(false);
      }
      return;
    }

    const validationError = validateFile(file);
    if (validationError) {
      setError(validationError);
      return;
    }

    const supabase = createClient();
    setBusy(true);
    setBusyLabel("Memeriksa sesi dan outlet...");
    try {
      const { data: { user }, error: authError } = await supabase.auth.getUser();
      if (authError || !user) {
        throw new Error("Sesi login tidak ditemukan atau sudah berakhir. Masuk kembali, lalu coba lagi.");
      }

      const { data: outlet, error: outletError } = await supabase
        .from("outlets")
        .select("id")
        .eq("code", OUTLET_CODE)
        .eq("is_active", true)
        .single();
      if (outletError || !outlet?.id) {
        throw new Error(outletError?.message ?? "Outlet Quena Mart tidak ditemukan atau tidak aktif.");
      }

      const storagePath = `incoming/${user.id}/${crypto.randomUUID()}.xlsx`;
      setBusyLabel("Mengunggah file asli...");
      const { error: uploadError } = await supabase.storage
        .from(BUCKET)
        .upload(storagePath, file!, { contentType: XLSX_MIME, upsert: false });

      if (uploadError) throw uploadError;

      const uploaded = { fileName: file!.name, storagePath, uploaderId: user.id };
      savePendingUpload(uploaded);
      await createRequest(uploaded, user.id);
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : "File gagal diunggah.";
      setError(describeError(message));
      setBusy(false);
    }
  }

  function onDrop(event: DragEvent<HTMLDivElement>) {
    event.preventDefault();
    setDragActive(false);
    chooseFile(event.dataTransfer.files[0] ?? null);
  }

  return (
    <div className="ipos-import-layout">
      <section className="surface-card ipos-import-card" aria-labelledby="ipos-upload-title">
        <div className="ipos-import-heading">
          <span className="ipos-import-icon" aria-hidden="true">⇧</span>
          <div>
            <h2 id="ipos-upload-title">Pilih file iPos</h2>
            <p>File asli iPos akan disimpan sebagai arsip. Pada tahap ini sistem hanya membuat permintaan import.</p>
          </div>
        </div>

        <div
          className={`ipos-dropzone${dragActive ? " ipos-dropzone-active" : ""}`}
          onDragEnter={(event) => { event.preventDefault(); setDragActive(true); }}
          onDragOver={(event) => event.preventDefault()}
          onDragLeave={(event) => { event.preventDefault(); setDragActive(false); }}
          onDrop={onDrop}
        >
          <input
            ref={inputRef}
            className="ipos-file-input"
            type="file"
            disabled={busy || Boolean(uploadedFile)}
            accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            aria-label="Pilih file XLSX iPos"
            onChange={(event) => {
              const nextFile = event.currentTarget.files?.[0] ?? null;
              event.currentTarget.value = "";
              chooseFile(nextFile);
            }}
          />
          <span className="ipos-file-icon" aria-hidden="true">▤</span>
          <strong>Tarik file XLSX ke sini</strong>
          <span>atau</span>
          <button className="ipos-choose-button" type="button" disabled={busy || Boolean(uploadedFile)} onClick={() => inputRef.current?.click()}>
            Pilih file
          </button>
          <small>Format .xlsx · Maksimal 25 MiB</small>
        </div>

        {file && (
          <div className="ipos-selected-file">
            <span className="ipos-selected-file-icon" aria-hidden="true">XLSX</span>
            <div className="ipos-selected-file-meta">
              <strong>{file.name}</strong>
              <span>{formatSize(file.size)}</span>
            </div>
            <button className="ipos-remove-file" type="button" disabled={busy} onClick={() => chooseFile(null)} aria-label="Hapus file pilihan">×</button>
          </div>
        )}

        {error && <div className={`ipos-message${request ? " ipos-message-info" : " ipos-message-error"}`} role="status">{error}</div>}

        <div className="ipos-import-actions">
          <button className="primary-button ipos-submit" type="button" disabled={busy || (!file && !uploadedFile)} onClick={handleSubmit}>
            {busy ? busyLabel : uploadedFile ? "Coba Buat Permintaan Lagi" : "Upload & Buat Import"}
          </button>
          <span>Produk dan stok belum diubah pada tahap ini.</span>
        </div>
      </section>

      {request && (
        <section className="surface-card ipos-success-card" aria-live="polite">
          <span className="ipos-success-mark" aria-hidden="true">✓</span>
          <div className="eyebrow">PERMINTAAN TERCATAT</div>
          <h2>File berhasil diunggah dan permintaan import dibuat.</h2>
          <p>File sudah tersimpan. Produk belum diproses atau diubah.</p>
          <dl className="ipos-request-details">
            <div><dt>Request ID</dt><dd>{request.id}</dd></div>
            <div><dt>File</dt><dd>{request.fileName}</dd></div>
            <div><dt>Status</dt><dd>{statusLabel(request.state)}</dd></div>
            <div><dt>Waktu permintaan</dt><dd>{request.createdAt ? new Date(request.createdAt).toLocaleString("id-ID") : "Belum tersedia"}</dd></div>
          </dl>
        </section>
      )}

      {uploadedFile && !request && (
        <section className="ipos-upload-warning" role="alert">
          <strong>File berhasil diunggah, tetapi permintaan import belum terkonfirmasi.</strong>
          <span>{uploadedFile.fileName} tetap tersimpan dengan aman dan belum diproses. Gunakan tombol di atas untuk mencoba membuat permintaan kembali. Jika sesi berakhir, masuk kembali dengan akun yang sama.</span>
          <Link href="/login">Masuk kembali</Link>
        </section>
      )}
    </div>
  );
}
