import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { WahaWhatsAppProviderAdapter } from "../services/whatsapp-waha/adapter.mjs";
import { normalizeWhatsAppDestination, sendManualWhatsAppTest } from "../services/whatsapp-waha/manual-test.mjs";

const actionSource = await readFile(new URL("../src/app/actions/whatsapp-provider.ts", import.meta.url), "utf8");
const formSource = await readFile(new URL("../src/components/settings/whatsapp-manual-test-form.tsx", import.meta.url), "utf8");
const settingsSource = await readFile(new URL("../src/components/settings/whatsapp-settings-form.tsx", import.meta.url), "utf8");
const helperSource = await readFile(new URL("../services/whatsapp-waha/manual-test.mjs", import.meta.url), "utf8");
const adapterSource = await readFile(new URL("../services/whatsapp-waha/adapter.mjs", import.meta.url), "utf8");

function testAdapter(fetcher) {
  return new WahaWhatsAppProviderAdapter({
    baseUrl: "http://127.0.0.1:3000",
    apiKey: "test-secret-key-with-more-than-24-characters",
    sessionName: "quena-test",
    fetcher,
  });
}

function jsonResponse(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
}

test("Indonesian number forms normalize to the same WhatsApp address", () => {
  const expected = { e164: "+6281234567890", chatId: "6281234567890@c.us" };
  for (const input of ["081234567890", "6281234567890", "+6281234567890", "08 1234-567-890", "006281234567890"]) {
    assert.deepEqual(normalizeWhatsAppDestination(input), expected, input);
  }
});

test("invalid or ambiguous destinations are rejected", () => {
  for (const input of ["", "0812", "1234567890", "+081234567890", "62abc1234567890", "++6281234567890", "6281234567890123456"]) {
    assert.equal(normalizeWhatsAppDestination(input), null, input);
  }
});

test("only OWNER may invoke a manual test send", async () => {
  let sends = 0;
  const provider = { async sendManualTestMessage() { sends += 1; } };
  for (const role of ["ADMIN", "KASIR", "GUDANG", "ANON", "UNKNOWN"]) {
    const result = await sendManualWhatsAppTest({ role, actorId: `actor-${role}`, destination: "081234567890", message: "Test", provider });
    assert.equal(result.ok, false, role);
    assert.match(result.message, /Hanya Owner/);
  }
  const allowed = await sendManualWhatsAppTest({ role: "OWNER", actorId: "owner-manual-allow", destination: "081234567890", message: "Test", provider });
  assert.equal(allowed.ok, true);
  assert.equal(sends, 1);
  assert.match(actionSource, /profile\.role !== "OWNER"/);
});

test("invalid destination and unconnected session never make a send request", async () => {
  const calls = [];
  const provider = testAdapter(async (url, init) => {
    calls.push({ url, method: init.method ?? "GET" });
    return jsonResponse({ status: "STARTING" });
  });
  const invalid = await sendManualWhatsAppTest({ role: "OWNER", actorId: "owner-invalid-no-send", destination: "bad", message: "Test", provider });
  assert.equal(invalid.ok, false);
  assert.equal(calls.length, 0);
  const disconnected = await sendManualWhatsAppTest({ role: "OWNER", actorId: "owner-starting-no-send", destination: "081234567890", message: "Test", provider });
  assert.equal(disconnected.ok, false);
  assert.match(disconnected.message, /belum terhubung/);
  assert.deepEqual(calls.map(({ method }) => method), ["GET"]);
});

test("connected WAHA sends exact documented sendText request with server API key", async () => {
  const calls = [];
  const provider = testAdapter(async (url, init) => {
    calls.push({ url, init });
    if (url.endsWith("/api/sessions/quena-test")) return jsonResponse({ status: "WORKING", me: { id: "6281234567890@c.us" } });
    return jsonResponse({ id: "provider-message-id" }, 201);
  });
  const result = await sendManualWhatsAppTest({ role: "OWNER", actorId: "owner-connected-contract", destination: "+6281234567890", message: "Quena test", provider });
  assert.deepEqual(result, { ok: true, message: "Pesan tes berhasil dikirim ke WhatsApp." });
  assert.equal(calls.length, 2);
  assert.equal(calls[0].url, "http://127.0.0.1:3000/api/sessions/quena-test");
  assert.equal(calls[0].init.method ?? "GET", "GET");
  assert.equal(calls[1].url, "http://127.0.0.1:3000/api/sendText");
  assert.equal(calls[1].init.method, "POST");
  assert.equal(calls[1].init.headers["X-Api-Key"], "test-secret-key-with-more-than-24-characters");
  assert.equal(calls[1].init.headers.Accept, "application/json");
  assert.deepEqual(JSON.parse(calls[1].init.body), { session: "quena-test", chatId: "6281234567890@c.us", text: "Quena test" });
  assert.equal(calls[1].init.cache, "no-store");
  assert.equal(calls[1].init.redirect, "error");
});

test("provider errors map to safe text and do not expose response bodies or secrets", async () => {
  const secretResponse = "private provider body with token and destination";
  const provider = testAdapter(async (url) => url.endsWith("/api/sessions/quena-test")
    ? jsonResponse({ status: "WORKING" })
    : new Response(secretResponse, { status: 500, headers: { "content-type": "text/plain" } }));
  const result = await sendManualWhatsAppTest({ role: "OWNER", actorId: "owner-safe-error", destination: "081234567890", message: "Test", provider });
  assert.equal(result.ok, false);
  assert.match(result.message, /belum dapat dikirim/);
  assert.doesNotMatch(result.message, /private provider body|token|destination/);
});

test("manual sends have a server cooldown to prevent duplicate clicks and concurrent sends", async () => {
  let resolveSend;
  let calls = 0;
  const provider = { async sendManualTestMessage() { calls += 1; await new Promise((resolve) => { resolveSend = resolve; }); } };
  const first = sendManualWhatsAppTest({ role: "OWNER", actorId: "owner-cooldown", destination: "081234567890", message: "Test", provider, now: 1000 });
  const second = await sendManualWhatsAppTest({ role: "OWNER", actorId: "owner-cooldown", destination: "081234567890", message: "Test", provider, now: 1001 });
  assert.equal(second.ok, false);
  assert.match(second.message, /Tunggu sebentar/);
  assert.equal(calls, 1);
  resolveSend();
  assert.equal((await first).ok, true);
});

test("manual test form is Owner-only, explicitly confirmed, and independent of outbox/customer records", () => {
  assert.match(settingsSource, /canEdit && <WhatsAppManualTestForm/);
  assert.match(formSource, /sendManualWhatsAppTestMessage\(destination, message\)/);
  assert.match(formSource, /disabled=\{busy \|\| !confirmed/);
  assert.match(formSource, /Saya memastikan nomor ini milik saya/);
  assert.match(formSource, /Tes koneksi WhatsApp Quena Mart/);
  const manualAction = actionSource.slice(actionSource.indexOf("export async function sendManualWhatsAppTestMessage"));
  assert.doesNotMatch(manualAction + helperSource, /notification_outbox|sale_id|member_id|consent|processOutbox/i);
  assert.doesNotMatch(adapterSource, /sendTransactionalMessage|sendMessage\(/);
  assert.match(helperSource, /SEND_COOLDOWN_MS = 30_000/);
});
