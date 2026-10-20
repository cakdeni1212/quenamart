"use client";

import { createContext, useContext, useState, type Dispatch, type ReactNode, type SetStateAction } from "react";
import Link from "next/link";
import type { WhatsAppProviderStatus } from "@/lib/notifications/waha-provider.shared";
import { getWhatsAppDeliveryReadiness, whatsappDeliveryReadinessLabel } from "@/lib/notifications/whatsapp-runtime.shared.mjs";
import styles from "@/components/notifications/whatsapp-center.module.css";

type ProviderStateContextValue = {
  status: WhatsAppProviderStatus | null;
  setStatus: Dispatch<SetStateAction<WhatsAppProviderStatus | null>>;
};

const ProviderStateContext = createContext<ProviderStateContextValue | null>(null);

export function WhatsAppProviderState({ initialStatus, children }: { initialStatus: WhatsAppProviderStatus | null; children: ReactNode }) {
  const [status, setStatus] = useState(initialStatus);
  return <ProviderStateContext.Provider value={{ status, setStatus }}>{children}</ProviderStateContext.Provider>;
}

export function useWhatsAppProviderState() {
  const value = useContext(ProviderStateContext);
  if (!value) throw new Error("WhatsAppProviderState is missing.");
  return value;
}

export function WhatsAppConnectionInfo({
  publicUrlReady,
  transactionsEnabled,
  automaticReceiptEnabled,
}: {
  publicUrlReady: boolean;
  transactionsEnabled: boolean;
  automaticReceiptEnabled: boolean;
}) {
  const { status } = useWhatsAppProviderState();
  const connectionState = status?.connection_state ?? "ERROR";
  const readiness = getWhatsAppDeliveryReadiness({ transactionsEnabled, automaticReceiptEnabled, connectionState, publicUrlReady });
  const provider = connectionState === "NOT_CONFIGURED" ? "Belum dikonfigurasi" : "QR Session";

  return <section className={styles.connectionInfo} aria-labelledby="connection-info-title">
    <header><span className={styles.asideIcon}><ReceiptIcon /></span><h2 id="connection-info-title">Informasi Koneksi</h2></header>
    <InfoRow label="Provider" value={provider} />
    <InfoRow label="Status" value={connectionState} code />
    <InfoRow label="URL publik" value={publicUrlReady ? "Siap" : "Belum dikonfigurasi"} />
    <InfoRow label="Otomatisasi" value={whatsappDeliveryReadinessLabel(readiness)} />
    <Link href="/pengaturan/whatsapp" className={styles.settingsLink}><SettingsIcon />Buka Pengaturan Lengkap</Link>
  </section>;
}

function InfoRow({ label, value, code = false }: { label: string; value: string; code?: boolean }) {
  return <div className={styles.infoRow}><span>{label}</span><strong className={code ? styles.codeValue : ""}>{value}</strong></div>;
}

function ReceiptIcon() {
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 3h12a2 2 0 0 1 2 2v16l-3-2-3 2-3-2-3 2-3-2V5a2 2 0 0 1 2-2Z"/><path d="M8 8h8M8 12h8M8 16h4"/></svg>;
}

function SettingsIcon() {
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7Z"/><path d="m19.4 15 .1.1a1.7 1.7 0 1 1-2.4 2.4l-.1-.1a1.7 1.7 0 0 0-2.9 1.2v.2a1.7 1.7 0 1 1-3.4 0v-.2a1.7 1.7 0 0 0-2.9-1.2l-.1.1a1.7 1.7 0 1 1-2.4-2.4l.1-.1a1.7 1.7 0 0 0-1.2-2.9H4a1.7 1.7 0 1 1 0-3.4h.2a1.7 1.7 0 0 0 1.2-2.9l-.1-.1a1.7 1.7 0 1 1 2.4-2.4l.1.1a1.7 1.7 0 0 0 2.9-1.2V2a1.7 1.7 0 1 1 3.4 0v.2a1.7 1.7 0 0 0 2.9 1.2l.1-.1a1.7 1.7 0 1 1 2.4 2.4l-.1.1a1.7 1.7 0 0 0 1.2 2.9h.2a1.7 1.7 0 1 1 0 3.4h-.2a1.7 1.7 0 0 0-1.2 2.9Z"/></svg>;
}
