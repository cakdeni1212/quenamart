# Native POS — P1B persisted carts

P1A architecture and locked product policy are documented in [POS Architecture](POS_ARCHITECTURE.md).

P1B migration `20260929330000_pos_cart_foundation_v1.sql` adds persisted `ACTIVE`, `PARKED`, and `CANCELLED` carts, cart lines, append-only cart events, and actor/payload-bound mutation requests. Carts are outlet-bound from the sole active stock authority period. KASIR can access its own carts; OWNER/ADMIN can access the authorized outlet's carts; GUDANG is denied. Carts and item snapshots survive refresh, are revision-guarded, and can have multiple open/parked instances. Cancellation preserves history.

Cart lines store server-resolved outlet selling price and price-history evidence, product display snapshots, and quantity to three decimals. Reads compare observed and current prices as `CURRENT`, `CHANGED`, or `UNAVAILABLE`; opening a parked cart does not silently reprice it. A controlled price acknowledgement updates the evidence only when the submitted confirmation matches the current server price. Repeated intentional barcode scans increase one product line; a request retry with the same UUID replays its saved result.

`pos_resolve_barcode` permits OWNER/ADMIN/KASIR, resolves exact active barcodes, and returns explicit not-found/ambiguous outcomes. `pos_search_products` is server-side and capped at 25 results. Both return POS-safe product, selling price, and informational stock fields only; they expose no HPP, WAC, cost layers, or profit. The existing stock barcode RPC remains unchanged.

P1B adds no completed sale state, checkout, payment, revenue, stock movement, costing event, or source-layer mutation. It does not reserve stock. Future completion must revalidate current price and stock and remain blocked until `WAC_ACTIVE`; then sale, payment, stock, and COGS must be atomic. POS v1 has no cashier manual discount. Payment storage is split-capable; the first completion UI will use one method. Unvalued sold quantity must remain explicitly unresolved, never zero COGS.

Validation uses `bash tests/staging/run-pos-cart-foundation-matrix.sh`, which clones the guarded local migration-300000 staging database, applies 310000–330000 to the disposable clone, runs the P1B transaction/rollback matrix, compares operational fingerprints, and drops only that clone. It never uses production.

## P1C cashier workspace

The `/kasir` route provides the first cashier UI over the persisted cart foundation installed in P1B. OWNER, ADMIN, and KASIR can access the route; GUDANG is redirected by the workspace role check. The cashier screen supports exact barcode resolution on Enter, debounced name/SKU/barcode search, quantity changes, explicit acknowledgement of changed prices, parking, resuming, and cancellation.

Cart state and commercial totals come from `pos_cart_workspace_read`. Mutations use the P1B server actions with a fresh request UUID and the read model revision. A stale revision triggers a reload. Empty ACTIVE cart creation is avoided when an ACTIVE cart already appears in the bounded P1B read model. The disabled Bayar button is informational only.

P1C does not complete sales, record payment, move stock, write COGS or revenue, activate WAC, or run bootstrap. Checkout remains pending a later phase. Product UI intentionally omits costing fields.

All editable Rupiah fields across the workspace use `RupiahInput` and `src/lib/money.ts`. The input displays Indonesian thousands separators while supplying exact canonical decimal strings to application state; future monetary inputs must reuse this component/parser rather than add custom formatting.

## P1D-A sale evidence foundation

Migration `20260929340000_pos_sales_evidence_v1.sql` adds native sale, item snapshot, split-capable tender, checkout-request, manager-protected COGS/source-layer allocation, and append-only future cost-resolution evidence schemas, plus the `COMPLETED` cart state/event values. It adds a private sequence for the future `QPOS-YYYYMMDD-NNNNNNNN` receipt number. Existing cart mutation functions still accept only ACTIVE carts; P1D-A adds no function capable of completing a sale.

At the P1D-A checkpoint, this was schema capability only: that migration added no public checkout RPC or sale/payment/stock/cost writer. Commercial sale tables had no direct client grants; future bounded receipt/history contracts must authorize reads. Cost evidence SELECT is restricted by RLS to OWNER/ADMIN for the single active outlet. Unknown COGS amounts remain nullable, with valued, provisional, and unvalued quantities represented separately. P1D-B implementation is described below.

