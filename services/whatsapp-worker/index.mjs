import { randomUUID } from "node:crypto";
import { chmod, mkdir, rm, stat } from "node:fs/promises";
import { join, resolve } from "node:path";
import process from "node:process";
import makeWASocket, { createReconnectManager, DisconnectReason, resolveWaWebVersion, useMultiFileAuthState as loadMultiFileAuthState } from "@chaeulso/baileys";
import { createClient } from "@supabase/supabase-js";
import { createConnectionLifecycle, encryptQrPayload, WorkerCommandGuard } from "./core.mjs";

process.umask(0o077);
try { process.loadEnvFile(".env.local"); } catch {}
try { process.loadEnvFile(".env"); } catch {}

const supabaseUrl = process.env.SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const qrKey = Buffer.from(process.env.WHATSAPP_QR_HANDOFF_KEY ?? "", "base64");
if (!supabaseUrl || !serviceRoleKey) throw new Error("Set SUPABASE_URL (or NEXT_PUBLIC_SUPABASE_URL) and SUPABASE_SERVICE_ROLE_KEY in the server environment.");
if (qrKey.length !== 32) throw new Error("WHATSAPP_QR_HANDOFF_KEY must be a base64-encoded 32-byte key.");

const supabase = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } });
const workerId = randomUUID();
const baseSessionPath = resolve(process.env.WHATSAPP_SESSION_DIR ?? ".var/whatsapp");
let outletId;
let reconnectManager;
let stopped = false;
let commandTimer;
let heartbeatTimer;
const commandGuard = new WorkerCommandGuard();

function log(message) { process.stdout.write(`[whatsapp-worker] ${message}\n`); }
function codeFrom(error) {
  const status = error?.output?.statusCode ?? error?.statusCode;
  if (status === DisconnectReason.loggedOut) return "SESSION_LOGGED_OUT";
  if (status === DisconnectReason.forbidden) return "AUTH_FAILURE";
  if (status === DisconnectReason.connectionLost || status === DisconnectReason.timedOut) return "NETWORK_ERROR";
  return "UNKNOWN_PROVIDER_ERROR";
}
async function setState(state, extra = {}) {
  const { data, error } = await supabase.rpc("whatsapp_provider_worker_state", {
    p_outlet_id: outletId,
    p_worker_id: workerId,
    p_state: state,
    p_qr_payload_encrypted: extra.qr ? encryptQrPayload(extra.qr, qrKey) : null,
    p_qr_expires_at: extra.qr ? new Date(Date.now() + 55_000).toISOString() : null,
    p_masked_number: extra.number ?? null,
    p_error_code: extra.error ?? null,
  });
  if (error) throw new Error(`state update failed: ${error.code ?? "unknown"}`);
  if (data !== true) throw new Error("worker lease lost");
}
async function secureSessionDirectory(path) {
  await mkdir(path, { recursive: true, mode: 0o700 });
  await chmod(path, 0o700);
  for (const entry of await (await import("node:fs/promises")).readdir(path, { withFileTypes: true })) {
    if (entry.isFile()) await chmod(join(path, entry.name), 0o600).catch(() => {});
  }
}
async function sessionExists(path) {
  try { const info = await stat(join(path, "creds.json")); return info.isFile(); } catch { return false; }
}

async function startConnection() {
  if (reconnectManager && !reconnectManager.stopped) return;
  const sessionPath = join(baseSessionPath, outletId);
  await secureSessionDirectory(sessionPath);
  const { state, saveCreds } = await loadMultiFileAuthState(sessionPath);
  const cachePath = join(sessionPath, "wa-version.json");
  const manager = createReconnectManager({
    maxRetries: 10,
    baseDelayMs: 2000,
    maxDelayMs: 60_000,
    connect: async ({ version }) => {
      const resolved = version ?? (await resolveWaWebVersion({ cachePath })).version;
      return makeWASocket({ auth: state, version: resolved, printQRInTerminal: false, logger: { level: "silent", child() { return this; }, trace() {}, debug() {}, info() {}, warn() {}, error() {}, fatal() {} } });
    },
    onSocket: async (socket) => {
      socket.ev.on("creds.update", async () => {
        await saveCreds();
        await secureSessionDirectory(sessionPath);
      });
      const handleUpdate = createConnectionLifecycle({
        writeState: (stateName, payload = {}) => setState(stateName, payload),
        clearSession: () => rm(sessionPath, { recursive: true, force: true }),
        logger: log,
      });
      socket.ev.on("connection.update", (update) => {
        void handleUpdate({
          ...update,
          number: socket.user?.id ?? socket.authState?.creds?.me?.id,
          errorCode: update.connection === "close" ? codeFrom(update.lastDisconnect?.error) : undefined,
        }).catch(() => log("Connection state update failed"));
      });
    },
    onGiveUp: () => { void setState("ERROR", { error: "NETWORK_ERROR" }).catch(() => {}); log("Reconnect limit reached"); },
  });
  reconnectManager = manager;
  try {
    const version = await resolveWaWebVersion({ cachePath });
    await manager.start({ version: version.version });
    log("Pairing started");
  } catch (error) {
    await setState("ERROR", { error: codeFrom(error) });
    log("Connection start failed");
  }
}

