"use server";

import { createDecipheriv } from "node:crypto";
import QRCode from "qrcode";
import { getProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";

export type WhatsAppProviderStatus = {
  outlet_id: string;
  provider_key: "QR_SESSION";
  connection_state: "NOT_CONFIGURED" | "WAITING_QR" | "CONNECTING" | "CONNECTED" | "DISCONNECTED" | "ERROR";
  connected_number_masked: string | null;
  last_connected_at: string | null;
  last_disconnected_at: string | null;
  last_error_code: string | null;
  last_heartbeat_at: string | null;
  worker_active: boolean;
  qr_expires_at: string | null;
};

function isRow(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseStatus(value: unknown): WhatsAppProviderStatus | null {
  if (!isRow(value) || typeof value.outlet_id !== "string") return null;
  const states = ["NOT_CONFIGURED", "WAITING_QR", "CONNECTING", "CONNECTED", "DISCONNECTED", "ERROR"] as const;
  if (!states.includes(value.connection_state as (typeof states)[number])) return null;
  return {
    outlet_id: value.outlet_id,
    provider_key: "QR_SESSION",
    connection_state: value.connection_state as WhatsAppProviderStatus["connection_state"],
    connected_number_masked: typeof value.connected_number_masked === "string" ? value.connected_number_masked : null,
    last_connected_at: typeof value.last_connected_at === "string" ? value.last_connected_at : null,
    last_disconnected_at: typeof value.last_disconnected_at === "string" ? value.last_disconnected_at : null,
    last_error_code: typeof value.last_error_code === "string" ? value.last_error_code : null,
    last_heartbeat_at: typeof value.last_heartbeat_at === "string" ? value.last_heartbeat_at : null,
    worker_active: value.worker_active === true,
    qr_expires_at: typeof value.qr_expires_at === "string" ? value.qr_expires_at : null,
  };
}

export async function readWhatsAppProviderStatus() {
  const profile = await getProfile();
  if (!profile || !["OWNER", "ADMIN"].includes(profile.role)) return { ok: false as const, status: null, message: "Akses ditolak." };
  const { data, error } = await (await createClient()).rpc("whatsapp_provider_connection_read");
  if (error) return { ok: false as const, status: null, message: "Status koneksi belum dapat dimuat." };
  const status = parseStatus(data);
  return status ? { ok: true as const, status } : { ok: false as const, status: null, message: "Data koneksi belum dapat dibaca." };
}

export async function requestWhatsAppProviderCommand(command: "CONNECT" | "DISCONNECT" | "RECONNECT") {
  const profile = await getProfile();
  if (!profile || profile.role !== "OWNER") return { ok: false as const, message: "Hanya Owner yang dapat mengelola koneksi WhatsApp." };
  if (!["CONNECT", "DISCONNECT", "RECONNECT"].includes(command)) return { ok: false as const, message: "Perintah koneksi tidak valid." };
  const { error } = await (await createClient()).rpc("whatsapp_provider_control_request", { p_command: command });
  if (error) return { ok: false as const, message: error.message.includes("WHATSAPP_PROVIDER_WORKER_OFFLINE") ? "Worker WhatsApp belum aktif. Jalankan worker, lalu coba lagi." : "Permintaan belum dapat dikirim. Coba kembali." };
  return { ok: true as const, message: command === "DISCONNECT" ? "Permintaan pemutusan dikirim ke worker." : "Permintaan koneksi dikirim ke worker." };
}

function decryptQrPayload(value: string) {
  const encodedKey = process.env.WHATSAPP_QR_HANDOFF_KEY;
  if (!encodedKey) throw new Error("WHATSAPP_QR_HANDOFF_KEY is not configured");
  const key = Buffer.from(encodedKey, "base64");
  if (key.length !== 32) throw new Error("WHATSAPP_QR_HANDOFF_KEY must decode to 32 bytes");
  const [version, ivText, tagText, ciphertextText] = value.split(".");
  if (version !== "v1" || !ivText || !tagText || !ciphertextText) throw new Error("Invalid QR handoff envelope");
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(ivText, "base64url"));
  decipher.setAuthTag(Buffer.from(tagText, "base64url"));
  return Buffer.concat([decipher.update(Buffer.from(ciphertextText, "base64url")), decipher.final()]).toString("utf8");
}

export async function readWhatsAppPairingQr() {
  const profile = await getProfile();
  if (!profile || profile.role !== "OWNER") return { ok: false as const, qrDataUrl: null, expiresAt: null };
  const { data, error } = await (await createClient()).rpc("whatsapp_provider_qr_read");
  if (error || !isRow(data) || typeof data.encrypted_payload !== "string" || typeof data.expires_at !== "string") {
    return { ok: true as const, qrDataUrl: null, expiresAt: null };
  }
  try {
    const qr = decryptQrPayload(data.encrypted_payload);
    const qrDataUrl = await QRCode.toDataURL(qr, { width: 300, margin: 2, errorCorrectionLevel: "M" });
    return { ok: true as const, qrDataUrl, expiresAt: data.expires_at };
  } catch (error) {
    console.error("[whatsapp_provider_qr_read] QR handoff could not be decoded", { name: error instanceof Error ? error.name : "unknown" });
    return { ok: true as const, qrDataUrl: null, expiresAt: null };
  }
}
