"use client";

import { useEffect, useState } from "react";
import Image from "next/image";
import { readWhatsAppPairingQr, readWhatsAppProviderStatus, requestWhatsAppProviderCommand, type WhatsAppProviderStatus } from "@/app/actions/whatsapp-provider";
import styles from "@/components/notifications/whatsapp-center.module.css";

const labels: Record<WhatsAppProviderStatus["connection_state"], string> = {
  NOT_CONFIGURED: "Belum dikonfigurasi", WAITING_QR: "Menunggu scan QR", CONNECTING: "Menghubungkan",
  CONNECTED: "Terhubung", DISCONNECTED: "Terputus", ERROR: "Perlu diperiksa",
};

function dateTime(value: string | null) {
  if (!value) return "—";
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "—" : date.toLocaleString("id-ID", { dateStyle: "medium", timeStyle: "short" });
}

export function WhatsAppConnectionControls({ initialStatus, canControl }: { initialStatus: WhatsAppProviderStatus | null; canControl: boolean }) {
  const [status, setStatus] = useState(initialStatus);
  const [qrDataUrl, setQrDataUrl] = useState<string | null>(null);
  const [qrExpiresAt, setQrExpiresAt] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);

  async function sync() {
    let result: Awaited<ReturnType<typeof readWhatsAppProviderStatus>>;
    try { result = await readWhatsAppProviderStatus(); } catch { return; }
    if (!result.ok || !result.status) return;
    setStatus(result.status);
    if (canControl && result.status.connection_state === "WAITING_QR") {
      const qr = await readWhatsAppPairingQr();
      setQrDataUrl(qr.qrDataUrl);
      setQrExpiresAt(qr.expiresAt);
    } else {
      setQrDataUrl(null);
      setQrExpiresAt(null);
    }
  }

  useEffect(() => {
    let active = true;
    let timer: ReturnType<typeof setTimeout>;
    const poll = async () => {
      if (active) await sync();
      if (active) timer = setTimeout(poll, 3000);
    };
    timer = setTimeout(poll, 1000);
    return () => { active = false; clearTimeout(timer); };
    // Poll lifecycle state while dashboard remains open.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [canControl]);

  async function command(value: "CONNECT" | "DISCONNECT" | "RECONNECT") {
    if (!canControl || busy) return;
    if (value === "DISCONNECT" && !window.confirm("Perangkat WhatsApp Quena akan dilepas. Untuk menghubungkannya kembali Anda perlu scan QR lagi.")) return;
    setBusy(true); setNotice(null);
    try {
      const result = await requestWhatsAppProviderCommand(value);
      setNotice(result.message);
      await sync();
    } catch {
      setNotice("Permintaan koneksi belum berhasil. Coba kembali.");
    } finally { setBusy(false); }
  }

  const state = status?.connection_state ?? "NOT_CONFIGURED";
  const connected = state === "CONNECTED" && status?.worker_active;
  const warning = state !== "CONNECTED";
  const cardClass = styles.connectionCard + (warning ? " " + styles.connectionWarning : " " + styles.connectionReady);
  const error = state === "ERROR" || status?.last_error_code === "WORKER_STALE";

  return <section className={cardClass} aria-labelledby="connection-title">
    <div className={styles.connectionIcon} aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M20.5 11.7a8.5 8.5 0 0 1-12.6 7.4L3 20l1-4.7a8.5 8.5 0 1 1 16.5-3.6Z"/><path d="M8.8 8.3c.4 2.3 2.2 4.1 4.5 4.6"/></svg></div>
    <div className={styles.connectionCopy}>
      <span className={styles.sectionEyebrow}>STATUS KONEKSI</span>
      <h2 id="connection-title">{connected ? "WhatsApp terhubung" : state === "WAITING_QR" ? "Scan QR WhatsApp" : state === "CONNECTING" ? "Menghubungkan WhatsApp..." : error ? "Koneksi WhatsApp bermasalah" : "WhatsApp belum terhubung"}</h2>
      <p>{connected ? `WhatsApp · ${status.connected_number_masked ?? "Nomor tersamarkan"} · QR Session` : error ? "Worker tidak aktif atau koneksi perlu diperiksa. Status aman ditampilkan tanpa detail teknis." : state === "WAITING_QR" ? `QR berlaku sementara${qrExpiresAt ? ` hingga ${dateTime(qrExpiresAt)}` : ""}.` : state === "CONNECTING" ? "Worker sedang menyambungkan perangkat." : status?.worker_active ? "Worker aktif. Siap menerima permintaan koneksi." : "Worker WhatsApp belum aktif. Jalankan worker untuk memulai pairing."}</p>
      {connected && <p>Terakhir terhubung: {dateTime(status.last_connected_at)} · Worker aktif</p>}
      {notice && <p role="status">{notice}</p>}
      {canControl && state === "WAITING_QR" && <div className={styles.qrPanel}>
        {qrDataUrl ? <Image unoptimized src={qrDataUrl} alt="QR sementara untuk menghubungkan WhatsApp Quena" width={260} height={260} /> : <div className={styles.qrPlaceholder}>Menyiapkan QR aman…</div>}
        <ol><li>Buka WhatsApp Business di HP</li><li>Pilih menu Perangkat Tertaut</li><li>Pilih Tautkan Perangkat</li><li>Scan QR di atas</li></ol>
        <small>QR hanya berlaku sementara. Jangan bagikan gambar QR ini.</small>
      </div>}
    </div>
    <div className={styles.connectionAction}>
      <span className={styles.statusPill + (connected ? " " + styles.statusSuccess : " " + styles.statusWarning)}>{labels[state]}</span>
      {canControl && (connected
        ? <button type="button" className={styles.primaryLink} disabled={busy} onClick={() => void command("DISCONNECT")}>{busy ? "Memproses…" : "Putuskan WhatsApp"}</button>
        : <button type="button" className={styles.primaryLink} disabled={busy || !status?.worker_active || state === "WAITING_QR" || state === "CONNECTING"} onClick={() => void command(state === "ERROR" || state === "DISCONNECTED" ? "RECONNECT" : "CONNECT")}>{busy ? "Mengirim…" : state === "ERROR" || state === "DISCONNECTED" ? "Hubungkan Ulang" : "Hubungkan WhatsApp"}</button>)}
      {canControl && state === "WAITING_QR" && <button type="button" className={styles.secondaryLink} disabled={busy} onClick={() => void command("DISCONNECT")}>Batalkan</button>}
    </div>
  </section>;
}