## P1D-B atomic checkout capability

Migration `20260929350000_pos_atomic_checkout_v1.sql` adds the authenticated `pos_checkout_complete` operation and private `inventory_cost_apply_pos_sale` helper. Checkout serializes on the existing outlet costing cutover lock, requires an existing `WAC_ACTIVE` authority, rechecks the ACTIVE cart revision, current selling prices, stock projection, and open stock authority period, and writes immutable sale/payment evidence, QUENA_POS stock OUT, C3B source-layer outflows, SALE_COGS evidence, and cart completion in one transaction. It consumes unvalued stock first; unknown COGS amounts remain NULL. The public operation accepts request/cart/revision and tender details only; totals, outlet, actor, prices, stock, and cost come from trusted server/database state.

Generic movement reversal now rejects completed native POS SALE movements. P1D-B does not activate WAC or run bootstrap; checkout fails closed while authority is missing or not `WAC_ACTIVE`.

## P1D-C payment and receipt UI

The cashier `/kasir` workspace uses the existing `pos_checkout_complete` RPC through a server action. P1D-C adds one-method v1 tender selection (Tunai, QRIS, Kartu, or E-Wallet), cash received/change display, client-side double-submit protection, safe Indonesian domain errors, and a bounded commercial receipt read via `pos_sale_receipt_read`. The backend remains split-payment capable. Server-side checkout remains authoritative for price, stock, totals, payment calculation, role, and outlet.

After confirmed checkout, the cashier sees the sale number and commercial receipt, then chooses `Cetak Struk` or `Transaksi Baru`. Receipt printing uses the browser print dialog with 58 mm / 80 mm width preference. Print CSS hides the workspace and prints only the receipt. There is no gateway, QR generation, settlement verification, direct printer driver, discount, refund, reporting, WAC activation, or bootstrap. Receipts contain commercial sale and tender facts only; no HPP, WAC, COGS, source layers, inventory valuation, margin, or profit.

## Native sales history

`/kasir` remains the only transaction creation and checkout workspace. `/transaksi` is a read-only history of completed `QUENA_POS` sales with Jakarta-local date filtering, sale-number search, payment-method filtering, filtered sales/count/average summaries, and fixed 20-row server pagination. “Jumlah item” means distinct sold product lines (the immutable `sale_items` count), so unlike units such as pcs and kg are not added together. OWNER/ADMIN can read the active outlet; KASIR sees only their own completed sales, matching the existing receipt RPC policy. GUDANG has no access.

History rows and detail use sale-time snapshots and payment evidence; details and 58 mm / 80 mm receipt reprints reuse `pos_sale_receipt_read`. Split tenders are shown as `Campuran` in the list and as separate payment rows in detail/receipt. These read contracts return commercial fields only. Completed sales remain immutable; refunds/returns are a future workflow.

## Kasir & Penjualan settings

`/pengaturan/kasir-penjualan` manages outlet-scoped receipt presentation, supported checkout methods, whether new carts may be held, and whether the cashier confirms before cancelling an ACTIVE/PARKED cart. Defaults are read from the existing behavior when no settings row exists: all native methods (`CASH`, `QRIS`, `CARD`, `E_WALLET`), address/phone display, hold, and cancellation confirmation remain enabled; the optional footer note is blank. Transfer Bank is not offered because the checkout payment enum does not support it. Active-cart limits and separate completed-sale void controls remain deferred.

OWNER can update settings; OWNER/ADMIN can read the management view. POS uses a separate effective-settings RPC for OWNER/ADMIN/KASIR, while GUDANG cannot read it. New payment evidence is checked by a database trigger under the same outlet advisory lock as settings changes, so a stale cashier screen cannot submit a method after it is disabled; existing sale/payment history is untouched. A database guard blocks only new PARKED transitions when hold is disabled, leaving already held carts available to resume or cancel. Receipt footer/address/phone are current presentation settings and do not alter sale, payment, stock, or costing evidence. Migration `20260929475000_pos_settings_v1.sql` records OWNER changes in the existing outlet settings event stream.

## Member & Poin V1

`/pengaturan/member-poin` controls an outlet-scoped loyalty policy. Both the
program and redemption default OFF, preserving current Member behavior until
an OWNER explicitly enables and saves the policy. POS reads only the bounded
effective policy needed for the selected Member; checkout remains authoritative.

