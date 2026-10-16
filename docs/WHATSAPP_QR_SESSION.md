# WhatsApp QR Session through WAHA

Quena uses WAHA as a separate, self-hosted WhatsApp service. Quena's server makes authenticated HTTP requests to WAHA; the browser never calls WAHA or receives its API key. WAHA owns the linked-device session. This checkpoint is connectivity only: Quena does not send messages or process the notification outbox.

WAHA is an unofficial WhatsApp Web integration, not Meta Cloud API or a BSP. Its protocol compatibility can change, linked sessions can disconnect, and account restrictions are possible. The provider has no per-message BSP fee; a hosted deployment still has infrastructure costs.

## Local setup

1. Copy `infra/waha/waha.env.example` to the ignored `infra/waha/waha.env`.
2. Generate a strong random secret, use it as `WAHA_API_KEY`, and put its SHA-512 hex digest (128 hex characters) in `WAHA_API_KEY_SHA512`. WAHA receives only the hash. Copy the raw key to Quena's ignored `.env.local`.
3. For Apple Silicon, keep the pinned ARM image. On x86_64, set `WAHA_IMAGE=devlikeapro/waha:gows-2026.9.2`.
4. Start WAHA:

   ```sh
   docker compose --env-file infra/waha/waha.env -f infra/waha/compose.yaml up -d
   ```

5. Add these server-only values to Quena `.env.local` (use the same raw key):

   ```dotenv
   WAHA_BASE_URL=http://127.0.0.1:3000
   WAHA_API_KEY=<same raw random key>
   WAHA_SESSION_NAME=quena-mart
   ```

6. Start Quena:

   ```sh
   npm run dev -- -p 3001
   ```

7. Open `http://localhost:3001/whatsapp` and use **Hubungkan WhatsApp**. Pairing is a manual OWNER action. This implementation does not scan a QR automatically.

The Compose file binds WAHA only to loopback and stores sessions in the named Docker volume `waha_sessions`. That volume survives container and host restarts. Do not delete it unless you intend to remove the linked-device session. Quena does not store WAHA session credentials.

## Provider and security boundary

The pinned image is WAHA `2026.9.2`, using the **GOWS** engine (`devlikeapro/waha:gows-arm-2026.9.2` by default; x86 alternative `devlikeapro/waha:gows-2026.9.2`). GOWS uses a WebSocket transport and does not require Chromium. The WAHA API key is sent only in the server-side `X-Api-Key` header. The key and the WAHA endpoint must not use `NEXT_PUBLIC_*` variables.

Production requires a persistent Docker/container host, a persistent session volume, a private WAHA API endpoint reachable only by Quena's server, and server-side API-key configuration. Do not expose WAHA's API port to customers or the public internet. In a containerized Quena deployment, use the private service hostname rather than localhost.

OWNER may start pairing, retrieve the temporary QR, reconnect, or unlink the device. ADMIN may view status only; KASIR, GUDANG, and anonymous users have no provider access. QR data is fetched from WAHA on demand, passed only to the OWNER, and is not stored in Quena or logged. Disconnect stops and logs out the WAHA session; a new QR scan is then required.

## Messaging remains disabled

The adapter intentionally has no send-message method. No customer message, test message, receipt, OTP, or campaign is sent. The notification outbox is not claimed or processed. Connecting WAHA does not change stored WhatsApp preferences, public URL readiness, or the existing notification eligibility state.

The pending migration `20261016100000_whatsapp_qr_session_provider_v1.sql` now creates only an append-only OWNER control-request audit table and its narrow OWNER-only RPC. It does not store provider state, QR material, session credentials, or worker leases, and does not touch outbox/settings/sales data. It remains pending and must be reviewed/deployed separately before the new control action can write its audit event.
