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

- Tiers, birthday/signup bonuses, campaigns, multipliers, reward catalog,
  expiration, and member-facing PWA/card.
- Manual point adjustment and opening-balance import UI.
- Completed-sale refund/reversal workflow. The ledger supports future
  offsetting reversal event types, but the application has no authoritative
  completed-sale reversal operation yet.
- iPos Member attribution.

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
