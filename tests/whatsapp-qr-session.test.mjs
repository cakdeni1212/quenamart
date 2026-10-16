import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { WahaProviderError, WahaWhatsAppProviderAdapter } from "../services/whatsapp-waha/adapter.mjs";

const actions = await readFile(new URL("../src/app/actions/whatsapp-provider.ts", import.meta.url), "utf8");
const adapterSource = await readFile(new URL("../services/whatsapp-waha/adapter.mjs", import.meta.url), "utf8");
const serverBoundary = await readFile(new URL("../src/lib/notifications/waha-provider.server.ts", import.meta.url), "utf8");
const controls = await readFile(new URL("../src/components/notifications/whatsapp-connection-controls.tsx", import.meta.url), "utf8");
const compose = await readFile(new URL("../infra/waha/compose.yaml", import.meta.url), "utf8");
const packageJson = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
const packageLock = await readFile(new URL("../package-lock.json", import.meta.url), "utf8");
const migration = await readFile(new URL("../supabase/migrations/20261016100000_whatsapp_qr_session_provider_v1.sql", import.meta.url), "utf8");

function adapter(fetcher, options = {}) {
  return new WahaWhatsAppProviderAdapter({
    baseUrl: "http://127.0.0.1:3000", apiKey: "test-secret-key-with-more-than-24-characters",
    sessionName: "quena-test", fetcher, ...options,
  });
}

function jsonResponse(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
}

test("WAHA session lifecycle states map to Quena provider states with masked identity", async () => {
  for (const [waha, quena] of [["SCAN_QR_CODE", "WAITING_QR"], ["STARTING", "CONNECTING"], ["WORKING", "CONNECTED"], ["STOPPED", "DISCONNECTED"], ["FAILED", "ERROR"]]) {
    const provider = adapter(async () => jsonResponse({ status: waha, me: { id: "6281234567890@c.us" } }));
    const status = await provider.getConnectionStatus();
    assert.equal(status.connection_state, quena);
    assert.equal(status.provider_available, true);
    assert.equal(status.connected_number_masked, quena === "CONNECTED" ? "62••••••7890" : null);
    assert.equal(status.last_connected_at, null);
  }
});

test("missing session is NOT_CONFIGURED and provider timeout fails closed", async () => {
  const missing = await adapter(async () => new Response(null, { status: 404 })).getConnectionStatus();
  assert.equal(missing.connection_state, "NOT_CONFIGURED");
  const unavailable = await adapter(async () => { throw new Error("connection refused"); }).getConnectionStatus();
  assert.equal(unavailable.connection_state, "ERROR");
  assert.equal(unavailable.provider_available, false);
  assert.equal(unavailable.last_error_code, "PROVIDER_UNAVAILABLE");
});

test("API credentials stay in X-Api-Key header and never enter URL or logs", async () => {
  const calls = [];
  const provider = adapter(async (url, init) => { calls.push({ url, init }); return jsonResponse({ status: "WORKING" }); });
  await provider.getConnectionStatus();
  assert.equal(calls[0].url, "http://127.0.0.1:3000/api/sessions/quena-test");
  assert.equal(calls[0].init.headers["X-Api-Key"], "test-secret-key-with-more-than-24-characters");
  assert.equal(calls[0].init.cache, "no-store");
  assert.equal(calls[0].init.redirect, "error");
  assert.doesNotMatch(JSON.stringify(calls[0].url), /test-secret/);
});

test("connect creates a missing WAHA session or starts a stopped session", async () => {
  const calls = [];
  let gets = 0;
  const provider = adapter(async (url, init) => {
    calls.push({ url, method: init.method ?? "GET", body: init.body });
    if (init.method === "POST") return jsonResponse({ status: "STARTING" });
    gets += 1;
    return gets === 1 ? new Response(null, { status: 404 }) : jsonResponse({ status: "STOPPED" });
  });
  await provider.requestPairing();
  await provider.requestPairing();
  assert.deepEqual(calls.filter((call) => call.method === "POST").map((call) => [call.url, call.body]), [
    ["http://127.0.0.1:3000/api/sessions", JSON.stringify({ name: "quena-test" })],
    ["http://127.0.0.1:3000/api/sessions/quena-test/start", undefined],
  ]);
});

