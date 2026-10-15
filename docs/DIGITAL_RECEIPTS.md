# Digital Receipt V1

Migration `20260929479000_digital_receipt_v1.sql` adds one outlet-bound,
hash-only public receipt identity for a completed native `QUENA_POS` sale.
Successful checkout creates an `UNISSUED` identity row; staff issue a 256-bit
random bearer link on demand. Only its SHA-256 hash is stored. Issuing another
link rotates the hash and immediately invalidates the preceding URL. Historical
sales are not backfilled, and imported `IPOS_IMPORT` sales never receive public
receipt identities.

`/struk/[token]` is a public, dynamic, read-only mobile page. A server-only
service-role boundary hashes the exact token and invokes a narrowly granted
receipt projection. Anonymous users have no direct table/function access to
sales, items, payments, Members, or point ledger. Invalid, unknown, or revoked
links share one not-found response. The route is private/no-store, no-referrer,
and excluded from indexing.

The receipt reads immutable sale number/time, item descriptions/prices and
totals, tender method/amount and persisted cash received/change, Member name/ID
only when attached, and point activity plus post-sale balance from the linked
immutable ledger snapshots. It omits customer phone/email, Member token, payment
reference, UUIDs, HPP, WAC, COGS, and profit. Outlet name/address/phone/footer
use current outlet receipt presentation settings because older sales do not
contain those display snapshots. Product names and loyalty evidence remain from
sale-time evidence and are never recalculated from current catalog or policy.

Authorized OWNER/ADMIN/KASIR users can issue a link from native transaction
detail; KASIR ownership is checked again by the database RPC. The customer can
print/save through browser print or share/copy the URL. Local development can
open a relative link. A copyable customer-facing absolute URL requires
`NEXT_PUBLIC_APP_URL` configured to the public HTTPS origin. It is not currently
configured in local development; do not substitute localhost as a public URL.

The server-only `getCustomerReceiptDeliveryPayload` contract is a preparation
boundary for a future worker. It requires a completed native sale, a normalized
Member WhatsApp destination, and latest affirmative `MEMBERSHIP_SERVICE`
consent; promotional consent is separate. It returns a scoped receipt URL and
safe delivery facts but sends nothing. There is no WhatsApp provider, queue,
OTP, member point portal session, campaign, or customer app. Any future
notification worker must remain asynchronous and outside checkout success.

The runtime matrix is `bash tests/staging/run-member-points-pg15.sh`; it applies
migrations 476000–479000 and rolls all receipt fixtures back on a disposable
PostgreSQL 15 cluster.