async function disconnectAndUnlink() {
  const socket = reconnectManager?.socket;
  await reconnectManager?.stop();
  if (socket?.logout) await socket.logout().catch(() => {});
  await rm(join(baseSessionPath, outletId), { recursive: true, force: true });
  reconnectManager = undefined;
  await setState("DISCONNECTED", { error: "SESSION_LOGGED_OUT" });
  log("Disconnected and unlinked");
}

async function processCommand() {
  const { data, error } = await supabase.rpc("whatsapp_provider_command_claim", { p_outlet_id: outletId, p_worker_id: workerId });
  if (error || !data?.id) return;
  const command = data.command_type;
  try {
    const executed = await commandGuard.run(data.id, command, {
      connect: startConnection,
      reconnect: async () => { await reconnectManager?.stop(); reconnectManager = undefined; await setState("CONNECTING"); await startConnection(); },
      disconnect: disconnectAndUnlink,
    });
    if (executed) await supabase.rpc("whatsapp_provider_command_complete", { p_command_id: data.id, p_worker_id: workerId, p_success: true, p_result_code: null });
  } catch {
    await setState("ERROR", { error: "UNKNOWN_PROVIDER_ERROR" }).catch(() => {});
    await supabase.rpc("whatsapp_provider_command_complete", { p_command_id: data.id, p_worker_id: workerId, p_success: false, p_result_code: "UNKNOWN_PROVIDER_ERROR" }).catch(() => {});
    log("Command failed safely");
  }
}

async function heartbeat() {
  const { data, error } = await supabase.rpc("whatsapp_provider_worker_heartbeat", { p_outlet_id: outletId, p_worker_id: workerId });
  if (error || data !== true) throw new Error("worker lease unavailable");
}
async function acquireLease() {
  for (let attempt = 0; attempt < 18; attempt += 1) {
    try { await heartbeat(); return; } catch {
      if (attempt === 0) log("Waiting for the existing worker lease to expire");
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 5000));
    }
  }
  throw new Error("worker lease unavailable");
}

async function shutdown() {
  if (stopped) return;
  stopped = true;
  clearInterval(commandTimer);
  clearInterval(heartbeatTimer);
  await reconnectManager?.stop().catch(() => {});
  await supabase.rpc("whatsapp_provider_worker_release", { p_outlet_id: outletId, p_worker_id: workerId }).catch(() => {});
  // Auth files are retained for restart.
  log("Worker stopped; linked-device session retained");
  process.exit(0);
}

async function main() {
  const { data, error } = await supabase.rpc("whatsapp_provider_worker_context");
  if (error || !data?.outlet_id) throw new Error("Could not resolve the active outlet for the worker.");
  outletId = data.outlet_id;
  await acquireLease();
  log("Worker started");
  log("Waiting for commands");
  if (await sessionExists(join(baseSessionPath, outletId))) await startConnection();
  heartbeatTimer = setInterval(() => { void heartbeat().catch(() => { log("Worker lease lost; stopping session"); void shutdown(); }); }, 25_000);
  commandTimer = setInterval(() => { if (!stopped) void processCommand(); }, 2500);
  process.on("SIGINT", () => void shutdown());
  process.on("SIGTERM", () => void shutdown());
}

main().catch((error) => {
  log("Worker failed to start; verify server configuration and database availability");
  process.exitCode = 1;
});
