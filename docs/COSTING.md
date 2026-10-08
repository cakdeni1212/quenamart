# Costing Engine v1

## Checkpoint 1: cost ledger and bootstrap foundation

Migration `20260929250000_costing_wac_foundation_v1.sql` is deployed to Quena Mart production. It installs capability only: no automatic bootstrap, historical backfill, purchase posting integration, invoice adjustment, landed-cost workflow, POS, or COGS posting is included. The production costing tables and authority state remain empty; bootstrap has not been run and WAC is not active.

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
