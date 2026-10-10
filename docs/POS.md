# Native POS — P1B persisted carts

P1A architecture and locked product policy are documented in [POS Architecture](POS_ARCHITECTURE.md).

P1B migration `20260929330000_pos_cart_foundation_v1.sql` adds persisted `ACTIVE`, `PARKED`, and `CANCELLED` carts, cart lines, append-only cart events, and actor/payload-bound mutation requests. Carts are outlet-bound from the sole active stock authority period. KASIR can access its own carts; OWNER/ADMIN can access the authorized outlet's carts; GUDANG is denied. Carts and item snapshots survive refresh, are revision-guarded, and can have multiple open/parked instances. Cancellation preserves history.

Cart lines store server-resolved outlet selling price and price-history evidence, product display snapshots, and quantity to three decimals. Reads compare observed and current prices as `CURRENT`, `CHANGED`, or `UNAVAILABLE`; opening a parked cart does not silently reprice it. A controlled price acknowledgement updates the evidence only when the submitted confirmation matches the current server price. Repeated intentional barcode scans increase one product line; a request retry with the same UUID replays its saved result.

`pos_resolve_barcode` permits OWNER/ADMIN/KASIR, resolves exact active barcodes, and returns explicit not-found/ambiguous outcomes. `pos_search_products` is server-side and capped at 25 results. Both return POS-safe product, selling price, and informational stock fields only; they expose no HPP, WAC, cost layers, or profit. The existing stock barcode RPC remains unchanged.

P1B adds no completed sale state, checkout, payment, revenue, stock movement, costing event, or source-layer mutation. It does not reserve stock. Future completion must revalidate current price and stock and remain blocked until `WAC_ACTIVE`; then sale, payment, stock, and COGS must be atomic. POS v1 has no cashier manual discount; split-payment storage is a future checkout concern, while the first completion UI will use one method. Unvalued sold quantity must remain explicitly unresolved, never zero COGS.

Validation uses `bash tests/staging/run-pos-cart-foundation-matrix.sh`, which clones the guarded local migration-300000 staging database, applies 310000–330000 to the disposable clone, runs the P1B transaction/rollback matrix, compares operational fingerprints, and drops only that clone. It never uses production.
