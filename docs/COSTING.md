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