Checkout applies redemption before earning. For a Rp150.000 merchandise
subtotal and Rp20.000 point discount, the earn basis is Rp130.000 payable.
The configured integer threshold determines `floor(payable / threshold)`;
rates and minimum redemption are settings, not code constants. The existing
POS amount model has no separate tax, shipping, service, or transaction
discount fields.

Checkout rechecks active Member status, balance, policy revision, minimum,
redemption value, and payable amount before any sale or stock evidence is
written. Payment must equal final payable; point value cannot exceed the
merchandise amount and does not create cash change. A successful checkout
appends negative `SALE_REDEEM` and positive `SALE_EARN` events in the same
transaction as sale/payment/stock/COGS. Earning follows redemption and uses
the remaining payable. Retry returns the stored checkout result and cannot
append a second event. Ledger rows snapshot the policy used; current settings
never recalculate historical points.

Receipt and native sale detail show Member and ledger-backed points earned,
redeemed, and discount. IPOS_IMPORT remains unassigned and receives no loyalty
events. Completed-sale reversal/refund is not implemented; future reversals
must append offset events rather than edit the ledger. See `docs/LOYALTY.md`.

## No-app Member access

KASIR lookup accepts name, normalized WhatsApp/phone, immutable Member ID, and
an exact opaque POS token submitted with Enter. Search is bounded to 10 rows;
cashier phone fields are masked and the token is not returned. New cashier
enrollment requires service-consent acknowledgement, records promotional
WhatsApp consent separately (false unless explicitly selected), and creates
and attaches the Member to the active cart in one database transaction. It
does not award signup points. Existing held-cart Member associations remain
cart-scoped.

Public pages `/member-quena`, `/member-quena/daftar`, and `/member-quena/cek`
are outside the staff workspace. Registration uses a narrowly granted
service-role RPC from a server action; anonymous clients cannot read Member,
consent, point ledger, or sales data. The RPC stores keyed phone/IP digests for
bounded registration attempts and returns only a Member number or generic
duplicate/rate-limit result. Set `NEXT_PUBLIC_APP_URL` to the public HTTPS
origin to generate the generic registration QR in OWNER Member & Poin
settings. Member detail displays a staff-only QR containing the POS lookup
token; it is an identifier, never an authenticated web credential.

The points page deliberately does not accept a phone number or reveal a
balance: verified WhatsApp/OTP delivery is not configured. Customer point
portal sessions remain deferred; WhatsApp Center has an outbox foundation but
no provider or external sending. Checkout never calls a messaging provider. Secure digital receipts are
available separately for completed native sales; see
[`DIGITAL_RECEIPTS.md`](DIGITAL_RECEIPTS.md).

## Digital Receipt V1

Migration `20260929479000_digital_receipt_v1.sql` creates a hash-only,
revocable receipt identity for each newly completed `QUENA_POS` sale. It does
not backfill historical sales or create identities for `IPOS_IMPORT`. Staff
issue or rotate a 256-bit random link from authorized native transaction detail;
the database stores only SHA-256 and the customer route resolves exact matches
through a service-only narrow projection. Checkout does not need a public link
or external delivery to succeed. Public pages are dynamic and no-store.

The receipt uses sale-time product/tender/loyalty evidence. Outlet presentation
fields (display name, address, phone, footer) use current receipt settings where
older sale snapshots do not exist. The public view excludes member contact
details, internal identifiers, payment references, and all costing/profit
fields. Staff can open a relative link locally; a shareable absolute HTTPS URL
requires `NEXT_PUBLIC_APP_URL`. Migration `20260929480000_whatsapp_center_foundation_v1.sql`
adds an inactive-by-default notification outbox, transactional receipt
eligibility, OWNER settings, and an operational dashboard. A job is recorded
only when transaction automation, provider readiness, HTTPS URL readiness,
active Member, normalized WhatsApp, affirmative latest service consent, and a
receipt identity all exist. Promotional consent is independent. Checkout never
calls a provider. V1 has no actual provider, connection workflow, or external
send; the unconfigured adapter refuses work without retrying. See
[`WHATSAPP_CENTER.md`](WHATSAPP_CENTER.md).
