import assert from "node:assert/strict";
import { createDecipheriv, randomBytes } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createConnectionLifecycle, encryptQrPayload, maskNumber, WorkerCommandGuard } from "../services/whatsapp-worker/core.mjs";

const migration = await readFile(new URL("../supabase/migrations/20261016100000_whatsapp_qr_session_provider_v1.sql", import.meta.url), "utf8");
const worker = await readFile(new URL("../services/whatsapp-worker/index.mjs", import.meta.url), "utf8");
const core = await readFile(new URL("../services/whatsapp-worker/core.mjs", import.meta.url), "utf8");
const actions = await readFile(new URL("../src/app/actions/whatsapp-provider.ts", import.meta.url), "utf8");
const gitignore = await readFile(new URL("../.gitignore", import.meta.url), "utf8");

function decryptQr(envelope, key) {
  const [version, iv, tag, ciphertext] = envelope.split(".");
  assert.equal(version, "v1");
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(iv, "base64url"));
  decipher.setAuthTag(Buffer.from(tag, "base64url"));
  return Buffer.concat([decipher.update(Buffer.from(ciphertext, "base64url")), decipher.final()]).toString();
}

test("QR payload is encrypted with a unique authenticated envelope and never logged", () => {
  const key = randomBytes(32);
  const rawQr = "temporary-whatsapp-pairing-payload";
  const first = encryptQrPayload(rawQr, key);
  const second = encryptQrPayload(rawQr, key);
  assert.notEqual(first, second);
  assert.equal(decryptQr(first, key), rawQr);
  assert.equal(first.includes(rawQr), false);
  assert.throws(() => encryptQrPayload(rawQr, Buffer.alloc(8)), /32 bytes/);
  assert.match(core, /QR ready/);
  assert.doesNotMatch(worker, /console\.log\([^\n]*qr|printQRInTerminal:\s*true/);
});

test("connection lifecycle covers QR replacement, connect, temporary drop, and logout", async () => {
  const writes = [];
  let cleared = 0;
  const events = [];
  const onEvent = createConnectionLifecycle({
    writeState: async (state, data = {}) => writes.push({ state, data }),
    clearSession: async () => { cleared += 1; },
    logger: (message) => events.push(message),
    now: () => 1_800_000_000_000,
  });
  await onEvent({ qr: "qr-one" });
  await onEvent({ qr: "qr-two" });
  await onEvent({ connection: "open", number: "6281234567890:12@s.whatsapp.net" });
  await onEvent({ connection: "close", errorCode: "NETWORK_ERROR" });
  await onEvent({ connection: "close", errorCode: "SESSION_LOGGED_OUT" });
  assert.deepEqual(writes.map((row) => row.state), ["WAITING_QR", "WAITING_QR", "CONNECTED", "CONNECTING", "DISCONNECTED"]);
  assert.equal(writes[0].data.expiresAt, new Date(1_800_000_055_000).toISOString());
  assert.equal(writes[2].data.number, "62••••••7890");
  assert.equal(cleared, 1);
  assert.ok(events.every((message) => !message.includes("qr-one") && !message.includes("qr-two")));
});

test("worker command handling is idempotent for replayed command IDs", async () => {
  const guard = new WorkerCommandGuard();
  let connects = 0;
  let disconnects = 0;
  const handlers = { connect: async () => { connects += 1; }, reconnect: async () => {}, disconnect: async () => { disconnects += 1; } };
  assert.equal(await guard.run("command-1", "CONNECT", handlers), true);
  assert.equal(await guard.run("command-1", "CONNECT", handlers), false);
  assert.equal(await guard.run("command-2", "DISCONNECT", handlers), true);
  assert.equal(connects, 1);
  assert.equal(disconnects, 1);
  await assert.rejects(() => guard.run("command-3", "SEND_MESSAGE", handlers), /Invalid provider command/);
});

test("connection control is OWNER-only and worker functions are service-role only", () => {
  assert.match(migration, /WHATSAPP_PROVIDER_CONTROL_DENIED/);
  assert.match(migration, /WHATSAPP_PROVIDER_QR_DENIED/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.whatsapp_provider_control_request\(text\) TO authenticated/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.whatsapp_provider_qr_read\(\) TO authenticated/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.whatsapp_provider_command_claim\(uuid,uuid\) TO service_role/);
  assert.match(migration, /FOR UPDATE SKIP LOCKED/);
  assert.match(migration, /worker_lease_expires_at=now\(\)\+interval '90 seconds'/);
  assert.match(actions, /profile\.role !== "OWNER"/);
  assert.match(actions, /\["OWNER", "ADMIN"\]\.includes\(profile\.role\)/);
  assert.match(actions, /profile\.role !== "OWNER"/);
  assert.match(actions, /QRCode\.toDataURL/);
  assert.doesNotMatch(actions, /console\.log\([^\n]*encrypted_payload/);
  assert.match(gitignore, /\.var\/whatsapp/);
});

test("connectivity worker cannot send or claim notifications", () => {
  assert.doesNotMatch(worker, /notification_outbox_claim|sendMessage|sendTransactionalMessage/);
  assert.doesNotMatch(worker, /notification_outbox/);
  assert.match(worker, /useMultiFileAuthState/);
  assert.match(worker, /createReconnectManager/);
  assert.match(worker, /maxRetries:\s*10/);
  assert.match(worker, /printQRInTerminal:\s*false/);
});

test("provider migration defaults are dormant and do not create jobs or issue QR", () => {
  assert.match(migration, /connection_state text NOT NULL DEFAULT 'NOT_CONFIGURED'/);
  assert.match(migration, /provider_key text NOT NULL DEFAULT 'QR_SESSION'/);
  assert.doesNotMatch(migration, /^INSERT INTO public\.(notification_outbox|whatsapp_provider_commands|whatsapp_provider_connections)/m);
  assert.doesNotMatch(migration, /UPDATE public\.(sales|sale_items|sale_payments|members|member_point_ledger|outlet_loyalty_settings|inventory_cost_projections)/);
  assert.equal(maskNumber("6281234567890@s.whatsapp.net"), "62••••••7890");
});
