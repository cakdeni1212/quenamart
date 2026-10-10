# Costing Engine v1

## Checkpoint 1: cost ledger and bootstrap foundation

Migration `20260929250000_costing_wac_foundation_v1.sql` is deployed to Quena Mart production. It installs capability only: no automatic bootstrap, historical backfill, purchase posting integration, invoice adjustment, landed-cost workflow, POS, or COGS posting is included. The production costing tables and authority state remain empty; bootstrap has not been run and WAC is not active.

## Checkpoint A: initial HPP acceptance (deployed capability)

Migration `20260929260000_costing_initial_hpp_acceptance_v1.sql` is deployed as a capability for one-time cutover evidence to accept legacy opening HPP. It is not normal product HPP verification, does not rewrite `product_costs`, `product_cost_history`, or iPos source rows, and does not create costing authority, projection, or bootstrap events. The deployed acceptance tables are empty until a manager explicitly prepares a batch.

The bounded OWNER/ADMIN preview classifies current positive-stock products from live database facts. An automatic candidate requires positive HPP within existing bounds/scale; valid current product/outlet/source-row/import-batch/normalization provenance; current HPP equal to normalized source HPP; matching latest cost history; no active HPP override, source conflict, unresolved review, or open HPP cost finding; and a positive selling price strictly above HPP. Missing HPP, explicit zero, and HPP equal to or above selling price are blocking exceptions. Margin at or below 5%, margin above 80%, Rp1 HPP, and a high absolute HPP outlier are separate warnings, not blockers.

OWNER and ADMIN may prepare a deterministic snapshot and resolve exceptions with a required reason. Supported dispositions are `ACCEPT_CURRENT_HPP`, `OPENING_HPP_OVERRIDE`, `LEAVE_UNVALUED`, and `AUTHORITATIVE_ZERO`. Explicit zero is available only when current HPP is actually zero; missing HPP cannot be represented as zero. An opening override is cutover-only evidence and never updates legacy HPP. Final approval is OWNER-only. Approval freezes evidence but does not bootstrap or activate WAC.

Preparation snapshots unit-cost trust evidence, not stock quantity authority. Relevant source/HPP/history/review/override/finding/selling-price changes make the batch stale; quantity-only changes do not. Future bootstrap must take current effective quantity from `stock_balance_projection`. Approved acceptance is one-time evidence and cannot be reused to let later iPos imports reset WAC. Production bootstrap remains explicitly on hold until its separate authorization and integration checkpoints are completed.

### Checkpoint B: Persiapan HPP Awal UI

The protected `/hpp-awal` workspace is available to OWNER and ADMIN. It reads the bounded Checkpoint A preview, paginates/searches server-side, defaults to exceptions, and separates informational warnings from blockers. Preparation is an explicit action. OWNER/ADMIN can resolve prepared exceptions with a required reason; only OWNER can approve a complete, current batch. Approved evidence is shown read-only. This page calls only the Checkpoint A preview, prepare, resolve, and approve contracts. It does not prepare on page load, bootstrap, activate WAC, or mutate stock/HPP data.

## Three separate authorities

- **Quantity authority:** `stock_balance_projection`. Effective stock quantity is derived from its baseline and controlled movement deltas. Never derive Quena stock from purchase or cost tables.
- **Legacy/reference cost:** `product_costs.hpp` and append-only `product_cost_history`, with iPos import and product-field-review provenance. These remain source/reference data; do not turn them into WAC state.
- **Future WAC valuation authority:** `inventory_cost_projections`, backed by immutable `inventory_cost_event_batches` and `inventory_cost_events`. WAC is not authoritative until the outlet reaches `WAC_ACTIVE` after all relevant stock writers have transactionally integrated cost.

`inventory_costing_outlet_authority` represents outlet cutover state. No row means `REFERENCE_ONLY`. The foundation bootstrap creates `BOOTSTRAP_READY`; this means the initial cost snapshot exists but writers are not yet cost-integrated. `WAC_ACTIVE` is reserved for a later controlled activation. The current migration intentionally does not provide an activation operation.

## Valuation status

- `VALUED`: the current positive quantity has an authoritative or computed value; for zero quantity the inventory value is zero and WAC is NULL because there is no on-hand unit cost.
- `PROVISIONAL`: a known estimate exists but final acquisition cost is pending. Later confirmed cost must be appended as an adjustment event.
- `UNVALUED`: cost is unknown. Inventory value and WAC remain NULL; unknown cost is never converted to zero.

