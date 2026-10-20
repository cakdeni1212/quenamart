import type { WhatsAppProviderStatus } from "./waha-provider.shared";

export type WhatsAppDeliveryReadiness = "INACTIVE" | "WAITING_CONNECTION" | "WAITING_PUBLIC_URL" | "SENDING_DISABLED";
export type WhatsAppConnectionState = WhatsAppProviderStatus["connection_state"] | "UNKNOWN";

export function getWhatsAppDeliveryReadiness(input: {
  transactionsEnabled: boolean;
  automaticReceiptEnabled: boolean;
  connectionState: WhatsAppConnectionState;
  publicUrlReady: boolean;
}): WhatsAppDeliveryReadiness;
export function whatsappDeliveryReadinessLabel(value: WhatsAppDeliveryReadiness): string;
export function whatsappDeliveryReadinessHint(value: WhatsAppDeliveryReadiness): string;
export function shouldPollWhatsAppProvider(state: WhatsAppConnectionState): boolean;
