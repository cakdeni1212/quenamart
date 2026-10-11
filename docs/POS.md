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

## P1D-A sale evidence foundation

Migration `20260929340000_pos_sales_evidence_v1.sql` adds native sale, item snapshot, split-capable tender, checkout-request, manager-protected COGS/source-layer allocation, and append-only future cost-resolution evidence schemas, plus the `COMPLETED` cart state/event values. It adds a private sequence for the future `QPOS-YYYYMMDD-NNNNNNNN` receipt number. Existing cart mutation functions still accept only ACTIVE carts; P1D-A adds no function capable of completing a sale.

At the P1D-A checkpoint, this was schema capability only: that migration added no public checkout RPC or sale/payment/stock/cost writer. Commercial sale tables had no direct client grants; future bounded receipt/history contracts must authorize reads. Cost evidence SELECT is restricted by RLS to OWNER/ADMIN for the single active outlet. Unknown COGS amounts remain nullable, with valued, provisional, and unvalued quantities represented separately. P1D-B implementation is described below.

## P1D-B atomic checkout capability

Migration `20260929350000_pos_atomic_checkout_v1.sql` adds the authenticated `pos_checkout_complete` operation and private `inventory_cost_apply_pos_sale` helper. Checkout serializes on the existing outlet costing cutover lock, requires an existing `WAC_ACTIVE` authority, rechecks the ACTIVE cart revision, current selling prices, stock projection, and open stock authority period, and writes immutable sale/payment evidence, QUENA_POS stock OUT, C3B source-layer outflows, SALE_COGS evidence, and cart completion in one transaction. It consumes unvalued stock first; unknown COGS amounts remain NULL. The public operation accepts request/cart/revision and tender details only; totals, outlet, actor, prices, stock, and cost come from trusted server/database state.

Generic movement reversal now rejects completed native POS SALE movements. The Bayar control remains disabled in P1C; this migration does not add cashier payment or receipt UI, gateway settlement, refunds, WAC activation, or bootstrap. Checkout fails closed while authority is missing or not `WAC_ACTIVE`.
