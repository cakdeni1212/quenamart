"use server";

import { getProfile } from "@/lib/auth/session";
import { getWahaWhatsAppProvider } from "@/lib/notifications/waha-provider.server";
import { createClient } from "@/lib/supabase/server";
import type { WhatsAppProviderStatus } from "@/lib/notifications/waha-provider.shared";
import { sendManualWhatsAppTest } from "../../../services/whatsapp-waha/manual-test.mjs";

function emptyStatus(state: WhatsAppProviderStatus["connection_state"] = "NOT_CONFIGURED"): WhatsAppProviderStatus {
  return {
    outlet_id: "", provider_key: "QR_SESSION", connection_state: state,
    connected_number_masked: null, last_connected_at: null, last_disconnected_at: null,
    last_error_code: null, provider_available: false, qr_expires_at: null,
  };
}

export async function readWhatsAppProviderStatus() {
  const profile = await getProfile();
  if (!profile || !["OWNER", "ADMIN"].includes(profile.role)) return { ok: false as const, status: null, message: "Akses ditolak." };
  try {
    const status = await getWahaWhatsAppProvider().getConnectionStatus();
    return { ok: true as const, status: { ...status, outlet_id: "", provider_key: "QR_SESSION" as const } };
  } catch {
    return { ok: true as const, status: emptyStatus("ERROR") };
  }
}

export async function requestWhatsAppProviderCommand(command: "CONNECT" | "DISCONNECT" | "RECONNECT") {
  const profile = await getProfile();
  if (!profile || profile.role !== "OWNER") return { ok: false as const, message: "Hanya Owner yang dapat mengelola koneksi WhatsApp." };
  if (!["CONNECT", "DISCONNECT", "RECONNECT"].includes(command)) return { ok: false as const, message: "Perintah koneksi tidak valid." };
  try {
    const { error: auditError } = await (await createClient()).rpc("whatsapp_provider_control_request", { p_command: command });
    if (auditError) return { ok: false as const, message: "Permintaan koneksi belum dapat dicatat. Coba kembali." };
    const provider = getWahaWhatsAppProvider();
    if (command === "CONNECT") await provider.requestPairing();
    else if (command === "RECONNECT") await provider.reconnect();
    else await provider.disconnect();
    return { ok: true as const, message: command === "DISCONNECT" ? "Perangkat WhatsApp berhasil diputuskan. Scan QR diperlukan untuk menghubungkan kembali." : "Permintaan koneksi dikirim ke WAHA." };
  } catch (error) {
    const code = typeof error === "object" && error !== null && "code" in error ? String(error.code) : "";
    const message = code === "PROVIDER_NOT_CONFIGURED"
      ? "Konfigurasi WAHA belum lengkap. Periksa WAHA_BASE_URL dan WAHA_API_KEY di server."
      : code === "PROVIDER_AUTH_FAILED"
        ? "Autentikasi Quena ke WAHA gagal. Periksa API key server."
        : "WAHA belum dapat dijangkau. Pastikan layanan WAHA aktif lalu coba kembali.";
    return { ok: false as const, message };
  }
}

export async function readWhatsAppPairingQr() {
  const profile = await getProfile();
  if (!profile || profile.role !== "OWNER") return { ok: false as const, qrDataUrl: null, expiresAt: null };
  try {
    const qr = await getWahaWhatsAppProvider().getPairingQr();
    return { ok: true as const, ...qr };
  } catch {
    return { ok: true as const, qrDataUrl: null, expiresAt: null };
  }
}

export async function sendManualWhatsAppTestMessage(destination: string, message: string) {
  const profile = await getProfile();
  if (!profile || profile.role !== "OWNER") {
    return { ok: false as const, message: "Hanya Owner yang dapat mengirim pesan tes WhatsApp." };
  }
  return sendManualWhatsAppTest({
    role: profile.role,
    actorId: profile.id,
    destination,
    message,
    provider: getWahaWhatsAppProvider,
  });
}