Checkpoint 1 bootstrap uses `stock_balance_projection.effective_quantity` and its balance version. A positive quantity is `VALUED` only when the current outlet-scoped `product_costs.hpp` is non-null, within its existing numeric bounds, tied to a valid current iPos row, and has a latest matching `SUDAH_DIVERIFIKASI` HPP review. A verified zero HPP is allowed as explicit evidence. Otherwise the row is `UNVALUED`. Zero stock has value 0 and NULL WAC, regardless of HPP; this represents no inventory value and does not assert a zero unit cost. A NULL effective quantity remains `UNVALUED` with NULL value/WAC.

Checkpoint A is not yet wired into this bootstrap contract. The deployed bootstrap RPC still uses the stricter normal-review requirement described above; acceptance evidence cannot be consumed until a separately reviewed bootstrap-integration checkpoint changes that contract.

The bootstrap records one `OPENING` event per stock projection row, including outlet/product, the stock authority period and balance version, quantity snapshot, source HPP and review/import provenance when verified, actor, request, and cost version. It does not change stock projection, `product_inventory`, HPP, HPP history, or old purchase/stock records. The request UUID is bound to the authenticated OWNER/ADMIN, operation, outlet, and canonical payload. Exact replay returns the stored result; a new request against an already bootstrapped outlet reports `ALREADY_BOOTSTRAPPED` and never resets cost state.

## Append-only and security rules

Cost batches and applied events cannot be updated or deleted. Future corrections use new compensating events. The cost projection is a mutable derived value, but authenticated direct DML is revoked and only future controlled database operations may update it. Bootstrap and the bounded read are manager-only. OWNER/ADMIN may inspect costs; GUDANG and KASIR receive no direct cost table rows and are denied by the RPC. Do not add cost fields to general stock RPCs or operational GUDANG projections.

Internal WAC uses `numeric(20,8)` unit cost and `numeric(32,8)` inventory value. Stock quantities retain the existing three-decimal rules; source invoice/landed-cost money remains two-decimal. PostgreSQL `numeric` is the calculation authority. Future monetary allocations must use deterministic largest-remainder allocation with stable identifier tie breaks and exactly reconcile to the two-decimal source amount.

## Future integration points

1. Receipt post must apply quantity and provisional/known acquisition value in one transaction.
2. Invoice finalization must append an invoice adjustment allocation; it must not post stock or change payable semantics.
3. Landed costs need separate auditable cost records and allocation events; they are not supplier payable.
4. POS sale must atomically post stock and cost/COGS. Provisional or unvalued sales remain identifiable; never silently book zero COGS.
5. Before POS launch, specify the consumed-versus-on-hand split for late invoice/landed-cost adjustments. Historical movement and sale rows stay immutable; already-consumed share is a current-period cost/COGS adjustment, while remaining value updates inventory/WAC.
6. Supplier returns, customer returns, stock adjustments, and reversals need cost events coordinated with their stock operation.

Later iPos imports may update legacy `product_costs` according to the existing import contract, but must not reset or overwrite the separate WAC projection after activation. Existing pre-cutover stock, receipts, and invoices are represented by the explicit opening valuation; do not fabricate historical WAC events.

### C3A: receipt acquisition evidence and partial valuation (local review)

Forward migration `20260929290000_costing_purchase_receipt_acquisition_v1.sql` adds manager-protected, append-only receipt-item estimate revisions and the database contract for receipt acquisition costing. OWNER/ADMIN may read and manage estimates through `purchase_receipt_acquisition_estimate_save`; GUDANG has no SELECT or financial response path, and KASIR is denied. Estimate values are IDR, exact to two decimal places. Positive estimates are provisional; explicit zero requires `AUTHORITATIVE_ZERO` and a nonblank reason; removal creates a tombstone revision. Estimates are frozen as posting evidence and cannot be edited after receipt posting.

Receipt draft saves now reconcile by product and preserve item IDs for retained products. Removed items are deleted from the live draft; any active estimate is first superseded by an immutable `REMOVED` revision tied to the stable item identity, so evidence cannot attach to a replacement item accidentally.

The costing projection now explicitly tracks `physical_quantity`, `valued_quantity`, `provisional_quantity`, and `unvalued_quantity`. Physical quantity mirrors `stock_balance_projection`; it is not quantity authority. The invariant is physical = valued + unvalued, provisional is a subset of valued, and WAC divides inventory value by valued quantity only. A positive receipt with no valuation basis adds unvalued quantity without inventing zero value. If existing current WAC is available, it is the second-priority provisional basis; therefore the no-basis partial-inventory example applies only when neither estimate nor usable WAC is available. No verified iPos HPP fallback is enabled in C3A because the strict cutover verification evaluator is not exposed as a reliable receipt-post basis contract.

