import { createCipheriv, randomBytes } from "node:crypto";

export function maskNumber(jid) {
  const number = String(jid ?? "").split("@")[0].split(":")[0].replace(/\D/g, "");
  if (number.length < 7) return "Nomor tersamarkan";
  return `${number.slice(0, 2)}••••••${number.slice(-4)}`;
}

export function encryptQrPayload(qr, key) {
  if (!Buffer.isBuffer(key) || key.length !== 32) throw new TypeError("QR handoff key must contain 32 bytes");
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const ciphertext = Buffer.concat([cipher.update(qr, "utf8"), cipher.final()]);
  return `v1.${iv.toString("base64url")}.${cipher.getAuthTag().toString("base64url")}.${ciphertext.toString("base64url")}`;
}

function safeErrorCode(value) {
  if (value === "SESSION_LOGGED_OUT" || value === "AUTH_FAILURE" || value === "NETWORK_ERROR") return value;
  return "UNKNOWN_PROVIDER_ERROR";
}

/** Small event-to-state boundary; it never receives or calls a message sender. */
export function createConnectionLifecycle({ writeState, clearSession, logger = () => {}, now = () => Date.now() }) {
  return async function handle(update) {
    if (typeof update?.qr === "string" && update.qr.length > 0) {
      await writeState("WAITING_QR", { qr: update.qr, expiresAt: new Date(now() + 55_000).toISOString() });
      logger("QR ready");
      return;
    }
    if (update?.connection === "connecting") {
      await writeState("CONNECTING");
      logger("Connecting");
      return;
    }
    if (update?.connection === "open") {
      await writeState("CONNECTED", { number: maskNumber(update.number) });
      logger("Connected");
      return;
    }
    if (update?.connection === "close") {
      const error = safeErrorCode(update.errorCode);
      if (error === "SESSION_LOGGED_OUT") await clearSession();
      await writeState(error === "SESSION_LOGGED_OUT" ? "DISCONNECTED" : "CONNECTING", { error });
      logger(error === "SESSION_LOGGED_OUT" ? "Disconnected; scan QR to link again" : "Disconnected; reconnect scheduled");
    }
  };
}

export class WorkerCommandGuard {
  #completed = new Set();
  async run(id, command, handlers) {
    if (this.#completed.has(id)) return false;
    if (!id || !["CONNECT", "DISCONNECT", "RECONNECT"].includes(command)) throw new TypeError("Invalid provider command");
    if (command === "CONNECT") await handlers.connect();
    else if (command === "RECONNECT") await handlers.reconnect();
    else await handlers.disconnect();
    this.#completed.add(id);
    return true;
  }
}
