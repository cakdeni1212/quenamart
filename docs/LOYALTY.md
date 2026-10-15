# Member and Loyalty

## Member Core V1

- Customer Member identity is separate from staff `auth.users` and profiles.
- Members are outlet-scoped, have immutable generated `QMEM-########` IDs, and
  an opaque UUID lookup token suitable for future barcode/QR use.
- Phone display preserves the entered string. Lookup normalization removes
  punctuation, maps `00` international prefixes, and maps Indonesian leading
  `0` to country code `62`. An active member phone can occur only once per
  outlet.
- OWNER/ADMIN have the bounded Member workspace. KASIR receives only the
  bounded active-member lookup needed by POS; GUDANG has no Member access.
- A selected active Member is stored on the POS cart and completed native
  Quena sales reference the canonical Member UUID. Checkout locks and
  revalidates the Member. Imported iPos sales stay unassigned because their
  source report has no member identity evidence.
- Member transaction totals derive from completed `QUENA_POS` sales. The
  append-only point ledger is the point-balance source. New members start at
  zero; creating a member does not award points.

## Configurable Member & Poin V1

`/pengaturan/member-poin` manages outlet-scoped earning and redemption policy.
Migration `20260929477000_member_loyalty_policy_v1.sql` creates no active
policy: both the program and redemption default OFF. Deploying it does not
change existing member balances or enable earning. OWNER can read and update;
ADMIN can read; KASIR can consume only the bounded effective policy needed for
POS; GUDANG is denied. Changes append `LOYALTY_SETTINGS_UPDATED` audit evidence
with changed field names and actor/time.

When enabled, native POS earns `floor(final_payable / rupiah_per_point)` whole
points. Eligible spend is the merchandise amount after point redemption; the
current checkout has no separate tax, shipping, service, or transaction
discount concept. Redemption is partial and uses the configured point value
and minimum. It cannot exceed payable or create cash change. Checkout locks
and revalidates member status, balance, current policy revision, and requested
redemption before writing any sale, payment, stock, costing, or point evidence.

If one sale both redeems and earns, redemption is applied first. Earning uses
the remaining payable. For example, a Rp150.000 subtotal with Rp20.000 point
discount has Rp130.000 eligible spend. A Rp10.000 earn threshold would award
13 points. Those example values are illustrative only; no business rate is
hard-coded.

`SALE_REDEEM` ledger deltas are negative and `SALE_EARN` deltas are positive.
They are appended atomically with completed native sale evidence, at most once
per sale and event type. Each event snapshots policy revision, effective
conversion value, eligible spend or discount, awarded/consumed points, and
event-time balance. Later policy changes do not reinterpret old events. A
zero-point earn creates no ledger event. `IPOS_IMPORT` does not earn or redeem
because the import source has no trustworthy Member association.

The receipt and native sale detail show only point facts captured from the
sale ledger. Official revenue, COGS, gross-profit completeness, and inventory
valuation contracts are unchanged by loyalty; point discounts reduce the
sale’s payable and payment evidence. Loyalty settings themselves do not
mutate stock, WAC, or existing Member history.

## Deferred

- Tiers, birthday/signup bonuses, campaigns, multipliers, reward catalog, and
  expiration.
- Manual point adjustment and opening-balance import UI.
- Completed-sale refund/reversal workflow. The ledger supports future
  offsetting reversal event types, but the application has no authoritative
  completed-sale reversal operation yet.
- iPos Member attribution.

## No-app Member access V1

Migration `20260929478000_member_public_access_foundation_v1.sql` adds public
web registration, append-only consent evidence, hashed attempt windows, and a
server-only service-role registration RPC. Membership service consent is
required; WhatsApp promotional consent is recorded separately and defaults
false. Public registration returns only the generated Member number. The
server derives keyed IP/normalized-phone digests and the database limits a
network digest to 10 registrations/hour and a phone digest to 3/hour. Public
roles receive no Member, consent, ledger, or registration-table grants.

`/member-quena` is the no-app landing page and `/member-quena/daftar` creates a
Member without staff login. `/member-quena/cek` is a fail-closed verification
placeholder: phone-only point lookup is not available until a verified
WhatsApp/OTP channel is configured. Signup does not create a portal session or
expose points/history. No WhatsApp provider or customer app is integrated.

POS lookup continues to use the canonical Member ID, normalized phone/name,
and exact opaque Member token. Enter on the Member field performs exact lookup;
cashier results expose a masked phone and no opaque token. Cashier enrollment
requires service consent, keeps promotional consent independent, and atomically
attaches the new Member to the active cart. Registration itself awards no
points. The personal QR on staff-only Member detail encodes only the existing
POS lookup token; it is not a portal credential. `/pengaturan/member-poin`
shows the generic registration QR only to OWNER and only when
`NEXT_PUBLIC_APP_URL` is configured to HTTPS (or local development); that QR
opens the generic landing page and does not identify a Member.

Customer point portal sessions, external WhatsApp OTP/receipts, customer-facing
personal card access, and asynchronous notification delivery remain deferred.
Secure digital receipts are implemented for completed native sales; their
Member and point summary is sourced only from the sale-linked immutable ledger
snapshots. No current loyalty policy is used to recalculate a receipt. The
customer roadmap is mobile web plus WhatsApp, not an installable customer app.
See `docs/DIGITAL_RECEIPTS.md`, `docs/POS.md`, and `docs/DATABASE.md` for receipt
and access boundaries.

No earn or redemption rate is seeded as business truth. Member identity and
history remain usable while the program is OFF; disabling it preserves every
existing balance and ledger event.

## Database boundary

Migrations `20260929476000_member_core_v1.sql` and
`20260929477000_member_loyalty_policy_v1.sql` are forward-only. Member,
settings, audit, and point-ledger tables keep direct browser DML revoked and
use bounded authenticated RPCs. The point ledger is append-only; the unique
sale/event constraint and checkout request idempotency prevent duplicate
earn/redemption. See `docs/POS.md` for the checkout and POS read boundary.
