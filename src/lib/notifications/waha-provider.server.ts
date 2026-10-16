import "server-only";
import { WahaWhatsAppProviderAdapter } from "../../../services/whatsapp-waha/adapter.mjs";

export function getWahaWhatsAppProvider() {
  return new WahaWhatsAppProviderAdapter({
    baseUrl: process.env.WAHA_BASE_URL,
    apiKey: process.env.WAHA_API_KEY,
    sessionName: process.env.WAHA_SESSION_NAME ?? "quena-mart",
  });
}
