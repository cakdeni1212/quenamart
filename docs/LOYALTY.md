# Member and Loyalty Foundation

## Implemented in Member Core V1

- Customer Member identity is separate from staff `auth.users` and profiles.
- Members are outlet-scoped, have immutable generated `QMEM-########` IDs, and
  an opaque UUID lookup token suitable for future barcode/QR use.
- Phone display preserves the entered string. Lookup normalization removes
  punctuation, maps `00` international prefixes, and maps Indonesian leading
  `0` to country code `62`. An active member phone can occur only once per
  outlet; duplicate creation is rejected and the existing member is surfaced.
- OWNER/ADMIN have the bounded Member workspace. KASIR receives only the
  bounded active-member lookup needed by POS and cannot access the workspace;
  GUDANG has no Member access.
- A selected active Member is stored on the POS cart and the completed native
  Quena sale references the canonical Member UUID. Checkout revalidates and
  locks the active member before recording the sale. Imported iPos sales stay
  unassigned because their source report has no member identity evidence.
- Member transaction totals are derived from completed `QUENA_POS` sales.
- The append-only point ledger is the future point-balance source. New members
  start at zero. Ledger rows cannot be updated or deleted through application
  roles. No earning events are generated yet.

## Not implemented yet

- Point earning policy or conversion value
- Point redemption, minimum redemption, eligible products/categories
- Reward catalog, tiers, expiration, promotions, or member-facing PWA
- Manual point adjustment UI or opening balance import
- iPos member attribution

No earning, redemption, expiration, or point value is hard-coded. `Member &
Poin` remains marked as coming soon in Settings until those policies have their
own implementation.

## Database boundary

Migration `20260929476000_member_core_v1.sql` is forward-only from the
production frontier `20260929475000`. Member, audit, and point-ledger tables
have RLS forced and direct browser DML revoked. Mutations use bounded
authenticated RPCs. The point-ledger foundation has no user-facing write RPC
in V1; future policy events must be appended by a controlled audited operation.