Receipt posting still posts stock only in `REFERENCE_ONLY`. It is blocked during `BOOTSTRAP_READY`. In `WAC_ACTIVE`, stock posting and generated `PURCHASE_RECEIPT` cost events/projection changes run in the same transaction. The writer takes the same outlet cutover advisory lock as bootstrap, then locks stock rows by product, the stock authority period, and costing projections by product. It records source item uniqueness in addition to request replay protection. The C3A migration does not activate WAC, bootstrap, or change outlet authority. Invoice reconciliation, landed costs, returns, sale COGS, and integration of other stock writers remain future work; WAC must not be activated until all relevant stock writers are costing-integrated.

### C3B: opname source layers and reversal costing (local implementation)

Forward migration `20260929300000_costing_stock_opname_source_layers_v1.sql` adds protected source quantity provenance for opening, receipt, and opname cost events. A source layer records where quantities came from and whether remaining units are valued, provisional, or unvalued. Its balance is a mutable projection reconciled to an append-only allocation ledger. Allocation rows carry quantity provenance only; they do not carry or assign acquisition values.

**Source layers are not FIFO or LIFO costing.** `inventory_cost_projections` remains the aggregate financial authority. A valued stock outflow removes inventory value at the current aggregate WAC, except final valued-quantity exhaustion removes the exact residual inventory value. Quantity provenance is apportioned proportionally in exact thousandths using largest remainder and stable layer/bucket ordering. Unvalued quantity leaves first; provisional and final-valued quantities share the valued allocation proportionally.

Positive unexplained opname variance becomes an `OPNAME_ADJUSTMENT` event and an unvalued source layer. It does not use current WAC or create zero-cost inventory. Negative variance consumes unvalued units first, then proportionally consumes valued source quantities while financial value follows aggregate WAC. A reversal inverts the original event and original layer allocations. It is blocked when later activity has touched an affected source layer; the operator must use a future compensating stock correction rather than rewriting history.

Under `REFERENCE_ONLY`, existing stock posting and reversal remain unchanged and no costing state is written. Under `BOOTSTRAP_READY`, opname posting and movement reversal are rejected before stock mutation, without terminalizing the pending stock request. Under `WAC_ACTIVE`, stock, costing event/projection, source-layer balances, and allocation evidence are part of the same transaction. The wrapper uses the shared outlet cutover advisory lock before request/operation locks. Bootstrap and C3A receipt posting now open matching source layers atomically with their existing writers.

C3B does not activate WAC and does not run bootstrap. Other stock-changing writers, including sales, supplier returns, manual correction, and any stock writer not explicitly integrated with costing, remain activation blockers. Future sales must allocate valued and unvalued source quantities explicitly; unknown/unvalued COGS must never be represented as zero. A later unvalued-quantity valuation writer must append evidence for only the source layer's remaining units.

### Checkpoint C3C: manual stock correction

OWNER and ADMIN may create a documented, multi-line correction draft and post it through the controlled stock movement engine. GUDANG and KASIR cannot create or post these corrections. Reasons use a bounded category and required human-readable text; `OTHER` requires a longer explanation. Drafts are revision-guarded and editable/cancellable; posted corrections are immutable. Every posted line is linked to its stock movement and posting request, and source-level uniqueness prevents a second movement or cost event for that line.

Manual stock-in increases physical stock as UNVALUED. It never uses current WAC or legacy HPP and never creates fake zero cost. Manual stock-out consumes unvalued source quantities first, then valued source quantities proportionally. Financial value leaves at aggregate current WAC, with exact remaining value removed when the last valued units are depleted. Source layers preserve quantity provenance only; they are not FIFO/LIFO carrying-value layers. Standard movement reversal reuses the original C3B allocation and recorded value and is blocked if later source-layer activity makes exact restoration unsafe.

Under `REFERENCE_ONLY`, the existing controlled stock ledger posts the correction without cost-event, projection, layer, or allocation writes. Under `BOOTSTRAP_READY`, posting is blocked before any stock/request mutation and remains retryable. Under `WAC_ACTIVE`, movement, stock projection, cost event/projection, layer changes, and allocation evidence commit in one transaction under the shared outlet cutover lock. This capability does not activate WAC. Sales, supplier returns, and any other stock writer not yet integrated remain activation blockers.
