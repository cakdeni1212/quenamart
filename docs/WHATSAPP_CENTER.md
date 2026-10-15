# WhatsApp Center Foundation V1

Migration `20260929480000_whatsapp_center_foundation_v1.sql` adds an
outlet-scoped generic notification outbox for `WHATSAPP` / `DIGITAL_RECEIPT`.
WhatsApp master and automatic receipt settings default OFF; provider state is
`NOT_CONFIGURED`; public URL readiness is false. Applying the migration does
not backfill history or create jobs.

An after-checkout trigger records at most one intent per channel/type/sale,
inside the checkout transaction, only for a completed `QUENA_POS` sale with an
active Member, normalized WhatsApp destination, latest affirmative
`MEMBERSHIP_SERVICE` consent, enabled automation, connected provider readiness,
HTTPS URL readiness, and a receipt identity. Promotional consent is neither
required nor treated as service consent. `IPOS_IMPORT` is never eligible. The
trigger catches notification-only failures so they cannot roll back sale,
stock, costing, payment, or loyalty evidence.

The payload is a bounded `DIGITAL_RECEIPT_V1` snapshot of customer display name,
normalized destination, sale number/total, selected loyalty facts, consent
evidence reference, outlet display name, and a receipt identity reference. It
does not store HPP/COGS/WAC/profit, customer email, provider credentials, or a
receipt bearer token/URL. A future worker must resolve a secure receipt URL
ephemerally before send; persistent bearer-token escrow and external delivery
are deliberately not implemented in V1.

`/whatsapp` is an OWNER/ADMIN dashboard with bounded masked history; transaction
detail shows the per-sale delivery state. `/pengaturan/whatsapp` permits OWNER
updates and ADMIN read-only access. KASIR can read only its own sale's delivery
status; GUDANG and anon have no WhatsApp management/read access. Browser roles
have no direct outbox table access. Settings audit stores changed booleans and
actor/time. Cancellation is OWNER-only for pending/retry jobs.

The server-only provider adapter is intentionally unconfigured and performs no
network calls. It returns `NOT_CONFIGURED` / `PROVIDER_NOT_CONFIGURED`; the
worker claim boundary declines to claim jobs while disconnected. The database
claim contract uses a five-minute lease, `FOR UPDATE SKIP LOCKED`, and at most
five attempts with 1, 5, 30, and 120 minute retry delays; SENT, FAILED, and
CANCELLED are terminal. Actual WhatsApp sending remains disabled.

`NEXT_PUBLIC_APP_URL` must be configured to a real public HTTPS origin before
future outbound messages. Do not use localhost, loopback, or LAN addresses.
Provider state and URL readiness are infrastructure-owned and cannot be
changed through the settings UI. The V1 interface does not connect an account.

Not implemented: Meta Cloud API, BSP, QR-session WhatsApp Web, OTP, outbound
delivery, AI/chatbot, marketing campaigns, customer app, and retention purge.
Provider secrets must stay server-side in future secret infrastructure and
must never enter browser storage, `NEXT_PUBLIC_*`, outbox snapshots, or audit
events. Delivery attempts are retained as operational evidence.

Runtime proof runs through `bash tests/staging/run-member-points-pg15.sh`, which
creates and removes a disposable PostgreSQL 15 cluster. It tests default-off
behavior, consent and source eligibility, owner/admin/cashier access, immutable
safe snapshots, one-job idempotency, a concurrent `SKIP LOCKED` claim, bounded
retry, and SENT terminal behavior. The test uses a fake database provider key;
it makes no network requests.
