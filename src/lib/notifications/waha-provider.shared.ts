export type WhatsAppProviderStatus = {
  outlet_id: string;
  provider_key: "QR_SESSION";
  connection_state: "NOT_CONFIGURED" | "WAITING_QR" | "CONNECTING" | "CONNECTED" | "DISCONNECTED" | "ERROR";
  connected_number_masked: string | null;
  last_connected_at: string | null;
  last_disconnected_at: string | null;
  last_error_code: string | null;
  provider_available: boolean;
  qr_expires_at: string | null;
};
