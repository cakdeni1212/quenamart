# WhatsApp QR Session Provider

The `QR_SESSION` provider is a connectivity-only linked-device adapter. It uses `@chaeulso/baileys` 7.5.0, an MIT-licensed unofficial WhatsApp Web protocol client. It is not Meta Cloud API or a BSP. WhatsApp protocol changes may interrupt pairing or disconnect the session, and linked-device use can expose the account to restrictions.

## Local startup

Run these in separate terminals:

```sh
npm run dev -- -p 3001
npm run whatsapp:worker
```

The worker loads `.env.local`/`.env` and requires `SUPABASE_SERVICE_ROLE_KEY` plus `WHATSAPP_QR_HANDOFF_KEY`, a base64-encoded 32-byte key. Generate a local key with:

```sh
openssl rand -base64 32
```

Keep the key server-side. Never put it in `NEXT_PUBLIC_*`, browser storage, or source control. The worker stores its linked-device auth under `.var/whatsapp/<outlet-id>` with restrictive permissions; this path is git-ignored. QR payloads are encrypted for temporary database handoff, available only to OWNER through server actions, and expire after about one minute.

## Hosting and safety

Production requires a persistent Node process and encrypted persistent storage for the session directory. Do not run the worker on ephemeral serverless storage. Web requests are only a control plane; the persistent worker owns session lifecycle and heartbeat. A database lease prevents two workers from controlling one outlet at a time.

This checkpoint does not process the notification outbox and contains no customer-message sender. Pairing does not change WhatsApp automation preferences. POS checkout does not depend on the worker.

## Dependency license

`@chaeulso/baileys` declares MIT, while its runtime dependency `libsignal@6.0.0` declares GPL-3.0. Private server hosting does not provide the transport to customers, but redistribution of a worker/runtime package needs license review and any applicable notices/source obligations.
