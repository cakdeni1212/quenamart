export type WahaConnectionState = "NOT_CONFIGURED" | "WAITING_QR" | "CONNECTING" | "CONNECTED" | "DISCONNECTED" | "ERROR";
export type WahaStatus = {
  connection_state: WahaConnectionState;
  connected_number_masked: string | null;
  last_connected_at: string | null;
  last_disconnected_at: string | null;
  last_error_code: string | null;
  provider_available: boolean;
  qr_expires_at: string | null;
};
export class WahaProviderError extends Error { code: string; }
export class WahaWhatsAppProviderAdapter {
  constructor(options: { baseUrl?: string; apiKey?: string; sessionName?: string; fetcher?: typeof fetch; timeoutMs?: number });
  getConnectionStatus(): Promise<WahaStatus>;
  sendManualTestMessage(chatId: string, text: string): Promise<{ ok: true }>;
  requestPairing(): Promise<void>;
  getPairingQr(): Promise<{ qrDataUrl: string | null; expiresAt: string | null }>;
  disconnect(): Promise<void>;
  reconnect(): Promise<void>;
}
