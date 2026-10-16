const STATUS_MAP = Object.freeze({
  SCAN_QR_CODE: "WAITING_QR",
  STARTING: "CONNECTING",
  STOPPING: "CONNECTING",
  WORKING: "CONNECTED",
  STOPPED: "DISCONNECTED",
  FAILED: "ERROR",
});

export class WahaProviderError extends Error {
  constructor(code) {
    super(code);
    this.name = "WahaProviderError";
    this.code = code;
  }
}

function maskNumber(value) {
  const number = String(value ?? "").split("@")[0].replace(/\D/g, "");
  return number.length >= 7 ? `${number.slice(0, 2)}••••••${number.slice(-4)}` : null;
}

function parseSession(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)
    || typeof value.status !== "string" || !Object.hasOwn(STATUS_MAP, value.status)) {
    throw new WahaProviderError("INVALID_PROVIDER_RESPONSE");
  }
  return {
    connection_state: STATUS_MAP[value.status],
    connected_number_masked: value.status === "WORKING" ? maskNumber(value.me?.id) : null,
    last_connected_at: null,
    last_disconnected_at: null,
    last_error_code: value.status === "FAILED" ? "UNKNOWN_PROVIDER_ERROR" : null,
    provider_available: true,
    qr_expires_at: null,
  };
}

function normalizeBaseUrl(value) {
  let url;
  try { url = new URL(value); } catch { throw new WahaProviderError("PROVIDER_NOT_CONFIGURED"); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
    throw new WahaProviderError("PROVIDER_NOT_CONFIGURED");
  }
  return url.toString().replace(/\/$/, "");
}

async function readBoundedBody(response, limit) {
  if (!response.body) throw new WahaProviderError("INVALID_PROVIDER_RESPONSE");
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > limit) {
        await reader.cancel();
        throw new WahaProviderError("INVALID_PROVIDER_RESPONSE");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return bytes;
}

/** Server-side WAHA REST adapter. It intentionally has no message-sending method. */
export class WahaWhatsAppProviderAdapter {
  constructor({ baseUrl, apiKey, sessionName, fetcher = globalThis.fetch, timeoutMs = 8000 }) {
    this.baseUrl = normalizeBaseUrl(baseUrl ?? "");
    if (typeof apiKey !== "string" || apiKey.length < 24 || /[\r\n]/.test(apiKey)) {
      throw new WahaProviderError("PROVIDER_NOT_CONFIGURED");
    }
    if (typeof sessionName !== "string" || !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/.test(sessionName)) {
      throw new WahaProviderError("PROVIDER_NOT_CONFIGURED");
    }
    this.apiKey = apiKey;
    this.sessionName = sessionName;
    this.fetcher = fetcher;
    this.timeoutMs = timeoutMs;
  }

  async request(path, init = {}) {
    let response;
    try {
      response = await this.fetcher(`${this.baseUrl}${path}`, {
        ...init,
        cache: "no-store",
        redirect: "error",
        signal: AbortSignal.timeout(this.timeoutMs),
        headers: { "X-Api-Key": this.apiKey, ...(init.body ? { "Content-Type": "application/json" } : {}), ...init.headers },
      });
    } catch {
      throw new WahaProviderError("PROVIDER_UNAVAILABLE");
    }
    return response;
  }

  sessionPath(suffix = "") {
    return `/api/sessions/${encodeURIComponent(this.sessionName)}${suffix}`;
  }

  async readSession() {
    const response = await this.request(this.sessionPath());
    if (response.status === 404) return null;
    if (response.status === 401 || response.status === 403) throw new WahaProviderError("PROVIDER_AUTH_FAILED");
    if (!response.ok) throw new WahaProviderError("PROVIDER_UNAVAILABLE");
    try { return parseSession(await response.json()); } catch (error) {
      if (error instanceof WahaProviderError) throw error;
      throw new WahaProviderError("INVALID_PROVIDER_RESPONSE");
    }
  }

  async getConnectionStatus() {
    try {
      return await this.readSession() ?? {
        connection_state: "NOT_CONFIGURED", connected_number_masked: null, last_connected_at: null,
        last_disconnected_at: null, last_error_code: null, provider_available: true, qr_expires_at: null,
      };
    } catch (error) {
      const code = error instanceof WahaProviderError ? error.code : "UNKNOWN_PROVIDER_ERROR";
      return {
        connection_state: code === "PROVIDER_NOT_CONFIGURED" ? "NOT_CONFIGURED" : "ERROR",
        connected_number_masked: null, last_connected_at: null, last_disconnected_at: null,
        last_error_code: code, provider_available: false, qr_expires_at: null,
      };
    }
  }

  async requestPairing() {
    const current = await this.readSession();
    if (!current) {
      const response = await this.request("/api/sessions", {
        method: "POST", body: JSON.stringify({ name: this.sessionName }),
      });
      if (!response.ok && response.status !== 409) throw new WahaProviderError("PROVIDER_UNAVAILABLE");
      return;
    }
    if (current.connection_state === "DISCONNECTED") {
      const response = await this.request(this.sessionPath("/start"), { method: "POST" });
      if (!response.ok && response.status !== 409) throw new WahaProviderError("PROVIDER_UNAVAILABLE");
    } else if (current.connection_state === "ERROR") {
      await this.reconnect();
    }
  }

  async getPairingQr() {
    const current = await this.readSession();
    if (!current || current.connection_state !== "WAITING_QR") return { qrDataUrl: null, expiresAt: null };
    const response = await this.request(this.sessionPath("/auth/qr?format=image"), {
      headers: { Accept: "image/png" },
    });
    if (!response.ok) return { qrDataUrl: null, expiresAt: null };
    const type = response.headers.get("content-type")?.split(";")[0].trim().toLowerCase();
    if (type !== "image/png") throw new WahaProviderError("INVALID_PROVIDER_RESPONSE");
    const bytes = await readBoundedBody(response, 512_000);
    if (bytes.length < 1 || bytes.length > 512_000) throw new WahaProviderError("INVALID_PROVIDER_RESPONSE");
    return {
      qrDataUrl: `data:image/png;base64,${Buffer.from(bytes).toString("base64")}`,
      expiresAt: null,
    };
  }

  async disconnect() {
    const current = await this.readSession();
    if (!current) return;
    if (current.connection_state !== "DISCONNECTED") {
      const stopped = await this.request(this.sessionPath("/stop"), { method: "POST" });
      if (!stopped.ok && stopped.status !== 409) throw new WahaProviderError("PROVIDER_UNAVAILABLE");
    }
    const response = await this.request(this.sessionPath("/logout"), { method: "POST" });
    if (!response.ok && response.status !== 404 && response.status !== 409) throw new WahaProviderError("PROVIDER_UNAVAILABLE");
  }

  async reconnect() {
    const current = await this.readSession();
    if (!current) return this.requestPairing();
    const response = await this.request(this.sessionPath("/restart"), { method: "POST" });
    if (!response.ok && response.status !== 409) throw new WahaProviderError("PROVIDER_UNAVAILABLE");
  }
}
