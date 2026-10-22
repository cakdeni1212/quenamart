export function getWhatsAppDeliveryReadiness(input) {
  if (!input.transactionsEnabled || !input.automaticReceiptEnabled) return "INACTIVE";
  if (input.connectionState !== "CONNECTED") return "WAITING_CONNECTION";
  if (!input.publicUrlReady) return "WAITING_PUBLIC_URL";
  // Delivery stays deliberately gated in the connection-only checkpoint.
  return "SENDING_DISABLED";
}

export function whatsappDeliveryReadinessLabel(value) {
  return ({
    INACTIVE: "Nonaktif",
    WAITING_CONNECTION: "Menunggu koneksi",
    WAITING_PUBLIC_URL: "Menunggu URL publik",
    SENDING_DISABLED: "Pengiriman belum diaktifkan",
  })[value];
}

export function whatsappDeliveryReadinessHint(value) {
  return ({
    INACTIVE: "Preferensi tersimpan nonaktif; tidak ada pesan yang diproses.",
    WAITING_CONNECTION: "Preferensi tersimpan aktif, tetapi otomatisasi menunggu koneksi WhatsApp.",
    WAITING_PUBLIC_URL: "Preferensi tersimpan aktif, tetapi otomatisasi menunggu URL publik HTTPS.",
    SENDING_DISABLED: "Koneksi dan URL publik tersedia, tetapi pengiriman pesan belum diaktifkan.",
  })[value];
}

export function shouldPollWhatsAppProvider(state) {
  return ["DISCONNECTED", "WAITING_QR", "CONNECTING"].includes(state);
}