test("QR retrieval is available only in scan state and returns a temporary image URL", async () => {
  let status = "SCAN_QR_CODE";
  const calls = [];
  const provider = adapter(async (url, init) => {
    calls.push({ url, init });
    if (!url.includes("/auth/qr")) return jsonResponse({ status });
    return new Response(Uint8Array.from([137, 80, 78, 71]), { headers: { "content-type": "image/png" } });
  });
  const qr = await provider.getPairingQr();
  assert.equal(qr.qrDataUrl, "data:image/png;base64,iVBORw==");
  assert.equal(qr.expiresAt, null);
  assert.equal(calls[1].init.headers.Accept, "image/png");
  status = "WORKING";
  assert.deepEqual(await provider.getPairingQr(), { qrDataUrl: null, expiresAt: null });
});

test("reconnect uses WAHA restart; disconnect stops and logs out instead of retaining auth", async () => {
  const calls = [];
  const provider = adapter(async (url, init) => {
    calls.push({ url, method: init.method ?? "GET" });
    return jsonResponse({ status: "WORKING" });
  });
  await provider.reconnect();
  await provider.disconnect();
  assert.deepEqual(calls.filter((call) => call.method === "POST").map((call) => call.url), [
    "http://127.0.0.1:3000/api/sessions/quena-test/restart",
    "http://127.0.0.1:3000/api/sessions/quena-test/stop",
    "http://127.0.0.1:3000/api/sessions/quena-test/logout",
  ]);
});

test("bad provider responses, invalid configuration, API auth, and QR media fail closed", async () => {
  await assert.rejects(() => adapter(async () => jsonResponse({ nonsense: true })).readSession(), WahaProviderError);
  await assert.rejects(() => adapter(async () => new Response(null, { status: 401 })).readSession(), (error) => error.code === "PROVIDER_AUTH_FAILED");
  await assert.rejects(() => adapter(async () => jsonResponse({ status: "SCAN_QR_CODE" })).getPairingQr(), /INVALID_PROVIDER_RESPONSE/);
  assert.throws(() => adapter(async () => jsonResponse({ status: "WORKING" }), { apiKey: "short" }), WahaProviderError);
});

test("Server Action boundary enforces OWNER controls and OWNER-only QR; adapter is server-only", () => {
  assert.match(actions, /profile\.role !== "OWNER"/);
  assert.match(actions, /!\["OWNER", "ADMIN"\]\.includes\(profile\.role\)/);
  assert.match(actions, /profile\.role !== "OWNER"\) return \{ ok: false as const, qrDataUrl/);
  assert.match(serverBoundary, /^import "server-only";/);
  assert.match(controls, /canControl && state === "WAITING_QR"/);
  assert.doesNotMatch(actions + adapterSource, /sendMessage|sendTransactionalMessage|notification_outbox/);
});

test("WAHA is loopback-bound with a persistent volume, and Baileys/libsignal were removed", () => {
  assert.match(compose, /127\.0\.0\.1:3000:3000/);
  assert.match(compose, /waha_sessions:\/app\/\.sessions/);
  assert.match(compose, /gows-arm-2026\.9\.2/);
  assert.doesNotMatch(compose, /latest(?::|\s|$)/);
  assert.equal(Object.hasOwn(packageJson.dependencies, "@chaeulso/baileys"), false);
  assert.equal(Object.hasOwn(packageJson.scripts, "whatsapp:worker"), false);
  assert.doesNotMatch(packageLock, /"node_modules\/(?:@chaeulso\/baileys|libsignal)"/);
  assert.match(migration, /whatsapp_provider_control_events/);
  assert.match(migration, /WHATSAPP_PROVIDER_CONTROL_DENIED/);
  assert.doesNotMatch(migration, /qr_payload|worker_lease|command_claim|notification_outbox/);
});
