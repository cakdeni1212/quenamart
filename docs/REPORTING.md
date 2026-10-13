# Reporting

Reporting definitions for revenue, COGS, gross profit, operating expenses, inventory value/capital, transaction count, average basket, supplier outstanding debt, member analytics, historical period comparison, and charts must remain explicit. Define accounting and date-boundary semantics before calculating totals. HPP, capital, and profit are sensitive; restrict both UI and server/database reads by role. Dashboard figures must come from bounded read models and must distinguish confirmed zero from unavailable evidence.

## Operating expenses

The `/pengeluaran` ledger records expenses already paid/incurred for operating the store. Only `POSTED` expense evidence contributes to expense summaries; `DRAFT` and `CANCELLED` records do not. Supplier invoices and payments, stock receipts/acquisition cost, supplier returns, stock corrections, and sale COGS remain in their own ledgers and are never counted as operating expenses. Dashboard `Laba Operasional` is shown only when same-day sale-time COGS is resolved: completed native sales revenue minus resolved sale-time COGS, less posted operating expenses for the same Jakarta business date. This is not net profit; taxes, owner withdrawals, depreciation, and other non-operating items are outside this V1 model. If gross profit is unavailable or incomplete, operating profit is unavailable too.

Costing Engine v1 is being built separately from reporting. `stock_balance_projection` remains the quantity authority; `inventory_cost_projections` becomes WAC valuation authority only after its outlet is explicitly activated and every stock-affecting writer is integrated. `product_costs.hpp` remains the legacy iPos/reference HPP. See [Costing Engine](COSTING.md) for the foundation and future POS/COGS requirements. Do not report WAC inventory value from a `BOOTSTRAP_READY` snapshot as an active, continuously synchronized valuation.
# Transitional sales source roadmap

Until native Quena Mart POS is production-ready, iPos remains the transaction system of record. A future phase will support importing daily iPos sales reports into Quena Mart for sales analytics/reporting; that importer is not part of Phase 3A. Imported iPos sales and future native POS sales must eventually share a reporting model while retaining source identity, for example `IPOS_IMPORT` and `QUENA_POS`, so totals can be combined without losing provenance.

## Owner Reports V1

`/laporan` is a period analysis workspace. All period dates use `Asia/Jakarta`; custom ranges are inclusive and limited to 366 days. Comparison periods are equal-length immediately preceding windows, except Bulan Ini compares the same elapsed day-of-month range in the previous month (clamped to that month's last day), and Bulan Lalu compares the complete preceding calendar month. When comparison revenue is zero, the UI says no comparison is available instead of displaying a percentage.

- **Omzet** is completed `sales.grand_total` in the selected period.
- **Transaksi** counts completed sales; **rata-rata belanja** is revenue divided by that count (2 decimal precision).
- **COGS** comes only from resolved immutable sale-time `sale_item_cost_evidence`. If the outlet is not `WAC_ACTIVE`, or any sale has absent/non-final item COGS evidence, gross profit, margin, and operating profit remain unavailable. No current HPP/WAC is used to reconstruct historical profit.
- **Laba kotor** is omzet minus resolved sale-time COGS. **Margin kotor** is laba kotor divided by omzet. **Pengeluaran** is only POSTED operational expense evidence for the selected period. **Laba operasional** is laba kotor minus those expenses; this is not net profit.
- Payments are aggregated from payment rows independently of sale items. The response includes a payment-to-sales reconciliation difference so discrepancies are visible.
- Sales trend is daily through 60 days and weekly above 60 days, with zero-sales buckets included. Source totals use current authoritative `sales.source_system` values without assuming future enum members or an iPos importer.
- Top products use immutable product-name/SKU and selling-price line evidence from sale items. Historical category ranking is deferred because the current sale-item schema has no category snapshot; current product categories are not treated as historical truth.
- Inventory and Tempo are labeled **current** snapshots and never follow the selected report period. Inventory value is available only with active WAC and complete current valuation projections. Tempo is finalized TEMPO payable original amount less authoritative payment allocations; invoice drafts are excluded.

The bounded `owner_reports_read` RPC is available to OWNER and ADMIN only and derives its outlet from the single active outlet authority period. KASIR and GUDANG have no report route or RPC access. Future imported sales can join report totals only after being represented by valid authoritative rows in `sales` with preserved source identity; no iPos-sales schema is defined by this checkpoint.
