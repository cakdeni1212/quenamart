const SEND_COOLDOWN_MS = 30_000;
const sendReservations = new Map();

export function normalizeWhatsAppDestination(value) {
  if (typeof value !== "string" || value.length > 40) return null;
  const input = value.trim();
  if (!input || !/^\+?[0-9\s()-]+$/.test(input) || (input.match(/\+/g) ?? []).length > 1) return null;
  if (input.includes("+") && !input.startsWith("+")) return null;

  let digits = input.replace(/\D/g, "");
  if (!input.startsWith("+")) {
    if (digits.startsWith("00")) digits = digits.slice(2);
    else if (digits.startsWith("08")) digits = `62${digits.slice(1)}`;
    else if (digits.startsWith("0")) return null;
    else if (!digits.startsWith("62")) return null;
  }
  if (digits.length < 8 || digits.length > 15 || digits.startsWith("0")) return null;
  return { e164: `+${digits}`, chatId: `${digits}@c.us` };
}

function safeSendError(error) {
  const code = typeof error === "object" && error !== null && "code" in error ? error.code : null;
  if (code === "PROVIDER_NOT_CONNECTED") return "WhatsApp belum terhubung. Pesan tes tidak dikirim.";
  if (code === "PROVIDER_NOT_CONFIGURED") return "Konfigurasi WhatsApp server belum lengkap.";
  if (code === "PROVIDER_AUTH_FAILED") return "Autentikasi Quena ke WAHA gagal. Periksa konfigurasi server.";
  if (code === "INVALID_MESSAGE_REQUEST") return "WAHA menolak format pesan tes. Periksa nomor dan pesan.";
  if (code === "PROVIDER_RATE_LIMITED") return "WAHA membatasi permintaan sementara. Coba kembali nanti.";
  return "Pesan tes belum dapat dikirim. Periksa koneksi WAHA lalu coba kembali.";
}

/**
 * OWNER-only diagnostic send with a process-local duplicate guard. This does
 * not enqueue work and is not used for transactional/customer delivery.
 */
export async function sendManualWhatsAppTest({ role, actorId, destination, message, provider, now = Date.now() }) {
  if (role !== "OWNER" || typeof actorId !== "string" || !actorId) {
    return { ok: false, message: "Hanya Owner yang dapat mengirim pesan tes WhatsApp." };
  }
  const target = normalizeWhatsAppDestination(destination);
  if (!target) return { ok: false, message: "Masukkan nomor WhatsApp yang valid, misalnya 081234567890." };
  if (typeof message !== "string" || message.trim().length < 1 || message.trim().length > 500 || /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/.test(message)) {
    return { ok: false, message: "Pesan tes wajib diisi dan maksimal 500 karakter." };
  }

  for (const [id, reservedAt] of sendReservations) {
    if (now - reservedAt >= SEND_COOLDOWN_MS) sendReservations.delete(id);
  }
  if (sendReservations.has(actorId)) {
    return { ok: false, message: "Tunggu sebentar sebelum mengirim pesan tes berikutnya." };
  }
  // Reserve before the first await so rapid concurrent calls cannot both send.
  sendReservations.set(actorId, now);
  try {
    const transport = typeof provider === "function" ? provider() : provider;
    await transport.sendManualTestMessage(target.chatId, message.trim());
    return { ok: true, message: "Pesan tes berhasil dikirim ke WhatsApp." };
  } catch (error) {
    return { ok: false, message: safeSendError(error) };
  }
}
